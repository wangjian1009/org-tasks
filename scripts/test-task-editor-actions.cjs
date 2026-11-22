// 验证编辑器返回修改组，确认交互经提交宿主完成，编辑器不直接执行任务动作。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-editor-actions.cjs\n验证 TaskEditor 的修改组返回值、零任务动作写入、弹窗结果返回、草稿／版本／取消／重入边界。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const FIXED_NOW = new Date(2026,10,18,12).getTime();
class TestDate extends Date { constructor(...args) { if(args.length) super(...args); else super(FIXED_NOW); } static now(){return FIXED_NOW;} }
function compile(source, bindings = {}) {
  bindings = { Date: TestDate, ...bindings };
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(module,exports,' + Object.keys(bindings).join(',') + '){' + code + '\n})')(module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const groupBuilders = compile(fs.readFileSync('entry/src/main/ets/services/TaskOperationGroups.ets', 'utf8'));
const { TaskEditorActionResult } = compile(fs.readFileSync('entry/src/main/ets/ui/TaskEditorActionResult.ets', 'utf8'));
const file = 'entry/src/main/ets/components/editors/TaskEditor.ets', source = fs.readFileSync(file, 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert.ok(match, name);
  const start = source.indexOf('{', match.index); let depth = 0;
  for (let i = start; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(match.index, i + 1);
  }
}
const methods = ['actionsAvailable', 'deletionAvailable', 'localDataSet', 'currentTask', 'actionError', 'actionSource', 'emitAction',
  'start', 'stop', 'wait', 'cancelTask', 'toggleWait', 'changeState', 'withStateNote', 'startDelete', 'cancelDelete', 'remove', 'moveTo', 'startMove', 'confirmMove', 'closeMove', 'loadMoveTargets', 'refreshMove',
  'moveToSomeday', 'convertToMemo', 'organize', 'setSchedule', 'setDeadline', 'planningGroup',
  'startSchedule', 'startDeadline', 'startDate', 'aboutToDisappear'].map(method).join('\n');
