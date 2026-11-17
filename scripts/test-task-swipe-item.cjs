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
const groupBuilders = compile(fs.readFileSync('entry/src/main/ets/services/TaskOperationGroups.ets', 'utf8'));
const { TaskSwipeOperations } = compile(fs.readFileSync('entry/src/main/ets/components/TaskSwipeOperations.ets', 'utf8').replace(/^import .*$/gm, ''), groupBuilders);
const { TaskEditorController } = compile(fs.readFileSync('entry/src/main/ets/ui/TaskEditorController.ets', 'utf8'));
const file = 'entry/src/main/ets/components/TaskSwipeItem.ets';
const source = fs.readFileSync(file, 'utf8');
const methods = source.slice(source.indexOf('  private taskDataSet()'), source.indexOf('  @Builder\n  swipeMenu'));
const { Item } = compile('export class Item {' + methods + '}', { ...actions, ...states, TaskSwipeOperations, coreErrorMessage: error => error.message });
function task(category = 'Todo', available = true) {
  return { state: category ? { category } : null, taskStateOf: category => available ? { name: category, category } : null };
}
function fixture() {
  const calls = [], guards = [], submitted = [], messages = []; let editable = true, deletable = true, state, write = async () => {};
  const controller = new TaskEditorController(group => { state.receiveOperation(group).catch(error => messages.push(error.message)); });
  const editor = { actionsAvailable: () => editable, deletionAvailable: () => deletable };
  for (const method of ['startMove', 'startSchedule', 'startDeadline', 'startDelete', 'start', 'stop', 'moveToSomeday', 'convertToMemo']) {
    editor[method] = async allowed => {
      guards.push(allowed); if (allowed()) calls.push(method);
      if (allowed()) return groupBuilders.taskModificationGroup({ repoId: 'repo', filePath: 'tasks.org', fileVersion: 'v1', fullPath: { repoId: 'repo', file: 'tasks.org', titles: ['任务'] } }, [{ field: 'TODO', value: method }]);
    };
  }
  controller.bind(editor);
  state = Object.assign(new Item(), { active: true, interactionEnabled: true, readOnly: false, busy: false,
    inlineTyping: false, checklistDragging: false, submitting: false, controller,
    getUIContext: () => ({ getPromptAction: () => ({ showToast: options => messages.push(options.message) }) }),
    dataSet: { async submitOperationGroup(group, allowed) { assert.equal(allowed(), true); submitted.push(group); await write(); } }, singleOperations: [], toggleStateCategory: null, rightSwipeAction: undefined });
  return { state, calls, guards, submitted, messages, controller, writeWith: fn => write = fn, editable: value => editable = value, deletable: value => deletable = value };
}
test('七种单条操作全部调用编辑器接口，开始／暂停使用同一枚举的不同形态', async () => {
  for (const [action, target, method] of [['move', null, 'startMove'], ['schedule', null, 'startSchedule'],
    ['deadline', null, 'startDeadline'], ['delete', null, 'startDelete'], ['someday', null, 'moveToSomeday'],
    ['memo', null, 'convertToMemo'], ['toggleState', 'Doing', 'start'], ['toggleState', 'Todo', 'stop']]) {
    const f = fixture(); f.state.singleOperations = [action]; f.state.toggleStateCategory = target;
    await f.state.activateOperation(action); assert.deepEqual(f.calls, [method]);
    assert.equal(f.submitted.length, 1);
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
  f.state.activateOperation('schedule'); assert.deepEqual(f.calls, ['startSchedule']);
  for (const flag of ['readOnly', 'busy', 'inlineTyping', 'checklistDragging']) {
    f.state[flag] = true; assert.equal(f.state.leftSwipeAvailable(), false); assert.equal(f.state.rightSwipeAvailable(), false);
    await f.state.activateOperation('schedule'); f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1); f.state[flag] = false;
  }
  f.editable(false); assert.equal(f.state.rightSwipeAvailable(), false); await f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1);
  f.editable(true); f.state.singleOperations = []; f.state.rightSwipeAction = undefined; f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1);
  f.state.active = false; await f.state.activateOperation('schedule'); assert.equal(f.calls.length, 1);
});
test('只读编辑器可独立注册删除权限，滑动组件不把删除错误归入普通编辑权限', async () => {
  const f = fixture(); f.state.singleOperations = ['delete', 'schedule']; f.editable(false);
  await f.state.activateOperation('delete'); await f.state.activateOperation('schedule'); assert.deepEqual(f.calls, ['startDelete']);
  f.deletable(false); await f.state.activateOperation('delete'); assert.deepEqual(f.calls, ['startDelete']);
});
test('取消编辑器绑定后所有旧动作失效，页面仍可提供专属菜单', async () => {
  const f = fixture(); f.state.singleOperations = ['delete']; f.state.rightSwipeAction = 'schedule'; f.controller.release();
  await f.state.activateOperation('delete'); f.state.activateOperation('schedule'); assert.deepEqual(f.calls, []);
  f.state.menuAvailable = () => true; f.state.singleOperations = []; assert.equal(f.state.leftSwipeAvailable(), true);
  f.state.activateOperation('schedule'); assert.deepEqual(f.calls, []);
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

test('修改组由滑动组件统一提交，批量组只提交一次，提交中拒绝重复动作', async () => {
  const f = fixture(); f.state.singleOperations = ['toggleState']; f.state.toggleStateCategory = 'Doing'; let finish;
  f.writeWith(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.state.activateOperation('toggleState'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.submitting, true); await f.state.activateOperation('toggleState'); assert.equal(f.submitted.length, 1);
  finish(); await pending; assert.equal(f.state.submitting, false);
  const group = f.submitted[0]; f.writeWith(async () => {}); f.submitted.length = 0;
  await f.state.submitOperationGroups([group, group]); assert.equal(f.submitted.length, 1); assert.equal(f.submitted[0].operations.length, 2);
});
test('提交失败由滑动宿主反馈错误并恢复可用状态', async () => {
  const f = fixture(); f.state.singleOperations = ['toggleState']; f.state.toggleStateCategory = 'Doing';
  f.writeWith(async () => { throw new Error('整组失败'); }); await f.state.activateOperation('toggleState');
  assert.deepEqual(f.messages, ['整组失败']); assert.equal(f.state.submitting, false);
});
