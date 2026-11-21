const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-background-sync.cjs\n验证同步启动策略、启动远端变化检查、非阻塞队列、退后台共享通知判断、系统实况窗、资源释放与失败重试。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets/services');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}
function compile(name, dependencies, globals = {}) {
  const filename = path.join(root, name + '.ets');
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  const context = vm.createContext({ module, exports: module.exports, require: dependencies,
    console: { info() {}, error() {} }, setTimeout, clearTimeout, ...globals });
  vm.runInContext(source, context, { filename });
  return module.exports;
}
function fixture() {
  const calls = [], notifications = [], timers = new Map(), states = [], reasons = [], inputs = [];
  const syncSteps = [];
  let badgeFailure = false;
  let changed = true, syncFailure = false, publishFailure = false, retainFailure = false;
  let notificationMisses = 0;
  let checkGate, flushGate, syncGate, retainGate, expiry;
  let monitor;
  const config = { repos: [{ id: 'host-a', rootDirectory: '/a', webdavEnabled: true }],
    todoDefaults: 'TODO DONE', coreSettings: { additionStates: [] } };
  const task = { notificationId: 77, continuousTaskId: 33, slotType: 4, contentType: 5 };
  const background = {
    requestSuspendDelay(reason, callback) { calls.push('delay'); expiry = callback; return { requestId: 5 }; },
    cancelSuspendDelay(id) { assert.equal(id, 5); calls.push('cancelDelay'); },
    async startBackgroundRunning(context, modes) {
      assert.deepEqual(Array.from(modes), ['dataTransfer']); calls.push('retain');
      if (retainGate) await retainGate.promise;
      if (retainFailure) throw new Error('后台权限失败');
      return task;
    },
    async stopBackgroundRunning(context, id) { assert.equal(id, 33); calls.push('release'); }
  };
  const native = {
    NativeCoreService: {
      async workspaceFor(){calls.push('workspace');return{query(){throw new Error('本地启动不应重新查询')}}},
      async syncWorkspaceWebDav(repos, callback, todoDefaults, coreSettings, source) {
        reasons.push(source); inputs.push(todoDefaults);
        calls.push('sync'); monitor = callback;
        callback({ type: 'fileStarted', index: 0, total: 2, path: 'a.org' });
        callback({ type: 'fileProcessed', path: 'a.org' });
        const step = syncSteps.shift();
        if (step) { await step.gate.promise; if (step.failed) throw new Error('网络不可用'); }
        else if (syncGate) await syncGate.promise;
        if (syncFailure) throw new Error('网络不可用');
        changed = false;
        callback({ type: 'finished', result: 'succeeded' });
        return [];
      }
    }, coreErrorMessage: e => e.message
  };
  const cache = {};
  function load(dependency) {
    if (dependency === 'liborg_tasks_harmony.so' || dependency === '@kit.AbilityKit') {
      return { wantAgent: { async getWantAgent() { return {}; }, OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } };
    }
    if (dependency === '@kit.BackgroundTasksKit') return { backgroundTaskManager: background };
    if (dependency === '@kit.NotificationKit') return { notificationManager: {
      ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5, NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
      async getActiveNotifications() {
        if (notificationMisses-- > 0) return [];
        return [{ id: 77, label: 'system', content: { notificationContentType: 5,
        systemLiveView: { typeCode: 8, title: '系统任务', text: '' } } }]; },
      async publish(request) {
        if (publishFailure) throw new Error('通知服务失败');
        assert(!calls.includes('release'), '释放后台任务后不能再更新实况窗');
        notifications.push(request);
      }
    } };
    if (dependency === './AppConfigService') return { AppConfigService: { async load(context, credentials) {
      calls.push(credentials === false ? 'configWithoutCredentials' : 'configWithCredentials'); return config;
    } } };
    if (dependency === './DeviceBadgeService') return { DeviceBadgeService: { async refresh() { calls.push('badge'); if (badgeFailure) throw new Error('角标失败'); } } };
    if (dependency === './NativeCoreService') return native;
    if (dependency === './NotificationManager') return { NotificationManager: { hasMissingRepository(){return false;}, subscribe(listener) {
      calls.push('check');
      let watching = true;
      const deliver = () => { if (watching) listener({ notifications: changed ? [{ type: 'syncRequired' }] : [] }); };
      if (checkGate) checkGate.promise.then(deliver); else deliver();
      return () => { watching = false; };
    } } };
    if (dependency === './DataSetManager') return { DataSetManager: { async reloadRepositories() {}, async flushAll() { calls.push('flush'); if (flushGate) await flushGate.promise; } } };
    if (dependency === '../models/OrgTask') return {};
    if (dependency.startsWith('./')) {
      const name = dependency.slice(2);
      return cache[name] ??= compile(name, load, {
        AppStorage: { setOrCreate(key, state) { states.push(state); } },
        setTimeout(callback) { const id = timers.size + 1; timers.set(id, callback); return id; },
        clearTimeout(id) { timers.delete(id); }
      });
    }
    throw new Error('缺少替身: ' + dependency);
  }
  return { service: load('./BackgroundRepositorySyncService').BackgroundRepositorySyncService,
    repository: load('./RepositorySyncService').RepositorySyncService,
    calls, notifications, timers, states, reasons, inputs, config, syncSteps,
    badgeFail() { badgeFailure = true; },
    context: { abilityInfo: { bundleName: 'com.example.orgtasks' } },
    change(value) { changed = value; }, syncFail(value) { syncFailure = value; }, publishFail() { publishFailure = true; },
    retainFail() { retainFailure = true; }, holdFlush(gate) { flushGate = gate; }, holdCheck(gate) { checkGate = gate; }, holdSync(gate) { syncGate = gate; },
    delayNotification() { notificationMisses = 1; },
    holdRetain(gate) { retainGate = gate; }, expire() { expiry(); },
    progress(event) { monitor(event); },
    async flushTimers() { for (const [id, callback] of [...timers]) { timers.delete(id); callback(); } await tick(); }
  };
}