function task(category = 'Todo', target = 'INPROGRESS') {
  return { id: 'task', heading: '验收任务', repoId: 'repo', filePath: 'tasks.org', fileVersion: 'v1',
    fullPath: { repoId: 'repo', file: 'tasks.org', titles: ['验收任务'] }, state: category ? { category } : null,
    editContent: {}, taskStateOf(category) { return target ? { name: category === 'Doing' ? target : category === 'Wait' ? 'HOLD' : category === 'Cancel' ? 'ABORTED' : 'TODO', category } : null; } };
}
function fixture(category = 'Todo', target = 'INPROGRESS') {
  const events = [], dialogs = [], messages = [], dates = [], emitted = [], planned = [];
  let save = async () => true, draft = async () => {};
  class Missing extends Error {}
  class Dialog { constructor(options) { this.options = options; } open() { dialogs.push(this.options); } close() { this.options.onWillDismiss?.({ dismiss() {} }); } }
  const { Editor } = compile('export class Editor {' + methods + '}', { ...groupBuilders, TaskEditorActionResult, refileSections: values => [{ targets: values }],
    TaskStateCategory: { Todo: 'Todo', Doing: 'Doing', Wait: 'Wait', Cancel: 'Cancel' }, TaskInlineSession: { release: key => events.push(['release', key]) },
    TaskInlineMissingError: Missing, coreErrorMessage: error => error.message, UiColor: { error: 'red' },
    InboxService: { async operationGroups(_context, records, action) {
      planned.push([records[0].fileVersion, action]);
      if(action==='delete')return [{operations:[{type:'Trash',data:{path:records[0].fullPath}}],fileVersions:[{repoId:records[0].repoId,file:records[0].filePath,version:records[0].fileVersion}]}];
      return [groupBuilders.taskModificationGroup(records[0], [{ field: 'TODO', value: action === 'memo' ? null : 'TODO' }])];
    } }, CustomDialogController: Dialog, TaskDateDialog: options => { dates.push(options); return options; }, DialogAlignment: { Center: 'center' } });
  const state = Object.assign(new Editor(), { taskId: 'key', task: task(category, target), appeared: true,
    readOnly: false, allowDeletion: false, completing: false, working: false, moveBusy: false, moveOpen: false,
    snapshotBlocked: false, removed: false, typing: false, checklistTouch: false, draggingCheck: false, deleteConfirming: false,
    expanded: true, ownerKey: 'owner', value() { return this.task; },
    async prepare() { return true; }, async finish(collapse) { events.push(['save', collapse]); const saved=await save(); if(saved){events.push('draft-ready');await draft();} return saved; },
    removeDeletedTask() { this.removed = true; }, applySnapshot(value) { this.task = value; }, moveRequest: 0, refreshRequest: 0, moveSections: [],
    cancelCheckDrag() {}, checkFocus: { dispose() {} },
    getUIContext: () => ({ showAlertDialog: options => dialogs.push(options), getHostContext: () => ({}),
      getPromptAction: () => ({ showToast: options => messages.push(options.message) }) }) });
  state.dataSet = { name: 'tasks', getTask(key) { assert.equal(key, 'key'); return state.task; },
    async settle() { assert.fail('生成操作不能等待后台确认'); }, async moveTargets() { return []; },
    async update() { assert.fail('编辑器不能直接提交任务字段修改'); }, async removeTask() { assert.fail('编辑器不能直接提交删除'); },
    async moveTask() { assert.fail('编辑器不能直接提交移动'); }, async operate() { assert.fail('编辑器不能直接执行操作组'); } };
  state.dataSet.taskSource = () => ({ rowId:'key', get task() { return state.dataSet.getTask('key'); } });
  state.controller = { emitOperation(group) { emitted.push(group); }, release() {} };
  return { state, events, dialogs, messages, dates, emitted, planned,
    saveWith: fn => save = fn, draftWith: fn => draft = fn };
}
test('start／stop 返回保存后版本的 TODO 修改组，生成阶段不执行任务动作', async () => {
  for (const [category, action, expected] of [['Todo', 'start', 'INPROGRESS'], ['Wait', 'start', 'INPROGRESS'], ['Doing', 'stop', 'TODO']]) {
    const f = fixture(category); f.draftWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
    const group = await f.state[action]();
    const expectedChanges = category === 'Doing' ? [{ field: 'TODO', value: expected }] :
      [{ field: 'TODO', value: expected }, { field: 'SCHEDULE', value: { date: '2026-11-18' } }];
    assert.deepEqual(group.operations[0].data.modifications, expectedChanges);
    assert.equal(group.fileVersions[0].version, 'saved'); assert.equal(group.operationId, undefined);
    assert.deepEqual(f.events, [['save', false], 'draft-ready']); assert.equal(f.emitted.length, 0); assert.equal(f.state.completing, false);
  }
});
test('单条取消使用保存后的文件版本与有效取消状态，只生成 TODO 修改', async () => {
  const f = fixture(null);
  f.draftWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
  const group = await f.state.cancelTask();
  assert.deepEqual(group.operations[0].data.modifications, [{ field: 'TODO', value: 'ABORTED' }]);
  assert.equal(group.fileVersions[0].version, 'saved');
  assert.equal(f.emitted.length, 0);
  assert.equal(await fixture('Cancel').state.cancelTask(), undefined);
  await assert.rejects(fixture('Todo', null).state.cancelTask(), /没有可用的取消状态/);
});

test('启动时仅为缺少计划或未来计划的任务设置今天，过去和今天保持原计划', async () => {
  for (const scheduled of ['', '2099-12-31', '2026-11-17', '2026-11-18']) {
    const f = fixture('Wait'); f.state.task = { ...f.state.task, scheduled }
    const group = await f.state.start()
    const modifications = group.operations[0].data.modifications
    assert.deepEqual(modifications, scheduled === '' || scheduled > '2026-11-18'
      ? [{ field: 'TODO', value: 'INPROGRESS' }, { field: 'SCHEDULE', value: { date: '2026-11-18' } }]
      : [{ field: 'TODO', value: 'INPROGRESS' }], scheduled)
  }
})

