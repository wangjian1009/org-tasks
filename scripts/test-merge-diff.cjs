// 验证展示用 diff 不丢失原文；不访问平台、仓库或 WebDAV。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-merge-diff.cjs\n验证任务比较的原文保真、单文件选择、退出放弃与本地提交保护。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}

const deveco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(deveco, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/ui/MergeDiff.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const moduleValue = { exports: {} };
vm.runInThisContext('(function(exports){' + compiled.outputText + '\n})', { filename })(moduleValue.exports);
const { mergeLineDiff, mergeSourceLines, mergeDiffText } = moduleValue.exports;

function checkRoundTrip(local, remote) {
  const diff = mergeLineDiff(local, remote);
  assert.equal(diff.filter(line => line.kind !== 'added').map(line => line.text).join(''), local);
  assert.equal(diff.filter(line => line.kind !== 'removed').map(line => line.text).join(''), remote);
  let oldLine = 0;
  let newLine = 0;
  for (const line of diff) {
    assert.equal(line.localLine, line.kind === 'added' ? 0 : ++oldLine);
    assert.equal(line.remoteLine, line.kind === 'removed' ? 0 : ++newLine);
  }
  return diff;
}

test('只突出变化行，保留相同标题、上下文与准确行号', () => {
  const lines = checkRoundTrip('* TODO 报销\n截止：周五\n附件\n', '* TODO 报销\n截止：周六\n附件\n');
  assert.deepEqual(lines.map(line => line.kind), ['context', 'removed', 'added', 'context']);
  assert.equal(lines[1].localLine, 2);
  assert.equal(lines[2].remoteLine, 2);
});

test('空版本、独有项、空行、缩进与文件末尾换行均可无损还原', () => {
  for (const local of ['', '\n', '\n\n', 'a', 'a\n', ' a \r\n\t\n', '* 标题\n正文\n']) {
    for (const remote of ['', '\n', 'a\n', 'a', 'a\r\n', '* 标题\n正文\n\n']) checkRoundTrip(local, remote);
    assert.equal(mergeSourceLines(local).map(line => line.text).join(''), local);
  }
  assert.deepEqual(mergeLineDiff('a\n', 'a').map(line => line.kind), ['removed', 'added']);
  assert.equal(mergeDiffText({ text: '\t缩进\r\n' }), '    缩进 ␍');
});

test('重复行与多段修改不会错配或丢行', () => {
  checkRoundTrip('相同\n重复\n重复\n旧值\n结尾\n', '相同\n新值\n重复\n结尾\n附加\n');
  let seed = 17;
  const random = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
  const tokens = ['重复\n', '\n', '\t缩进\r\n', '* 标题\n', '尾行'];
  for (let trial = 0; trial < 300; trial++) {
    const source = () => Array.from({ length: random() % 30 }, () => tokens[random() % tokens.length]).join('');
    checkRoundTrip(source(), source());
  }
});

test('超大改动限制比较开销并保留全部原文与共同首尾', () => {
  const local = '共同开头\n' + Array.from({ length: 2000 }, (_, index) => `本地 ${index}\n`).join('') + '共同结尾\n';
  const remote = '共同开头\n' + Array.from({ length: 2000 }, (_, index) => `远端 ${index}\n`).join('') + '共同结尾\n';
  const diff = checkRoundTrip(local, remote);
  assert.equal(diff.length, 4002);
  assert.equal(diff[0].kind, 'context');
  assert.equal(diff.at(-1).kind, 'context');
});

// 只加载页面的状态与操作方法，ArkUI 布局和手势由设备验证。
function reviewFixture() {
  const file = path.resolve(__dirname, '../entry/src/main/ets/pages/ConflictFile.ets');
  const source = fs.readFileSync(file, 'utf8').split('  build()')[0]
    .replace(/@Entry\n|@Component\n|@State /g, '').replace('struct ConflictFile', 'class ConflictFile') +
    '}\nmodule.exports = ConflictFile;';
  const result = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  });
  const calls = [];
  let backs = 0, failure;
  const comparison = { syncId: 'sync', repoId: 'repo', path: 'a.org', localHash: 'local-v1', remoteHash: 'remote-v1',
    localMissing: false, unchangedCount: 2, changes: [
      { id: 'task', path: 'a.org', kind: 'modified', preamble: false, localChange: 'modified', remoteChange: 'modified',
        local: { title: '任务', source: '* TODO 本地\n' }, remote: { title: '任务', source: '* TODO 远端\n' } },
      { id: 'preamble', path: 'a.org', kind: 'modified', preamble: true, localChange: 'modified', remoteChange: 'unchanged',
        local: { title: '前言', source: '#+TITLE: 本地\n' }, remote: { title: '前言', source: '#+TITLE: 远端\n' } }
    ] };
  const repo = { async compareConflict() { return structuredClone(comparison); }, async resolveConflict(value) {
    calls.push(value);
    await new Promise(resolve => setImmediate(resolve));
    if (failure) throw new Error(failure);
  } };
  const dependencies = {
    '../services/AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'config' }] }; } } },
    '../services/NativeCoreService': {
      NativeCoreService: { async repository() { return repo; } }, coreErrorMessage: error => error.message
    },
    '../services/CoreNotificationService': { CoreNotificationService: { async refresh() {} } },
    '../services/RepositorySyncService': { RepositorySyncService: { async refreshConflicts() {} } }
  };
  const pageModule = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + result.outputText + '\n})', { filename: file })(
    dependency => { assert.ok(dependencies[dependency], dependency); return dependencies[dependency]; },
    pageModule, pageModule.exports);
  const page = new pageModule.exports();
  page.getUIContext = () => ({ getHostContext: () => ({}), getRouter: () => ({
    getParams: () => ({ repoId: 'config', syncId: 'sync', path: 'a.org' }), back: () => { backs++; }
  }) });
  page.comparison = comparison;
  page.repo = repo;
  page.loading = false;
  page.choices = comparison.changes.map(change => ({ id: change.id, side: '' }));
  return { page, comparison, calls, backs: () => backs, fail(message) { failure = message; } };
}

