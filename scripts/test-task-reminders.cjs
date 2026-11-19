const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-reminders.cjs\n验证全局共享提醒数据集、日历指纹恢复、首次同步与后续增删改、权限、失败保护和本机开关。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(name, mocks, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync(`entry/src/main/ets/services/${name}.ets`, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, console,
    require(name) { assert.ok(name in mocks, name); return mocks[name]; }, ...globals });
  return module.exports[name];
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(shared = {}) {
  const clock = shared.clock ?? { now: Date.now() };
  const config = shared.config ?? { enabled: true };
  const native = shared.native ?? { events: new Map(), calendars: [], next: 1 };
  const calls = [], listeners = new Set(), timers = new Map();
  let tasks = [], view = [], ready = true, version = 1, dataError = '', permission = 'enabled';
  let inventoryError, updateError, publishError, createGate, starts = 0, closes = 0, creates = 0;
  class Clock extends Date { static now() { return clock.now; } }
  const calendar = native.calendar = {
    id: 15, getAccount: () => ({ name: 'org-tasks.reminders', type: 0 }),
    getConfig: () => ({ enableReminder: true }),
    async setConfig(value) { calls.push(['config', value]); },
    async getEvents(...args) {
      calls.push(['inventory']); assert.equal(args.length, 0, '当前平台全量查询不接受显式 undefined 参数');
      if (inventoryError) throw inventoryError;
      return [...native.events.values()].map(value => structuredClone(value));
    },
    async addEvent(event) {
      if (createGate) await createGate;
      if (publishError) throw publishError;
      const id = native.next++; native.events.set(id, { ...structuredClone(event), id }); calls.push(['add', id]); return id;
    },
    async updateEvent(event) {
      if (updateError) throw updateError;
      assert(native.events.has(event.id)); native.events.set(event.id, structuredClone(event)); calls.push(['update', event.id]);
    },
    async deleteEvent(id) { assert(native.events.has(id)); native.events.delete(id); calls.push(['delete', id]); }
  };
  native.calendars = native.calendars.map(previous => previous.getAccount().name === 'org-tasks.reminders' ? calendar : previous);
  const kit = { calendarManager: { CalendarType: { LOCAL: 0 }, EventType: { NORMAL: 0 }, getCalendarManager() { return {
    async getAllCalendars() { calls.push(['calendars']); if (inventoryError) throw inventoryError; return native.calendars; },
    async createCalendar(account) { assert.equal(account.name, 'org-tasks.reminders'); native.calendars.push(calendar); calls.push(['calendar']); return calendar; }
  }; } } };
  const digest = { cryptoFramework: { createMd(name) { assert.equal(name, 'SHA256'); const hash = crypto.createHash('sha256'); return {
    async update(blob) { hash.update(blob.data); }, async digest() { return { data: hash.digest() }; }
  }; } } };
  const CalendarSync = load('CalendarSync', { '@kit.CalendarKit': kit, '@kit.CryptoArchitectureKit': digest,
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } } }, { Date: Clock });
  const dataSet = {
    get error() { return dataError; }, get data() { return { type: 'task', result: { tasks: view } }; },
    isReady: () => ready,
    getConfirmed: () => ({ version, data: { type: 'task', result: { tasks } } }),
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    async refresh() { calls.push(['query']); }, reportError(error) { dataError = error.message; },
  };
  const manager = { dataSet(name) { assert.equal(name, 'tasks'); return dataSet; },
    async start() { starts++; if (dataError) throw new Error(dataError); }, async close() { closes++; } };
  const service = load('TaskEventManager', {
    './DataSetManager': { DataSetManager: { create(context, name, factory, options) {
      creates++; assert.equal(name, 'events'); assert.equal(options.cache, false);
      const definitions = factory({}); assert.equal(definitions[0].query.query.expression, 'it.todo has.reminder o.reminder'); return manager;
    } } },
    './FileTargetService': { systemTrashExclusions: () => ({ files: [], repositoryBindings: [] }) },
    './CalendarSync': { CalendarSync }, './CalendarPermissionService': { CalendarPermissionService: { async state() { return permission; } } },
    './TaskReminderSettings': { TaskReminderSettings: { async load() { return { ...config }; } } }
  }, { Date: Clock, setTimeout(fn, delay) { const id = timers.size + 1; timers.set(id, { fn, delay }); return id; }, clearTimeout(id) { timers.delete(id); } });
  function task(id = 'one', offset = 120000) { return { id, heading: `任务 ${id}`, reminderAt: clock.now + offset, state: { name: 'TODO' }, isDone: () => false }; }
  return { service, config, clock, native, calls, timers, listeners, task, dataSet,
    tasks(value) { tasks = value.map(task => ({ ...task })); view = value; },
    emit(value, optimistic = false) { if (!optimistic) tasks = value.map(task => ({ ...task })); view = value; for (const listener of listeners) listener({ optimistic }); },
    ready(value) { ready = value; }, version(value) { version = value; }, error(value) { dataError = value; }, permission(value) { permission = value; },
    inventoryError(value) { inventoryError = value; }, updateError(value) { updateError = value; }, publishError(value) { publishError = value; },
    holdCreate(value) { createGate = value; }, refresh: () => service.refresh({}), async settle() { await tick(); await service.refresh({}); },
    creates: () => creates, starts: () => starts, closes: () => closes,
    shared: () => ({ clock, config, native }) };
}