test('共享同步保留最初请求入口，退后台新会话使用后台入口', async () => {
  for (const reason of ['startup', 'manual']) {
    const f = fixture(), gate = deferred(); f.holdSync(gate);
    const running = f.repository.start(f.context, { source: reason, policy: 'Reuse' }).handle;
    await tick();
    const background = f.service.start(f.context);
    const rejected = f.repository.start(f.context, { source: 'background', policy: 'Reject' });
    assert.equal(rejected.kind, 'rejected'); assert.equal(rejected.active, running);
    gate.resolve(); await Promise.all([running.completion, background]);
    assert.deepEqual(f.reasons, [reason]);
  }
  const f = fixture(); await f.service.start(f.context);
  assert.deepEqual(f.reasons, ['background']);
});

test('start 立即受理并保留会话，Reuse 与 Reject 不再启动新同步', async () => {
  const f = fixture(), gate = deferred(); f.holdSync(gate);
  const first = f.repository.start(f.context, { source: 'startup', policy: 'Reuse' });
  assert.equal(first.kind, 'started'); assert.equal(first.then, undefined);
  assert.equal(f.repository.runningSync(), first.handle);
  assert.equal(f.calls.length, 0, '请求受理时不读取配置或执行同步');
  const reused = f.repository.start(f.context, { source: 'manual', policy: 'Reuse' });
  const rejected = f.repository.start(f.context, { source: 'background', policy: 'Reject' });
  assert.equal(reused.kind, 'reused'); assert.equal(reused.handle, first.handle);
  assert.equal(rejected.kind, 'rejected'); assert.equal(rejected.active, first.handle);
  await tick(); assert.deepEqual(f.reasons, ['startup']);
  assert(!f.calls.includes('retain')); assert.equal(f.notifications.length, 0);
  gate.resolve(); assert.equal((await first.handle.completion).status, 'succeeded');
  assert.equal(f.repository.runningSync(), undefined);
});

test('Wait 立即返回独立句柄并按顺序执行，轮到时读取最新配置', async () => {
  const f = fixture(), gates = [deferred(), deferred(), deferred()];
  gates.forEach(gate => f.syncSteps.push({ gate }));
  const first = f.repository.start(f.context, { source: 'startup', policy: 'Reuse' });
  const second = f.repository.start(f.context, { source: 'manual', policy: 'Wait' });
  const third = f.repository.start(f.context, { source: 'manual', policy: 'Wait' });
  assert.equal(second.kind, 'queued'); assert.equal(third.kind, 'queued');
  assert.notEqual(second.handle.id, third.handle.id);
  let completed = false; second.handle.completion.then(() => { completed = true; });
  await tick(); assert.equal(completed, false); assert.equal(f.reasons.length, 1);
  f.config.todoDefaults = '第二轮配置'; gates[0].resolve(); await first.handle.completion;
  await tick(); assert.deepEqual(f.inputs, ['TODO DONE', '第二轮配置']);
  assert.equal(f.repository.runningSync(), second.handle); assert.equal(completed, false);
  f.config.todoDefaults = '第三轮配置'; gates[1].resolve(); await second.handle.completion;
  await tick(); assert.equal(f.repository.runningSync(), third.handle);
  assert.deepEqual(f.inputs, ['TODO DONE', '第二轮配置', '第三轮配置']);
  gates[2].resolve(); await third.handle.completion;
  assert.deepEqual(f.reasons, ['startup', 'manual', 'manual']);
});

