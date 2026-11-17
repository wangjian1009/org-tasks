// 验证页面动作配置、动态菜单和批量操作的提交门槛。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-actions.cjs\n验证各页面菜单配置、显示顺序、批量入口开关、自定义动作与禁用条件，以及收件箱菜单延迟创建。存在 make build 产物时同时验证编译后的菜单配置和今天页整行展开与 checkbox 的点击边界。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function compile(source, filename, mocks = {}) {
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(module,exports,require,$r){' + code + '\n})', { filename })(
    module, module.exports, name => { assert.ok(Object.hasOwn(mocks, name), name); return mocks[name]; }, name => ({ name }));
  return module.exports;
}
const filename = 'entry/src/main/ets/ui/TaskActionPresentation.ets';
const actions = compile(fs.readFileSync(filename, 'utf8'), filename);
const { TaskOperation, taskActionPolicy, taskPageActionPolicy, taskSingleMenu, taskSwipeMenu, taskBatchMenu, taskSwipeMenuWidth } = actions;

function pagePolicy(page) {
  const file = page === 'inbox' ? 'entry/src/main/ets/pages/Inbox.ets' : 'entry/src/main/ets/components/LogbookTaskList.ets';
  if (!['inbox', 'logbook'].includes(page)) return taskPageActionPolicy(page);
  const source = fs.readFileSync(file, 'utf8');
  const call = source.match(/taskActionPolicy\((\{[\s\S]*?\})(?:, '([^']+)')?\)/);
  return taskActionPolicy(vm.runInNewContext('(' + call[1] + ')', { TaskOperation }), call[2]);
}

function checkDeferredSwipeMenu(expression, filename) {
  const { options } = compile('export function options(record) { return ' + expression + '; }', filename, { actions });
  const renders = [], activated = [], record = { id: 'source-record' };
  const page = { pageReady: true, actionPolicy: pagePolicy('inbox'), listScroller: {},
    taskDataSet: () => ({ taskKey: id => id }),
    swipeMenu(value, activate) { renders.push([this, value]); activate(TaskOperation.Schedule); } };
  const value = options.call(page, record);
  assert.deepEqual(renders, []);
  assert.equal(typeof value.menuContent, 'function'); value.menuContent(action => activated.push([record, action]));
  assert.deepEqual(renders, [[page, record]]);
  assert.equal(value.rightSwipeAction, 'schedule'); assert.equal(value.rightAction, undefined);
  assert.deepEqual(activated, [[record, 'schedule']]);
  renders.length = 0; page.actionPolicy = taskActionPolicy();
  assert.equal(options.call(page, record).rightSwipeAction, 'none');
  for (const flag of ['selectingRecords', 'actionBusy', 'selectionStarting', 'mergeBusy', 'selected']) {
    page[flag] = true; assert.equal(options.call(page, record).busy, true, flag);
    if (flag === 'selectionStarting') assert.equal(options.call(page, record).interactionEnabled, false);
    page[flag] = false;
  }
  assert.deepEqual(renders, []);
}

test('收件箱向统一控件注册菜单和右滑回调，普通布局不创建菜单节点', () => {
  const filename = 'entry/src/main/ets/pages/Inbox.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const start = source.indexOf('TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(record.id)');
  assert.ok(start >= 0);
  const end = source.indexOf('content:', start);
  checkDeferredSwipeMenu(source.slice(start + 'TaskSwipeItem('.length, end) + '}', filename);
});

const emittedInbox = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Inbox.ts';
const emittedTask = path.join(path.dirname(emittedInbox), '../components/editors/TaskEditor.ts');
test('今天页编译后的展开点击区覆盖全部内容，checkbox 始终在手势范围之外', { skip: !fs.existsSync(emittedTask) }, () => {
  const source = ts.createSourceFile(emittedTask, fs.readFileSync(emittedTask, 'utf8'), ts.ScriptTarget.Latest, true);
  let builder;
  function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name?.getText(source) === 'compactRow') builder = node.getText(source);
    ts.forEachChild(node, visit);
  }
  visit(source);
  assert.ok(builder, '缺少收起任务行编译产物');
  for (const state of [{ category: 'Todo' }, null]) {
    const root = { children: [] }, stack = [root];
    const current = () => stack.at(-1);
    const Row = { create() { const node = { children: [], parent: current() }; current().children.push(node); stack.push(node); },
      pop() { stack.pop(); }, width() {}, layoutWeight() {}, constraintSize() {}, padding() {}, accessibilityText() {}, onTouch(callback) { current().touch = callback; } };
    const If = { create() {}, pop() {} };
    const Gesture = { create(priority, mask) { current().gesture = { priority, mask }; }, pop() {} };
    const TapGesture = { create() {}, onAction(action) { current().gesture.action = action; }, pop() {} };
    const toggleFromCompact = fs.readFileSync('entry/src/main/ets/components/editors/TaskEditor.ets', 'utf8')
      .match(/  private toggleFromCompact\(\): void \{[\s\S]*?\n  \}/)[0];
    const code = ts.transpileModule('export class Card {' + builder + toggleFromCompact + '}', {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const module = { exports: {} };
    vm.runInThisContext('(function(module,exports,Row,If,globalThis,TapGesture,GesturePriority,GestureMask,UiSize,taskTitleText){' + code + '\n})')(
      module, module.exports, Row, If, { Gesture }, TapGesture, { High: 'high' }, { IgnoreInternal: 'ignore' },
      { taskRow: 44 }, () => '任务');
    const parts = new Map();
    const leaf = name => { const node = { parent: current() }; current().children.push(node); parts.set(name, node); };
    let expanded = 0;
    const card = Object.assign(new module.exports.Card(), { expandOnRowClick: true, value: () => ({ state }),
      observeComponentCreation2: callback => callback(1, true), ifElseBranchUpdateFunction: (_, callback) => callback(),
      compactTime() {}, leadingTime: () => false, stateIndicator: () => leaf('state'), toggle: () => expanded++,
      compactContent() { for (const name of ['title', 'link', 'priority', 'count', 'tag', 'repeat', 'indicator', 'duration', 'deadline', 'blank']) leaf(name); } });
    card.compactRow();
    const gestureFor = node => { while (node && !node.gesture) node = node.parent; return node?.gesture; };
    for (const [name, node] of parts) {
      const gesture = gestureFor(node);
      if (name === 'state' && state !== null) { assert.equal(gesture, undefined, 'checkbox 不应触发展开'); continue; }
      assert.equal(gesture?.priority, 'high', name);
      assert.equal(gesture?.mask, 'ignore', name);
      const before = expanded; gesture.action(); assert.equal(expanded, before + 1, name);
    }
    assert.equal(root.children[0].children.length, state === null ? 1 : 2);
    root.children = []; card.expandOnRowClick = false; card.compactRow();
    assert.equal(gestureFor(parts.get('title')), undefined, '未启用整行展开的入口保留原交互');
  }
});

test('ArkUI 编译产物保留统一控件的菜单回调，不参与普通列表测量', { skip: !fs.existsSync(emittedInbox) }, () => {
  const source = ts.createSourceFile(emittedInbox, fs.readFileSync(emittedInbox, 'utf8'), ts.ScriptTarget.Latest, true);
  let checked = 0;
  function visit(node) {
    if (ts.isNewExpression(node) && node.expression.getText(source) === 'TaskSwipeItem') {
      const options = node.arguments?.[1];
      if (options && ts.isObjectLiteralExpression(options) && options.properties.some(p => p.name?.getText(source) === 'menuContent')) {
        const properties = options.properties.filter(p => p.name?.getText(source) !== 'content').map(p => p.getText(source));
        checkDeferredSwipeMenu('({' + properties.join(',') + '})', emittedInbox); checked++;
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source); assert.ok(checked > 0, '缺少收件箱统一滑动控件编译产物');
});

test('操作列表默认留空，多选固定追加，页面配置与传入数组互不污染', () => {
  const defaults = taskActionPolicy();
  assert.deepEqual(taskSwipeMenu(defaults, () => {}).map(item => item.id), ['select']);
  assert.deepEqual(taskBatchMenu(defaults, () => {}), []);
  assert.deepEqual(defaults.singleOperations, []); assert.deepEqual(defaults.bulkOperations, []);
  const inbox = pagePolicy('inbox');
  assert.deepEqual(taskSwipeMenu(inbox, () => {}).map(item => item.id), ['move', 'someday', 'memo', 'delete', 'select']);
  assert.deepEqual(taskBatchMenu(inbox, () => {}).map(item => item.id), ['move', 'someday', 'memo', 'delete', 'merge']);
  assert.deepEqual(taskBatchMenu(pagePolicy('logbook'), () => {}).map(item => item.id), ['delete', 'restore']);
  inbox.singleOperations.length = 0;
  assert.equal(pagePolicy('inbox').singleOperations.length, 4);
  const input = { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] };
  const policy = taskActionPolicy(input);
  policy.singleOperations.push(TaskOperation.Move); policy.bulkOperations.length = 0;
  assert.deepEqual(input, { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] });
  assert.deepEqual(pagePolicy('today').singleOperations, ['toggleState', 'delete']);
  for (const page of ['planned', 'anytime', 'someday', 'recent']) {
    assert.deepEqual(pagePolicy(page).singleOperations, ['delete']);
  }
});

test('状态切换复用单条操作数组和菜单，状态只控制形态，数组控制启用及顺序', () => {
  const invoked = [], activate = action => invoked.push(action);
  const operations = [TaskOperation.Delete, TaskOperation.ToggleState];
  for (const [category, title, icon] of [['Doing', '开始', 'ui_task_start'], ['Todo', '暂停', 'ui_task_pause']]) {
    const menu = taskSingleMenu(operations, activate, category);
    assert.deepEqual(menu.map(item => item.id), ['delete', 'toggleState']);
    assert.equal(menu[1].title, title); assert.equal(menu[1].icon.name, `app.media.${icon}`);
    menu[1].action();
    const swipe = taskSwipeMenu(taskActionPolicy({ singleOperations: operations }), activate, category);
    assert.deepEqual(swipe.map(item => item.id), ['delete', 'toggleState', 'select']);
  }
  assert.deepEqual(invoked, ['toggleState', 'toggleState']);
  assert.deepEqual(taskSingleMenu(operations, activate).map(item => item.id), ['delete']);
  assert.deepEqual(taskSingleMenu([], activate, 'Doing'), []);
  assert.deepEqual(taskBatchMenu(taskActionPolicy({ singleOperations: operations }), activate), []);
});

const cardFile = 'entry/src/main/ets/components/editors/TaskEditor.ets';
const cardSource = fs.readFileSync(cardFile, 'utf8');
const controllerFile = 'entry/src/main/ets/ui/TaskEditorController.ets';
const { TaskEditorController } = compile(fs.readFileSync(controllerFile, 'utf8'), controllerFile);
function swipeCard(page) {
  const adapterFile = 'entry/src/main/ets/components/TaskSwipeItem.ets';
  const source = fs.readFileSync(adapterFile, 'utf8');
  const method = ['hostBlocked', 'gesturesBlocked', 'blocked', 'rightSwipeAvailable', 'activateRightSwipe', 'operationEnabled', 'activateOperation'].map(name => source.match(new RegExp('  ' + '(?:async )?' + name + '\\([^\\n]*\\): [^\\n]+\\{[\\s\\S]*?\\n  \\}'))[0]).join('\n');
  const { Card } = compile('import { TaskOperation } from \"actions\"; export class Card {' + method + '}', adapterFile, { actions });
  const { Availability } = compile('export class Availability {' + cardSource.match(/  actionsAvailable\(\): boolean \{[\s\S]*?\n  \}/)[0] + '}', cardFile);
  const editor = Object.assign(new Availability(), { appeared: true });
  const controller = new TaskEditorController(), calls = [];
  controller.bind({ actionsAvailable: () => editor.actionsAvailable(), deletionAvailable: () => editor.actionsAvailable(), startSchedule: async () => { calls.push('schedule'); }, startMove: async () => { calls.push('move'); } });
  const state = Object.assign(new Card(), { active: true, interactionEnabled: true, rightSwipeAction: pagePolicy(page).rightSwipeAction, controller });
  return { state, editor, controller, calls };
}

test('今天、计划、随时、某天与最近新增均由外层右滑设置计划，日志簿关闭右滑', () => {
  for (const [page, action] of Object.entries({ someday: 'schedule', anytime: 'schedule', planned: 'schedule', today: 'schedule', inbox: 'schedule', recent: 'schedule' })) {
    const f = swipeCard(page);
    f.state.activateRightSwipe(); assert.deepEqual(f.calls, [action], page);
  }
  const logbook = swipeCard('logbook'); logbook.state.activateRightSwipe(); assert.deepEqual(logbook.calls, []);
  const inboxMenu = taskSwipeMenu(pagePolicy('inbox'), () => {});
  assert.deepEqual(inboxMenu.map(item => item.id), ['move', 'someday', 'memo', 'delete', 'select']);
  assert.equal(taskSwipeMenuWidth(inboxMenu), 256);
});

test('外部控制器仅作用于绑定卡片，卡片离开后不再打开编辑入口', () => {
  const a = swipeCard('today'), b = swipeCard('someday');
  a.state.activateRightSwipe(); assert.deepEqual(a.calls, ['schedule']); assert.deepEqual(b.calls, []);
  a.controller.release(); a.state.activateRightSwipe(); assert.deepEqual(a.calls, ['schedule']);
  b.state.activateRightSwipe(); assert.deepEqual(b.calls, ['schedule']);
});

test('收件箱右滑的单条计划日期允许提交，左滑移动沿用同一入口，批量能力仍独立校验', async () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/Inbox.ets', 'utf8');
  const method = source.match(/  async performSelected\([^\n]+\n[\s\S]*?\n  \}/)[0];
  const writes = [];
  const { Inbox } = compile("import { taskBatchMenu, taskSwipeMenu } from 'actions'; import { InboxService } from 'service'; import { TaskSwipeOperations } from 'submit'; export class Inbox {" + method + '}', 'Inbox.ets', {
    actions, service: { InboxService: { async operationGroups(...args) { return [{ args }]; } } }, submit: { TaskSwipeOperations: { async submit(_dataSet, groups, allowed) { assert.equal(!!allowed(), true); writes.push(groups[0].args); } } }
  });
  const record = { id: 'source' }, date = { date: '2026-11-17' };
  const page = Object.assign(new Inbox(), { visible: true, actionPolicy: pagePolicy('inbox'), records: [record],
    tasksDataSet: { async operate(work) { await work('operation'); } },
    getUIContext: () => ({ getHostContext: () => ({}) }), selectedRecords: () => [record],
    resetSelection() {}, async loadRecords() {} });
  assert.equal(await page.performSelected('schedule', undefined, date, [record]), true);
  assert.equal(writes.length, 1); assert.equal(writes[0][2], 'schedule'); assert.equal(writes[0][4], date);
  assert.equal(await page.performSelected('move', { id: 'target' }, undefined, [record]), true);
  assert.equal(writes[1][2], 'move');
  assert.equal(await page.performSelected('schedule', undefined, date, [record, record]), false);
  page.selectingRecords = true;
  assert.equal(await page.performSelected('schedule', undefined, date, [record]), false);
  page.selectingRecords = false; page.actionPolicy = taskActionPolicy();
  assert.equal(await page.performSelected('schedule', undefined, date, [record]), false);
  assert.equal(writes.length, 2);
});

