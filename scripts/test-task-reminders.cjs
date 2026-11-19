const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-reminders.cjs\n验证提醒登记、去重恢复、取消、名额、已确认数据边界、权限错误及全局响铃设置。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(name, mocks, globals = {}) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(`entry/src/main/ets/services/${name}.ets`, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, console, setTimeout: () => 1, clearTimeout() {},
    require(name) { assert.ok(name in mocks, name); return mocks[name]; }, ...globals });
  return module.exports[name];
}
function fixture(shared = {}) {
  const clock = shared.clock ?? { now: Date.now() };
  const values = shared.values ?? new Map();
  const system = shared.system ?? new Map();
  const config = shared.config ?? { enabled: true, ringDuration: 30 };
  let tasks = [], ready = true, version = 1, queryError = '', inventoryError, publishError, saveAfterPublish = false, published = false, failSave = false;
  const writes = [], cancelled = [], listeners = new Set(), timers = [];
  class Clock extends Date { static now() { return clock.now; } }
  const store = { async get(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
    async put(key, value) { if (failSave || saveAfterPublish && published) throw new Error('写入失败'); values.set(key, value); }, async flush() {} };
  const dataSet = { get error() { return queryError; }, isReady: () => ready,
    getConfirmed: () => ({ version, data: { type: 'task', result: { tasks } } }),
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); } };
  const service = load('TaskReminderService', {
    './AppDataManager': { AppDataManager: { shared: () => ({ start: async () => {}, dataSet: () => dataSet }) } },
    './PreferencesStore': { PreferencesStore: { open: async () => store } },
    './TaskReminderSettings': { TaskReminderSettings: { load: async () => ({ ...config }) } },
    '@kit.NotificationKit': { notificationManager: { isNotificationEnabled: async () => true, SlotType: { CONTENT_INFORMATION: 1 } } },
    '@kit.BackgroundTasksKit': { reminderAgentManager: {
      ReminderType: { REMINDER_TYPE_CALENDAR: 1 }, ActionButtonType: { ACTION_BUTTON_TYPE_CLOSE: 0 },
      async getAllValidReminders() { if (inventoryError) throw inventoryError; return [...system.values()]; },
      async publishReminder(request) {
        if (publishError) throw publishError;
        if (system.size >= 30) throw { code: 1700002 };
        const reminderId = Math.max(0, ...system.keys()) + 1;
        system.set(reminderId, { reminderId, reminderReq: structuredClone(request) }); writes.push(request); published = true; return reminderId;
      },
      async cancelReminder(id) { cancelled.push(id); system.delete(id); }
    } }
  }, { Date: Clock, setTimeout(fn, delay) { timers.push({ fn, delay }); return timers.length; } });
  function task(id = 'one', offset = 60000) {
    return { id, repoId: 'repo', heading: `任务 ${id}`, state: { name: 'TODO' }, isDone: () => false,
      reminderAt: clock.now + offset };
  }
  return { service, values, system, config, clock, writes, cancelled, listeners, timers, task,
    tasks(value) { tasks = value; }, ready(value) { ready = value; }, version(value) { version = value; },
    error(value) { queryError = value; }, inventoryError(value) { inventoryError = value; }, publishError(value) { publishError = value; },
    failAfterPublish(value) { saveAfterPublish = value; }, failSave(value) { failSave = value; },
    refresh: () => service.refresh({}), shared: () => ({ values, system, config, clock }) };
}

test('每个任务只登记唯一时间，重复协调与重启不重复创建，默认响铃 30 秒', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh();
  assert.equal(f.system.size, 1); assert.equal(f.writes[0].ringDuration, 30);
  await f.refresh(); assert.equal(f.writes.length, 1);
  const restarted = fixture(f.shared()); restarted.tasks([task]); await restarted.refresh();
  assert.equal(restarted.writes.length, 0); assert.equal(restarted.system.size, 1);
  assert.equal(restarted.service.status(task), '提醒已安排');
});