test('文件任务与前言均需要选择，逐项选择不触发任何写入', async () => {
  const { page, calls } = reviewFixture();
  page.choose('task', 'local');
  assert.equal(page.choice('task'), 'local');
  assert.equal(page.remaining(), 1);
  await page.save();
  assert.equal(calls.length, 0);
  page.choose('preamble', 'remote');
  assert.equal(page.ready(), true);
  assert.equal(calls.length, 0);
});

test('保存传递完整来源与逐项选择，保存期间阻止返回和重复提交', async () => {
  const { page, comparison, calls, backs } = reviewFixture();
  page.choose('task', 'local'); page.choose('preamble', 'remote');
  const saving = page.save();
  assert.equal(page.onBackPress(), true);
  await page.save(); await saving;
  assert.equal(calls.length, 1);
  const selected = calls[0];
  assert.equal(selected.localHash, comparison.localHash);
  assert.equal(selected.remoteHash, comparison.remoteHash);
  assert.equal(selected.syncId, comparison.syncId);
  assert.deepEqual(selected.changes.map(c => c.resolution), ['local', 'remote']);
  assert.equal(selected.changes[1].preamble, true);
  assert.equal(selected.changes[0].local, comparison.changes[0].local);
  assert.equal(backs(), 1);
});

test('离开页面丢弃内存选择，重新打开从未选择状态比较', async () => {
  const { page, calls } = reviewFixture();
  page.choose('task', 'local');
  page.aboutToDisappear();
  assert.equal(page.comparison, undefined);
  assert.deepEqual(page.choices, []);
  await page.load();
  assert.equal(page.remaining(), 2);
  assert.equal(page.choice('task'), '');
  assert.equal(calls.length, 0);
});

test('保存失败作废旧比较，不返回日志，重新比较读取最新来源', async () => {
  const { page, backs, fail } = reviewFixture();
  page.choose('task', 'local'); page.choose('preamble', 'local');
  fail('本地文件已改变');
  await page.save();
  assert.equal(page.comparison, undefined);
  assert.equal(page.saving, false);
  assert.equal(backs(), 0);
  assert.match(page.message, /重新比较/);
  await page.load();
  assert.equal(page.remaining(), 2);
});

test('零待选择项允许显式保存，比较本身不提交', async () => {
  const { page, calls, backs } = reviewFixture();
  page.comparison.changes = []; page.choices = [];
  assert.equal(page.ready(), true);
  assert.equal(calls.length, 0);
  await page.save();
  assert.deepEqual(calls[0].changes, []);
  assert.equal(backs(), 1);
});
