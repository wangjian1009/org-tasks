// 验证日志簿完成与取消任务编排，以及共享卡片只读会话不会打开编辑入口或写入。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-logbook.cjs\n验证完成与取消任务的时间分组、分类／项目平级分组、顺序、缺失时间、只读卡片及批量删除与恢复的交互边界。');
  process.exit(0);
}
const ts = require(path.join('/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function compile(source, mocks = {}) {
  const module = { exports: {} };
  const code = transpileFixture(ts, source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(require,module,exports,TaskInlineSession,LogShowPolicy,ReminderManager){' + code + '\n})')(
    name => name === './TaskOperationGroups' ? compile(fs.readFileSync('entry/src/main/ets/services/TaskOperationGroups.ets', 'utf8')) : mocks[name],
    module, module.exports, mocks.session, { LogShowBySwitch: 'LogShowBySwitch', LogShowAlways: 'LogShowAlways' },
    { subscribe: () => () => {} });
  return module.exports;
}
const regions = compile(fs.readFileSync('entry/src/main/ets/ui/TaskRegionPresentation.ets', 'utf8'));
const { logbookGroups } = compile(fs.readFileSync('entry/src/main/ets/ui/LogbookPresentation.ets', 'utf8'), {
  './TaskRegionPresentation': regions,
  './Theme': { localDate: d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
});
const time = (value) => new Date(value).getTime();
const now = new Date('2026-11-12T12:00:00');
function task(id, created, closed, category = 'Done', project = null, region = '工作', repoId = 'repo', filePath = 'task.org') {
  return { id, repoId, filePath, category: region, heading: id, createdAt: created ? time(created) : null, closedAt: closed ? time(closed) : null,
    state: { name: '任意自定义名字', category }, project: () => project, logs: [], editContent: { notes: '', checklist: [] } };
}
test('日志簿请求完成与取消分类，由 Core 排除未完成任务', () => {
  const { overviewTaskQuery } = compile(fs.readFileSync('entry/src/main/ets/services/TaskViewQueries.ets', 'utf8'));
  assert.deepEqual(overviewTaskQuery('logbook'), { expression: 'it.done' });
});
test('完成与取消任务各按关闭时间出现一次，创建时间不增加记录或改变顺序', () => {
  const a = task('A', '2026-11-12T09:00', '2026-11-12T11:30');
  const b = task('B', '2025-01-01T08:00', '2026-11-12T10:00', 'Cancel');
  const groups = logbookGroups([b, a], now);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].subtitle, '今天');
  assert.deepEqual(groups[0].items.map(item => item.task), [a, b]);
  assert.equal(new Set(groups[0].items.map(item => item.key)).size, 2);
});
test('按日任务将项目与分类平级分组，普通任务按分类合并且不丢失任务', () => {
  const tasks = [task('A', null, '2026-11-12T11:30', 'Done', '工作'),
    task('B', null, '2026-11-12T11:00'),
    task('C', null, '2026-11-12T10:30', 'Done', '工作'),
    task('D', null, '2026-11-12T10:00')];
  const day = logbookGroups(tasks, now)[0];
  assert.deepEqual(day.groups.map(group => [group.kind, group.title, group.items.map(item => item.task.id)]),
    [['project', '工作', ['A', 'C']], ['category', '工作', ['B', 'D']]]);
  assert.equal(day.groups.flatMap(group => group.items).length, tasks.length);
});
test('最近七天按日，更早按月与年，分组只使用完成日期', () => {
  const groups = logbookGroups([task('A', '2025-01-02T09:00', '2026-11-11T11:30'),
    task('B', '2026-10-31T08:00', '2026-11-05T10:00'), task('C', null, '2025-01-02T09:00')], now);
  assert.deepEqual(groups.map(g => [g.key, g.kind]), [['2026-11-11', 'day'], ['2026-11', 'month'], ['2025', 'year']]);
  assert.equal(groups[0].subtitle, '昨天');
  assert.equal(groups[1].groups.length, 0);
});
test('月年区域不合并分类或项目，混合任务严格按完成日期倒序', () => {
  const tasks = [
    task('month-old', '2026-11-12T12:00', '2026-11-02T09:00', 'Done', '项目甲'),
    task('year-old', '2026-11-12T13:00', '2025-01-02T09:00', 'Done', '项目甲'),
    task('month-latest', '2025-01-01T08:00', '2026-11-05T10:00', 'Done', '项目甲'),
    task('month-between', null, '2026-11-04T11:00', 'Done', null, '其他分类'),
    task('month-same-day', null, '2026-11-05T09:00', 'Done', '项目乙'),
    task('year-latest', '2025-01-01T08:00', '2025-12-03T10:00', 'Done', '项目甲'),
    task('year-between', null, '2025-06-10T11:00', 'Done', null, '其他分类')
  ];
  const groups = logbookGroups(tasks, now);
  assert.deepEqual(groups.map(g => [g.kind, g.key]), [['month', '2026-11'], ['year', '2025']]);
  assert.deepEqual(groups[0].items.map(item => item.task.id),
    ['month-latest', 'month-same-day', 'month-between', 'month-old']);
  assert.deepEqual(groups[1].items.map(item => item.task.id), ['year-latest', 'year-between', 'year-old']);
  for (const group of groups) assert.deepEqual(group.groups, []);
  assert.equal(groups.flatMap(group => group.items).length, tasks.length);
});
test('缺失或无效完成时间放在末尾，不借用创建时间，空快照不生成分组', () => {
  const groups = logbookGroups([task('A', '2026-11-12T08:00', null), task('B', null, null, 'Cancel'),
    task('C', null, '2026-11-12T10:00')], now);
  assert.deepEqual(groups.map(g => g.kind), ['day', 'unknown']);
  assert.deepEqual(groups[1].items.map(item => [item.task.id, item.timestamp]), [['A', null], ['B', null]]);
  assert.equal(logbookGroups([], now).length, 0);
});
const { taskEventLogs } = compile(fs.readFileSync('entry/src/main/ets/ui/TaskLogPresentation.ets', 'utf8'));
const source = fs.readFileSync('entry/src/main/ets/components/editors/TaskEditor.ets', 'utf8');
function readOnlyCard(instanceKey = 'event-A') {
  const methods = ['aboutToAppear', 'value', 'moreItems', 'prepare', 'toggle', 'toggleFromCompact', 'collapseAnimated', 'finish', 'persist', 'saveText', 'saveCheck',
    'actionsAvailable', 'startMove', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'startSchedule', 'repeats', 'tags', 'priorities', 'choosePriority', 'startCheckDrag', 'inputFocus'];
  const chunks = methods.map(name => {
    const result = source.match(new RegExp('  (?:private )?(?:async )?' + name + '\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));
    assert.ok(result, name); return result[0];
  });
  let released;
  const session = { begin: async () => true, release: key => { released = key; } };
  const { Card } = compile('import { taskEventLogs } from \'logs\'; export class Card {\n' + chunks.join('\n') + '\n}', { session, logs: { taskEventLogs } });
  const card = Object.assign(new Card(), { readOnly: true, logShowPolicy: 'LogShowBySwitch', instanceKey, task: task('A', null, null),
    localDataSet() { return { taskSource: () => ({
      rowId: instanceKey, task: card.task, monitor: () => () => {}
    }) }; },
    getUIContext() { return { animateTo(_, change) { change(); } }; } });
  global.Curve = { EaseInOut: 0 };
  card.aboutToAppear();
  return { card, released: () => released };
}
test('只读卡片可展开收起，任务实例保持独立会话身份', async () => {
  const a = readOnlyCard('A'), b = readOnlyCard('B');
  global.$r = name => name;
  a.card.task.logs = [{ type: 'taskStateChange', from: 'TODO', to: 'DONE', timestamp: '2026-11-13', noteHtml: '<p>历史</p>' }];
  await a.card.toggle(); assert.equal(a.card.expanded, true);
  assert.equal(a.card.logbookExpanded, false);
  assert.deepEqual(a.card.moreItems().map(item => item.title), ['日志']);
  assert.equal(a.card.moreItems()[0].icon, 'app.media.ui_visibility');
  a.card.moreItems()[0].action();
  assert.equal(a.card.logbookExpanded, true);
  assert.equal(a.card.moreItems()[0].title, '日志');
  assert.equal(a.card.moreItems()[0].icon, 'app.media.ui_visibility_off');
  a.card.moreItems()[0].action();
  assert.equal(a.card.logbookExpanded, false);
  a.card.moreItems()[0].action();
  await a.card.toggle(); assert.equal(a.card.expanded, false); assert.equal(a.released(), 'A');
  await a.card.toggle(); assert.equal(a.card.logbookExpanded, false);
  await b.card.toggle(); assert.equal(b.card.ownerKey, 'B');
  assert.deepEqual(b.card.moreItems(), []);
  assert.notEqual(a.card.ownerKey, b.card.ownerKey);
});
const emittedTask = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/editors/TaskEditor.ts';
test('只有 note 或完成说明时不提供日志开关', () => {
  const { card } = readOnlyCard();
  card.task.logs = [{ type: 'taskNote', timestamp: '2026-11-17', noteHtml: '<p>备注</p>' },
    { type: 'taskClosingNote', timestamp: '2026-11-17', noteHtml: '<p>完成说明</p>' }];
  assert.deepEqual(card.moreItems(), []);
});
test('日志簿收起标题的实际点击回调可展开只读卡片，再点标题可收起', { skip: !fs.existsSync(emittedTask) }, async () => {
  const file = ts.createSourceFile(emittedTask, fs.readFileSync(emittedTask, 'utf8'), ts.ScriptTarget.Latest, true);
  let params;
  function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name?.getText(file) === 'compactTitle') {
      function findTitle(child) {
        if (ts.isNewExpression(child) && child.expression.getText(file) === 'TitleText') params = child.arguments[1].getText(file);
        ts.forEachChild(child, findTitle);
      }
      findTitle(node);
    }
    ts.forEachChild(node, visit);
  }
  visit(file);
  assert.ok(params, '缺少收起标题的编译参数');
  const { titleParams } = compile(`import { TaskStateCategory } from 'states'; import { UiSize } from 'theme'; export function titleParams() { return ${params}; }`, {
    theme: { UiSize: { taskTitleLineHeight: 22 } },
    states: { TaskStateCategory: { Cancel: 'Cancel' } }
  });
  const { card } = readOnlyCard();
  const title = titleParams.call(card);
  assert.equal(typeof title.activate, 'function', '标题必须接入展开回调，不能仅依赖父容器点击');
  title.activate();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(card.expanded, true);
  title.activate();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(card.expanded, false);
  assert.equal(card.typing, undefined);
});
test('只读模式阻止所有编辑、完成与清单修改，保存不产生请求', async () => {
  const { card } = readOnlyCard();
  for (const name of ['startMove', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'startSchedule', 'repeats', 'tags', 'priorities', 'choosePriority', 'startCheckDrag', 'inputFocus']) {
    await card[name]();
  }
  assert.equal(await card.persist([{ field: 'TITLE', value: '不允许的修改' }]), false);
  assert.equal(await card.saveText(), true); assert.equal(await card.saveCheck(false), true);
  assert.equal(card.editTask, undefined); assert.equal(card.typing, undefined);
});
