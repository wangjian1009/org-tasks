// 验证应用目录读取、安装检测和添加面板的响应与重试。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-app-links.cjs\n验证应用目录的并发安装检测、资源失败重试，以及添加面板立即展示、候选复用与错误恢复。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(source, mocks = {}, bindings = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(require,module,exports,' + Object.keys(bindings).join(',') + '){' + code + '\n})')(name => {
    assert.ok(name in mocks, name); return mocks[name];
  }, module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
test('目录应用并发检测，已安装的 HarmonyOS 包可见，未安装项不影响其他应用', async () => {
  const checks = [], gate = deferred();
  const { AppLinkManager } = compile(fs.readFileSync('entry/src/main/ets/services/AppLinkService.ets', 'utf8'), {
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 }, async getBundleInfo(id) {
      checks.push(id); await gate.promise;
      if (id === 'missing') throw new Error('未安装');
      return { appInfo: { iconResource: { id: 1, bundleName: id } } };
    } } },
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString() }) } } },
    './PreferencesStore': { PreferencesStore: {} }
  });
  let fail = true, reads = 0;
  const context = { resourceManager: { async getRawFileContent() {
    reads++; if (fail) throw new Error('资源读取失败');
    return Buffer.from(JSON.stringify({ apps: [{ id: 'com.icbc.harmonyclient', name: '中国工商银行' }, { id: 'com.cmbchina.harmony', name: '招商银行' }, { id: 'missing', name: '未安装' }] }));
  } } };
  await assert.rejects(AppLinkManager.shared.catalog(context), /资源读取失败/);
  fail = false;
  const loading = AppLinkManager.shared.catalog(context); await tick();
  assert.equal(checks.length, 3); gate.resolve();
  assert.deepEqual((await loading).map(app => app.name), ['中国工商银行', '招商银行']);
  await AppLinkManager.shared.catalog(context); assert.equal(reads, 2);
});
function page(manager) {
  const source = fs.readFileSync('entry/src/main/ets/pages/Settings.ets', 'utf8');
  const methods = ['openAppLinkAdd', 'loadAppLinkCandidates'].map(name => {
    const match = source.match(new RegExp('  (?:private )?async ' + name + '\\([^\\n]*\\)[^\\n]* \\{[\\s\\S]*?\\n  \\}'));
    assert.ok(match, name); return match[0];
  });
  const { Page } = compile('export class Page {' + methods.join('\n') + '}', {}, { AppLinkManager: { shared: manager } });
  return Object.assign(new Page(), { appLinkCandidates: [], getUIContext: () => ({ getHostContext: () => ({}) }) });
}
test('添加面板立即打开，无需任务查询，连续打开复用候选与已有关联', async () => {
  const gate = deferred(); let reads = 0;
  const state = page({ async catalog() { reads++; await gate.promise; return [{ name: '招商银行', id: 'com.cmbchina.harmony', iconResource: { id: 1 } }]; }, async load() { return [{ name: '招商银行' }]; } });
  const opening = state.openAppLinkAdd();
  assert.equal(state.appLinkAddOpen, true); assert.equal(state.appLinkAddBusy, true);
  await state.openAppLinkAdd(); assert.equal(reads, 1);
  gate.resolve(); await opening;
  assert.equal(state.appLinkCandidates[0].name, '招商银行'); assert.equal(state.appLinkCandidates[0].selected, true);
  await state.openAppLinkAdd(); assert.equal(reads, 1);
});
test('候选读取失败保留面板，重试后恢复，不把错误缓存为空目录', async () => {
  let fail = true;
  const state = page({ async catalog() { if (fail) throw new Error('资源错误'); return []; }, async load() { return []; } });
  await state.openAppLinkAdd();
  assert.equal(state.appLinkAddOpen, true); assert.match(state.appLinkCandidateError, /读取失败/);
  assert.equal(state.appLinkCandidatesLoaded, undefined); assert.equal(state.appLinkAddBusy, false);
  fail = false; await state.openAppLinkAdd();
  assert.equal(state.appLinkCandidatesLoaded, true); assert.equal(state.appLinkCandidateError, '');
});
