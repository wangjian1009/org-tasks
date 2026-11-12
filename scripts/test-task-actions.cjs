// 验证页面动作配置、动态菜单和批量操作的提交门槛。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-actions.cjs\n验证各页面菜单配置、显示顺序、批量入口开关、自定义动作与禁用条件，以及收件箱菜单延迟创建。存在 make build 产物时同时验证编译后的菜单配置。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
const { taskPageActionPolicy, taskSwipeMenu, taskBatchMenu, taskSwipeMenuWidth } = actions;

function checkDeferredSwipeMenu(expression, filename) {
  const { options } = compile('export function options(record) { return ' + expression + '; }', filename,
    {});
  const renders = [], record = { id: 'source-record' };
  const page = { selectingRecords: false, actionPolicy: taskPageActionPolicy('inbox'),
    scheduleHint() {}, requestSchedule() {}, swipeMenu(value) { renders.push([this, value]); } };
  // 只注入框架常量，执行产品表达式本身：普通布局阶段不得产生菜单节点。
  global.SwipeEdgeEffect = { None: 0 };
  try {
    const value = options.call(page, record);
    assert.deepEqual(renders, []);
    assert.equal(typeof value.end.builder, 'function');
    value.end.builder();
    assert.deepEqual(renders, [[page, record]]);
    renders.length = 0;
    page.actionPolicy.swipeActions = [];
    assert.equal(options.call(page, record).end, undefined);
    page.selectingRecords = true;
    assert.deepEqual(options.call(page, record), {});
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

test('页面策略分别定义左滑、批量入口和批量菜单，不共享可变数组', () => {
  const inbox = taskPageActionPolicy('inbox');
  assert.deepEqual(inbox, { swipeActions: ['move', 'someday', 'memo', 'delete', 'select'], batchEditing: true, batchActions: ['merge'] });
  for (const page of ['today', 'planned', 'anytime', 'someday', 'logbook', 'recent']) {
    assert.deepEqual(taskPageActionPolicy(page), { swipeActions: [], batchEditing: false, batchActions: [] });
  }
  inbox.swipeActions.reverse(); inbox.batchActions.length = 0;
  assert.equal(taskPageActionPolicy('inbox').swipeActions[0], 'move');
  assert.deepEqual(taskPageActionPolicy('inbox').batchActions, ['merge']);
});

test('页面可以裁剪与重排左滑按钮，动态宽度与动作回调对应实际菜单', () => {
  const policy = taskPageActionPolicy('inbox'), invoked = [];
  policy.swipeActions = ['select', 'delete', 'move'];
  const menu = taskSwipeMenu(policy, id => invoked.push(id));
  assert.deepEqual(menu.map(item => item.id), policy.swipeActions);
  menu.forEach(item => item.action());
  assert.deepEqual(invoked, ['select', 'delete', 'move']);
  assert.equal(menu[0].style, 'selection');
  assert.equal(menu[1].style, 'danger');
  assert.equal(taskSwipeMenuWidth(menu), 160);
  policy.swipeActions = ['delete'];
  assert.equal(taskSwipeMenuWidth(taskSwipeMenu(policy, () => {})), 64);
  assert.equal(taskSwipeMenuWidth([]), 0);
});

test('关闭批量入口时隐藏左滑多选和批量菜单，其余按钮按原序保留', () => {
  const policy = taskPageActionPolicy('inbox'); policy.batchEditing = false;
  assert.deepEqual(taskSwipeMenu(policy, () => {}).map(item => item.id), ['move', 'someday', 'memo', 'delete']);
  assert.deepEqual(taskBatchMenu(policy, () => {}), []);
  policy.swipeActions = []; policy.batchEditing = true; policy.batchActions = [];
  assert.deepEqual(taskSwipeMenu(policy, () => {}), []);
  assert.deepEqual(taskBatchMenu(policy, () => {}), []);
});

const toolbarFile = 'entry/src/main/ets/components/TaskBatchToolbar.ets';
const toolbarSource = fs.readFileSync(toolbarFile, 'utf8');
const method = toolbarSource.match(/  activate\(item: TaskActionItem\) \{[\s\S]*?\n  \}/)[0];
// 独立编译方法的依赖通过词法参数注入，直接执行产品中的事件处理。
function toolbar(state) {
  const source = 'import { taskBatchActionEnabled } from "actions"; export class Toolbar {' + method + '}';
  const { Toolbar } = compile(source, toolbarFile, { actions });
  return Object.assign(new Toolbar(), { count: 0, busy: false, invalid: false }, state);
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
  const invoked = [], menu = taskBatchMenu(taskPageActionPolicy('inbox'), id => invoked.push(id));
  const state = toolbar({ count: 1 });
  state.activate(menu[0]); assert.deepEqual(invoked, []);
  state.count = 2; state.activate(menu[0]); assert.deepEqual(invoked, ['merge']);
});


test('共享选择行按页面开关处理长按与点按，选中状态或忙碌时不重新进入', () => {
  const source = fs.readFileSync('entry/src/main/ets/components/TaskSelectionRow.ets', 'utf8');
  const methods = source.slice(source.indexOf('  selectionActive()'), source.indexOf('  build()'));
  const { SelectionRow } = compile('export class SelectionRow {' + methods + '}', 'TaskSelectionRow.ets');
  let begins = 0, toggles = 0;
  const row = Object.assign(new SelectionRow(), { batchEditing: false, selecting: true, busy: false,
    begin: () => begins++, toggle: () => toggles++ });
  assert.equal(row.selectionActive(), false);
  row.beginSelection(); row.toggleSelection();
  assert.equal(begins + toggles, 0);
  row.batchEditing = true; row.selecting = false;
  row.beginSelection(); assert.equal(begins, 1);
  row.toggleSelection(); assert.equal(toggles, 0);
  row.selecting = true; row.beginSelection(); assert.equal(begins, 1);
  row.toggleSelection(); assert.equal(toggles, 1);
  row.busy = true; row.beginSelection(); row.toggleSelection();
  assert.equal(begins, 1); assert.equal(toggles, 1);
});
