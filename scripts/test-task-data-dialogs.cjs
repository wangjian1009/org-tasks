// 验证标签与重复窗口的数据结果不依赖提交成功，调用点选择提交频率。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-data-dialogs.cjs\n验证标签／重复窗口的纯数据回调、单次或连续处理、只读标签、输入校验及日期子窗口。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(source, bindings = {}) {
  const module = { exports: {} };
  const code = transpileFixture(ts, source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(module,exports,' + Object.keys(bindings).join(',') + '){' + code + '\n})')(module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const tagHelpers = compile(fs.readFileSync('entry/src/main/ets/ui/TaskTagsPresentation.ets', 'utf8'));
const repeatHelpers = compile(fs.readFileSync('entry/src/main/ets/ui/TaskRepeatPresentation.ets', 'utf8'));
const tagSource = fs.readFileSync('entry/src/main/ets/components/editors/TaskTagsDialog.ets', 'utf8');
const { Tags } = compile('export class Tags {' + tagSource.slice(tagSource.indexOf('  aboutToAppear()'), tagSource.indexOf('  @Builder')) + '}', tagHelpers);
function tags() {
  const changes = [], confirmations = []; let closed = 0;
  const state = Object.assign(new Tags(), { ownTags: ['old', 'project'], visibleTags: ['old', 'new', 'project'], inheritedTags: [], hiddenTags: ['project'], supportTags: null,
    names: [], selected: [], busy: false, creating: false, name: '', closeOnConfirm: true, changed: change => changes.push(change), confirmed: change => confirmations.push(change), controller: { close() { closed++; } } });
  state.aboutToAppear(); return { state, changes, confirmations, closed: () => closed };
}
const repeatSource = fs.readFileSync('entry/src/main/ets/components/editors/TaskRepeatDialog.ets', 'utf8');
function repeats() {
  const confirmations = [], dates = []; let closed = 0;
  class Dialog { open() {} }
  const { Repeats } = compile('export class Repeats {' + repeatSource.slice(repeatSource.indexOf('  info()'), repeatSource.indexOf('  build()')) + '}', {
    ...repeatHelpers, inlineDate: () => '2026-11-17', CustomDialogController: Dialog, DialogAlignment: { Center: 'center' }, TaskDateDialog: options => { dates.push(options); return options; } });
  const state = Object.assign(new Repeats(), { task: { editContent: { scheduledRepeat: { date: '2026-11-17', hasTime: true, rule: { mode: 'cumulative', interval: 1, unit: 'day' } }, deadlineRepeat: null } },
    deadline: false, interval: '1', unit: 'day', mode: 'cumulative', date: '2026-11-17', busy: false, closeOnConfirm: true,
    confirmed: changes => confirmations.push(changes), closed() {}, controller: { close() { closed++; } } });
  return { state, confirmations, dates, closed: () => closed };
}
test('标签点击只修改窗口数据并返回 TAGS 修改，隐藏标签保留且不改写传入数组', () => {
  const f = tags(); f.state.toggle('new');
  assert.deepEqual(f.changes[0], { field: 'TAGS', value: ['old', 'project', 'new'] }); assert.deepEqual(f.state.ownTags, ['old', 'project']);
  assert.equal(f.confirmations.length, 0); f.state.accept(); assert.deepEqual(f.confirmations[0], f.changes[0]); assert.equal(f.closed(), 1);
});
test('标签调用点可在确认时统一处理，也可按每次变化连续处理', () => {
  const once = tags(), writes = []; once.state.confirmed = change => writes.push(change);
  once.state.toggle('new'); once.state.toggle('old'); assert.equal(writes.length, 0); once.state.accept(); assert.equal(writes.length, 1);
  const many = tags(), changes = []; many.state.changed = change => changes.push(change);
  many.state.toggle('new'); many.state.toggle('old'); assert.equal(changes.length, 2); assert.deepEqual(changes[0].value, ['old', 'project', 'new']);
  assert.deepEqual(changes[1].value, ['project', 'new']);
});
test('新建标签和保持窗口的多次确认不依赖持久化结果', () => {
  const f = tags(); f.state.name = 'created'; f.state.create(); assert.ok(f.state.selected.includes('created'));
  f.state.closeOnConfirm = false; f.state.accept(); f.state.toggle('new'); f.state.accept(); assert.equal(f.confirmations.length, 2); assert.equal(f.closed(), 0);
});
test('重复设置返回字段修改数组，确认后关闭，与持久化 Promise 无关', () => {
  const f = repeats(); f.state.date = '2026-11-19'; f.state.accept(); assert.equal(f.confirmations.length, 1);
  assert.equal(f.confirmations[0].some(change => change.field === 'SCHEDULE'), true); assert.equal(f.confirmations[0].some(change => change.field === 'SCHEDULE_REPEAT'), true);
  assert.equal(f.closed(), 1); assert.equal(f.state.task.editContent.scheduledRepeat.date, '2026-11-17');
  const asyncCaller = repeats(); let finish; asyncCaller.state.confirmed = () => new Promise(resolve => { finish = resolve; });
  asyncCaller.state.accept(); assert.equal(asyncCaller.closed(), 1); assert.equal(asyncCaller.state.busy, false); finish();
});
test('重复输入校验在数据窗口完成，停止重复与多次确认只返回数据', () => {
  const f = repeats(); f.state.interval = '0'; f.state.accept(); assert.equal(f.confirmations.length, 0);
  f.state.interval = '2'; f.state.closeOnConfirm = false; f.state.accept(); f.state.accept(true);
  assert.equal(f.confirmations.length, 2); assert.ok(f.confirmations[1].some(change => change.field === 'SCHEDULE_REPEAT' && change.value === null)); assert.equal(f.closed(), 0);
});
test('重复窗口内的日期选择仅更新重复草稿，主确认前不返回外层修改', () => {
  const f = repeats(); f.state.chooseDate(); f.dates[0].confirmed({ field: 'SCHEDULE', value: { date: '2026-11-20' } });
  assert.equal(f.state.date, '2026-11-20'); assert.equal(f.confirmations.length, 0); f.state.accept(); assert.equal(f.confirmations.length, 1);
});