test('改期、改标题和全局响铃会替换提醒，清空时间或关闭本机开关会撤销', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); await f.refresh();
  task.heading = '修改后的任务'; task.reminderAt += 300000; f.config.ringDuration = 60; await f.refresh();
  assert.equal(f.cancelled.length, 1); assert.equal(f.writes.length, 2);
  assert.equal([...f.system.values()][0].reminderReq.content, task.heading);
  assert.equal([...f.system.values()][0].reminderReq.ringDuration, 60);
  const timestamp = task.reminderAt; task.reminderAt = null; await f.refresh(); assert.equal(f.system.size, 0);
  task.reminderAt = timestamp; await f.refresh(); assert.equal(f.system.size, 1);
  f.config.enabled = false; f.ready(false); await f.refresh(); assert.equal(f.system.size, 0);
  assert.match(f.service.summary(), /已关闭/);
});

test('任务完成、删除或改名使旧映射移除，其他系统提醒保持', async () => {
  const f = fixture(), task = f.task(); f.system.set(100, { reminderId: 100, reminderReq: {} });
  f.tasks([task]); await f.refresh(); task.id = 'renamed'; await f.refresh();
  assert.equal(f.cancelled.length, 1); assert.equal(f.system.size, 2);
  f.tasks([]); await f.refresh(); assert.equal(f.system.size, 1); assert.ok(f.system.has(100));
});

test('查询失败、未就绪和版本零缓存不能清空系统提醒', async () => {
  const f = fixture(); f.tasks([f.task()]); await f.refresh(); f.tasks([]);
  f.ready(false); await f.refresh(); assert.equal(f.system.size, 1);
  f.ready(true); f.version(0); await f.refresh(); assert.equal(f.system.size, 1);
  f.version(1); f.error('读取失败'); await f.refresh(); assert.equal(f.system.size, 1);
  f.error(''); await f.refresh(); assert.equal(f.system.size, 0);
});

test('发布成功但日志保存失败，重启根据系统标记恢复', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.failAfterPublish(true); await f.refresh();
  assert.equal(f.system.size, 1); assert.match(f.service.summary(), /失败/);
  const restarted = fixture(f.shared()); restarted.tasks([task]); await restarted.refresh();
  assert.equal(restarted.writes.length, 0); assert.equal(restarted.system.size, 1);
  assert.equal(JSON.parse(restarted.values.get('journal')).records[0].reminderId, 1);
});

test('无法保存发布意图时不调用系统，系统查询失败时不删除', async () => {
  const f = fixture(); f.tasks([f.task()]); f.failSave(true); await f.refresh(); assert.equal(f.system.size, 0);
  f.failSave(false); await f.refresh(); assert.equal(f.system.size, 1);
  f.tasks([]); f.inventoryError(new Error('系统暂不可用')); await f.refresh(); assert.equal(f.system.size, 1);
});

test('30 个名额按时间安排，超出任务等待，清理过期提醒后补位且不补发', async () => {
  const f = fixture(), tasks = Array.from({ length: 32 }, (_, i) => f.task(`t${i}`, 60000 + i * 300000));
  f.tasks(tasks); await f.refresh(); assert.equal(f.system.size, 30);
  assert.equal(f.service.status(tasks[30]), '等待系统提醒名额');
  f.clock.now = tasks[0].reminderAt + 31000; await f.refresh();
  assert.equal(f.system.size, 30); assert.equal(f.service.status(tasks[30]), '提醒已安排');
  assert.equal(f.service.status(tasks[0]), '提醒时间已过');
});

test('响铃中的提醒继续占用名额，清空时间时立即取消', async () => {
  const f = fixture(), tasks = Array.from({ length: 31 }, (_, i) => f.task(`t${i}`, 60000 + i * 300000));
  f.tasks(tasks); await f.refresh(); f.clock.now = tasks[0].reminderAt + 1000; await f.refresh();
  assert.equal(f.system.size, 30); assert.equal(f.cancelled.length, 0);
  assert.equal(f.service.status(tasks[30]), '等待系统提醒名额');
  tasks[0].reminderAt = null; await f.refresh(); assert.equal(f.cancelled.length, 1);
  assert.equal(f.service.status(tasks[30]), '提醒已安排');
});

test('没有 Org ID 仍能安排，权限拒绝不报告成功，空时间不安排', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.publishError({ code: 201 }); await f.refresh();
  assert.equal(f.system.size, 0); assert.match(f.service.status(task), /权限未开通/);
  f.publishError(null); await f.refresh(); assert.equal(f.system.size, 1);
  task.reminderAt = null; await f.refresh(); assert.equal(f.system.size, 0);
});

