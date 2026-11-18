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
const session = {
  owner: '', finish: undefined, saves: 0, saveAllowed: true,
  async end() { this.saves++; return this.finish ? await this.finish() : this.saveAllowed; },
  async begin(owner, finish) { this.owner = owner; this.finish = finish; return true; },
  release(owner) { if (this.owner === owner) { this.owner = ''; this.finish = undefined; } }
};
const { Item } = compile('export class Item {' + methods + '}', { ...actions, ...states, TaskSwipeOperations, TaskInlineSession: session, KeyboardAvoidMode: { RESIZE: 1 },
  ProjectCreateService: { repositories: async context => context.repositories() }, setTimeout: callback => callback(), coreErrorMessage: error => error.message });
function task(category = 'Todo', available = true) {
  return { state: category ? { category } : null, taskStateOf: category => available ? { name: category, category } : null };
}
function fixture() {
  const calls = [], guards = [], submitted = [], messages = []; let editable = true, deletable = true, state, write = async () => {};
  const controller = new TaskEditorController(group => { state.receiveOperation(group).catch(error => messages.push(error.message)); });
  const editor = { actionsAvailable: () => editable, deletionAvailable: () => deletable };
  for (const method of ['startMove', 'startSchedule', 'startDeadline', 'startDelete', 'start', 'stop', 'wait', 'toggleWait', 'moveToSomeday', 'convertToMemo']) {
    editor[method] = async allowed => {
      guards.push(allowed); if (allowed()) calls.push(method);
      if (allowed()) return groupBuilders.taskModificationGroup({ repoId: 'repo', filePath: 'tasks.org', fileVersion: 'v1', fullPath: { repoId: 'repo', file: 'tasks.org', titles: ['任务'] } }, [{ field: 'TODO', value: method }]);
    };
  }
  controller.bind(editor);
  state = Object.assign(new Item(), { active: true, interactionEnabled: true, readOnly: false, busy: false,
    inlineTyping: false, checklistDragging: false, submitting: false, controller,
    getUIContext: () => ({ getPromptAction: () => ({ showToast: options => messages.push(options.message) }) }),
    dataSet: { async submitOperationGroup(group, allowed) { assert.equal(allowed(), true); submitted.push(group); await write(); } }, singleOperations: [], recordActionPending: false, toggleStateCategory: null, rightSwipeAction: undefined });
  return { state, calls, guards, submitted, messages, controller, writeWith: fn => write = fn, editable: value => editable = value, deletable: value => deletable = value };
}
test('状态、规划和整理操作全部调用编辑器接口，开始／暂停与等待／待办使用同一枚举的不同形态', async () => {
  for (const [action, target, method] of [['move', null, 'startMove'], ['schedule', null, 'startSchedule'],
    ['deadline', null, 'startDeadline'], ['delete', null, 'startDelete'], ['someday', null, 'moveToSomeday'],
    ['memo', null, 'convertToMemo'], ['toggleWait', 'Wait', 'toggleWait'], ['toggleState', 'Doing', 'start'], ['toggleState', 'Todo', 'stop']]) {
    const f = fixture(); f.state.singleOperations = [action]; f.state.toggleStateCategory = target; f.state.toggleWaitCategory = target;
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
test('目标状态存在时才显示切换，等待可开始，完成、取消和备忘保留其他操作', () => {
  for (const [category, expected] of [['Todo', 'Doing'], ['Doing', 'Todo'], ['Wait', 'Doing'], ['Done', null], ['Cancel', null], [null, null]]) {
    assert.equal(states.taskStateToggleCategory(task(category)), expected);
  }
  assert.equal(states.taskStateToggleCategory(task('Todo', false)), null);
  assert.equal(states.taskStateToggleCategory(undefined), null);
  for (const [category, expected] of [['Todo', 'Wait'], ['Doing', 'Wait'], ['Wait', 'Todo'], ['Done', null], ['Cancel', null], [null, null]]) {
    assert.equal(states.taskStateToggleWaitCategory(task(category)), expected);
  }
  assert.equal(states.taskStateToggleWaitCategory(task('Todo', false)), null);
  assert.equal(states.taskStateToggleWaitCategory(undefined), null);
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

function projectFixture() {
  Object.assign(session, { owner: '', finish: undefined, saves: 0, saveAllowed: true });
  const f = fixture(), modes = [], source = { id: 'task', repoId: 'repo', heading: '草稿', fileVersion: 'v1' };
  Object.assign(f.state, { taskId: 'task', singleOperations: [actions.TaskOperation.Project], projectOwner: '', projectScope: '',
    projectOpen: false, projectLoading: false, projectGenerating: false, projectTyping: false, getUniqueId: () => 1,
    getUIContext: () => ({ getHostContext: () => ({ repositories: async () => [{ repoId: 'repo', regions: [] }] }),
      getKeyboardAvoidMode: () => 0, setKeyboardAvoidMode: value => modes.push(value),
      getFocusController: () => ({ clearFocus() {} }), getPromptAction: () => ({ showToast: options => f.messages.push(options.message) }) }) });
  Object.assign(f.state.dataSet, { identity: 'scope', settle: async () => {}, getTask: () => source, error: '' });
  return { ...f, source, modes };
}
test('Project 通过统一 Action 入口先保存草稿、等待确认再打开面板，取消零提交', async () => {
  const f = projectFixture();
  f.state.dataSet.settle = async () => { f.source.heading = '已保存标题'; f.source.fileVersion = 'v2'; };
  await f.state.activateOperation(actions.TaskOperation.Project);
  assert.equal(session.saves, 1); assert.equal(f.state.projectOpen, true);
  assert.equal(f.state.projectSource.heading, '已保存标题'); assert.equal(f.state.projectSource.fileVersion, 'v2');
  assert.equal(f.submitted.length, 0); f.state.dismissProject();
  assert.equal(f.state.projectOpen, false); assert.equal(session.owner, ''); assert.deepEqual(f.modes, [1, 0]);
});
test('项目面板提交失败保留源快照与面板，重复确认阻止重入，成功只提交一个操作组', async () => {
  const f = projectFixture(); await f.state.activateOperation(actions.TaskOperation.Project);
  const group = groupBuilders.taskModificationGroup({repoId:'repo',filePath:'inbox.org',fileVersion:'v1',fullPath:{}}, []);
  f.writeWith(async () => { throw new Error('目标文件已存在'); });
  await f.state.submitProject(group);
  assert.equal(f.state.projectOpen, true); assert.equal(f.state.projectMessage, '目标文件已存在');
  assert.equal(f.state.projectSource, f.source); assert.equal(f.state.submitting, false);
  let finish; f.writeWith(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.state.submitProject(group); await new Promise(resolve => setImmediate(resolve));
  const before = f.submitted.length; await f.state.submitProject(group); f.state.dismissProject();
  assert.equal(f.submitted.length, before); assert.equal(f.state.projectOpen, true);
  finish(); await pending; assert.equal(f.state.projectOpen, false); assert.equal(session.owner, '');
});
test('草稿保存失败或准备期间控件离开时不打开项目面板，数据集重绑后拒绝旧操作组', async () => {
  const failed = projectFixture(); session.saveAllowed = false;
  await failed.state.activateOperation(actions.TaskOperation.Project); assert.equal(failed.state.projectOpen, false);
  const left = projectFixture(); left.state.dataSet.settle = async () => { left.state.active = false; };
  await left.state.activateOperation(actions.TaskOperation.Project); assert.equal(left.state.projectOpen, false);
  const rebound = projectFixture(); await rebound.state.activateOperation(actions.TaskOperation.Project);
  rebound.state.dataSet.identity = 'new-scope';
  await rebound.state.submitProject({ operations: [], fileVersions: [] });
  assert.equal(rebound.submitted.length, 0); assert.equal(rebound.state.projectOpen, true);
  assert.match(rebound.state.projectMessage, /取消/); rebound.state.dismissProject();
});

test('只读任务内容可执行配置的 Reopen、Restore、Clear，统一交给记录操作执行器', async () => {
  for (const action of ['setTodo','restoreLocation','clear']) {
    const f=fixture(), performed=[];f.editable(false);f.state.singleOperations=[action];
    const source={id:'task',fileVersion:'v2'};
    Object.assign(f.state.dataSet,{identity:'scope',settle:async()=>{},getTask:()=>source});
    f.state.recordActions={execute:async(_context,dataSet,tasks,operation,allowed)=>{
      assert.equal(allowed(),true);assert.equal(dataSet,f.state.dataSet);performed.push([operation,tasks]);return {committed:true,retainedKeys:[]};}};
    await f.state.activateOperation(action);
    assert.equal(performed.length,1);assert.equal(performed[0][0],action);assert.equal(performed[0][1][0],source);assert.equal(f.calls.length,0);assert.equal(f.state.recordActionPending,false);
  }
});
test('记录操作准备期间阻止重入，菜单撤销或数据集重绑会使执行条件失效', async () => {
  Object.assign(session,{owner:'',finish:undefined,saveAllowed:true});
  const f=fixture();f.state.singleOperations=['restoreLocation'];let finish,allowed;
  Object.assign(f.state.dataSet,{identity:'scope',settle:async()=>{},getTask:()=>({id:'task'})});
  f.state.recordActions={execute:async(_context,_dataSet,_tasks,_action,guard)=>{
    allowed=guard;return await new Promise(resolve=>finish=resolve);}};
  const pending=f.state.activateOperation('restoreLocation');await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.state.recordActionPending,true);await f.state.activateOperation('restoreLocation');assert.equal(allowed(),true);
  f.state.dataSet.identity='new-scope';assert.equal(allowed(),false);
  finish({committed:false,retainedKeys:[]});await pending;assert.equal(f.state.recordActionPending,false);
});

test('等待／待办 Action 复用启用数组和提交入口，撤销配置或编辑器失效后不执行',async()=>{
  const f=fixture();f.state.singleOperations=['toggleWait'];f.state.toggleWaitCategory='Wait';await f.state.activateOperation('toggleWait');
  assert.deepEqual(f.calls,['toggleWait']);assert.equal(f.submitted.length,1);
  f.state.singleOperations=[];assert.equal(f.guards[0](),false);await f.state.activateOperation('toggleWait');
  f.state.singleOperations=['toggleWait'];f.controller.release();await f.state.activateOperation('toggleWait');
  assert.equal(f.submitted.length,1);
});