test('输入、清单触摸与拖动或操作忙碌时不执行右滑', () => {
  for (const flag of ['readOnly', 'typing', 'checklistTouch', 'draggingCheck', 'completing', 'working', 'moveBusy', 'moveOpen', 'snapshotBlocked', 'removed']) {
    const f = swipeCard('today'); f.editor[flag] = true;
    f.state.activateRightSwipe(); assert.deepEqual(f.calls, [], flag);
  }
});

test('单条与批量操作列表独立控制能力、顺序与回调，多选固定在最后', () => {
  for (const id of [TaskOperation.Move, TaskOperation.Schedule, TaskOperation.Deadline, TaskOperation.Someday, TaskOperation.Memo, TaskOperation.Delete]) {
    const invoked = [], policy = taskActionPolicy({ singleOperations: [id] });
    const swipe = taskSwipeMenu(policy, id => invoked.push(id));
    assert.deepEqual(swipe.map(item => item.id), [id, 'select']);
    assert.deepEqual(taskBatchMenu(policy, () => {}), []);
    policy.singleOperations = []; policy.bulkOperations = [id];
    assert.deepEqual(taskSwipeMenu(policy, () => {}).map(item => item.id), ['select']);
    const batch = taskBatchMenu(policy, id => invoked.push(id));
    assert.deepEqual(batch.map(item => item.id), [id]);
    assert.equal(swipe[0].icon.name, batch[0].icon.name);
    assert.equal(swipe[0].style, batch[0].style);
    swipe[0].action(); batch[0].action(); assert.deepEqual(invoked, [id, id]);
    policy.bulkOperations = []; assert.deepEqual(taskBatchMenu(policy, () => {}), []);
  }
  const policy = taskActionPolicy({ singleOperations: [TaskOperation.Delete, TaskOperation.Move], bulkOperations: [TaskOperation.Merge, TaskOperation.Delete] });
  assert.deepEqual(taskSwipeMenu(policy, () => {}).map(item => item.id), ['delete', 'move', 'select']);
  assert.deepEqual(taskBatchMenu(policy, () => {}).map(item => item.id), ['merge', 'delete']);
  assert.equal(taskSwipeMenuWidth([]), 0);
});

