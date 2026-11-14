// 验证日志簿完成与取消任务编排，以及共享卡片只读会话不会打开编辑入口或写入。
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
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(require,module,exports,TaskInlineSession){' + code + '\n})')(name => mocks[name], module, module.exports, mocks.session);
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
  assert.deepEqual(overviewTaskQuery('logbook'), { expression: 'it.done', includeComposeTasks: true });
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
const source = fs.readFileSync('entry/src/main/ets/components/TaskListItem.ets', 'utf8');
function readOnlyCard(instanceKey = 'event-A') {
  const methods = ['aboutToAppear', 'value', 'moreItems', 'prepare', 'toggle', 'finish', 'persist', 'saveText', 'saveCheck',
    'horizontalSwipe', 'rightSwipe', 'openMove', 'toggleDoing', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'dates', 'repeats', 'tags', 'priorities', 'choosePriority', 'startCheckDrag', 'inputFocus'];
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
test('只读卡片可展开收起，任务实例保持独立会话身份', async () => {
  const a = readOnlyCard('A'), b = readOnlyCard('B');
  global.$r = name => name;
  a.card.task.logs = [{ type: 'taskNote', timestamp: '2026-11-13', noteHtml: '<p>历史</p>' }];
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
const emittedTask = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/TaskListItem.ts';
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
  const { titleParams } = compile(`import { TaskStateCategory } from 'states'; export function titleParams() { return ${params}; }`, {
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
test('只读模式阻止所有编辑、完成、清单修改与左右滑动，保存不产生请求', async () => {
  const { card } = readOnlyCard();
  for (const name of ['openMove', 'toggleDoing', 'complete', 'changeCheck', 'editCheck', 'addCheck', 'dates', 'repeats', 'tags', 'priorities', 'choosePriority', 'startCheckDrag', 'inputFocus']) {
    await card[name]();
  }
  card.horizontalSwipe(100); card.horizontalSwipe(-100); card.rightSwipe();
  assert.equal(await card.persist([{ field: 'TITLE', value: '不允许的修改' }]), false);
  assert.equal(await card.saveText(), true); assert.equal(await card.saveCheck(false), true);
  assert.equal(card.editTask, undefined); assert.equal(card.typing, undefined);
});

function batchService() {
  const submissions = [], loaded = [];
  const repos = [{ id: 'repo', rootDirectory: '/sync', load: async () => loaded.push('repo') },
    { id: 'local', rootDirectory: '/local', load: async () => loaded.push('local') }];
  const workspace = { repos: async () => repos, executeTaskOperations: async group => submissions.push(group) };
  const { LogbookService } = compile(fs.readFileSync('entry/src/main/ets/services/LogbookService.ets', 'utf8'), {
    './AppConfigService': { AppConfigService: { load: async () => ({ repos: [
      { rootDirectory: '/sync', webdavEnabled: true }, { rootDirectory: '/local', webdavEnabled: false }
    ] }) } },
    './NativeCoreService': { NativeCoreService: { workspaceFor: async () => workspace } },
    '../ui/TaskStatePresentation': { TaskStateCategory: { Todo: 'Todo' } }
  });
  return { service: LogbookService, submissions, loaded };
}
function batchTask(id, state = 'TODO', filePath = 'task.org', repoId = 'repo') {
  return { id, heading: id, repoId, filePath, fileVersion: 'version-' + filePath,
    fullPath: { repoId, file: filePath, titles: [id] },
    taskStateOf(category) { assert.equal(category, 'Todo'); return state === null ? null : { name: state }; } };
}
test('批量恢复按各文件有效待办状态一次提交，沿用源版本与同步队列', async () => {
  const f = batchService(), a = batchTask('A', 'NEXT'), b = batchTask('B', 'TODO'),
    c = batchTask('C', 'OPEN', 'other.org', 'local');
  await f.service.restore({}, [a, b, c]);
  assert.equal(f.submissions.length, 1);
  const group = f.submissions[0];
  assert.deepEqual(group.operations, [a, b, c].map((task, i) => ({ type: 'Modification', data: {
    path: task.fullPath, modifications: [{ field: 'TODO', value: ['NEXT', 'TODO', 'OPEN'][i] }]
  } })));
  assert.deepEqual(group.fileVersions, [
    { repoId: 'repo', file: 'task.org', version: 'version-task.org' },
    { repoId: 'local', file: 'other.org', version: 'version-other.org' }
  ]);
  assert.deepEqual(group.queueRepoIds, ['repo']);
});
test('任一任务缺少待办状态时不提交部分恢复，空选择不发起请求', async () => {
  const f = batchService();
  await f.service.restore({}, []); assert.deepEqual(f.loaded, []);
  await assert.rejects(() => f.service.restore({}, [batchTask('A'), batchTask('B', null)]), /没有可用的待办状态/);
  assert.deepEqual(f.submissions, []);
});
test('批量删除仍一次提交删除操作与去重后的源文件版本', async () => {
  const f = batchService(), tasks = [batchTask('A'), batchTask('B')];
  await f.service.remove({}, tasks);
  assert.equal(f.submissions.length, 1);
  assert.deepEqual(f.submissions[0].operations, tasks.map(task => ({ type: 'Deletion', data: { path: task.fullPath } })));
  assert.equal(f.submissions[0].fileVersions.length, 1);
});
function batchList() {
  const source = fs.readFileSync('entry/src/main/ets/components/LogbookTaskList.ets', 'utf8');
  const chunks = ['allItems', 'selectedItems', 'startSelection', 'toggleSelection', 'resetSelection', 'restoreTasks', 'removeTasks', 'performTasks']
    .map(name => source.match(new RegExp('  (?:async )?' + name + '\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'))[0]);
  const calls = [], messages = [];
  let perform = async () => {};
  const { List } = compile(`import { LogbookService } from 'service';
    import { TaskOperation } from 'actions';
    import { coreErrorMessage } from 'errors'; export class List { ${chunks.join('\n')} }`, {
    session: { end: async () => true },
    actions: compile(fs.readFileSync('entry/src/main/ets/ui/TaskActionPresentation.ets', 'utf8')),
    service: { LogbookService: { restore: async (_, tasks) => { calls.push(['restore', tasks]); await perform(); },
      remove: async (_, tasks) => { calls.push(['delete', tasks]); await perform(); } } },
    errors: { coreErrorMessage: error => error.message }
  });
  const items = [batchTask('A'), batchTask('B')].map(task => ({ key: task.id, task }));
  const list = Object.assign(new List(), { groups: [{ items }], selectedTaskKeys: [], selectingTasks: false,
    actionBusy: false, selectionSnapshot: [], listScroller: { closeAllSwipeActions() {} },
    policy: () => ({ singleOperations: ['delete'], bulkOperations: ['delete', 'restore'] }),
    refresh() { this.refreshed = true; }, getUIContext: () => ({ getHostContext: () => ({}),
      getPromptAction: () => ({ showToast: value => messages.push(value.message) }) }) });
  return { list, items, calls, messages, performWith: value => perform = value };
}
test('左滑多选选中当前任务，批量恢复期间防重复提交，成功退出并刷新', async () => {
  const f = batchList(); await f.list.startSelection(f.items[0]);
  assert.deepEqual(f.list.selectedTaskKeys, ['A']);
  f.list.toggleSelection(f.items[1]);
  let finish;
  f.performWith(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.list.restoreTasks();
  await Promise.resolve(); await Promise.resolve();
  assert.equal(f.list.busyAction, 'restore');
  await f.list.restoreTasks(); assert.equal(f.calls.length, 1);
  finish(); await pending;
  assert.equal(f.list.selectingTasks, false); assert.equal(f.list.refreshed, true);
  assert.deepEqual(f.list.selectedTaskKeys, []); assert.equal(f.list.actionBusy, false);
});
test('刷新不替换多选源版本，失败保留选择并显示错误，关闭开关后不提交', async () => {
  const f = batchList(); await f.list.startSelection(f.items[0]);
  f.list.groups = [{ items: [{ key: 'A', task: batchTask('A', 'NEW') }] }];
  f.performWith(async () => { throw new Error('文件版本已变化'); });
  await f.list.restoreTasks();
  assert.equal(f.calls[0][1][0], f.items[0].task);
  assert.deepEqual(f.list.selectedTaskKeys, ['A']); assert.equal(f.list.selectingTasks, true);
  assert.deepEqual(f.messages, ['文件版本已变化']); assert.equal(f.list.refreshed, undefined);
  f.list.policy = () => ({ singleOperations: ['delete'], bulkOperations: ['delete'] });
  await f.list.restoreTasks(); assert.equal(f.calls.length, 1);
});
