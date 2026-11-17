// 验证 APP 临时测试入口与服务生命周期；网络与事件由 Rust 集成测试覆盖。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-http-api.cjs\n验证普通启动不开服务、测试启动参数、生命周期串行、配置重绑与启动失败。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(name, mocks, globals = {}) {
  const file = path.resolve('entry/src/main/ets', name + '.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(code, { module, exports: module.exports, require(name) {
    if (name.endsWith('/PagePath')) return require('./helpers/page-navigator.cjs').pagePathModule;
    if (name.endsWith('/EntryNavigation')) return require('./helpers/page-navigator.cjs').entryNavigationModule;
    if (name.endsWith('/PageNavigator')) return require('./helpers/page-navigator.cjs').pageNavigatorMock;
    if (name.endsWith('/SystemRepositoryService')) return {SystemRepositoryService:{ensure:async()=>({id:'org-tasks-system',rootDirectory:'/system'})}};
    assert.ok(name in mocks, '缺少替身 ' + name); return mocks[name];
  }, console: { info() {}, error() {} }, ...globals }, { filename: file });
  return module.exports;
}
function fixture() {
  let current, failure; const calls = [], watchers = new Set(), handlers = [], activeChecks = [];
  function workspace(name) { return { async startHttpServer(port, handler) {
    handlers.push(handler);
    calls.push(['start', name, port]); if (failure) throw failure; return { address: '127.0.0.1:8787' };
  }, async stopHttpServer() { calls.push(['stop', name]); } }; }
  current = workspace('a');
  const Service = load('services/HttpApiService', {
    './HttpNavigationService': { HttpNavigationService: { async handle(_, request, active) { activeChecks.push(active); return { status: 200, body: '{}' }; } } },
    './AppConfigService': { AppConfigService: { async load(context, credentials) {
      assert.equal(credentials, false); return { repos: [] };
    }, watchChanges(fn) { watchers.add(fn); }, stopWatchingChanges(fn) { watchers.delete(fn); } } },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return current; } } }
  }).HttpApiService;
  return { Service, calls, watchers, handlers, activeChecks, change() { current = workspace('b'); for (const fn of watchers) fn(); }, fail(value) { failure = value; } };
}
test('服务启停排队，停止后配置变化不会重新启动', async () => {
  const f = fixture();
  await Promise.all([f.Service.start({}), f.Service.stop()]);
  assert.deepEqual(f.calls, [['start', 'a', 8787], ['stop', 'a']]);
  assert.equal(f.watchers.size, 0);
  f.change(); await f.Service.stop();
  assert.equal(f.calls.length, 2);
});
test('配置变化停止旧 Workspace 并在当前 Workspace 启动', async () => {
  const f = fixture(); await f.Service.start({}); f.change();
  await f.Service.stop();
  assert.deepEqual(f.calls, [['start','a',8787], ['stop','a'], ['start','b',8787], ['stop','b']]);
});
test('监听失败拒绝启动并清理配置监听，之后可以重试', async () => {
  const f = fixture(); f.fail(new Error('端口占用'));
  await assert.rejects(f.Service.start({}), /端口占用/);
  assert.equal(f.watchers.size, 0);
  f.fail(undefined); await f.Service.start({}); await f.Service.stop();
  assert.equal(f.calls.length, 3);
});
test('普通启动不启用 HTTP，仅显式布尔测试参数生效，销毁停止', async () => {
  let starts = 0, stops = 0;
  const Ability = load('entryability/EntryAbility', {
    '../services/NativeCoreService': { NativeCoreService: { start() {} } },
    '@kit.AbilityKit': { UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 1 } } },
    '../services/NotificationManager': { NotificationManager: { async start() {}, async refresh() {}, stop() {} } },
    '../services/HttpApiService': { HttpApiService: { attachWindow() {}, async start() { starts++; }, async stop() { stops++; } } },
    '../services/LegacySyncScheduleService': { LegacySyncScheduleService: { async remove() {} } },
    '../services/BackgroundRepositorySyncService': {},
    '../services/RepositorySyncService': { emptyRepositorySyncState() { return {}; } },
    '../services/DeviceBadgeService': { DeviceBadgeService: { stop() {} } },
    '../services/DataSetManager': {},
    '../services/NotificationPermissionService': { NotificationPermissionService: { stop() {} } },
    '../ui/Theme': {}
  }, { AppStorage: { has() { return true; } } }).default;
  const ability = new Ability(); ability.context = { getApplicationContext() { return { setColorMode() {} }; } };
  await ability.onCreate({}, {}); assert.equal(starts, 0);
  await ability.onCreate({ parameters: { httpApiEnabled: 'true' } }, {}); assert.equal(starts, 0);
  await ability.onCreate({ parameters: { httpApiEnabled: true } }, {}); assert.equal(starts, 1);
  ability.onNewWant({}, {}); assert.equal(starts, 1);
  ability.onNewWant({ parameters: { httpApiEnabled: false } }, {}); assert.equal(stops, 1);
  ability.onNewWant({ parameters: { httpApiEnabled: true } }, {}); assert.equal(starts, 2);
  ability.onDestroy(); assert.equal(stops, 2);
});


test('主窗口处理器复用同一监听；服务停止重启后旧请求会话失效', async () => {
  const f = fixture();
  f.Service.attachWindow({ async getMainWindow() { return { getUIContext() { return {}; } }; } });
  await f.Service.start({});
  const responses = [];
  f.handlers[0]({ method: 'GET', body: 'null' }, value => responses.push(value));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(responses[0].status, 200); assert.equal(f.activeChecks[0](), true);
  await f.Service.stop(); await f.Service.start({});
  assert.equal(f.activeChecks[0](), false);
  f.handlers[1]({ method: 'GET', body: 'null' }, value => responses.push(value));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.activeChecks[1](), true);
  await f.Service.stop();
});