const toolbarFile = 'entry/src/main/ets/components/TaskActionMenu.ets';
const toolbarSource = fs.readFileSync(toolbarFile, 'utf8');
const methods = toolbarSource.slice(toolbarSource.indexOf('  actionEnabled('), toolbarSource.indexOf('  build()'));
function toolbar(state) {
  const source = 'import { taskBatchActionEnabled } from "actions"; export class Toolbar {' + methods + '}';
  const { Toolbar } = compile(source, toolbarFile, { actions });
  return Object.assign(new Toolbar(), { count: 0, selecting: true, busy: false, invalid: false }, state);
}

test('批量栏支持页面自定义按钮与最少选择数，忙碌或失效时不执行回调', () => {
  let calls = 0;
  const custom = { id: 'custom', title: '自定义', label: '自定义动作', icon: {}, minimumSelection: 3, action: () => calls++ };
  const state = toolbar({ count: 2 }); state.activate(custom); assert.equal(calls, 0);
  state.count = 3; state.activate(custom); assert.equal(calls, 1);
  state.busy = true; state.activate(custom); assert.equal(calls, 1);
  state.busy = false; state.invalid = true; state.activate(custom); assert.equal(calls, 1);
  state.invalid = false; state.count = 0; state.activate({ ...custom, minimumSelection: undefined }); assert.equal(calls, 1);
});

