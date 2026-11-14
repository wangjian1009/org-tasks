const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-device-badge.cjs\n验证设备角标的单次批量查询、过期结果、失败恢复、前台订阅及后台单次刷新。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}
function fixture() {
  const config = { repos: [{ id: 'host-a', rootDirectory: '/a' }], inboxRepoId: 'host-a', inboxFile: 'inbox.org', todoDefaults: '' };
  const writes = [], batches = [], stopped = [], timers = new Map(), callbacks = new Map(), configCallbacks = new Set();
  let inbox = 2, deadline = 3, conflicts = 1, missing = false, queryFailure = false, writeFailure = false;
  let queryGate, registrationGate, nextId = 1;
  const workspace = {
    async repos() { return [{ id: 'core-a', rootDirectory: '/a' }, { id: 'core-b', rootDirectory: '/b' }]; },
    async query(batch) {
      batches.push(batch);
      if (queryFailure) throw new Error('读取失败');
      const result = batch.map(request => request.type === 'notification'
        ? { type: 'notification', result: [{ type: 'syncRequired' }, ...Array(conflicts).fill({ type: 'syncConflict' })] }
        : request.type === 'file'
          ? { type: 'file', result: missing ? [] : [{ tagOptions: [], tagGroups: [] }] }
          : { type: 'task', result: { tasks: Array(request.repoIds ? inbox : deadline).fill({}), categories: [] } });
      const gate = queryGate; queryGate = undefined;
      if (gate) await gate.promise;
      return result;
    },
    async watchDataChanges(callback) {
      const id = nextId++; callbacks.set(id, callback);
      const gate = registrationGate; registrationGate = undefined;
      if (gate) await gate.promise;
      return id;
    },
    stopWatchingDataChanges(id) { stopped.push(id); callbacks.delete(id); }
  };
  const configService = { async load(_, credentials) { assert.equal(credentials, false); return config; },
    watchChanges(callback) { configCallbacks.add(callback); }, stopWatchingChanges(callback) { configCallbacks.delete(callback); } };
  const native = { NativeCoreService: { async workspaceFor() { return workspace; } },
    taskResult: value => { assert.equal(value.type, 'task'); return value.result; },
    fileResult: value => { assert.equal(value.type, 'file'); return value.result; },
    notificationResult: value => { assert.equal(value.type, 'notification'); return value.result; } };
  const cache = new Map();
  function load(name) {
    const filename = path.join(root, name + '.ets');
    if (cache.has(filename)) return cache.get(filename).exports;
    const module = { exports: {} }; cache.set(filename, module);
    const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const requireLocal = dependency => {
      if (dependency === '@kit.NotificationKit') return { notificationManager: { async setBadgeNumber(value) {
        if (writeFailure) throw new Error('系统服务不可用'); writes.push(value);
      } } };
      if (dependency === './NativeCoreService') return native;
      if (dependency === './AppConfigService') return { AppConfigService: configService };
      if (dependency === './PageQueryService') return { PageQueryService: {} };
      if (dependency.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(filename), dependency)));
      throw new Error('缺少替身: ' + dependency);
    };
    vm.runInThisContext('(function(require,module,exports,setTimeout,clearTimeout,console){' + output + '\n})', { filename })(
      requireLocal, module, module.exports,
      (callback, delay) => { const id = nextId++; timers.set(id, { callback, delay }); return id; },
      id => timers.delete(id), { error() {} });
    return module.exports;
  }
  return { service: load('services/DeviceBadgeService').DeviceBadgeService, config, writes, batches, stopped, timers, callbacks, configCallbacks,
    counts(a, b, c) { inbox = a; deadline = b; conflicts = c; }, missing() { missing = true; },
    failQuery(value) { queryFailure = value; }, failWrite(value) { writeFailure = value; },
    holdQuery(gate) { queryGate = gate; }, holdRegistration(gate) { registrationGate = gate; } };
}