test('启动建立唯一来源数据集并只核对一次库存；重复启动和设置页共用同一实例', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh();
  assert.equal(f.service.dataSet({}), f.dataSet); f.service.start({}); await f.refresh();
  assert.equal(f.creates(), 1); assert.equal(f.calls.filter(x => x[0] === 'inventory').length, 1);
  assert.equal(f.calls.filter(x => x[0] === 'add').length, 1); assert.equal(f.native.events.size, 1);
  const event = [...f.native.events.values()][0], marker = JSON.parse(event.identifier);
  assert.equal(marker.owner, 'org-tasks'); assert.match(marker.taskKey, /^[0-9a-f]{64}$/); assert.match(marker.contentHash, /^[0-9a-f]{64}$/);
  assert(!event.identifier.includes(task.id)); assert.equal(event.startTime, task.reminderAt); assert.deepEqual(event.reminderTime, [0]);
  f.service.stop(); assert.equal(f.listeners.size, 0); assert.equal(f.timers.size, 0);
});

test('提醒改期和显示标题变化更新同一个事件，后续维护不遍历系统日历', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh(); const id = [...f.native.events.keys()][0];
  task.reminderAt += 300000; f.emit([task]); await f.settle();
  task.heading += ' [1/2]'; f.emit([task]); await f.settle();
  assert.equal(f.native.events.size, 1); assert.equal(f.native.events.get(id).title, task.heading);
  assert.equal(f.native.events.get(id).startTime, task.reminderAt);
  assert.equal(f.calls.filter(x => x[0] === 'update').length, 2);
  assert.equal(f.calls.filter(x => x[0] === 'inventory').length, 1);
});

test('新增、完成和身份改变按增删改维护，取消旧事件并保留无关事件', async () => {
  const f = fixture(), first = f.task(); f.tasks([first]); await f.refresh();
  const foreign = f.native.next++; f.native.events.set(foreign, { id: foreign, identifier: '用户手动创建', title: '保留' });
  const second = f.task('two'); f.emit([first, second]); await f.settle(); assert.equal(f.native.events.size, 3);
  first.id = 'renamed'; first.heading = '改名'; f.emit([first, second]); await f.settle();
  assert.equal(f.native.events.size, 3); assert.equal(f.calls.filter(x => x[0] === 'delete').length, 1);
  f.emit([]); await f.settle(); assert.deepEqual([...f.native.events.keys()], [foreign]);
  assert.equal(f.calls.filter(x => x[0] === 'inventory').length, 1);
});

test('重启从事件中的标记恢复映射，不依赖 Preferences，不重复创建', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh(); f.service.stop();
  const restarted = fixture(f.shared()); restarted.tasks([task]); await restarted.refresh();
  assert.equal(restarted.native.events.size, 1); assert.equal(restarted.calls.filter(x => x[0] === 'add' || x[0] === 'update').length, 0);
  assert.equal(restarted.calls.filter(x => x[0] === 'inventory').length, 1);
  task.reminderAt += 60000; restarted.emit([task]); await restarted.settle();
  assert.equal(restarted.calls.filter(x => x[0] === 'update').length, 1);
});

test('启动会删除已失效的本应用事件并清理重复项，外来标记不修改', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh(); f.service.stop();
  const event = [...f.native.events.values()][0]; const duplicate = f.native.next++;
  f.native.events.set(duplicate, { ...structuredClone(event), id: duplicate });
  const foreign = f.native.next++; f.native.events.set(foreign, { id: foreign, identifier: '{"owner":"other"}' });
  const resumed = fixture(f.shared()); resumed.tasks([task]); await resumed.refresh(); assert.equal(resumed.native.events.size, 2);
  resumed.service.stop(); const stale = fixture(f.shared()); stale.tasks([]); await stale.refresh();
  assert.deepEqual([...stale.native.events.keys()], [foreign]);
});

test('日历查询失败或本应用标记损坏时不清理任何事件', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh(); f.service.stop();
  const restarted = fixture(f.shared()); restarted.tasks([]); restarted.inventoryError(new Error('系统读取失败')); await restarted.refresh();
  assert.equal(restarted.native.events.size, 1); assert.match(restarted.service.summary(), /读取失败/);
  restarted.inventoryError(undefined);
  const id = restarted.native.next++; restarted.native.events.set(id, { id, identifier: '{"owner":"org-tasks","taskKey":"broken"}' });
  await restarted.refresh(); assert.equal(restarted.native.events.size, 2); assert.match(restarted.service.summary(), /标记无效/);
});