test('前一轮失败仍继续排队请求，错误快照不会被下一轮清除', async () => {
  const f = fixture(), firstGate = deferred(), secondGate = deferred();
  f.syncSteps.push({ gate: firstGate, failed: true }, { gate: secondGate });
  const first = f.repository.start(f.context, { source: 'startup', policy: 'Reuse' });
  const second = f.repository.start(f.context, { source: 'manual', policy: 'Wait' });
  firstGate.resolve();
  const failed = await first.handle.completion;
  assert.equal(failed.status, 'failed'); assert.match(failed.message, /网络不可用/);
  await tick(); assert.equal(f.reasons.length, 2);
  assert.match(f.repository.takeFailure().message, /网络不可用/);
  assert.equal(f.repository.takeFailure(), undefined);
  secondGate.resolve(); assert.equal((await second.handle.completion).status, 'succeeded');
});

test('观察者重入时复用已保留的会话，角标失败不改变同步结果或阻塞队列', async () => {
  const f = fixture(); f.badgeFail();
  let reused;
  f.repository.watch(state => {
    if (state.running) reused = f.repository.start(f.context, { source: 'manual', policy: 'Reuse' });
  });
  const first = f.repository.start(f.context, { source: 'startup', policy: 'Reuse' });
  const next = f.repository.start(f.context, { source: 'manual', policy: 'Wait' });
  assert.equal((await first.handle.completion).status, 'succeeded');
  assert.equal((await next.handle.completion).status, 'succeeded');
  assert.equal(reused.handle, next.handle); assert.equal(f.reasons.length, 2);
});

test('主界面首次显示且在前台时同步一次，恢复前台和重新路由不重复启动', async () => {
  for (const contentFirst of [true, false]) {
    const requests = [], callbacks = [], context = {}; let backgroundRequests = 0;
    const Ability = compile('../entryability/EntryAbility', name => {
      if (name.endsWith('/PagePath')) return require('./helpers/page-navigator.cjs').pagePathModule;
      if (name.endsWith('/EntryNavigation')) return require('./helpers/page-navigator.cjs').entryNavigationModule;
      if (name.endsWith('/PageNavigator')) return require('./helpers/page-navigator.cjs').pageNavigatorMock;
      if (name === '../services/NativeCoreService') return { NativeCoreService: { start() {} } };
      if (name === '../services/HttpApiService') return { HttpApiService: { attachWindow() {} } };
      if (name === '@kit.AbilityKit') return { UIAbility: class {} };
      if (name === '../services/RepositorySyncService') return {
        SyncStartPolicy: { Reuse: 'Reuse' }, emptyRepositorySyncState() {},
        RepositorySyncService: { start(actual, options) { requests.push({ actual, ...options }); } }
      };
      if (name === '../services/NotificationManager') return { NotificationManager: { async start(){},resume(){},stop(){},hasMissingRepository(){return false;} } };
      if (name === '../services/DeviceBadgeService') return { DeviceBadgeService: { start() {}, stop() {}, close() {} } };
      if (name === '../services/AppDataManager') return {AppDataManager:{shared:()=>({start:async()=>{}}),close:async()=>{}}};
      if (name === '../services/ReminderManager') return { ReminderManager: { start() {}, refresh() {}, stop() {} } };
      if (name === '../services/NotificationPermissionService') return { NotificationPermissionService: { async start() {}, stop() {} } };
      if (name === '../services/BackgroundRepositorySyncService') return { BackgroundRepositorySyncService: { async start() { backgroundRequests++; } } };
      if (name === '../ui/Theme') return { UiColor: {} };
      return {};
    }, { LocalStorage: class {} }).default;
    const ability = new Ability(); ability.context = context;
    const stage = { async getMainWindow() { return { async setWindowSystemBarProperties() {} }; },
      loadContent(page, storage, done) { callbacks.push(done); } };
    await ability.onWindowStageCreate(stage);
    if (contentFirst) callbacks[0]({ code: 0 }); else ability.onForeground();
    assert.equal(requests.length, 0);
    if (contentFirst) ability.onForeground(); else callbacks[0]({ code: 0 });
    assert.deepEqual(requests, [{ actual: context, source: 'startup', policy: 'Reuse' }]);
    ability.onBackground(); ability.onForeground(); assert.equal(backgroundRequests, 1);
    ability.onNewWant({ parameters: { page: 'inbox' } }); callbacks[1]({ code: 0 });
    assert.equal(requests.length, 1);
  }
});

