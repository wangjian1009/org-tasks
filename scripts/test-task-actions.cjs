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
const { TaskOperation, taskActionPolicy, taskPageActionPolicy, taskSwipeMenu, taskBatchMenu, taskSwipeMenuWidth } = actions;

function pagePolicy(page) {
  const file = page === 'inbox' ? 'entry/src/main/ets/pages/Inbox.ets' : 'entry/src/main/ets/components/LogbookTaskList.ets';
  if (!['inbox', 'logbook'].includes(page)) return taskPageActionPolicy(page);
  const source = fs.readFileSync(file, 'utf8');
  const call = source.match(/taskActionPolicy\((\{[\s\S]*?\})(?:, '([^']+)')?\)/);
  return taskActionPolicy(vm.runInNewContext('(' + call[1] + ')', { TaskOperation }), call[2]);
}

function checkDeferredSwipeMenu(expression, filename) {
  const { options } = compile('export function options(record) { return ' + expression + '; }', filename,
    { actions });
  const renders = [], record = { id: 'source-record' };
  const page = { selectingRecords: false, actionPolicy: pagePolicy('inbox'),
    swipeMenu(value) { renders.push([this, value]); } };
  // 只注入框架常量，执行产品表达式本身：普通布局阶段不得产生菜单节点。
  global.SwipeEdgeEffect = { None: 0 };
  try {
    const value = options.call(page, record);
    assert.deepEqual(renders, []);
    assert.equal(typeof value.end.builder, 'function');
    value.end.builder();
    assert.deepEqual(renders, [[page, record]]);
    assert.equal(typeof value.start?.onAction, 'function', '右滑应注册移动动作');
    assert.equal(value.start.actionAreaDistance, 48);
    renders.length = 0;
    page.actionPolicy = taskActionPolicy();
    assert.equal(typeof options.call(page, record).end.builder, 'function');
    assert.equal(options.call(page, record).start, undefined);
    for (const flag of ['selectingRecords', 'actionBusy', 'selectionStarting', 'mergeBusy', 'checklistDragging', 'selected', 'inlineTyping']) {
      page[flag] = true;
      assert.deepEqual(options.call(page, record), {}, flag);
      page[flag] = false;
    }
    assert.deepEqual(renders, []);
  } finally { delete global.SwipeEdgeEffect; }
}

test('收件箱普通布局不执行左滑菜单，打开菜单才为当前记录创建节点', () => {
  const filename = 'entry/src/main/ets/pages/Inbox.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const expression = source.match(/\.swipeAction\((this\.selectingRecords[\s\S]*?)\)\.enabled\(!this\.selectionStarting\)/)[1];
  checkDeferredSwipeMenu(expression, filename);
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
      pop() { stack.pop(); }, width() {}, layoutWeight() {}, constraintSize() {}, padding() {}, accessibilityText() {} };
    const If = { create() {}, pop() {} };
    const Gesture = { create(priority, mask) { current().gesture = { priority, mask }; }, pop() {} };
    const TapGesture = { create() {}, onAction(action) { current().gesture.action = action; }, pop() {} };
    const code = ts.transpileModule('export class Card {' + builder + '}', {
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
      stateIndicator: () => leaf('state'), toggle: () => expanded++,
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

test('ArkUI 编译产物保留延迟 builder，避免菜单参与普通列表测量', { skip: !fs.existsSync(emittedInbox) }, () => {
  const source = ts.createSourceFile(emittedInbox, fs.readFileSync(emittedInbox, 'utf8'), ts.ScriptTarget.Latest, true);
  let checked = 0;
  function visit(node) {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === 'swipeAction' && node.arguments[0]?.getText(source).startsWith('this.selectingRecords')) {
      checkDeferredSwipeMenu(node.arguments[0].getText(source), emittedInbox);
      checked++;
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  assert.ok(checked > 0, '缺少收件箱 swipeAction 编译产物');
});

test('操作列表默认留空，多选固定追加，页面配置与传入数组互不污染', () => {
  const defaults = taskActionPolicy();
  assert.deepEqual(taskSwipeMenu(defaults, () => {}).map(item => item.id), ['select']);
  assert.deepEqual(taskBatchMenu(defaults, () => {}), []);
  assert.deepEqual(defaults.singleOperations, []); assert.deepEqual(defaults.bulkOperations, []);
  const inbox = pagePolicy('inbox');
  assert.deepEqual(taskSwipeMenu(inbox, () => {}).map(item => item.id), ['someday', 'memo', 'delete', 'select']);
  assert.deepEqual(taskBatchMenu(inbox, () => {}).map(item => item.id), ['move', 'someday', 'memo', 'delete', 'merge']);
  assert.deepEqual(taskBatchMenu(pagePolicy('logbook'), () => {}).map(item => item.id), ['delete', 'restore']);
  inbox.singleOperations.length = 0;
  assert.equal(pagePolicy('inbox').singleOperations.length, 3);
  const input = { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] };
  const policy = taskActionPolicy(input);
  policy.singleOperations.push(TaskOperation.Move); policy.bulkOperations.length = 0;
  assert.deepEqual(input, { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] });
  for (const page of ['today', 'planned', 'anytime', 'someday', 'recent']) {
    assert.deepEqual(pagePolicy(page).singleOperations, []);
  }
});

const cardFile = 'entry/src/main/ets/components/editors/TaskEditor.ets';
const cardSource = fs.readFileSync(cardFile, 'utf8');
test('收件箱左滑交给原生菜单且保留右滑，日志簿只读模式拒绝卡片手势', () => {
  const direction = cardSource.match(/\.priorityGesture\(PanGesture\(\{ direction: ([^,\n]+), distance: 48/)[1];
  const decision = cardSource.match(/\.onGestureJudgeBegin\(\(\) => ([^\n]+)\)/)[1];
  const { gesture } = compile(`const PanDirection = { Right:'right', Horizontal:'horizontal' };
    const GestureJudgeResult = { REJECT:'reject', CONTINUE:'continue' };
    export function gesture() { return { direction: ${direction}, decision: ${decision} }; }`, cardFile);
  const inbox = { enableSwipeActions:true, rightSwipeAction:'move', readOnly:false };
  assert.deepEqual(gesture.call(inbox), {direction:'right',decision:'continue'});
  assert.deepEqual(gesture.call({enableSwipeActions:false,rightSwipeAction:'schedule'}), {direction:'horizontal',decision:'continue'});
  for (const blocked of [{readOnly:true}, {rightSwipeAction:'none'}, {checklistTouch:true}, {typing:true}]) {
    assert.equal(gesture.call({...inbox,...blocked}).decision, 'reject');
  }
});

function cardMethod(name, async = false) {
  return cardSource.match(new RegExp('  ' + (async ? 'async ' : '') + name + '\\([^\\n]*\\) \\{[\\s\\S]*?\\n  \\}\\n'))[0];
}

function swipeCard(page) {
  const { Card } = compile('export class Card {' + cardMethod('horizontalSwipe') + cardMethod('rightSwipe') + '}', cardFile);
  const calls = [], policy = pagePolicy(page);
  const state = Object.assign(new Card(), {
    rightSwipeAction: policy.rightSwipeAction, enableSwipeActions: page === 'inbox',
    dates: deadline => calls.push(deadline ? 'deadline' : 'schedule'),
    toggleDoing: () => calls.push('doing'), openMove: () => calls.push('move'), swipe: left => calls.push(left ? 'menu' : 'right')
  });
  return { state, calls };
}

test('六个区域右滑分别执行移动、日期或进行中，左滑不执行右滑动作', () => {
  for (const [page, action] of Object.entries({ someday: 'move', anytime: 'schedule', planned: 'schedule', today: 'doing', inbox: 'move', recent: 'schedule' })) {
    const f = swipeCard(page);
    f.state.horizontalSwipe(60); assert.deepEqual(f.calls, [action], page);
    f.calls.length = 0;
    f.state.horizontalSwipe(-60); assert.deepEqual(f.calls, page === 'inbox' ? ['menu'] : [], page);
    f.calls.length = 0;
    for (const offset of [-48, 0, 48]) f.state.horizontalSwipe(offset);
    assert.deepEqual(f.calls, [], page);
  }
  const inboxMenu = taskSwipeMenu(pagePolicy('inbox'), () => {});
  assert.deepEqual(inboxMenu.map(item => item.id), ['someday', 'memo', 'delete', 'select']);
  assert.equal(taskSwipeMenuWidth(inboxMenu), 208);
});

test('输入、清单触摸与拖动或操作忙碌时不执行右滑', () => {
  for (const flag of ['typing', 'checklistTouch', 'draggingCheck', 'completing', 'working', 'moveBusy', 'moveOpen', 'snapshotBlocked', 'removed']) {
    const f = swipeCard('today'); f.state[flag] = true;
    f.state.horizontalSwipe(60); assert.deepEqual(f.calls, [], flag);
  }
});

function moveCard() {
  const saved = { id: 'task', fileVersion: 'saved', fullPath: { titles: ['改后的标题'] } };
  const target = { fileVersion: 'target-version', fullPath: { titles: ['目标'] }, category: '工作' };
  const calls = [], released = [];
  let save = async () => true, write = async () => {}, read = async () => saved, targets = async () => [target];
  // 方法按产品依赖运行，保留源与目标快照以检验保存、取消和版本冲突。
  const code = 'export class MoveCard {' + ['openMove', 'loadMoveTargets', 'moveTo'].map(name => cardMethod(name, true)).join('') + cardMethod('closeMove') + '}';
  const output = ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  class Missing extends Error {}
  vm.runInThisContext('(function(module,exports,TaskInlineService,TaskInlineSession,MoveToTargetService,refileSections,TaskInlineMissingError,coreErrorMessage){' + output + '\n})', { filename: cardFile })(
    module, module.exports, { reload: () => read() }, { release: key => released.push(key) },
    { targets: () => targets(), move: async (_context, source, selected) => { calls.push({ source, action: 'move', target: selected }); await write(); } },
    values => [{ category: '工作', targets: values }], Missing, error => error.message);
  const state = Object.assign(new module.exports.MoveCard(), {
    rightSwipeAction: 'move', appeared: true, moveRequest: 0, moveOpen: false, moveBusy: false, ownerKey: 'task',
    value: () => ({ fileVersion: 'old' }), prepare: async () => true, finish: () => save(),
    applySnapshot: task => { state.current = task; }, getUIContext: () => ({ getHostContext: () => ({}) }),
    removeDeletedTask: () => { state.removed = true; }
  });
  return { state, saved, target, calls, released, saveWith: fn => save = fn, writeWith: fn => write = fn, readWith: fn => read = fn, targetsWith: fn => targets = fn };
}

test('某天右滑先保存并读取最新源快照，确认移动携带原目标版本且防止重复提交', async () => {
  const f = moveCard(); let finishWrite;
  await f.state.openMove();
  assert.equal(f.state.moveOpen, true); assert.equal(f.state.moveSource, f.saved);
  f.writeWith(() => new Promise(resolve => { finishWrite = resolve; }));
  const pending = f.state.moveTo(f.target);
  await f.state.moveTo(f.target);
  assert.deepEqual(f.calls, [{ source: f.saved, action: 'move', target: f.target }]);
  finishWrite(); await pending;
  assert.equal(f.state.moveOpen, false); assert.equal(f.state.removed, true); assert.equal(f.state.moveBusy, false);
});

test('移动草稿保存失败不打开浮层，版本冲突保留源与目标会话供显式刷新', async () => {
  const failed = moveCard(); failed.saveWith(async () => false);
  await failed.state.openMove(); assert.equal(failed.state.moveOpen, false); assert.deepEqual(failed.calls, []);
  const f = moveCard(); await f.state.openMove();
  f.writeWith(async () => { throw new Error('文件版本冲突'); });
  await f.state.moveTo(f.target);
  assert.equal(f.state.moveOpen, true); assert.equal(f.state.moveMessage, '文件版本冲突');
  assert.equal(f.state.moveSource, f.saved); assert.equal(f.state.removed, undefined); assert.equal(f.calls.length, 1);
});

test('移动浮层取消后丢弃在途目标结果，卡片离开后不打开浮层', async () => {
  const f = moveCard(); let finishTargets;
  f.targetsWith(() => new Promise(resolve => { finishTargets = resolve; }));
  const pending = f.state.openMove();
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  assert.equal(f.state.moveOpen, true); f.state.closeMove();
  assert.equal(f.state.completing, false);
  finishTargets([f.target]); await pending;
  assert.equal(f.state.moveOpen, false); assert.deepEqual(f.state.moveSections, []); assert.deepEqual(f.calls, []);
  const left = moveCard(); left.readWith(async () => { left.state.appeared = false; return left.saved; });
  await left.state.openMove(); assert.equal(left.state.moveOpen, false);
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