test('查询失败、未就绪、版本零与乐观快照不影响已经登记的提醒', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh();
  f.emit([] , true); await f.settle(); assert.equal(f.native.events.size, 1);
  f.ready(false); f.emit([]); await f.settle(); assert.equal(f.native.events.size, 1);
  f.ready(true); f.version(0); await f.refresh(); assert.equal(f.native.events.size, 1);
  f.version(1); f.error('查询失败'); await f.refresh(); assert.equal(f.native.events.size, 1);
  f.error(''); await f.refresh(); assert.equal(f.native.events.size, 0);
});

test('关闭本机开关清理本应用事件，不依赖任务查询成功', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh();
  f.config.enabled = false; f.ready(false); f.version(0); await f.refresh();
  assert.equal(f.native.events.size, 0); assert.equal(f.service.summary(), '本机任务提醒已关闭');
});

test('没有日历权限时不调用系统写入，恢复授权自动进行首次核对', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.permission('disabled'); await f.refresh();
  assert.equal(f.calls.length, 0); assert.match(f.service.summary(), /未授权/);
  f.permission('enabled'); await f.refresh(); assert.equal(f.native.events.size, 1);
});

test('系统写入失败不报告成功，下一次变更恢复后不重复创建', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.publishError(new Error('创建失败')); await f.refresh();
  assert.equal(f.native.events.size, 0); assert.match(f.service.summary(), /创建失败/);
  f.publishError(undefined); await f.refresh(); assert.equal(f.native.events.size, 1);
  task.reminderAt += 60000; f.updateError(new Error('更新失败')); f.emit([task]); await f.settle();
  assert.match(f.service.status(task), /更新失败/); assert.equal(f.native.events.size, 1);
  f.updateError(undefined); await f.refresh(); assert.equal(f.native.events.size, 1);
  assert.equal([...f.native.events.values()][0].startTime, task.reminderAt);
});

test('过去的提醒不补发，已触发的事件保留，结束或清除后撤销', async () => {
  const f = fixture(), past = f.task('past', -60000), future = f.task(); f.tasks([past, future]); await f.refresh();
  assert.equal(f.native.events.size, 1); assert.equal(f.service.status(past), '提醒时间已过');
  f.clock.now = future.reminderAt + 1000; f.emit([past, future]); await f.settle(); assert.equal(f.native.events.size, 1);
  f.emit([]); await f.settle(); assert.equal(f.native.events.size, 0);
});

test('重复任务的下一次提醒直接更新系统事件时间，不生成多个实例', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh(); const id = [...f.native.events.keys()][0];
  task.reminderAt += 86400000; f.emit([task]); await f.settle();
  assert.deepEqual([...f.native.events.keys()], [id]); assert.equal(f.native.events.get(id).startTime, task.reminderAt);
});

test('关闭后保留系统事件交给日历，重启能恢复写入成功但管理器已停止的事件', async () => {
  const f = fixture(), task = f.task(); let release; const gate = new Promise(resolve => release = resolve);
  f.holdCreate(gate); f.tasks([task]); const pending = f.refresh();
  await tick(); f.service.stop(); release(); await pending;
  const resumed = fixture(f.shared()); resumed.tasks([task]); await resumed.refresh(); assert.equal(resumed.native.events.size, 1);
});

test('创建尚未返回时任务被删除，会自动清理已成功写入的过期批次且不重扫库存', async () => {
  const f = fixture(); f.tasks([]); await f.refresh();
  let release; const gate = new Promise(resolve => release = resolve); f.holdCreate(gate);
  f.emit([f.task()]); await tick(); f.emit([]); release(); await f.settle();
  assert.equal(f.native.events.size, 0);
  assert.equal(f.calls.filter(call => call[0] === 'inventory').length, 1);
});

test('本机设置仅保存开关，刷新失败恢复旧值且后续可重试', async () => {
  const values = new Map(); let fail = false;
  const store = { get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
    put: async (key, value) => values.set(key, value), flush: async () => { if (fail) { fail = false; throw new Error('保存失败'); } } };
  const settings = load('TaskReminderSettings', { './PreferencesStore': { PreferencesStore: { open: async () => store } } });
  assert.deepEqual(JSON.parse(JSON.stringify(await settings.load({}))), { enabled: false });
  await settings.save({}, { enabled: true }); fail = true; await assert.rejects(settings.save({}, { enabled: false }));
  assert.deepEqual(JSON.parse(JSON.stringify(await settings.load({}))), { enabled: true });
  await settings.save({}, { enabled: false }); assert.deepEqual([...values.keys()], ['enabled']);
});