test('没有本地同步通知时不读取配置、不申请长时任务或访问凭据', async () => {
  const f = fixture(); f.change(false); await f.service.start(f.context);
  assert.deepEqual(f.calls, ['delay', 'flush', 'check', 'cancelDelay']);
  assert.equal(f.notifications.length, 0);
});

test('退后台同步共享进度，沿用系统通知的 ID、类型码并释放任务', async () => {
  const f = fixture(), gate = deferred(); f.holdSync(gate);
  const operation = f.service.start(f.context); await tick();
  await f.flushTimers();
  const progress = f.notifications.at(-1);
  assert.equal(progress.id, 77); assert.equal(progress.notificationSlotType, 4);
  assert.equal(progress.content.systemLiveView.typeCode, 8);
  assert.equal(progress.content.systemLiveView.capsule.title, '同步 50%');
  assert.equal(progress.content.systemLiveView.progress.currentValue, 50);
  gate.resolve(); await operation;
  assert.equal(f.notifications.at(-1).content.systemLiveView.title, '同步完成');
  assert.equal(f.notifications.at(-1).content.systemLiveView.progress.currentValue, 100);
  assert.equal(f.calls.filter(x => x === 'sync').length, 1);
  assert.equal(f.calls.at(-1), 'release'); assert.equal(f.timers.size, 0);
  assert(f.calls.indexOf('retain') < f.calls.indexOf('sync'));
});

test('快速反复退后台与 Reuse 请求只保留同一轮同步', async () => {
  const f = fixture(), gate = deferred(); f.holdSync(gate);
  const first = f.service.start(f.context), second = f.service.start(f.context);
  assert.equal(first, second); await tick();
  const manual = f.repository.start(f.context, { source: 'manual', policy: 'Reuse' }).handle;
  assert.equal(manual, f.repository.start(f.context, { source: 'manual', policy: 'Reuse' }).handle);
  gate.resolve(); await Promise.all([first, manual.completion]);
  assert.equal(f.calls.filter(x => x === 'sync').length, 1);
  assert.equal(f.calls.filter(x => x === 'retain').length, 1);
});

test('前台同步在准备实况窗期间结束，也不会再启动第二轮同步', async () => {
  const f = fixture(), sync = deferred(), retain = deferred(); f.holdSync(sync); f.holdRetain(retain);
  const manual = f.repository.start(f.context, { source: 'manual', policy: 'Reuse' }).handle; await tick();
  const background = f.service.start(f.context); await tick();
  sync.resolve(); await manual.completion; retain.resolve(); await background;
  assert.equal(f.calls.filter(x => x === 'sync').length, 1);
  assert(!f.calls.includes('check'));
  assert.equal(f.calls.at(-1), 'release');
});

test('退后台准备期间出现手动同步时 Reject 拒绝另建会话', async () => {
  const f = fixture(), retain = deferred(), sync = deferred(); f.holdRetain(retain); f.holdSync(sync);
  const background = f.service.start(f.context); await tick();
  const manual = f.repository.start(f.context, { source: 'manual', policy: 'Wait' });
  assert.equal(manual.kind, 'started'); await tick();
  retain.resolve(); await tick();
  assert.deepEqual(f.reasons, ['manual']);
  sync.resolve(); await Promise.all([background, manual.handle.completion]);
  assert.equal(f.calls.filter(call => call === 'sync').length, 1);
});

test('同步失败显示失败并释放资源，下次退后台重新检查并重试', async () => {
  const f = fixture(); f.syncFail(true); await f.service.start(f.context);
  assert.equal(f.notifications.at(-1).content.systemLiveView.title, '同步失败');
  assert.match(f.notifications.at(-1).content.systemLiveView.text, /网络不可用/);
  f.calls.length = 0; f.syncFail(false); await f.service.start(f.context);
  assert(f.calls.includes('check')); assert.equal(f.calls.filter(x => x === 'sync').length, 1);
  assert.equal(f.notifications.at(-1).content.systemLiveView.title, '同步完成');
});

