// 验证修改组合并、一次提交及跨文件排队边界。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-operation-groups.cjs\n验证修改组的操作顺序、文件版本去重与冲突、不可变快照、单次提交、operationId、目标文件排队和取消／失败边界。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(source, bindings = {}) {
  const module = { exports: {} };
  const code = transpileFixture(ts, source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(module,exports,' + Object.keys(bindings).join(',') + '){' + code + '\n})')(module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const groups = compile(fs.readFileSync('entry/src/main/ets/services/TaskOperationGroups.ets', 'utf8'));
const { TaskSwipeOperations } = compile(fs.readFileSync('entry/src/main/ets/components/TaskSwipeOperations.ets', 'utf8').replace(/^import .*$/gm, ''), groups);
const source = fs.readFileSync('entry/src/main/ets/services/DataSet.ets', 'utf8');
function method(name) {
  const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(source); assert.ok(match, name);
  let depth = 0; const begin = source.indexOf('{', match.index);
  for (let i = begin; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(match.index, i + 1);
  }
}
const { UserOperationQueue } = compile(source.slice(source.indexOf('export class UserOperationQueue'), source.indexOf('export class DataSet {')));
const submitMethods = ['operationId', 'eventVersion', 'submitOperationGroup', 'submit', 'rebasedGroup',
  'currentFileVersion', 'track', 'settle', 'finishEdit', 'emitError'];
const { Submitter } = compile('export class Submitter {' + submitMethods.map(method).join('\n') + '}', { UserOperationQueue });
function task(title = '任务', file = 'tasks.org', version = 'v1', repoId = 'repo') {
  return { repoId, filePath: file, fileVersion: version, fullPath: { repoId, file, titles: [title] } };
}
function fixture() {
  const writes = [], events = [], errors = []; let execute = async () => {};
  const state = Object.assign(new Submitter(), {
    name: 'tasks', owner: 'audit', epoch: 1, sequence: 0, versions: new Map(), pending: [], loadError: '',
    writes: new Set(), views: new Map(), confirmed: new Map(), taskSources: new Map(), rowIds: new Map(),
    async start() {}, isReady: () => true, scopeFiles: () => ['fallback'],
    rebuild() {}, getConfirmed: () => ({}),
    publish(event) {
      events.push(event);
      if (event.type === 'error') errors.push(event);
    },
    workspace: { async executeTaskOperations(group) { writes.push(group); await execute(group); } }
  });
  return { state, writes, events, errors, executeWith: fn => execute = fn };
}
function deferred() { let resolve; const promise = new Promise(done => resolve = done); return { promise, resolve }; }
test('合并保留每组操作顺序，按仓库和文件去重版本，不继承组内 operationId', () => {
  const first = groups.taskModificationGroup(task('甲'), [{ field: 'TODO', value: 'DOING' }]); first.operationId = 'old/a';
  const move = groups.taskMovementGroup(task('甲'), { repoId: 'repo', path: 'target.org', fileVersion: 'v2', fullPath: { repoId: 'repo', file: 'target.org', titles: [] } });
  const last = groups.taskDeletionGroup(task('乙')); last.operationId = 'old/b';
  const merged = groups.mergeTaskOperationGroups([first, move, last]);
  assert.deepEqual(merged.operations.map(op => op.type), ['Modification', 'Movement', 'Deletion']);
  assert.deepEqual(merged.fileVersions, [{ repoId: 'repo', file: 'tasks.org', version: 'v1' }, { repoId: 'repo', file: 'target.org', version: 'v2' }]);
  assert.equal(merged.operationId, undefined); assert.equal(first.operationId, 'old/a');
  first.operations[0].data.modifications[0].value = 'DONE'; first.fileVersions[0].version = 'changed';
  assert.equal(merged.operations[0].data.modifications[0].value, 'DOING'); assert.equal(merged.fileVersions[0].version, 'v1');
});
test('同文件版本冲突整组拒绝，不把其他任务先提交；不同仓库同路径各自保留', async () => {
  const f = fixture();
  await assert.rejects(TaskSwipeOperations.submit(f.state, [groups.taskDeletionGroup(task('甲')), groups.taskDeletionGroup(task('乙', 'tasks.org', 'v2'))]), error => error.code === 'invalidState');
  assert.equal(f.writes.length, 0); assert.equal(f.state.sequence, 0);
  const merged = groups.mergeTaskOperationGroups([groups.taskDeletionGroup(task()), groups.taskDeletionGroup(task('甲', 'tasks.org', 'v2', 'other'))]);
  assert.equal(merged.fileVersions.length, 2);
});
test('多条操作仅执行一次 Core 请求，并分配一次数据集 operationId 与版本', async () => {
  const f = fixture(); const inputs = [groups.taskDeletionGroup(task('甲')), groups.taskDeletionGroup(task('乙'))];
  await TaskSwipeOperations.submit(f.state, inputs, undefined, true);
  assert.equal(f.writes.length, 1); assert.equal(f.writes[0].operations.length, 2);
  assert.equal(f.writes[0].operationId, 'dataset/audit/1/group/1'); assert.equal(f.state.sequence, 1);
  assert.equal(f.events.filter(event => event.type === 'complete').length, 1); assert.equal(inputs[0].operationId, undefined);
});
test('合并组同时登记源与目标文件依赖，不能越过目标文件的在途修改', async () => {
  const f = fixture(); const held = deferred(), order = [];
  const previous = UserOperationQueue.submit(async () => { order.push('previous'); await held.promise; }, [JSON.stringify(['repo', 'target.org'])]);
  const move = groups.taskMovementGroup(task(), { repoId: 'repo', path: 'target.org', fileVersion: 'v2', fullPath: { repoId: 'repo', file: 'target.org', titles: [] } });
  f.executeWith(async () => { order.push('batch'); });
  try {
    await TaskSwipeOperations.submit(f.state, [move]);
    assert.equal(f.writes.length, 0);
    assert.equal(f.state.pending.length, 1);
  } finally {
    held.resolve();
    await Promise.all([previous, f.state.settle()]);
  }
  assert.deepEqual(order, ['previous', 'batch']);
});
test('受理前撤销操作不会进入队列', async () => {
  const f = fixture(), held = deferred(); let allowed = true;
  f.state.start = () => held.promise;
  const pending = TaskSwipeOperations.submit(f.state, [groups.taskDeletionGroup(task())], () => allowed);
  allowed = false;
  held.resolve();
  await assert.rejects(pending, /取消/);
  assert.equal(f.writes.length, 0);
  assert.equal(f.events.length, 0);
});
test('等待确认的提交将失败反馈给表单，且不会推进确认版本', async () => {
  const f = fixture();
  f.executeWith(async () => { throw new Error('整组失败'); });
  const inputs = [groups.taskDeletionGroup(task('甲')), groups.taskDeletionGroup(task('乙'))];
  await assert.rejects(TaskSwipeOperations.submit(f.state, inputs, undefined, true), /整组失败/);
  assert.equal(f.writes.length, 1);
  assert.deepEqual(f.events.filter(event => event.type === 'complete').map(event => event.succeeded), [false]);
  assert.equal(f.state.versions.size, 0);
  assert.equal(f.state.pending.length, 0);
  assert.equal(f.state.loadError, '');
  assert.equal(f.errors[0].targetKey, f.writes[0].operationId);
});
test('空修改组不提交、不分配版本', async () => {
  const f = fixture(); await TaskSwipeOperations.submit(f.state, []);
  assert.equal(f.writes.length, 0); assert.equal(f.state.sequence, 0);
});
