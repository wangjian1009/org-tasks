// 验证日期窗口只编辑数据并返回字段修改，由调用点决定提交策略。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-date-dialog.cjs\n验证日期／时间草稿、字段修改返回值、一次确认、连续变化通知、取消及调用点提交策略。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/components/editors/TaskDateDialog.ets', 'utf8');
const methods = source.slice(source.indexOf('  aboutToAppear()'), source.indexOf('  @Builder'));
const code = transpileFixture(ts, 'export class Dialog {' + methods + '}', { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const moduleValue = { exports: {} };
vm.runInThisContext('(function(module,exports,inlineDate,UiColor){' + code + '\n})')(moduleValue, moduleValue.exports,
  date => `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`, { error: 'red', primary: 'green' });
function fixture() {
  const changes = [], confirmations = []; let closed = 0;
  const planning = { date: '2026-11-17', time: { start: '09:00', end: '10:00' } };
  const state = Object.assign(new moduleValue.exports.Dialog(), { planning, selected: '', deadline: false, closeOnConfirm: true,
    busy: false, message: '', timeChanged: false, editingTime: false, start: '', end: '',
    changed: change => changes.push(change), confirmed: change => confirmations.push(change), closed() {},
    controller: { close() { closed++; } } });
  state.aboutToAppear(); return { state, planning, changes, confirmations, closed: () => closed };
}
test('窗口读取传入数据的副本，只改日期时返回省略时间的字段修改', () => {
  const f = fixture(); f.state.pick('2026-11-18');
  assert.deepEqual(f.changes, [{ field: 'SCHEDULE', value: { date: '2026-11-18' } }]);
  assert.deepEqual(f.planning, { date: '2026-11-17', time: { start: '09:00', end: '10:00' } });
  f.state.accept(); assert.deepEqual(f.confirmations, f.changes); assert.equal(f.closed(), 1);
});
test('截止、时间范围及显式清除均返回结构化修改，不调用任何持久化接口', () => {
  const f = fixture(); f.state.deadline = true; f.state.draftStart = '13:00'; f.state.draftEnd = '14:00';
  f.state.acceptTime(); assert.deepEqual(f.changes.at(-1), { field: 'DEADLINE', value: { date: '2026-11-17', time: { start: '13:00', end: '14:00' } } });
  f.state.clearTime(); assert.deepEqual(f.changes.at(-1).value, { date: '2026-11-17', time: null });
  f.state.clearDate(); assert.deepEqual(f.changes.at(-1), { field: 'DEADLINE', value: null });
});
test('内部时间草稿取消或非法范围不发出修改，首次补日期只通知一次', () => {
  const f = fixture(); f.state.draftStart = '14:00'; f.state.draftEnd = '13:00'; f.state.acceptTime();
  assert.equal(f.changes.length, 0); assert.match(f.state.message, /结束时间/);
  f.state.date = ''; f.state.draftStart = '13:00'; f.state.draftEnd = ''; f.state.acceptTime(); assert.equal(f.changes.length, 1);
});
test('调用点可只在确认时处理一次，也可按每次数据变化连续处理', () => {
  const once = fixture(), singleWrites = []; once.state.confirmed = change => singleWrites.push(change);
  once.state.pick('2026-11-18'); once.state.pick('2026-11-19'); assert.equal(singleWrites.length, 0);
  once.state.accept(); assert.equal(singleWrites.length, 1); assert.equal(singleWrites[0].value.date, '2026-11-19');
  const multiple = fixture(), writes = []; multiple.state.changed = change => writes.push(change);
  multiple.state.pick('2026-11-18'); multiple.state.pick('2026-11-19'); multiple.state.close();
  assert.equal(writes.length, 2); assert.equal(writes[0].value.date, '2026-11-18'); assert.equal(multiple.confirmations.length, 0);
});
test('窗口不等待调用点的持久化结果，调用点可保持窗口以接收多次确认', () => {
  const f = fixture(); let finish;
  f.state.confirmed = () => new Promise(resolve => { finish = resolve; }); f.state.accept();
  assert.equal(f.closed(), 1); assert.equal(f.state.busy, false); finish();
  const continued = fixture(); continued.state.closeOnConfirm = false;
  continued.state.pick('2026-11-18'); continued.state.accept(); continued.state.pick('2026-11-19'); continued.state.accept();
  assert.equal(continued.confirmations.length, 2); assert.equal(continued.closed(), 0);
});
test('未注册数据变化处理时，取消只关闭窗口，不返回确认修改', () => {
  const f = fixture(); let writes = 0; f.state.changed = () => {}; f.state.confirmed = () => { writes++; };
  f.state.pick('2026-11-20'); f.state.close(); assert.equal(writes, 0); assert.equal(f.closed(), 1);
});
