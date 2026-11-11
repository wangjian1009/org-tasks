const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-notification-permission.cjs\n验证首次通知授权、拒绝后不重复请求、前后台取消、技术失败重试、系统设置与主窗口就绪时序。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}
function load(name, mocks, globals = {}) {
  const filename = path.resolve('entry/src/main/ets', name + '.ets');
  const output = ts.transpileModule(globals.source ?? fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,LocalStorage,setTimeout,clearTimeout){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    throw new Error('缺少平台替身: ' + name);
  }, module, module.exports, globals.LocalStorage, globals.setTimeout ?? setTimeout, globals.clearTimeout ?? clearTimeout);
  return module.exports;
}
function fixture(values = new Map()) {
  let enabled = false, response = 'allow', calls = 0, opens = 0, badges = 0, checks = 0;
  let gate, checkGate, flushGate, failStorage = false;
  const context = {}, events = [];
  const store = {
    async get(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
    async put(key, value) { values.set(key, value); },
    async flush() {
      if (failStorage) throw new Error('保存失败');
      const current = flushGate; flushGate = undefined;
      if (current) await current.promise;
      events.push('flush');
    }
  };
  const service = load('services/NotificationPermissionService', {
    '@kit.NotificationKit': { notificationManager: {
      async isNotificationEnabled() {
        checks++;
        const current = checkGate; checkGate = undefined;
        if (current) await current.promise;
        return enabled;
      },
      async requestEnableNotification(actual) {
        assert.equal(actual, context);
        assert.equal(values.get('notificationPromptHandled'), true);
        assert.equal(events.at(-1), 'flush');
        calls++;
        const current = gate; gate = undefined;
        if (current) await current.promise;
        if (response === 'deny') throw { code: 1600004 };
        if (response === 'error') throw { code: 1600003 };
        enabled = true;
      },
      async openNotificationSettings(actual) { assert.equal(actual, context); opens++; }
    } },
    './PreferencesStore': { PreferencesStore: { async open(actual, name) {
      assert.equal(actual, context); assert.equal(name, 'org_tasks_notification'); return store;
    } } },
    './DeviceBadgeService': { DeviceBadgeService: { async refresh(actual) { assert.equal(actual, context); badges++; } } }
  }).NotificationPermissionService;
  return { service, context, values, events,
    start() { return service.start(context); }, manage() { return service.manage(context); }, state() { return service.state(context); },
    enabled(value) { enabled = value; }, response(value) { response = value; },
    hold(value) { gate = value; }, holdCheck(value) { checkGate = value; }, holdFlush(value) { flushGate = value; },
    failStorage(value = true) { failStorage = value; }, counts() { return { calls, opens, badges, checks }; } };
}

test('首次前台请求前先持久化标记，允许后立即刷新角标', async () => {
  const f = fixture(); assert.equal(await f.state(), 'unrequested');
  await f.start(); assert.equal(await f.state(), 'enabled');
  assert.equal(f.values.get('notificationPromptHandled'), true);
  assert.equal(f.counts().calls, 1); assert.equal(f.counts().badges, 1);
  await f.start(); assert.equal(f.counts().calls, 1);
});

test('拒绝后重启进程不自动请求，主动入口打开系统设置', async () => {
  const f = fixture(); f.response('deny'); await f.start();
  assert.equal(await f.state(), 'disabled'); assert.equal(f.counts().badges, 0);
  f.service.stop(); await f.start(); assert.equal(f.counts().calls, 1);
  const restarted = fixture(f.values); await restarted.start();
  assert.equal(restarted.counts().calls, 0); await restarted.manage();
  assert.equal(restarted.counts().opens, 1); assert.equal(restarted.counts().calls, 0);
});

test('旧用户已允许则补记标记，之后系统撤销也不自动请求', async () => {
  const f = fixture(); f.enabled(true); await f.start();
  assert.equal(f.values.get('notificationPromptHandled'), true); assert.equal(f.counts().calls, 0);
  f.enabled(false); assert.equal(await f.state(), 'disabled');
  await f.start(); assert.equal(f.counts().calls, 0);
  f.enabled(true); await f.start(); assert.equal(f.counts().badges, 2);
});

test('技术失败撤回首次标记，不当成拒绝，后续允许重试', async () => {
  const f = fixture(); f.response('error');
  await assert.rejects(f.start(), /1600003/); assert.equal(await f.state(), 'unrequested');
  f.response('allow'); await f.manage(); assert.equal(f.counts().calls, 2); assert.equal(f.counts().badges, 1);
});

test('本地标记保存失败不能发起系统弹窗', async () => {
  const f = fixture(); f.failStorage(); await assert.rejects(f.start(), /保存失败/);
  assert.equal(f.counts().calls, 0);
  assert.equal(await f.state(), 'unrequested');
  f.failStorage(false); await f.manage(); assert.equal(f.counts().calls, 1);
});

test('读取状态期间退到后台，不消费首次请求机会', async () => {
  const f = fixture(), gate = deferred(); f.holdCheck(gate);
  const running = f.start(); await tick(); f.service.stop(); gate.resolve(); await running;
  assert.equal(f.counts().calls, 0); assert.equal(f.values.has('notificationPromptHandled'), false);
  await f.manage(); assert.equal(f.counts().opens, 0); assert.equal(f.counts().calls, 0);
  await f.start(); assert.equal(f.counts().calls, 1);
});

test('标记落盘期间退到后台会撤回标记，恢复前台后仍可请求', async () => {
  const f = fixture(), gate = deferred(); f.holdFlush(gate);
  const running = f.start(); await tick(); f.service.stop(); gate.resolve(); await running;
  assert.equal(f.counts().calls, 0); assert.equal(f.values.get('notificationPromptHandled'), false);
  await f.start(); assert.equal(f.counts().calls, 1);
});

test('授权窗口未完成时重复前台检查串行执行，最多一个系统授权窗口', async () => {
  const f = fixture(), gate = deferred(); f.hold(gate);
  const first = f.start(); await tick();
  const second = f.start(); await tick(); assert.equal(f.counts().calls, 1);
  gate.resolve(); await Promise.all([first, second]); assert.equal(f.counts().calls, 1);
});

test('从系统设置返回重新读取授权状态，已开启时刷新角标', async () => {
  const f = fixture(); f.response('deny'); await f.start(); await f.manage();
  assert.equal(f.counts().opens, 1); f.enabled(true); await f.start();
  assert.equal(await f.state(), 'enabled'); assert.equal(f.counts().badges, 1);
});

test('主窗口与前台两个条件均满足才检查授权，后台及销毁停止请求', async () => {
  const starts = [], stops = [], loads = [];
  const Ability = load('entryability/EntryAbility', {
    '@kit.AbilityKit': { UIAbility: class {} },
    '@kit.ArkData': { preferences: {} },
    '../services/BackgroundSyncService': { BackgroundSyncService: {} },
    '../services/RepositorySyncService': { emptyRepositorySyncState() {} },
    '../services/DeviceBadgeService': { DeviceBadgeService: { start() {}, stop() {} } },
    '../services/NotificationPermissionService': { NotificationPermissionService: {
      async start(context) { starts.push(context); }, stop() { stops.push(true); }
    } },
    '../ui/Theme': { UiColor: {} }
  }, { LocalStorage: class {} }).default;
  const ability = new Ability(); ability.context = {};
  const stage = { async getMainWindow() { return { async setWindowSystemBarProperties() {} }; },
    loadContent(page, storage, done) { loads.push(done); } };
  ability.onForeground(); assert.equal(starts.length, 0);
  await ability.onWindowStageCreate(stage); assert.equal(starts.length, 0);
  ability.onBackground(); loads[0]({ code: 0 }); assert.equal(starts.length, 0);
  ability.onForeground(); assert.deepEqual(starts, [ability.context]);
  ability.onDestroy(); assert.equal(stops.length, 2);
});

function settingsFixture() {
  const filename = path.resolve('entry/src/main/ets/pages/Settings.ets');
  const source = fs.readFileSync(filename, 'utf8').split('  build()')[0]
    .replace(/@Entry\n|@Component\n|@State /g, '')
    .replace('struct Settings', 'export class Settings') + '}';
  const timers = new Map();
  let state = 'enabled', refreshed = 0, reads = 0, readGate, nextId = 1, foreground = true;
  const Settings = load('pages/Settings', {
    '../models/OrgTask': { DEFAULT_CONFIG: {} },
    '../services/BackgroundSyncService': {}, '../services/AppConfigService': {},
    '../services/NativeCoreService': { coreErrorMessage: error => error.message },
    '../ui/Theme': {}, '../services/FileTargetService': {},
    '../services/NotificationPermissionService': { NotificationPermissionService: {
      isForeground() { return foreground; },
      async state() { reads++; const result = state, gate = readGate; readGate = undefined; if (gate) await gate.promise; return result; },
      async refresh() { refreshed++; return state; }
    } }
  }, { source, setTimeout(callback, delay) { assert.equal(delay, 1000); const id = nextId++; timers.set(id, callback); return id; },
    clearTimeout(id) { timers.delete(id); } }).Settings;
  const settings = new Settings();
  settings.load = async () => {};
  settings.getUIContext = () => ({ getHostContext: () => ({}) });
  return { settings, timers, state(value) { state = value; }, refreshed: () => refreshed, reads: () => reads,
    foreground(value) { foreground = value; }, holdRead(gate) { readGate = gate; },
    async advance() { const [id, callback] = timers.entries().next().value; timers.delete(id); await callback(); } };
}

test('半屏系统设置改变权限后定期重读状态，仅重新开启时重算角标', async () => {
  const f = settingsFixture(); f.settings.section = '应用程序'; f.settings.onPageShow(); await tick();
  assert.equal(f.settings.notificationState, 'enabled'); assert.equal(f.timers.size, 1);
  f.state('disabled'); await f.advance();
  assert.equal(f.settings.notificationState, 'disabled'); assert.equal(f.refreshed(), 0);
  f.state('enabled'); await f.advance(); assert.equal(f.settings.notificationState, 'enabled');
  assert.equal(f.refreshed(), 1); await f.advance(); assert.equal(f.refreshed(), 1);
  f.settings.onPageHide(); assert.equal(f.timers.size, 0);
});

test('页面隐藏时停止定时检查，旧读取不覆盖重新显示后的状态', async () => {
  const f = settingsFixture(), read = deferred();
  f.holdRead(read); f.settings.onPageShow(); await tick();
  f.settings.onPageHide(); assert.equal(f.timers.size, 0);
  f.state('disabled'); f.settings.onPageShow(); await tick();
  assert.equal(f.settings.notificationState, 'disabled'); assert.equal(f.timers.size, 1);
  read.resolve(); await tick(); assert.equal(f.settings.notificationState, 'disabled');
  f.settings.aboutToDisappear(); assert.equal(f.timers.size, 0);
});

test('其他设置分组与应用后台不定期读取权限', async () => {
  const f = settingsFixture(); f.settings.onPageShow(); await tick();
  const before = f.reads(); await f.advance(); assert.equal(f.reads(), before);
  f.settings.section = '应用程序'; f.foreground(false); await f.advance(); assert.equal(f.reads(), before);
  f.foreground(true); await f.advance(); assert.equal(f.reads(), before + 1);
  f.settings.onPageHide();
});