test('收件箱合并按钮至少选择两条，使用配置的回调', () => {
  const invoked = [], menu = taskBatchMenu(taskActionPolicy({ bulkOperations: [TaskOperation.Merge] }), id => invoked.push(id));
  const state = toolbar({ count: 1 });
  state.activate(menu[0]); assert.deepEqual(invoked, []);
  state.count = 2; state.activate(menu[0]); assert.deepEqual(invoked, ['merge']);
});


test('共享选择行固定提供长按进入与点按切换，选中状态或忙碌时不重新进入', () => {
  const source = fs.readFileSync('entry/src/main/ets/components/TaskSelectionRow.ets', 'utf8');
  const methods = source.slice(source.indexOf('  selectionActive()'), source.indexOf('  build()'));
  const { SelectionRow } = compile('export class SelectionRow {' + methods + '}', 'TaskSelectionRow.ets');
  let begins = 0, toggles = 0;
  const row = Object.assign(new SelectionRow(), { selecting: false, busy: false,
    begin: () => begins++, toggle: () => toggles++ });
  assert.equal(row.selectionActive(), false);
  row.beginSelection(); assert.equal(begins, 1);
  row.toggleSelection(); assert.equal(toggles, 0);
  row.selecting = true; row.beginSelection(); assert.equal(begins, 1);
  row.toggleSelection(); assert.equal(toggles, 1);
  row.busy = true; row.beginSelection(); row.toggleSelection();
  assert.equal(begins, 1); assert.equal(toggles, 1);
});

test('日志簿左滑进入多选，批量恢复由操作列表独立控制', () => {
  const policy = pagePolicy('logbook'), invoked = [];
  assert.deepEqual(taskSwipeMenu(policy, () => {}).map(item => item.id), ['delete', 'select']);
  const menu = taskBatchMenu(policy, action => invoked.push(action));
  assert.deepEqual(menu.map(item => item.title), ['删除', '恢复']);
  menu[1].action(); assert.deepEqual(invoked, ['restore']);
  policy.bulkOperations = [TaskOperation.Delete];
  assert.deepEqual(taskBatchMenu(policy, () => {}).map(item => item.id), ['delete']);
  policy.bulkOperations = [];
  assert.deepEqual(taskBatchMenu(policy, () => {}), []);
});
