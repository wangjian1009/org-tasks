// 验证日志簿事件编排，以及共享卡片只读会话不会打开编辑入口或写入。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-logbook.cjs\n验证创建、完成／取消事件的时间分组、顺序、缺失时间与只读卡片的交互边界。');
  process.exit(0);
}
const ts = require(path.join('/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function compile(source, mocks = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(require,module,exports,TaskInlineSession){' + code + '\n})')(name => mocks[name], module, module.exports, mocks.session);
  return module.exports;
}
const { logbookGroups, logbookEventTime } = compile(fs.readFileSync('entry/src/main/ets/ui/LogbookPresentation.ets', 'utf8'), {
  './TaskStatePresentation': { TaskStateCategory: { Cancel: 'Cancel' } },
  './TaskListPresentation': { TaskDateDisplay: { None: 'None', Closed: 'Closed' } },
  './Theme': { localDate: d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
});
const time = (value) => new Date(value).getTime();
const now = new Date('2026-11-12T12:00:00');
function task(id, created, closed, category = 'Done', project = null) {
  return { id, heading: id, createdAt: created ? time(created) : null, closedAt: closed ? time(closed) : null,
    state: { name: '任意自定义名字', category }, project: () => project, editContent: { notes: '', checklist: [] } };
}
test('同一任务保留创建与关闭两件事件，同日按时刻倒序并区分取消分类', () => {
  const groups = logbookGroups([task('A', '2026-11-12T09:00', '2026-11-12T11:30'),
    task('B', '2026-11-12T08:00', '2026-11-12T10:00', 'Cancel')], now);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].subtitle, '今天');
  assert.deepEqual(groups[0].events.map(e => [e.task.id, e.label, logbookEventTime(e, groups[0])]),
    [['A', '完成', '11:30'], ['B', '取消', '10:00'], ['A', '创建', '09:00'], ['B', '创建', '08:00']]);
  assert.equal(new Set(groups[0].events.map(e => e.key)).size, 4);
});
test('按日事件按项目归并，未归入项目的事件保持独立', () => {
  const groups = logbookGroups([task('A', '2026-11-12T09:00', '2026-11-12T11:30', 'Done', '项目甲'),
    task('B', '2026-11-12T08:00', '2026-11-12T10:00', 'Done', '项目甲'),
    task('C', '2026-11-12T07:00', '2026-11-12T09:00')], now);
  assert.deepEqual(groups[0].groups.map(group => [group.project, group.events.length]), [['项目甲', 4], [null, 1], [null, 1]]);
  assert.equal(groups[0].events.every(event => event.dateDisplay === (event.kind === 'closed' ? 'Closed' : 'None')), true);
});
test('最近七天按日，更早按月与年，跨年和月末保持倒序', () => {
  const groups = logbookGroups([task('A', '2025-01-02T09:00', '2026-11-11T11:30'),
    task('B', '2026-10-31T08:00', '2026-11-05T10:00')], now);
  assert.deepEqual(groups.map(g => [g.key, g.kind]), [['2026-11-11', 'day'], ['2026-11', 'month'], ['2026-10', 'month'], ['2025', 'year']]);
  assert.equal(groups[0].subtitle, '昨天');
  assert.equal(logbookEventTime(groups[1].events[0], groups[1]), '11月5日 10:00');
});
test('缺失创建时间不伪造事件，缺失完成时间放在末尾且不借用创建时间', () => {
  const groups = logbookGroups([task('A', '2026-11-12T08:00', null), task('B', null, null, 'Cancel')], now);
  assert.deepEqual(groups.map(g => g.kind), ['day', 'unknown']);
  assert.deepEqual(groups[1].events.map(e => [e.task.id, e.label, e.timestamp]), [['A', '完成', null], ['B', '取消', null]]);
  assert.equal(logbookGroups([], now).length, 0);
});
const source = fs.readFileSync('entry/src/main/ets/components/TaskListItem.ets', 'utf8');
function readOnlyCard(instanceKey = 'event-A') {
  const methods = ['aboutToAppear', 'value', 'prepare', 'toggle', 'finish', 'persist', 'saveText', 'saveCheck',
    'horizontalSwipe', 'rightSwipe', 'openMove', 'toggleDoing', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'dates', 'repeats', 'tags', 'priorities', 'choosePriority', 'highestPriority', 'startCheckDrag', 'inputFocus'];
  const chunks = methods.map(name => {
    const result = source.match(new RegExp('  (?:async )?' + name + '\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));
    assert.ok(result, name); return result[0];
  });
  let released;
  const session = { begin: async () => true, release: key => { released = key; } };
  const { Card } = compile('export class Card {\n' + chunks.join('\n') + '\n}', { session });
  const card = Object.assign(new Card(), { readOnly: true, instanceKey, task: task('A', null, null), dataChanges: { revision: 1 },
    getUIContext() { return { animateTo(_, change) { change(); } }; } });
  global.Curve = { EaseInOut: 0 };
  card.aboutToAppear();
  return { card, released: () => released };
}
test('只读卡片可展开收起，同一任务不同事件使用独立会话身份', async () => {
  const a = readOnlyCard('A-created'), b = readOnlyCard('A-closed');
  await a.card.toggle(); assert.equal(a.card.expanded, true);
  await a.card.toggle(); assert.equal(a.card.expanded, false); assert.equal(a.released(), 'A-created');
  await b.card.toggle(); assert.equal(b.card.ownerKey, 'A-closed');
  assert.notEqual(a.card.ownerKey, b.card.ownerKey);
});
test('只读模式阻止所有编辑、完成、清单修改与左右滑动，保存不产生请求', async () => {
  const { card } = readOnlyCard();
  for (const name of ['openMove', 'toggleDoing', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'dates', 'repeats', 'tags', 'priorities', 'choosePriority', 'highestPriority', 'startCheckDrag', 'inputFocus']) {
    await card[name]();
  }
  card.horizontalSwipe(100); card.horizontalSwipe(-100); card.rightSwipe();
  assert.equal(await card.persist([{ field: 'TITLE', value: '不允许的修改' }]), false);
  assert.equal(await card.saveText(), true); assert.equal(await card.saveCheck(false), true);
  assert.equal(card.editTask, undefined); assert.equal(card.typing, undefined);
});