test('短时任务到期或长时任务被拒绝时不开始网络同步并释放短时任务', async () => {
  const f = fixture(), gate = deferred(); f.holdCheck(gate);
  const operation = f.service.start(f.context); await tick(); f.expire();
  assert.equal(f.calls.at(-1), 'cancelDelay', '查询结束前立即释放到期任务');
  await operation; gate.resolve();
  assert(!f.calls.includes('sync')); assert.equal(f.calls.at(-1), 'cancelDelay');
  const rejected = fixture(); rejected.retainFail(); await rejected.service.start(rejected.context);
  assert(!rejected.calls.includes('sync')); assert.equal(rejected.calls.at(-1), 'cancelDelay');
});

test('实况窗更新失败不影响同步和后台资源回收', async () => {
  const f = fixture(); f.publishFail(); await f.service.start(f.context);
  assert.equal(f.calls.filter(x => x === 'sync').length, 1);
  assert.equal(f.calls.at(-1), 'release'); assert.equal(f.states.at(-1).error, false);
});

test('系统通知稍晚创建时后续进度重新读取，仍能更新最终状态', async () => {
  const f = fixture(); f.delayNotification(); await f.service.start(f.context);
  assert.equal(f.notifications.at(-1).content.systemLiveView.title, '同步完成');
  assert.equal(f.calls.at(-1), 'release');
});

test('存在本地同步通知但未启用 WebDAV 时不启动同步', async () => {
  const f = fixture(); f.config.repos[0].webdavEnabled = false;
  await f.service.start(f.context);
  assert.deepEqual(f.calls, ['delay', 'flush', 'check', 'configWithoutCredentials', 'cancelDelay']);
  assert.equal(f.notifications.length, 0);
});

test('先等待排队修改完成，再判断共享通知，避免刚编辑即退后台漏同步', async () => {
  const f = fixture(), gate = deferred(); f.change(false); f.holdFlush(gate);
  const work = f.service.start(f.context); await tick();
  assert.deepEqual(f.calls, ['delay', 'flush']);
  f.change(true); gate.resolve(); await work;
  assert.equal(f.calls.filter(call => call === 'sync').length, 1);
  assert(f.calls.indexOf('check') < f.calls.indexOf('sync'));
});

test('升级仅取消旧版同步作业，不注册新作业或清除其他作业', async () => {
  const stopped = [];
  const old = { workId: 1001, abilityName: 'SyncWorkExtension', isPersisted: true };
  const other = { workId: 2000, abilityName: 'OtherExtension' };
  const service = compile('LegacySyncScheduleService', name => {
    assert.equal(name, '@kit.BackgroundTasksKit');
    return { workScheduler: {
      async obtainAllWorks() { return [old, other, { workId: 1001, abilityName: 'OtherExtension' }]; },
      stopWork(work, cancel) { stopped.push({ work, cancel }); },
      startWork() { assert.fail('退出同步不能注册定时作业'); },
      stopAndClearWorks() { assert.fail('不能清理其他作业'); }
    } };
  }).LegacySyncScheduleService;
  await service.remove();
  assert.deepEqual(stopped, [{ work: old, cancel: true }]);
});

test('没有旧作业时迁移不做修改；系统查询失败后允许再次清理', async () => {
  let reads = 0, stops = 0;
  const service = compile('LegacySyncScheduleService', () => ({ workScheduler: {
    async obtainAllWorks() {
      if (++reads === 1) throw new Error('系统服务暂时不可用');
      return reads === 2 ? [{ workId: 1001, abilityName: 'SyncWorkExtension' }] : [];
    },
    stopWork() { stops++; }
  } })).LegacySyncScheduleService;
  await service.remove(); assert.equal(stops, 0);
  await service.remove(); assert.equal(stops, 1);
  await service.remove(); assert.equal(stops, 1); assert.equal(reads, 3);
});

test('取消旧作业失败时不保存完成标记，下次启动重试', async () => {
  let stops = 0;
  const service = compile('LegacySyncScheduleService', () => ({ workScheduler: {
    async obtainAllWorks() { return [{ workId: 1001, abilityName: 'SyncWorkExtension' }]; },
    stopWork() { if (++stops === 1) throw new Error('取消失败'); }
  } })).LegacySyncScheduleService;
  await service.remove(); await service.remove(); assert.equal(stops, 2);
});


