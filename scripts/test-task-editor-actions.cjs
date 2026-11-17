// 验证编辑器操作接口的草稿保存、状态切换、确认与失败恢复。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-editor-actions.cjs\n验证 TaskEditor 的 start／stop、删除、日期及整理接口，覆盖草稿、版本、取消、重入和失败边界。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const file = 'entry/src/main/ets/components/editors/TaskEditor.ets';
const source = fs.readFileSync(file, 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source);
  assert.ok(match, name);
  const start = source.indexOf('{', match.index); let depth = 0;
  for (let i = start; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(match.index, i + 1);
  }
  throw new Error('未找到方法结尾 ' + name);
}
const methods = ['actionsAvailable', 'deletionAvailable', 'localDataSet', 'currentTask', 'actionError', 'actionSource',
  'start', 'stop', 'changeState', 'startDelete', 'cancelDelete', 'remove', 'moveToSomeday', 'convertToMemo', 'organize',
  'startSchedule', 'startDeadline', 'startDate'].map(method).join('\n');
const code = ts.transpileModule('export class Editor {' + methods + '}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
function task(category = 'Todo', target = 'INPROGRESS') {
  return { id: 'task', heading: '验收任务', fileVersion: 'v1', state: category ? { category } : null,
    editContent: {}, taskStateOf(category) { return target ? { name: category === 'Doing' ? target : 'TODO', category } : null; } };
}
function fixture(category = 'Todo', target = 'INPROGRESS') {
  const events = [], dialogs = [], messages = [], dates = [];
  let save = async () => true, settle = async () => {}, write = async () => {}, remove = async () => {};
  const module = { exports: {} };
  class Missing extends Error {}
  class Dialog { constructor(options) { this.options = options; } open() { dialogs.push(this.options); } }
  vm.runInThisContext('(function(module,exports,TaskStateCategory,TaskInlineSession,TaskInlineMissingError,coreErrorMessage,UiColor,InboxService,CustomDialogController,TaskDateDialog,DialogAlignment){' + code + '\n})', { filename: file })(
    module, module.exports, { Todo: 'Todo', Doing: 'Doing' }, { release: key => events.push(['release', key]) }, Missing,
    error => error.message, { error: 'red' }, { async performMany(_context, records, action, _target, _date, operationId) {
      events.push(['organize', records[0].fileVersion, action, operationId]); await write();
    } }, Dialog, options => { dates.push(options); return options; }, { Center: 'center' });
  const state = Object.assign(new module.exports.Editor(), { taskId: 'key', task: task(category, target), appeared: true,
    readOnly: false, allowDeletion: false, completing: false, working: false, moveBusy: false, moveOpen: false,
    snapshotBlocked: false, removed: false, typing: false, checklistTouch: false, draggingCheck: false, deleteConfirming: false,
    expanded: true, ownerKey: 'owner', value() { return this.task; },
    async prepare() { return true; }, async finish(collapse) { events.push(['save', collapse]); return save(); },
    removeDeletedTask() { this.removed = true; }, async persist(changes) { events.push(['persist', changes]); return true; },
    getUIContext: () => ({ showAlertDialog: options => dialogs.push(options), getHostContext: () => ({}),
      getPromptAction: () => ({ showToast: options => messages.push(options.message) }) }) });
  state.dataSet = { name: 'tasks', getTask(key) { assert.equal(key, 'key'); return state.task; },
    async settle() { events.push('settle'); await settle(); },
    async update(...args) { events.push(['update', ...args]); await write(); },
    async removeTask(key) { events.push(['remove', key]); await remove(); }, async operate(work) { await work('operation'); } };
  return { state, events, dialogs, messages, dates, saveWith: fn => save = fn, settleWith: fn => settle = fn,
    writeWith: fn => write = fn, removeWith: fn => remove = fn };
}
test('start／stop 使用保存后的状态名与版本，只提交 TODO 字段', async () => {
  for (const [category, action, expected] of [['Todo', 'start', 'INPROGRESS'], ['Doing', 'stop', 'TODO']]) {
    const f = fixture(category); f.settleWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
    await f.state[action]();
    assert.deepEqual(f.events, [['save', false], 'settle', ['update', 'tasks', 'key', [{ field: 'TODO', value: expected }], 'saved']]);
    assert.equal(f.state.completing, false);
  }
});
test('保存失败、源消失、状态已变化或目标状态缺失不提交', async () => {
  const failed = fixture(); failed.saveWith(async () => false); await failed.state.start();
  assert.deepEqual(failed.events, [['save', false]]);
  for (const change of [f => { f.state.task = undefined; }, f => { f.state.task = task('Doing'); },
    f => { f.state.task = task('Todo', null); }, f => { f.state.appeared = false; },
    f => { f.state.dataSet.error = '草稿保存失败'; }]) {
    const f = fixture(); f.settleWith(async () => change(f)); await f.state.start();
    assert.equal(f.events.some(e => Array.isArray(e) && e[0] === 'update'), false);
  }
});
test('直接操作在等待期间重新检查启用条件，拒绝旧按钮和重复点击，失败后可重试', async () => {
  const f = fixture(); let enabled = true, reject;
  f.settleWith(async () => { enabled = false; }); await f.state.start(() => enabled);
  assert.equal(f.events.some(e => Array.isArray(e) && e[0] === 'update'), false);
  const busy = fixture(); busy.writeWith(() => new Promise((_, fail) => { reject = fail; }));
  const pending = busy.state.start(); await new Promise(resolve => setImmediate(resolve)); await busy.state.start();
  assert.equal(busy.events.filter(e => Array.isArray(e) && e[0] === 'update').length, 1);
  reject(new Error('写入失败')); await pending; assert.deepEqual(busy.messages, ['写入失败']);
  busy.writeWith(async () => {}); await busy.state.start(); assert.equal(busy.state.completing, false);
});
test('startDelete 使用保存后的标题确认，取消不删除，确认时校验源版本', async () => {
  const f = fixture(); f.settleWith(async () => { f.state.task = { ...f.state.task, heading: '已保存标题', fileVersion: 'v2' }; });
  await f.state.startDelete(); assert.match(f.dialogs[0].message, /已保存标题/);
  f.dialogs[0].primaryButton.action(); assert.equal(f.state.deleteConfirming, false);
  await f.state.startDelete(); f.state.task = { ...f.state.task, fileVersion: 'v3' };
  f.dialogs[1].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.events.some(e => Array.isArray(e) && e[0] === 'remove'), false); assert.match(f.messages[0], /重新确认/);
});
test('删除确认失效、源消失或离开页面不删除，连续确认只提交一次', async () => {
  for (const change of [f => { f.enabled = false; }, f => { f.state.appeared = false; }, f => { f.state.task = undefined; }]) {
    const f = fixture(); f.enabled = true; await f.state.startDelete(() => f.enabled); change(f);
    f.dialogs[0].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.events.some(e => Array.isArray(e) && e[0] === 'remove'), false);
  }
  const f = fixture(); let finish; f.removeWith(() => new Promise(resolve => { finish = resolve; }));
  await f.state.startDelete(); f.dialogs[0].secondaryButton.action(); f.dialogs[0].secondaryButton.action();
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.events.filter(e => Array.isArray(e) && e[0] === 'remove').length, 1);
  finish(); await new Promise(resolve => setImmediate(resolve));
});
test('只读日志可单独允许删除，不开放开始／暂停或其他编辑操作', async () => {
  const f = fixture(); f.state.readOnly = true; f.state.allowDeletion = true;
  await f.state.start(); assert.deepEqual(f.events, []);
  await f.state.startDelete(); assert.equal(f.dialogs.length, 1);
  const disabled = fixture(); disabled.state.readOnly = true; await disabled.state.startDelete(); assert.equal(disabled.dialogs.length, 0);
});
test('整理操作先保存并使用数据集 operationId 提交最新源快照', async () => {
  for (const [method, destination] of [['moveToSomeday', 'someday'], ['convertToMemo', 'memo']]) {
    const f = fixture(); f.settleWith(async () => { f.state.task = { ...f.state.task, fileVersion: 'saved' }; });
    await f.state[method](); assert.deepEqual(f.events, [['save', false], 'settle', ['organize', 'saved', destination, 'operation']]);
  }
});
test('startSchedule／startDeadline 打开相应日期面板，提交前重新检查启用条件', async () => {
  for (const [method, field] of [['startSchedule', 'SCHEDULE'], ['startDeadline', 'DEADLINE']]) {
    const f = fixture(); let allowed = true; await f.state[method](() => allowed);
    assert.equal(f.dates[0].deadline, field === 'DEADLINE');
    allowed = false; assert.equal(await f.dates[0].choose({ date: '2026-11-18' }), false);
    allowed = true; assert.equal(await f.dates[0].choose({ date: '2026-11-18' }), true);
    assert.deepEqual(f.events.at(-1), ['persist', [{ field, value: { date: '2026-11-18' } }]]);
  }
});
test('不可用编辑器不启动操作', async () => {
  for (const flag of ['readOnly', 'completing', 'working', 'moveBusy', 'moveOpen', 'snapshotBlocked', 'removed', 'typing', 'checklistTouch', 'draggingCheck', 'deleteConfirming']) {
    const f = fixture(); f.state[flag] = true;
    await f.state.start(); await f.state.stop(); await f.state.startDelete(); await f.state.moveToSomeday(); await f.state.convertToMemo();
    assert.deepEqual(f.events, [], flag); assert.equal(f.dialogs.length, 0, flag);
  }
});

test('收起卡片取消确认后释放会话，页面离开后的迟到回调不释放新会话', async () => {
  const f = fixture(); f.state.expanded = false; await f.state.startDelete();
  assert.equal(f.events.some(e => Array.isArray(e) && e[0] === 'release'), false);
  f.dialogs[0].cancel(); assert.deepEqual(f.events.at(-1), ['release', 'owner']);
  const date = fixture(); date.state.expanded = false; await date.state.startSchedule();
  date.dates[0].closed(); assert.deepEqual(date.events.at(-1), ['release', 'owner']);
  const before = date.events.length; date.state.appeared = false; date.dates[0].closed(); assert.equal(date.events.length, before);
  const gone = fixture(); gone.state.expanded = false; await gone.state.startDelete(); gone.state.appeared = false;
  gone.dialogs[0].secondaryButton.action(); assert.equal(gone.events.some(e => Array.isArray(e) && e[0] === 'release'), false);
});
