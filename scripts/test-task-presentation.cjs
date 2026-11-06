// 验证只读任务快照更新时列表行与点击参数的一致性；不连接 WebDAV 或系统日历。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-presentation.cjs\n验证任务刷新后的行内容与点击参数更新。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const deveco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(deveco, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/ui/TaskPresentation.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const exported = {};
vm.runInThisContext('(function(exports){' + compiled.outputText + '\n})', { filename })(exported);
const { taskRenderKey } = exported;

// 与 native Task 一样，数据字段只读且可枚举，行为位于原型上。
function task(id, values = {}) {
  const result = Object.create({ isDone() { return this.todoKind === 'done'; } });
  for (const [key, value] of Object.entries({ id, repoId: 'repo', heading: '记录', headingParts: [],
    todoState: 'TODO', todoKind: 'pending', priority: '', scheduled: '', deadline: '', tags: [],
    filePath: 'inbox.org', fileName: 'inbox.org', level: 1, body: '正文', bodyHtml: '<p>正文</p>', logbookHtml: '', progress: -1, ...values })) {
    Object.defineProperty(result, key, { value, enumerable: true });
  }
  return result;
}

// ForEach 对同键条目保留已有行及其点击闭包。
function refresh(previous, tasks, keyFor = taskRenderKey) {
  const rows = new Map();
  for (const value of tasks) {
    const key = keyFor(value);
    rows.set(key, previous.get(key) || { heading: value.heading, body: value.body,
      done: value.isDone(), open: () => value });
  }
  return rows;
}

test('删除前两条记录后，剩余行与点击对象对应最新结果', () => {
  const initial = [task('alpha', { heading: 'Alpha' }), task('bravo', { heading: 'Bravo' }),
    task('charlie', { heading: 'Charlie' }), task('delta', { heading: 'Delta' })];
  const updated = [task('charlie', { heading: 'Charlie', body: '更新正文' }), task('delta', { heading: 'Delta' })];
  const rows = [...refresh(refresh(new Map(), initial), updated).values()];
  assert.deepEqual(rows.map(row => row.heading), ['Charlie', 'Delta']);
  assert.equal(rows[0].body, '更新正文');
  assert.equal(rows[0].open(), updated[0]);
});

test('逻辑 ID 稳定时，状态、进度标题和正文仍更新；仅用 ID 会复现旧行残留', () => {
  const before = task('same-id', { heading: '项目 [0/2]' });
  const after = task('same-id', { heading: '项目 [2/2]', todoState: 'DONE', todoKind: 'done', body: '新正文' });
  const legacy = refresh(refresh(new Map(), [before], task => task.id), [after], task => task.id);
  assert.equal([...legacy.values()][0].open(), before);
  const rows = refresh(refresh(new Map(), [before]), [after]);
  const row = [...rows.values()][0];
  assert.equal(row.heading, '项目 [2/2]');
  assert.equal(row.body, '新正文');
  assert.equal(row.done, true);
  assert.equal(row.open(), after);
});

test('计划、标签、链接及详情正文更新都能刷新点击参数，相同快照继续复用', () => {
  const before = task('same-id');
  assert.equal(taskRenderKey(before), taskRenderKey(task('same-id')));
  for (const changes of [{ scheduled: '2026-11-06' }, { deadline: '2026-11-07' }, { priority: 'A' },
    { tags: ['work'] }, { headingParts: [{ text: '链接', href: 'https://example.org', isLink: true }] },
    { bodyHtml: '<p>新正文</p>' }, { logbookHtml: '<p>新日志</p>' }]) {
    const after = task('same-id', changes);
    const rows = refresh(refresh(new Map(), [before]), [after]);
    assert.equal([...rows.values()][0].open(), after);
  }
});
