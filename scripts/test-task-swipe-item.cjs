// 验证滑动组件只分发 Action，编辑器接口负责交互和提交。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-swipe-item.cjs\n验证操作枚举到 TaskEditor 接口的完整映射、启用数组、状态按钮形态、回调失效与左右滑禁用边界。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(source, bindings = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, $r: name => ({ name }), ...bindings });
  return module.exports;
}
const actions = compile(fs.readFileSync('entry/src/main/ets/ui/TaskActionPresentation.ets', 'utf8'));
const states = compile(fs.readFileSync('entry/src/main/ets/ui/TaskStatePresentation.ets', 'utf8'));
const { TaskEditorController } = compile(fs.readFileSync('entry/src/main/ets/ui/TaskEditorController.ets', 'utf8'));
const file = 'entry/src/main/ets/components/TaskSwipeItem.ets';
const source = fs.readFileSync(file, 'utf8');
const methods = source.slice(source.indexOf('  private taskDataSet()'), source.indexOf('  @Builder\n  swipeMenu'));
const { Item } = compile('export class Item {' + methods + '}', { ...actions, ...states });
function task(category = 'Todo', available = true) {
  return { state: category ? { category } : null, taskStateOf: category => available ? { name: category, category } : null };
}
function fixture() {
  const calls = [], guards = []; let editable = true, deletable = true;
  const controller = new TaskEditorController();
  const editor = { actionsAvailable: () => editable, deletionAvailable: () => deletable };
  for (const method of ['startMove', 'startSchedule', 'startDeadline', 'startDelete', 'start', 'stop', 'moveToSomeday', 'convertToMemo']) {
    editor[method] = async allowed => { guards.push(allowed); if (allowed()) calls.push(method); };
  }
  controller.bind(editor);
  const state = Object.assign(new Item(), { active: true, interactionEnabled: true, readOnly: false, busy: false,
    inlineTyping: false, checklistDragging: false, controller, singleOperations: [], toggleStateCategory: null, rightSwipeAction: 'none' });
  return { state, calls, guards, controller, editable: value => editable = value, deletable: value => deletable = value };
}
test('七种单条操作全部调用编辑器接口，开始／暂停使用同一枚举的不同形态', async () => {
  for (const [action, target, method] of [['move', null, 'startMove'], ['schedule', null, 'startSchedule'],
    ['deadline', null, 'startDeadline'], ['delete', null, 'startDelete'], ['someday', null, 'moveToSomeday'],
    ['memo', null, 'convertToMemo'], ['toggleState', 'Doing', 'start'], ['toggleState', 'Todo', 'stop']]) {
    const f = fixture(); f.state.singleOperations = [action]; f.state.toggleStateCategory = target;
    await f.state.activateOperation(action); assert.deepEqual(f.calls, [method]);
  }
});
test('启用数组决定菜单顺序，移除操作后旧回调和编辑器保存的执行条件均失效', async () => {
  const f = fixture(); f.state.singleOperations = ['delete', 'toggleState']; f.state.toggleStateCategory = 'Doing';
  const menu = f.state.swipeMenuItems(); assert.deepEqual(Array.from(menu, item => item.id), ['delete', 'toggleState']);
  assert.equal(menu[1].title, '开始'); menu[0].action(); assert.deepEqual(f.calls, ['startDelete']);
  f.state.singleOperations = []; assert.equal(f.guards[0](), false);
  menu[1].action(); await f.state.activateOperation('delete'); assert.deepEqual(f.calls, ['startDelete']);
  assert.equal(f.state.leftSwipeAvailable(), false);
});
test('目标状态存在时才显示切换，等待、完成、取消、备忘只保留其他操作', () => {
  for (const [category, expected] of [['Todo', 'Doing'], ['Doing', 'Todo'], ['Wait', null], ['Done', null], ['Cancel', null], [null, null]]) {
    assert.equal(states.taskStateToggleCategory(task(category)), expected);
  }
  assert.equal(states.taskStateToggleCategory(task('Todo', false)), null);
  assert.equal(states.taskStateToggleCategory(undefined), null);
});
test('左右滑共用宿主禁用状态，右滑完成时重新检查编辑器和配置', async () => {
  const f = fixture(); f.state.singleOperations = ['schedule']; f.state.rightSwipeAction = 'schedule';
  f.state.activateRightSwipe(); assert.deepEqual(f.calls, ['startSchedule']);
  for (const flag of ['readOnly', 'busy', 'inlineTyping', 'checklistDragging']) {
    f.state[flag] = true; assert.equal(f.state.leftSwipeAvailable(), false); assert.equal(f.state.rightSwipeAvailable(), false);
    await f.state.activateOperation('schedule'); f.state.activateRightSwipe(); assert.equal(f.calls.length, 1); f.state[flag] = false;
  }
  f.editable(false); assert.equal(f.state.rightSwipeAvailable(), false); await f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1);
  f.editable(true); f.state.rightSwipeAction = 'none'; f.state.activateRightSwipe(); assert.equal(f.calls.length, 1);
  f.state.active = false; await f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1);
});
test('只读编辑器可独立注册删除权限，滑动组件不把删除错误归入普通编辑权限', async () => {
  const f = fixture(); f.state.singleOperations = ['delete', 'schedule']; f.editable(false);
  await f.state.activateOperation('delete'); await f.state.activateOperation('schedule'); assert.deepEqual(f.calls, ['startDelete']);
  f.deletable(false); await f.state.activateOperation('delete'); assert.deepEqual(f.calls, ['startDelete']);
});
test('取消编辑器绑定后所有旧动作失效，页面仍可提供专属菜单', async () => {
  const f = fixture(); f.state.singleOperations = ['delete']; f.state.rightSwipeAction = 'schedule'; f.controller.release();
  await f.state.activateOperation('delete'); f.state.activateRightSwipe(); assert.deepEqual(f.calls, []);
  f.state.menuAvailable = () => true; f.state.singleOperations = []; assert.equal(f.state.leftSwipeAvailable(), true);
  f.state.activateRightSwipe(); assert.deepEqual(f.calls, []);
});
test('启用数组启停状态订阅，禁用后忽略迟到状态回调', () => {
  const f = fixture(); let listener, stopped = 0;
  f.state.dataSet = { watchTask(_id, notify) { listener = notify; notify({ task: task() }); return () => stopped++; } };
  f.state.singleOperations = ['toggleState']; f.state.operationsChanged(); assert.equal(f.state.toggleStateCategory, 'Doing');
  listener({ task: task('Doing') }); assert.equal(f.state.toggleStateCategory, 'Todo');
  f.state.singleOperations = []; f.state.operationsChanged(); listener({ task: task() });
  assert.equal(stopped, 1); assert.equal(f.state.toggleStateCategory, null);
});
test('原生左滑仅与共享右滑并行，保留其他手势识别方式', () => {
  const callback = source.match(/\.shouldBuiltInRecognizerParallelWith\(([\s\S]*?)\n      \}\)/)[1] + '\n}';
  const { choose } = compile('export const choose = ' + callback + ';');
  const current = {}, scroll = { getTag: () => 'scroll' }, right = { getTag: () => 'shared_right_swipe' };
  assert.equal(choose(current, [scroll, right]), right); assert.equal(choose(current, [scroll]), current);
});
