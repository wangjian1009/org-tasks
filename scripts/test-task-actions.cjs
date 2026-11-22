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
  if (page === 'logbook') {
    const single = source.match(/@Prop singleOperations:[^=]+=\s*(\[[^\n]+\])/)[1];
    const bulk = source.match(/@Prop bulkOperations:[^=]+=\s*(\[[^\n]+\])/)[1];
    return taskActionPolicy({singleOperations:vm.runInNewContext(single,{TaskOperation}),bulkOperations:vm.runInNewContext(bulk,{TaskOperation})});
  }
  const call = source.match(/taskActionPolicy\((\{[\s\S]*?\})(?:, TaskOperation\.([A-Za-z]+))?\)/);
  return taskActionPolicy(vm.runInNewContext('(' + call[1] + ')', { TaskOperation }), call[2] ? TaskOperation[call[2]] : undefined);
}

function checkDeferredSwipeMenu(expression, filename) {
  const { options } = compile('export function options(record) { return ' + expression + '; }', filename, { actions });
  const record = { id: 'source-record' };
  const page = { pageReady: true, actionPolicy: pagePolicy('inbox'), listScroller: {},
    selection: {selecting:false,starting:false,busy:false},
    taskDataSet: () => ({ taskKey: id => id }) };
  const value = options.call(page, record);
  assert.equal(value.menuContent, undefined);
  assert.equal(value.selection,page.selection);
  assert.equal(value.menuIdPrefix,'inbox_swipe');
  assert.equal(value.rightSwipeAction,TaskOperation.Schedule);
  for(const flag of ['selecting','starting','busy']){
    page.selection[flag]=true;assert.equal(options.call(page,record).busy,true,flag);
    if(flag==='starting')assert.equal(options.call(page,record).interactionEnabled,false);
    page.selection[flag]=false;
  }
  page.actionBusy=true;assert.equal(options.call(page,record).busy,true);

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
test('收起任务行使用普通点击，链接可优先处理，checkbox 独立操作', { skip: !fs.existsSync(emittedTask) }, () => {
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
      pop() { stack.pop(); }, width() {}, layoutWeight() {}, constraintSize() {}, padding() {}, accessibilityText() {}, onClick(callback) { current().click = callback; }, onTouch(callback) { current().touch = callback; } };
    const If = { create() {}, pop() {} };
    const toggleFromCompact = fs.readFileSync('entry/src/main/ets/components/editors/TaskEditor.ets', 'utf8')
      .match(/  private toggleFromCompact\(\): void \{[\s\S]*?\n  \}/)[0];
    const code = ts.transpileModule('export class Card {' + builder + toggleFromCompact + '}', {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const module = { exports: {} };
    let protectedInteraction = false;
    vm.runInThisContext('(function(module,exports,Row,If,LinkEditController,UiSize,taskTitleText){' + code + '\n})')(
      module, module.exports, Row, If, { interactionProtected: () => protectedInteraction },
      { taskRow: 44 }, () => '任务');
    const parts = new Map();
    const leaf = name => { const node = { parent: current() }; current().children.push(node); parts.set(name, node); };
    let expanded = 0;
    const card = Object.assign(new module.exports.Card(), { value: () => ({ state }),
      observeComponentCreation2: callback => callback(1, true), ifElseBranchUpdateFunction: (_, callback) => callback(),
      compactTime() {}, leadingTime: () => false, stateIndicator: () => leaf('state'), toggle: () => expanded++,
      compactContent() { for (const name of ['title', 'link', 'priority', 'count', 'tag', 'repeat', 'indicator', 'duration', 'deadline', 'blank']) leaf(name); } });
    card.compactRow();
    const clickFor = node => { while (node && !node.click) node = node.parent; return node?.click; };
    for (const [name, node] of parts) {
      const click = clickFor(node);
      if (name === 'state' && state !== null) { assert.equal(click, undefined, 'checkbox 不应触发展开'); continue; }
      protectedInteraction = name === 'link';
      const before = expanded; click(); assert.equal(expanded, before + (protectedInteraction ? 0 : 1), name);
    }
    assert.equal(root.children[0].children.length, state === null ? 1 : 2);
    root.children = []; card.compactRow();
    assert.equal(typeof clickFor(parts.get('title')), 'function');
  }
});

test('ArkUI 编译产物保留统一控件的菜单回调，不参与普通列表测量', { skip: !fs.existsSync(emittedInbox) }, () => {
  const source = ts.createSourceFile(emittedInbox, fs.readFileSync(emittedInbox, 'utf8'), ts.ScriptTarget.Latest, true);
  let checked = 0;
  function visit(node) {
    if (ts.isNewExpression(node) && node.expression.getText(source) === 'TaskSwipeItem') {
      const options = node.arguments?.[1];
      if (options && ts.isObjectLiteralExpression(options) && options.properties.some(p => p.name?.getText(source) === 'selection')) {
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
  assert.deepEqual(taskSwipeMenu(inbox, () => {}).map(item => item.id), ['move', 'cancel', 'someday', 'memo', 'project', 'delete', 'select']);
  assert.deepEqual(taskBatchMenu(inbox, () => {}).map(item => item.id), ['move', 'cancel', 'someday', 'memo', 'merge', 'delete']);
  assert.deepEqual(taskBatchMenu(pagePolicy('logbook'), () => {}).map(item => item.id), ['delete']);
  inbox.singleOperations.length = 0;
  assert.equal(pagePolicy('inbox').singleOperations.length, 6);
  const input = { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] };
  const policy = taskActionPolicy(input);
  policy.singleOperations.push(TaskOperation.Move); policy.bulkOperations.length = 0;
  assert.deepEqual(input, { singleOperations: [TaskOperation.Delete], bulkOperations: [TaskOperation.Restore] });
  assert.deepEqual(pagePolicy('today').singleOperations, ['toggleState', 'toggleWait', 'cancel', 'someday', 'delete']);
  assert.deepEqual(pagePolicy('waiting').singleOperations, ['toggleState', 'toggleWait', 'cancel', 'someday', 'delete']);
  assert.deepEqual(pagePolicy('anytime').singleOperations, ['toggleState', 'toggleWait', 'cancel', 'someday', 'delete']);
  assert.deepEqual(pagePolicy('someday').singleOperations, ['restore', 'delete']);
  assert.deepEqual(pagePolicy('recent').singleOperations, ['toggleState', 'toggleWait', 'cancel', 'someday', 'delete']);
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
  const method = ['hostBlocked', 'gesturesBlocked', 'blocked', 'rightSwipeAvailable',  'operationEnabled', 'activateOperation'].map(name => source.match(new RegExp('  ' + '(?:async )?' + name + '\\([^\\n]*\\): [^\\n]+\\{[\\s\\S]*?\\n  \\}'))[0]).join('\n');
  const { Card } = compile('import { TaskOperation } from \"actions\"; export class Card {' + method + '}', adapterFile, { actions });
  const { Availability } = compile('export class Availability {' + cardSource.match(/  actionsAvailable\(\): boolean \{[\s\S]*?\n  \}/)[0] + '}', cardFile);
  const editor = Object.assign(new Availability(), { appeared: true });
  const controller = new TaskEditorController(), calls = [];
  controller.bind({ actionsAvailable: () => editor.actionsAvailable(), deletionAvailable: () => editor.actionsAvailable(), startSchedule: async () => { calls.push('schedule'); }, startMove: async () => { calls.push('move'); } });
  const state = Object.assign(new Card(), { active: true, interactionEnabled: true, singleOperations: [], rightSwipeAction: pagePolicy(page).rightSwipeAction, controller });
  return { state, editor, controller, calls };
}

test('等待页状态切换、取消、某天与删除按规划排序', () => {
  const menu = taskSwipeMenu(taskPageActionPolicy('waiting'), () => {}, 'Doing', 'Todo')
  assert.deepEqual(menu.map(item => item.id), ['toggleState', 'toggleWait', 'cancel', 'someday', 'delete', 'select'])
  assert.equal(menu[0].title, '开始')
  assert.equal(menu[1].title, '待办')
  assert.equal(menu[1].label, '恢复为待办')
})

test('今天、计划、随时、某天与最近新增均由外层右滑设置计划，日志簿关闭右滑', () => {
  for (const [page, action] of Object.entries({ someday: 'schedule', anytime: 'schedule', planned: 'schedule', today: 'schedule', inbox: 'schedule', recent: 'schedule' })) {
    const f = swipeCard(page);
    f.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(f.calls, [action], page);
  }
  const logbook = swipeCard('logbook'); logbook.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(logbook.calls, []);
  const inboxMenu = taskSwipeMenu(pagePolicy('inbox'), () => {});
  assert.deepEqual(inboxMenu.map(item => item.id), ['move', 'cancel', 'someday', 'memo', 'project', 'delete', 'select']);
  assert.equal(taskSwipeMenuWidth(inboxMenu), 304);
});

test('外部控制器仅作用于绑定卡片，卡片离开后不再打开编辑入口', () => {
  const a = swipeCard('today'), b = swipeCard('someday');
  a.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(a.calls, ['schedule']); assert.deepEqual(b.calls, []);
  a.controller.release(); a.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(a.calls, ['schedule']);
  b.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(b.calls, ['schedule']);
});

test('收件箱单条右滑和移动通过编辑器执行，不依赖批量启用数组', async () => {
  const f=swipeCard('inbox');f.state.singleOperations=[TaskOperation.Move];
  await f.state.activateOperation(TaskOperation.Schedule);await f.state.activateOperation(TaskOperation.Move);
  assert.deepEqual(f.calls,['schedule','move']);
  f.state.singleOperations=[];await f.state.activateOperation(TaskOperation.Move);assert.deepEqual(f.calls,['schedule','move']);
});

test('输入、清单触摸与拖动或操作忙碌时不执行右滑', () => {
  for (const flag of ['readOnly', 'typing', 'checklistTouch', 'draggingCheck', 'completing', 'working', 'moveBusy', 'moveOpen', 'snapshotBlocked', 'removed']) {
    const f = swipeCard('today'); f.editor[flag] = true;
    f.state.activateOperation(TaskOperation.Schedule); assert.deepEqual(f.calls, [], flag);
  }
});

test('单条与批量操作列表独立控制能力、顺序与回调，多选固定在最后', () => {
  for (const id of [TaskOperation.Move, TaskOperation.Schedule, TaskOperation.Deadline, TaskOperation.Cancel, TaskOperation.Someday, TaskOperation.Memo, TaskOperation.Delete]) {
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
const methods = toolbarSource.slice(toolbarSource.indexOf('  actionEnabled('), toolbarSource.indexOf('  @Builder'));
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

test('日志簿单条与批量均仅提供删除', () => {
  const policy = pagePolicy('logbook'), invoked = [];
  assert.deepEqual(taskSwipeMenu(policy, () => {}).map(item => item.id), ['delete', 'select']);
  const menu = taskBatchMenu(policy, action => invoked.push(action));
  assert.deepEqual(menu.map(item => item.title), ['删除']);
  menu[0].action(); assert.deepEqual(invoked, ['delete']);
  policy.bulkOperations = [TaskOperation.Delete];
  assert.deepEqual(taskBatchMenu(policy, () => {}).map(item => item.id), ['delete']);
  policy.bulkOperations = [];
  assert.deepEqual(taskBatchMenu(policy, () => {}), []);
});

// 今天只接入单条菜单，不连接选择控制器。
test('今天左滑严格按开始暂停、等待、取消、某天、删除排序，右滑改期且批量关闭', () => {
  const policy=pagePolicy('today');
  for(const [target,title] of [['Doing','开始'],['Todo','暂停']]){
    const items=taskSingleMenu(policy.singleOperations,()=>{},target,'Wait');
    assert.deepEqual(items.map(item=>item.id),['toggleState','toggleWait','cancel','someday','delete']);
    assert.deepEqual(items.map(item=>item.title),[title,'等待','取消','某天','删除']);
  }
  assert.deepEqual(taskBatchMenu(policy,()=>{}),[]);assert.equal(policy.rightSwipeAction,'schedule');
  assert.ok(!policy.singleOperations.includes('select'));
  const unsupported=taskSingleMenu(policy.singleOperations,()=>{});
  assert.deepEqual(unsupported.map(item=>item.id),['cancel','someday','delete']);
});

test('计划独立配置左滑与四项批量，固定追加多选并保留右滑改期',()=>{
 const policy=pagePolicy('planned');
 assert.deepEqual(taskSwipeMenu(policy,()=>{},null,'Wait').map(item=>item.id),['toggleWait','cancel','someday','delete','select']);
 const invoked=[];const items=taskBatchMenu(policy,action=>invoked.push(action));
 assert.deepEqual(items.map(item=>item.id),['schedule','deadline','someday','delete']);
 items[2].action();assert.deepEqual(invoked,['someday']);assert.equal(policy.rightSwipeAction,'schedule');
 assert.deepEqual(taskBatchMenu(pagePolicy('today'),()=>{}),[]);
});

// 页面级规划避免新增按钮与批量入口只更新了一侧。
test('八个页面区域的单条与批量菜单严格遵循交付规划', () => {
  const expected = {
    inbox: [['move','cancel','someday','memo','project','delete'],['move','cancel','someday','memo','merge','delete']],
    recent: [['toggleState','toggleWait','cancel','someday','delete'],[]],
    today: [['toggleState','toggleWait','cancel','someday','delete'],[]],
    waiting: [['toggleState','toggleWait','cancel','someday','delete'],[]],
    planned: [['toggleState','toggleWait','cancel','someday','delete'],['schedule','deadline','someday','delete']],
    anytime: [['toggleState','toggleWait','cancel','someday','delete'],['schedule','deadline','cancel','someday','delete']],
    someday: [['restore','delete'],['restore','delete']],
    logbook: [['delete'],['delete']]
  };
  for (const [page,[single,bulk]] of Object.entries(expected)) {
    const policy = pagePolicy(page);
    assert.deepEqual(taskSingleMenu(policy.singleOperations,()=>{},'Doing','Wait').map(item=>item.id),single,page);
    assert.deepEqual(taskBatchMenu(policy,()=>{}).map(item=>item.id),bulk,page);
  }
});

const emittedActionMenu = path.join(path.dirname(emittedInbox),'../components/TaskActionMenu.ts');
test('编译后的普通线框图标不调用 fillColor，删除和多选保留填充', {skip:!fs.existsSync(emittedActionMenu)}, () => {
  const source=ts.createSourceFile(emittedActionMenu,fs.readFileSync(emittedActionMenu,'utf8'),ts.ScriptTarget.Latest,true);
  let method;
  function visit(node){if(ts.isMethodDeclaration(node)&&node.name?.getText(source)==='actionIcon')method=node.getText(source);ts.forEachChild(node,visit);}
  visit(source);assert.ok(method);
  const fills=[];
  const Image={create(){},width(){},height(){},accessibilityLevel(){},fillColor(value){fills.push(value);}};
  const If={create(){},pop(){}};
  const result={exports:{}};
  const code=ts.transpileModule('export class Menu {'+method+'}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:result,exports:result.exports,Image,If,UiColor:{error:'red'},Color:{White:'white'}});
  const menu=new result.exports.Menu();
  menu.observeComponentCreation2=fn=>fn(1,true);menu.ifElseBranchUpdateFunction=(_branch,fn)=>fn();
  for(const style of [undefined,'normal'])menu.actionIcon({icon:{},style});
  assert.deepEqual(fills,[],'fillColor 即使传 undefined 也会破坏透明区域');
  menu.actionIcon({icon:{},style:'danger'});menu.actionIcon({icon:{},style:'selection'});
  assert.deepEqual(fills,['red','white']);
});