test('保存失败、状态已变化、目标缺失和失效回调不产生修改组，读取错误向宿主抛出', async () => {
  const failed = fixture(); failed.saveWith(async () => false); assert.equal(await failed.state.start(), undefined);
  for (const change of [f => { f.state.task = task('Doing'); }, f => { f.state.task = task('Todo', null); }, f => { f.state.appeared = false; }]) {
    const f = fixture(); f.draftWith(async () => change(f)); assert.equal(await f.state.start(), undefined); assert.equal(f.emitted.length, 0);
  }
  const gone = fixture(); gone.draftWith(async () => { gone.state.task = undefined; }); await assert.rejects(gone.state.start());
  const error = fixture(); error.draftWith(async () => { error.state.dataSet.error = '保存失败'; }); await assert.rejects(error.state.start(), /保存失败/);
});
test('生成阶段锁定编辑器，等待期间撤销启用或离开页面不会返回旧修改组', async () => {
  const f = fixture(); let enabled = true, finish;
  f.draftWith(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.state.start(() => enabled); await new Promise(resolve => setImmediate(resolve));
  assert.equal(await f.state.start(), undefined); enabled = false; finish(); assert.equal(await pending, undefined);
  assert.equal(f.emitted.length, 0); assert.equal(f.state.completing, false);
});
test('移动、日期和删除直接接口均返回可组合的修改组，不打开弹窗或提交', async () => {
  const target = { repoId: 'repo', path: 'target.org', fileVersion: 'target-v1', fullPath: { repoId: 'repo', file: 'target.org', titles: [] } };
  for (const [method, args, type, field] of [['moveTo', [target], 'Movement'], ['setSchedule', [{ date: '2026-11-18' }], 'Modification', 'SCHEDULE'],
    ['setDeadline', [null], 'Modification', 'DEADLINE'], ['remove', [], 'Trash']]) {
    const f = fixture(), group = await f.state[method](...args);
    assert.equal(group.operations[0].type, type); if (field) assert.equal(group.operations[0].data.modifications[0].field, field);
    assert.equal(f.dialogs.length, 0); assert.equal(f.emitted.length, 0);
  }
});
const tick = () => new Promise(resolve => setImmediate(resolve));
test('startDelete 等待用户确认后返回删除组，窗口不执行提交或隐式发出结果事件', async () => {
  const f = fixture(); let finished = false;
  const pending = f.state.startDelete().then(group => { finished = true; return group; }); await tick();
  assert.equal(finished, false); assert.equal(f.emitted.length, 0);
  f.dialogs[0].secondaryButton.action(); f.dialogs[0].secondaryButton.action();
  const group = await pending; assert.equal(group.operations[0].type, 'Trash'); assert.equal(f.emitted.length, 0);
  assert.equal(f.state.pendingAction, undefined);
});
test('取消、启用条件撤销或页面退出均返回 undefined，不产生修改', async () => {
  const f = fixture(); const pending = f.state.startDelete(); await tick(); f.dialogs[0].primaryButton.action(); assert.equal(await pending, undefined);
  const cancelled = fixture(); let allowed = true; const waiting = cancelled.state.startDelete(() => allowed); await tick(); allowed = false;
  cancelled.dialogs[0].secondaryButton.action(); assert.equal(await waiting, undefined);
  const gone = fixture(); const old = gone.state.startSchedule(); await tick(); gone.state.aboutToDisappear(); assert.equal(await old, undefined);
  const count = gone.events.length; gone.dates[0].confirmed({ field: 'SCHEDULE', value: { date: '2026-11-18' } });
  assert.equal(gone.events.length, count); assert.equal(gone.emitted.length, 0);
});
test('日期结果固定在正在编辑的数据版本，调用点收到结果后决定何时提交', async () => {
  for (const [method, field] of [['startSchedule', 'SCHEDULE'], ['startDeadline', 'DEADLINE']]) {
    const f = fixture(); const pending = f.state[method](); await tick(); assert.equal(f.dates[0].deadline, field === 'DEADLINE');
    f.state.task = { ...f.state.task, fileVersion: 'v2' };
    f.dates[0].confirmed({ field, value: { date: '2026-11-18' } }); f.dates[0].closed();
    const group = await pending;
    assert.equal(group.fileVersions[0].version, 'v1'); assert.deepEqual(group.operations[0].data.modifications, [{ field, value: { date: '2026-11-18' } }]);
    assert.equal(f.emitted.length, 0);
  }
});
test('移动面板返回移动组，取消不返回，源和目标版本均属于编辑数据', async () => {
  const target = { repoId: 'repo', path: 'target.org', fileVersion: 'target-v1', fullPath: { repoId: 'repo', file: 'target.org', titles: [] } };
  const f = fixture(); const pending = f.state.startMove(); await tick(); assert.equal(f.state.moveOpen, true);
  f.state.confirmMove(target); const group = await pending;
  assert.equal(group.operations[0].type, 'Movement'); assert.equal(group.fileVersions[1].version, 'target-v1'); assert.equal(f.emitted.length, 0);
  const cancelled = fixture(); const waiting = cancelled.state.startMove(); await tick(); cancelled.state.closeMove(); assert.equal(await waiting, undefined);
});
test('只读日志可返回删除数据，不开放状态与其他编辑', async () => {
  const f = fixture(); f.state.readOnly = true; f.state.allowDeletion = true; assert.equal(await f.state.start(), undefined);
  const pending = f.state.startDelete(); await tick(); f.dialogs[0].secondaryButton.action(); assert.equal((await pending).operations[0].type, 'Trash');
  const disabled = fixture(); disabled.state.readOnly = true; assert.equal(await disabled.state.startDelete(), undefined);
});
test('整理接口只返回修改组，不执行请求', async () => {
  for (const [method, destination] of [['moveToSomeday', 'someday'], ['convertToMemo', 'memo']]) {
    const f = fixture(); f.draftWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
    const group = await f.state[method](); assert.deepEqual(f.planned, [['saved', destination]]); assert.equal(group.fileVersions[0].version, 'saved'); assert.equal(f.emitted.length, 0);
  }
});
test('属性按钮调用点接收操作事件，可以累积多次数据结果，不隐式执行写入', async () => {
  const f = fixture();
  for (const date of ['2026-11-18', '2026-11-19']) {
    const pending = f.state.emitAction(f.state.startSchedule()); await tick();
    f.dates.at(-1).confirmed({ field: 'SCHEDULE', value: { date } }); await pending;
  }
  assert.equal(f.emitted.length, 2); assert.equal(f.emitted[0].operations[0].data.modifications[0].value.date, '2026-11-18');
  assert.equal(f.emitted[1].operations[0].data.modifications[0].value.date, '2026-11-19');
});
test('不可用编辑器不产生直接操作组', async () => {
  for (const flag of ['readOnly', 'completing', 'working', 'moveBusy', 'moveOpen', 'snapshotBlocked', 'removed', 'typing', 'checklistTouch', 'draggingCheck', 'deleteConfirming']) {
    const f = fixture(); f.state[flag] = true;
    assert.equal(await f.state.start(), undefined, flag); assert.equal(await f.state.convertToMemo(), undefined, flag); assert.equal(f.emitted.length, 0);
  }
});
test('收起卡片结束数据编辑会话后释放所有权，新会话不受旧回调影响', async () => {
  const f = fixture(); f.state.expanded = false; const pending = f.state.startSchedule(); await tick(); f.dates[0].closed(); await pending;
  assert.deepEqual(f.events.at(-1), ['release', 'owner']);
  const next = f.state.startDelete(); await tick(); f.state.aboutToDisappear(); await next;
  const count = f.events.length; f.dialogs.at(-1).secondaryButton.action(); assert.equal(f.events.length, count);
});

test('移动目标读取期间取消会忽略迟到结果，显式刷新更新正在编辑的数据版本', async () => {
  const target = { repoId: 'repo', path: 'target.org', fileVersion: 'target-v1', fullPath: { repoId: 'repo', file: 'target.org', titles: [] } };
  const cancelled = fixture(); let finish;
  cancelled.state.dataSet.moveTargets = () => new Promise(resolve => { finish = resolve; });
  const pending = cancelled.state.startMove(); await tick(); cancelled.state.closeMove(); assert.equal(await pending, undefined); finish([target]); await tick();
  assert.equal(await pending, undefined); assert.equal(cancelled.state.moveSections.length, 0); assert.equal(cancelled.emitted.length, 0);
  const refreshed = fixture(); const editing = refreshed.state.startMove(); await tick();
  refreshed.state.task = { ...refreshed.state.task, fileVersion: 'v2' }; await refreshed.state.refreshMove(); refreshed.state.confirmMove(target);
  assert.equal((await editing).fileVersions[0].version, 'v2'); assert.equal(refreshed.emitted.length, 0);
});

test('等待仅返回文件有效 Wait 状态修改，使用保存后的版本，其他字段由 Core 保留',async()=>{
  for(const category of ['Todo','Doing']){
    const f=fixture(category);f.draftWith(async()=>{f.state.task={...f.state.task,fileVersion:'saved'};});
    const group=await f.state.wait();assert.deepEqual(group.operations[0].data.modifications,[{field:'TODO',value:'HOLD'}]);
    assert.equal(group.fileVersions[0].version,'saved');assert.equal(f.emitted.length,0);assert.equal(f.dialogs.length,0);
  }
  const existing=fixture('Wait');assert.equal(await existing.state.wait(),undefined);
  const missing=fixture('Todo',null);await assert.rejects(missing.state.wait(),/没有可用的等待状态/);
});
test('等待与恢复共用 toggleWait 接口，根据当前状态返回对应 TODO 修改', async () => {
  for (const [category, expected] of [['Todo', 'HOLD'], ['Doing', 'HOLD'], ['Wait', 'TODO']]) {
    const f = fixture(category); f.draftWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
    const group = await f.state.toggleWait();
    assert.deepEqual(group.operations[0].data.modifications, [{ field: 'TODO', value: expected }]);
    assert.equal(group.fileVersions[0].version, 'saved'); assert.equal(f.emitted.length, 0);
  }
  const done = fixture('Done'); assert.equal(await done.state.toggleWait(), undefined);
  const missing = fixture('Todo', null); await assert.rejects(missing.state.toggleWait());
});
test('等待在保存失败、菜单撤销、页面离开或任务消失后不生成操作组',async()=>{
  const failed=fixture();failed.saveWith(async()=>false);assert.equal(await failed.state.wait(),undefined);
  for(const mode of ['policy','leave']){
    const f=fixture();let allowed=true;f.draftWith(async()=>{if(mode==='policy')allowed=false;else f.state.appeared=false;});
    assert.equal(await f.state.wait(()=>allowed),undefined);assert.equal(f.state.completing,false);
  }
  const gone=fixture();gone.draftWith(async()=>{gone.state.task=undefined;});await assert.rejects(gone.state.wait());
});

test('提醒不可用的设置入口先保存当前编辑，单次跳转提醒子页，保存失败或页面失效不跳转', async () => {
  const calls = [], errors = [];
  let finish = async () => true, settle = async () => {}, route;
  const { ReminderNavigation } = compile('export class ReminderNavigation {' + method('openReminderSettings') + '}', {
    PageNavigator: { shared: { async pushPage(context, page) { calls.push('navigate'); route = page; return true; } } }
  });
  const state = Object.assign(new ReminderNavigation(), {
    appeared: true, removed: false, working: false, completing: false, moveBusy: false, snapshotBlocked: false,
    async finish(collapse) { assert.equal(collapse, false); calls.push('finish'); return finish(); },
    localDataSet() { return { error: '', async settle() { calls.push('draft-ready'); await settle(); } }; },
    getUIContext: () => ({}), actionError: error => errors.push(error.message)
  });
  await state.openReminderSettings();
  assert.deepEqual(calls, ['finish', 'draft-ready', 'navigate']);
  assert.deepEqual(route, { url: 'pages/Settings', params: { section: '任务提醒' } });
  calls.length = 0; finish = async () => false; await state.openReminderSettings();
  assert.deepEqual(calls, ['finish']); assert.equal(state.completing, false);
  calls.length = 0; finish = async () => true; settle = async () => { state.appeared = false; };
  await state.openReminderSettings(); assert.deepEqual(calls, ['finish', 'draft-ready']);
  state.appeared = true; calls.length = 0;
  let release; settle = () => new Promise(done => { release = done; });
  const waiting = state.openReminderSettings(); await tick();
  await state.openReminderSettings(); assert.deepEqual(calls, ['finish', 'draft-ready']);
  release(); await waiting; assert.equal(calls.filter(call => call === 'navigate').length, 1);
  calls.length = 0; settle = async () => { throw new Error('保存失败'); };
  await state.openReminderSettings(); assert.deepEqual(calls, ['finish', 'draft-ready']);
  assert.deepEqual(errors, ['保存失败']); assert.equal(state.completing, false);
});
