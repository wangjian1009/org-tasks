// 固定应用签名；本地密钥库与 Keychain 密码配套使用。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync, spawn } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const mode = process.argv[2];
const deveco = process.argv[3];
const template = path.join(root, 'build-profile.json5.example');
const buildProfile = path.join(root, 'build-profile.json5');
const local = path.join(root, '.signing');
let build;
let generatedProfile = false;

function checked(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.error || result.status !== 0) {
    throw new Error(result.error?.message || result.stderr?.trim() || '签名准备命令执行失败。');
  }
  return result.stdout;
}

function cleanup() {
  if (generatedProfile) {
    fs.copyFileSync(template, buildProfile);
    fs.chmodSync(buildProfile, 0o600);
    generatedProfile = false;
  }
}

async function main() {
  if (!['debug', 'release'].includes(mode) || !deveco) {
    throw new Error('通过 make build 或 make release 执行构建。');
  }
  const config = JSON.parse(fs.readFileSync(template, 'utf8'));
  const material = config.app.signingConfigs[0].material;
  const certificate = path.join(root, material.certpath);
  const profile = path.join(root, material.profile);
  const chain = fs.readFileSync(certificate, 'utf8').match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g);
  if (!chain?.length) throw new Error('应用证书链为空。');
  const leaf = new crypto.X509Certificate(chain[chain.length - 1]);
  const now = Date.now();
  if (now < Date.parse(leaf.validFrom) || now >= Date.parse(leaf.validTo)) {
    throw new Error('应用证书尚未生效或已过期，请更新 signing 中的证书与 Profile。');
  }
  const provision = JSON.parse(checked('/opt/homebrew/bin/openssl',
    ['cms', '-verify', '-inform', 'DER', '-in', profile, '-noverify']));
  const app = JSON.parse(fs.readFileSync(path.join(root, 'AppScope/app.json5'), 'utf8'));
  if (provision['bundle-info']['bundle-name'] !== app.app.bundleName || provision.type !== 'debug') {
    throw new Error('调试 Profile 的包名或类型与项目不匹配。');
  }
  if (now / 1000 < provision.validity['not-before'] || now / 1000 >= provision.validity['not-after']) {
    throw new Error('调试 Profile 尚未生效或已过期。');
  }
  const profileCertificate = new crypto.X509Certificate(provision['bundle-info']['development-certificate']);
  if (!leaf.publicKey.equals(profileCertificate.publicKey)) {
    throw new Error('应用证书与 Profile 不配套。');
  }
  fs.mkdirSync(local, { recursive: true, mode: 0o700 });
  const store = path.join(root, material.storeFile);
  if (!fs.existsSync(store)) throw new Error('缺少 signing/org-tasks.p12，请恢复签名密钥库。');
  const password = checked('/usr/bin/security',
    ['find-generic-password', '-s', 'org-tasks-signing', '-a', 'development', '-w']).replace(/\n$/, '');
  const keytool = path.join(deveco, 'jbr/Contents/Home/bin/keytool');
  const secretEnv = { ...process.env, ORG_TASKS_KEYSTORE_PASSWORD: password };
  const args = ['-keystore', store, '-storetype', 'PKCS12', '-storepass:env', 'ORG_TASKS_KEYSTORE_PASSWORD'];
  const exportedCertificate = new crypto.X509Certificate(checked(keytool,
    ['-exportcert', '-rfc', '-alias', material.keyAlias, ...args], { env: secretEnv }));
  if (!leaf.publicKey.equals(exportedCertificate.publicKey)) {
    throw new Error('本地密钥库与应用证书不匹配。');
  }
  material.storeFile = store;
  // Hvigor 只编译 unsigned HAP，随后单独签名，密码通过 stdin 传递。
  config.app.signingConfigs = [];
  for (const product of config.app.products) delete product.signingConfig;
  fs.writeFileSync(buildProfile, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  generatedProfile = true;
  fs.chmodSync(buildProfile, 0o600);
  console.log('>>> 使用本地 p12、Keychain 密码和 signing 中的调试签名材料');
  const hvigor = path.join(deveco, 'tools/hvigor/bin/hvigorw');
  // 两个任务均依赖 PackageHap；保留打包检查和符号收集，签名由下方独立完成。
  const parameters = ['default@PackingCheck', 'default@CollectDebugSymbol',
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', `buildMode=${mode}`];
  if (mode === 'debug') parameters.push('-p', 'debuggable=true');
  parameters.push('--no-daemon');
  const status = await new Promise((resolve, reject) => {
    build = spawn(hvigor, parameters, { cwd: root, stdio: 'inherit' });
    build.once('error', reject);
    build.once('exit', (code, signal) => resolve(code ?? (signal ? 1 : 0)));
  });
  if (status !== 0) {
    process.exitCode = status;
    return;
  }
  const jar = path.join(deveco, 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar');
  const java = path.join(deveco, 'jbr/Contents/Home/bin');
  const source = path.join(__dirname, 'OrgTasksHapSigner.java');
  checked(path.join(java, 'javac'), ['-encoding', 'UTF-8', '-cp', jar, '-d', local, source]);
  const output = path.join(root, 'entry/build/default/outputs/default');
  const unsigned = path.join(output, 'entry-default-unsigned.hap');
  const signed = path.join(output, 'entry-default-signed.hap');
  // 先移除旧产物，避免签名失败后安装过期 HAP。
  if (fs.existsSync(signed)) fs.unlinkSync(signed);
  const version = String(config.app.products[0].compatibleSdkVersion);
  const compatible = /^\d+$/.test(version) ? version : version.match(/\((\d+)\)/)?.[1];
  if (!compatible) throw new Error('无法确定 HAP 签名使用的兼容 API 版本。');
  const payload = Buffer.from(password);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(payload.length);
  const result = checked(path.join(java, 'java'), ['-cp', `${local}:${jar}`, 'OrgTasksHapSigner',
    'sign-app', '-mode', 'localSign', '-keyAlias', material.keyAlias,
    '-appCertFile', certificate, '-profileFile', profile, '-keystoreFile', store,
    '-inFile', unsigned, '-outFile', signed, '-signAlg', material.signAlg,
    '-compatibleVersion', compatible], { input: Buffer.concat([length, payload]) });
  if (result) process.stdout.write(result);
  if (!fs.existsSync(signed)) throw new Error('签名工具没有生成已签名 HAP。');
  console.log('>>> 已生成签名 HAP');
}

process.once('exit', cleanup);
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    if (build) build.kill(signal);
    else {
      cleanup();
      process.exit(signal === 'SIGINT' ? 130 : 143);
    }
  });
}
main().catch(error => {
  console.error(`构建失败：${error.message}`);
  process.exitCode = 1;
}).finally(cleanup);