test('后台单次刷新只发一个混合批次，按 Core 仓库隔离收件箱，排除同步提示', async () => {
  const f = fixture(); await f.service.refresh({});
  assert.deepEqual(f.writes, [6]); assert.equal(f.batches.length, 1);
  const batch = f.batches[0];
  assert.deepEqual(batch.map(query => query.type), ['task', 'notification', 'task', 'file']);
  assert.equal(batch[0].query.expression, 'it.todo d.lt.tomorrow');
  assert.deepEqual(Object.keys(batch[0].query).sort(), ['excludedFiles', 'expression', 'includeComposeTasks']);
  assert.deepEqual(batch[0].query.excludedFiles, [{ repoId: 'core-a', path: 'inbox.org' }]);
  assert.deepEqual(batch[2].repoIds, ['core-a']);
  assert.deepEqual(batch[2].query, { expression: 'b."inbox.org"', includeComposeTasks: true });
  assert.deepEqual(batch[3].query.includeFiles, [{ repoId: 'core-a', path: 'inbox.org' }]);
  assert.equal(f.callbacks.size, 0); assert.equal(f.timers.size, 0);
});

test('未配置或失效收件箱贡献零，不回退到其他文件；总数为零清除角标', async () => {
  const f = fixture(); f.missing(); await f.service.refresh({}); assert.deepEqual(f.writes, [4]);
  f.config.inboxRepoId = ''; f.counts(10, 0, 0); await f.service.refresh({});
  assert.deepEqual(f.writes, [4, 0]); assert.equal(f.batches[1].length, 2);
  assert.deepEqual(f.batches[1][0].query.excludedFiles, []);
});

test('查询或系统写入失败保留原数字，后续请求正常恢复', async () => {
  const f = fixture(); await f.service.refresh({}); f.counts(0, 1, 0);
  f.failQuery(true); await f.service.refresh({}); assert.deepEqual(f.writes, [6]);
  f.failQuery(false); f.failWrite(true); await f.service.refresh({}); assert.deepEqual(f.writes, [6]);
  f.failWrite(false); await f.service.refresh({}); assert.deepEqual(f.writes, [6, 1]);
});

test('查询中连续变更合并为一次补查，旧结果不会写回系统', async () => {
  const f = fixture(), gate = deferred(); f.holdQuery(gate);
  const first = f.service.refresh({}); await tick();
  f.counts(1, 0, 0); const second = f.service.refresh({}); f.service.refresh({});
  gate.resolve(); await Promise.all([first, second]);
  assert.equal(f.batches.length, 2); assert.deepEqual(f.writes, [1]);
});

test('前台订阅不依赖页面，数据和配置变更触发重算，停止后注销且可重新启动', async () => {
  const f = fixture(), context = {}; f.service.start(context); await tick();
  assert.equal(f.callbacks.size, 1); assert.equal(f.configCallbacks.size, 1); assert.equal(f.timers.size, 1);
  f.counts(0, 1, 1); [...f.callbacks.values()][0](); await tick(); assert.equal(f.writes.at(-1), 2);
  f.counts(0, 0, 0); [...f.configCallbacks][0](); await tick(); assert.equal(f.writes.at(-1), 0);
  const oldCallback = [...f.callbacks.values()][0]; f.service.stop();
  assert.equal(f.callbacks.size, 0); assert.equal(f.configCallbacks.size, 0); assert.equal(f.timers.size, 0);
  const before = f.batches.length; oldCallback(); await tick(); assert.equal(f.batches.length, before);
  f.service.start(context); await tick(); assert.equal(f.callbacks.size, 1); f.service.stop();
});

test('前台跨日重算，退到后台不保留日期定时器', async () => {
  const f = fixture(); f.service.start({}); await tick();
  const timer = [...f.timers.values()][0]; assert.ok(timer.delay > 0 && timer.delay <= 86400000);
  f.counts(0, 4, 0); timer.callback(); await tick(); assert.equal(f.writes.at(-1), 4);
  f.service.stop(); assert.equal(f.timers.size, 0);
});

test('异步订阅注册期间退到后台，注册完成后立即注销', async () => {
  const f = fixture(), gate = deferred(); f.holdRegistration(gate);
  f.service.start({}); await tick(); f.service.stop(); gate.resolve(); await tick();
  assert.equal(f.callbacks.size, 0); assert.equal(f.stopped.length, 1); assert.equal(f.timers.size, 0);
});
