// 验证共享列表项的删除确认、草稿提交、版本保护与失败恢复。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-swipe-item.cjs\n验证左滑删除的草稿保存、确认与取消、版本变化、重复点击、错误反馈和页面离开边界。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const file = 'entry/src/main/ets/components/TaskSwipeItem.ets';
const source = fs.readFileSync(file, 'utf8');
function fixture() {
  let save = async () => true, settle = async () => {}, remove = async () => {};
  const events = [], dialogs = [], messages = [];
  const methods = source.slice(source.indexOf('  private taskDataSet()'), source.indexOf('  @Builder\n  deleteMenu'));
  const code = ts.transpileModule('export class Item {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(module,exports,TaskInlineSession,UiColor,coreErrorMessage){' + code + '\n})', { filename: file })(
    module, module.exports, { async end(collapse) { events.push(['save', collapse]); return await save(); } },
    { error: 'red' }, error => error.message);
  const original = { id: 'task', heading: '待删除记录', fileVersion: 'v1' };
  const state = Object.assign(new module.exports.Item(), { active: true, taskId: 'stable-key', task: original,
    getUIContext: () => ({ showAlertDialog(value) { dialogs.push(value); }, getPromptAction: () => ({ showToast(value) { messages.push(value.message); } }) }) });
  state.dataSet = { getTask(key) { assert.equal(key, 'stable-key'); return state.task; },
    async settle() { events.push('settle'); await settle(); },
    async removeTask(key) { events.push(['remove', key]); await remove(); } };
  return { state, original, events, dialogs, messages,
    saveWith(fn) { save = fn; }, settleWith(fn) { settle = fn; }, removeWith(fn) { remove = fn; } };
}
test('先保存草稿并等待确认快照，删除确认采用保存后的标题与版本', async () => {
  const f = fixture();
  f.settleWith(async () => { f.state.task = { ...f.original, heading: '已保存标题', fileVersion: 'v2' }; });
  await f.state.confirmDelete();
  assert.deepEqual(f.events, [['save', false], 'settle']);
  assert.match(f.dialogs[0].message, /已保存标题/);
  f.dialogs[0].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.events.at(-1), ['remove', 'stable-key']);
});
test('取消按钮与系统取消均不删除，随后可重新确认', async () => {
  for (const cancel of ['primaryButton', 'cancel']) {
    const f = fixture(); await f.state.confirmDelete();
    if (cancel === 'cancel') f.dialogs[0].cancel(); else f.dialogs[0].primaryButton.action();
    assert.equal(f.state.confirming, false); assert.equal(f.events.length, 2);
    await f.state.confirmDelete(); assert.equal(f.dialogs.length, 2);
  }
});
test('草稿保存失败或底层写入回滚不打开删除确认', async () => {
  const failed = fixture(); failed.saveWith(async () => false); await failed.state.confirmDelete();
  assert.equal(failed.dialogs.length, 0); assert.deepEqual(failed.events, [['save', false]]);
  const rejected = fixture(); rejected.settleWith(async () => { rejected.state.dataSet.error = '草稿保存失败'; });
  await rejected.state.confirmDelete(); assert.equal(rejected.dialogs.length, 0); assert.deepEqual(rejected.messages, ['草稿保存失败']);
});
test('确认期间源版本变化或任务消失，不提交旧记录', async () => {
  const changed = fixture(); await changed.state.confirmDelete();
  changed.state.task = { ...changed.original, fileVersion: 'v2' };
  changed.dialogs[0].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(changed.events.length, 2); assert.match(changed.messages[0], /重新确认/);
  const gone = fixture(); await gone.state.confirmDelete(); gone.state.task = undefined;
  gone.dialogs[0].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(gone.events.length, 2);
});
test('连续点击确认只提交一次，失败显示错误并允许重试', async () => {
  const f = fixture(); let reject;
  f.removeWith(() => new Promise((_, fail) => { reject = fail; }));
  const work = f.state.deleteTask(f.original); await f.state.deleteTask(f.original);
  assert.equal(f.events.length, 1); reject(new Error('磁盘写入失败')); await work;
  assert.equal(f.state.deleting, false); assert.deepEqual(f.messages, ['磁盘写入失败']);
  f.removeWith(async () => {}); await f.state.deleteTask(f.original); assert.equal(f.events.length, 2);
});
test('只读、忙碌、输入与清单拖动期间不打开确认，失效按钮不提交', async () => {
  for (const flag of ['readOnly', 'busy', 'preparing', 'deleting', 'confirming', 'inlineTyping', 'checklistDragging']) {
    const f = fixture(); f.state[flag] = true;
    await f.state.confirmDelete(); await f.state.deleteTask(f.original);
    assert.deepEqual(f.events, [], flag); assert.equal(f.dialogs.length, 0, flag);
  }
});
test('保存或等待底层确认期间离开页面、进入多选、源消失均不打开弹窗', async () => {
  for (const change of [f => { f.state.active = false; }, f => { f.state.busy = true; }, f => { f.state.task = undefined; }]) {
    const f = fixture(); f.settleWith(async () => { change(f); }); await f.state.confirmDelete();
    assert.equal(f.dialogs.length, 0); assert.equal(f.events.length, 2);
  }
});

test('原生左滑仅与共享右滑并行，保留其他手势的原识别方式', () => {
  const callback = source.match(/\.shouldBuiltInRecognizerParallelWith\(([\s\S]*?)\n      \}\)/)[1] + '\n}';
  const code = ts.transpileModule('exports.choose = ' + callback + ';', { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
  const exports = {}; vm.runInNewContext(code, { exports });
  const current = {}, scroll = { getTag: () => 'scroll' }, right = { getTag: () => 'shared_right_swipe' };
  assert.equal(exports.choose(current, [scroll, right]), right);
  assert.equal(exports.choose(current, [scroll]), current);
});