test('纯本地启动只接入 Workspace，角标消费共享数据，不增加全量查询',async()=>{
 const f=fixture();f.config.repos[0].webdavEnabled=false;
 const result=f.repository.start(f.context,{source:'startup',policy:'Reuse'});await result.handle.completion;
 assert.equal(f.calls.filter(value=>value==='workspace').length,1);assert.equal(f.calls.filter(value=>value==='sync').length,0);
 assert.equal(f.calls.filter(value=>value==='badge').length,1);
});

function remoteCheckFixture(states) {
  const calls = [], policies = [];
  const { NativeCoreService } = compile('NativeCoreService', dependency => {
    assert.equal(dependency, 'liborg_tasks_harmony.so');
    return { WebDavSyncPolicy: class {
      constructor(url, username, password) { policies.push([url, username, password]); }
    } };
  });
  const configs = states.map((_, index) => ({ id: `host-${index}`, rootDirectory: `/repo-${index}`, webdavEnabled: true,
    webdavUrl: `https://example.test/${index}`, webdavUsername: 'user', webdavPassword: 'secret',
    excludedDirectories: ['archive'] }));
  const repos = configs.map((config, index) => ({ id: `core-${index}`, rootDirectory: config.rootDirectory }));
  NativeCoreService.workspaceFor = async () => ({
    async repos() { return repos; },
    async setSyncPolicy(id, policy, excludedDirectories) { calls.push(['set', id, Array.from(excludedDirectories)]); },
    async removeSyncPolicy(id) { calls.push(['remove', id]); },
    async checkRemoteChanges(...args) {
      assert.equal(args.length, 0); calls.push(['check']);
      return states.map((state, index) => state instanceof Error
        ? { repoId: repos[index].id, state: null, error: state }
        : { repoId: repos[index].id, state: typeof state === 'string' ? state : state ? 'changed' : 'unchanged', error: null });
    },
    async syncRepos(ids, reason) {
      calls.push(['sync', Array.from(ids), reason]);
      return ids.map(repoId => ({ repoId, record: { result: 'succeeded' }, error: null }));
    }
  });
  return { calls, policies, configs, run: (reason, repositoryId) =>
    NativeCoreService.syncWorkspaceWebDav(configs, undefined, '', undefined, reason, repositoryId) };
}

test('启动无参检查全部仓库，仅将有变化或未知的仓库列表交给 Core 同步', async () => {
  const f = remoteCheckFixture([false, true, 'unknown']);
  await f.run('startup');
  assert.deepEqual(f.calls, [['set', 'core-0', ['archive']], ['set', 'core-1', ['archive']],
    ['set', 'core-2', ['archive']], ['check'], ['sync', ['core-1', 'core-2'], 'remoteChanged']]);
  assert.equal(f.policies.length, 3);
});

test('远端无变化不调用同步，单仓库检查失败不阻止其他仓库同步', async () => {
  const unchanged = remoteCheckFixture([false]);
  await unchanged.run('startup');
  assert.deepEqual(unchanged.calls.map(([kind]) => kind), ['set', 'check']);
  const failed = remoteCheckFixture([new Error('远端检查失败'), true]);
  await assert.rejects(failed.run('startup'), /远端检查失败/);
  assert.deepEqual(failed.calls.at(-1), ['sync', ['core-1'], 'remoteChanged']);
});

test('手动与退后台直接传指定仓库列表，关闭远端时解绑 Policy', async () => {
  for (const reason of ['manual', 'background']) {
    const f = remoteCheckFixture([false, false]);
    f.configs[1].webdavEnabled = false;
    await f.run(reason);
    assert.deepEqual(f.calls, [['set', 'core-0', ['archive']], ['remove', 'core-1'], ['sync', ['core-0'], reason === 'background' ? 'localChanged' : 'manual']]);
  }
});

test('新建与重置都仅同步选中仓库并保留独立原因', async () => {
  for (const reason of ['repositoryCreated', 'repositoryReset']) {
    const f = remoteCheckFixture([true, false, true]);
    await f.run(reason, 'host-1');
    assert.deepEqual(f.calls, [['set', 'core-1', ['archive']], ['sync', ['core-1'], reason]]);
  }
});
