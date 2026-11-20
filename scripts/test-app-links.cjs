// 验证应用目录、安装检测和应用绑定。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-app-links.cjs\n验证内置应用目录、链接选择的安装检测、设置页候选和错误恢复。');
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
      if (id === 'missing') throw Object.assign(new Error('未安装'), { code: 17700001 });
      if (id === 'unknown') throw Object.assign(new Error('权限不足'), { code: 201 });
      return { appInfo: { iconResource: { id: 1, bundleName: id } } };
    } } },
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString() }) } } },
    './PreferencesStore': { PreferencesStore: {} }
  });
  let fail = true, reads = 0;
  const context = { resourceManager: { async getRawFileContent() {
    reads++; if (fail) throw new Error('资源读取失败');
    const launch = { moduleName: 'entry', abilityName: 'EntryAbility' };
    return Buffer.from(JSON.stringify({ apps: [
      { id: 'com.icbc.harmonyclient', name: '中国工商银行', launch },
      { id: 'com.cmbchina.harmony', name: '招商银行', launch },
      { id: 'missing', name: '未安装', launch },
      { id: 'unknown', name: '无法查询', launch },
      { id: 'unconfigured', name: '启动参数待验证' }
    ] }));
  } } };
  await assert.rejects(AppLinkManager.shared.catalog(context), /资源读取失败/);
  fail = false;
  assert.deepEqual((await AppLinkManager.shared.catalog(context)).map(app => app.name), ['中国工商银行', '招商银行', '未安装', '无法查询', '启动参数待验证']);
  assert.equal(checks.length, 0);
  const loading = AppLinkManager.shared.bindingCandidates(context, '招商银行'); await tick();
  assert.equal(checks.length, 4); gate.resolve();
  assert.deepEqual((await loading).map(app => app.name), ['招商银行', '中国工商银行', '无法查询']);
  assert.ok((await AppLinkManager.shared.catalog(context)).every(app => !app.iconResource));
  assert.equal((await AppLinkManager.shared.targetStatus('missing')).availability, 'missing');
  assert.equal((await AppLinkManager.shared.targetStatus('unknown')).availability, 'unknown');
  assert.equal(reads, 2);
});
function page(manager) {
  const source = fs.readFileSync('entry/src/main/ets/pages/Settings.ets', 'utf8');
  const methods = ['appLinkNames', 'appLinkBundle', 'chooseAppLink', 'loadAppLinkCandidates', 'bindAppLink'].map(name => {
    const match = source.match(new RegExp('  (?:private )?(?:async )?' + name + '\\([^\\n]*\\)[^\\n]* \\{[\\s\\S]*?\\n  \\}'));
    assert.ok(match, name); return match[0];
  });
  const { Page } = compile('export class Page {' + methods.join('\n') + '}', {},
    { AppLinkManager: { shared: manager } });
  return Object.assign(new Page(), { appLinkCandidates: [], appLinks: [], requiredAppLinks: [],
    getUIContext: () => ({ getHostContext: () => ({}) }), refreshAppLinks: async () => {} });
}
test('列表合并已保存的关联与有启动配置的文档引用，同名项只显示一次', () => {
  const state = page({});
  state.appLinks = [{ name: '中国工商银行' }, { name: '中国建设银行' }];
  state.requiredAppLinks = ['中国工商银行', '中国银行', '中国银行', '平安银行', '未知应用', '无启动项'];
  const { apps } = require('../entry/src/main/resources/rawfile/app-links/apps.json');
  state.appLinkCatalog = apps.concat([{ name: '无启动项' }]);
  assert.deepEqual(state.appLinkNames(), ['中国工商银行', '中国建设银行', '中国银行', '平安银行']);
});
test('已绑定与未绑定的行复用选择面板，点选应用只保存关系', async () => {
  const gate = deferred();
  const { apps } = require('../entry/src/main/resources/rawfile/app-links/apps.json');
  const [current, replacement] = apps;
  const writes = [];
  const state = page({
    async bindingCandidates(_context, name) {
      assert.equal(name, '中国银行'); await gate.promise; return [current, replacement];
    },
    async bind(_context, name, bundleName) { writes.push({ name, bundleName }); }
  });
  state.appLinks = [{ name: '中国银行', bundleName: current.id }];
  const opening = state.chooseAppLink('中国银行');
  assert.equal(state.appLinkPickerOpen, true);
  assert.equal(state.appLinkPickerBundle, current.id);
  assert.equal(state.appLinkPickerBusy, true);
  gate.resolve(); await opening;
  await state.bindAppLink(replacement);
  assert.equal(state.appLinkPickerOpen, false);
  assert.deepEqual(writes, [{ name: '中国银行', bundleName: replacement.id }]);
});

test('历史关联只读取绑定关系，启动参数取当前目录，重绑仅保存名称与目标', async () => {
  const catalog = require('../entry/src/main/resources/rawfile/app-links/apps.json');
  const [icbc, ccb] = catalog.apps;
  let stored = JSON.stringify([{ name: '银行', bundleName: icbc.id, moduleName: 'old', abilityName: 'Old' }]);
  const { AppLinkManager, openAppLink } = compile(fs.readFileSync('entry/src/main/ets/services/AppLinkService.ets', 'utf8'), {
    '@kit.AbilityKit': {}, '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString() }) } } },
    './PreferencesStore': { PreferencesStore: { async open() { return {
      async get() { return stored; },
      async put(_key, value) { stored = value; },
      async flush() {}
    }; } } }
  });
  const wants = [];
  const context = {
    resourceManager: { async getRawFileContent() { return Buffer.from(JSON.stringify(catalog)); } },
    async startAbility(want) { wants.push(want); }
  };
  const manager = AppLinkManager.shared;
  const legacy = await manager.find(context, '银行');
  assert.deepEqual(legacy, { name: '银行', bundleName: icbc.id });
  await openAppLink(context, legacy, 'app:银行');
  assert.deepEqual(wants, [{ bundleName: icbc.id, ...icbc.launch }]);
  await manager.bind(context, '银行', ccb.id);
  assert.deepEqual(JSON.parse(stored), [{ name: '银行', bundleName: ccb.id }]);
  await assert.rejects(manager.bind(context, '银行', 'com.example.unlisted'), /启动配置/);
  assert.equal(wants.length, 1);
});
test('候选读取失败保留面板，重试后恢复', async () => {
  let fail = true;
  const state = page({ async bindingCandidates() { if (fail) throw new Error('资源错误'); return []; } });
  await state.chooseAppLink('中国银行');
  assert.equal(state.appLinkPickerOpen, true);
  assert.match(state.appLinkCandidateError, /读取失败/);
  assert.equal(state.appLinkPickerBusy, false);
  fail = false; await state.loadAppLinkCandidates();
  assert.equal(state.appLinkCandidateError, '');
});