test('忽略乐观事件，只处理已确认快照，停止释放订阅', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.service.start({}); await f.refresh();
  const listener = [...f.listeners][0]; task.heading = '已提交的新标题';
  listener({ optimistic: true }); assert.equal(f.writes.length, 1);
  listener({ optimistic: false }); await f.refresh(); assert.equal(f.writes.length, 2);
  f.service.stop(); assert.equal(f.listeners.size, 0);
});

test('全局设置默认为关闭与 30 秒，非法时长不写入，保存失败恢复旧值', async () => {
  const values = new Map(); let fail = false;
  const store = { get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
    put: async (key, value) => values.set(key, value), flush: async () => { if (fail) { fail = false; throw new Error('保存失败'); } } };
  const settings = load('TaskReminderSettings', { './PreferencesStore': { PreferencesStore: { open: async () => store } } });
  assert.deepEqual(JSON.parse(JSON.stringify(await settings.load({}))), { enabled: false, ringDuration: 30 });
  await assert.rejects(settings.save({}, { enabled: true, ringDuration: 0 })); assert.equal(values.size, 0);
  await settings.save({}, { enabled: true, ringDuration: 60 });
  fail = true; await assert.rejects(settings.save({}, { enabled: false, ringDuration: 120 }));
  assert.deepEqual(JSON.parse(JSON.stringify(await settings.load({}))), { enabled: true, ringDuration: 60 });
});

test('日期控件只返回 SET_REMINDER 时间戳或空值，不暴露属性名、不生成 ID', () => {
  const source = ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/TaskReminderPresentation.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(source, { module, exports: module.exports, require: () => ({
    inlineDate: date => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
  }) });
  const { reminderPlanning, reminderModification } = module.exports;
  const when = new Date(2026, 10, 20, 9, 0).getTime(), task = { reminderAt: when };
  assert.equal(reminderPlanning(task).time.start, '09:00');
  assert.equal(reminderPlanning({ reminderAt: null }), null);
  const set = reminderModification(task, { date: '2026-11-21' });
  assert.equal(set.field, 'SET_REMINDER'); assert.equal(set.value, new Date(2026, 10, 21, 9, 0).getTime());
  assert.equal(reminderModification(task, null).value, null);
  assert.equal(reminderModification({ reminderAt: null }, { date: '2026-11-21' }).value, new Date(2026, 10, 21).getTime());
  assert.throws(() => reminderModification(task, { date: '2026-11-21', time: { start: '09:00', end: '10:00' } }));
});

test('重复完成后的已确认提醒时间更新会取消旧响铃实例并安排下一轮，不重复登记', async () => {
  const f = fixture(), task = f.task(); f.tasks([task]); f.service.start({}); await f.refresh();
  assert.equal(f.writes.length, 1);
  f.clock.now = task.reminderAt + 1000;
  task.reminderAt += 7 * 86400000;
  for (const listener of f.listeners) listener({ optimistic: false });
  await f.refresh();
  assert.equal(f.cancelled.length, 1); assert.equal(f.writes.length, 2); assert.equal(f.system.size, 1);
  assert.equal(f.service.status(task), '提醒已安排');
  const date = new Date(task.reminderAt), next = f.writes[1].dateTime;
  assert.equal(next.day, date.getDate()); assert.equal(next.hour, date.getHours());
  await f.refresh(); assert.equal(f.writes.length, 2);
  f.tasks([]);
  for (const listener of f.listeners) listener({ optimistic: false });
  await f.refresh(); assert.equal(f.system.size, 0);
  f.service.stop();
});

test('Loki 后继的已确认提醒进入订阅后取消完成来源的实例，只为新节点安排一次', async () => {
  const f = fixture(), source = f.task('source', 60000); f.tasks([source]); f.service.start({}); await f.refresh();
  const successor = f.task('successor', 6 * 30 * 86400000);
  successor.heading = '后继任务'; f.tasks([successor]);
  for (const listener of f.listeners) listener({ optimistic: false });
  await f.refresh();
  assert.equal(f.cancelled.length, 1); assert.equal(f.writes.length, 2); assert.equal(f.system.size, 1);
  assert.equal(f.writes[1].content, '后继任务'); assert.equal(f.service.status(successor), '提醒已安排');
  await f.refresh(); assert.equal(f.writes.length, 2);
  f.service.stop();
});
