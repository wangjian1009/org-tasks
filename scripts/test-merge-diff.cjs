// 验证展示用 diff 不丢失原文；不访问平台、仓库或 WebDAV。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-merge-diff.cjs\n验证任务比较的原文保真、文件分区、接受丢弃与提交保护。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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

// 只加载页面的状态与操作方法，ArkUI 布局和手势由模拟器验证。
function reviewFixture() {
  const file = path.resolve(__dirname, '../entry/src/main/ets/pages/MergeConflict.ets');
  const source = fs.readFileSync(file, 'utf8').split('  @Builder\n')[0]
    .replace(/@Entry\n|@Component\n|@State /g, '').replace('struct MergeConflict', 'class MergeConflict') +
    '}\nmodule.exports = MergeConflict;';
  const result = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  });
  const dialogs = [];
  const calls = [];
  const repo = { id: 'repo' };
  const comparison = { syncId: 'sync', repoId: 'repo', repositoryVersion: 'repository-v1', endpointVersion: 'endpoint-v1',
    mode: 'mergeTasks', unchangedCount: 12, files: [{ path: 'a.org' }, { path: 'b.org' }],
    changes: [
      { id: 'a1', path: 'a.org', kind: 'modified', preamble: false, localChange: 'modified', remoteChange: 'modified',
        local: { title: '任务', source: '* TODO 本地\n' }, remote: { title: '任务', source: '* TODO 远端\n' } },
      { id: 'a2', path: 'a.org', kind: 'added', preamble: false, localChange: 'modified', remoteChange: 'deleted',
        local: { title: '恢复', source: '* 恢复\n' }, remote: null },
      { id: 'b1', path: 'b.org', kind: 'deleted', preamble: false, localChange: 'deleted', remoteChange: 'modified',
        local: null, remote: { title: '删除', source: '* 删除\n' } },
      { id: 'b2', path: 'b.org', kind: 'modified', preamble: true, localChange: 'modified', remoteChange: 'unchanged',
        local: { title: '文件前言', source: '#+TITLE: 本地\n' }, remote: { title: '文件前言', source: '#+TITLE: 远端\n' } }
    ] };
  let outcome = { result: 'succeeded', backups: [{ path: 'a.org', backupPath: '.sync/backups/a.org' }] };
  let failure;
  const policy = { async applyMerge(...args) {
    calls.push(args);
    await new Promise(resolve => setImmediate(resolve));
    if (failure) throw new Error(failure);
    return outcome;
  } };
  const dependencies = {
    '@kit.ArkUI': { router: {} },
    '../services/AppConfigService': { AppConfigService: { async load() { return { repos: [] }; } } },
    '../services/NativeCoreService': {
      CoreMergeResolution: { Local: 'local', Remote: 'remote', Remove: 'remove' },
      CoreMergeMode: { AcceptRemote: 'acceptRemote', MergeTasks: 'mergeTasks' },
      NativeCoreService: { async workspaceFor() {} }, coreErrorMessage: error => error.message
    },
    '../services/RepositorySyncService': { RepositorySyncService: { async refreshConflicts() {} } }
  };
  const pageModule = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,getContext){' + result.outputText + '\n})', { filename: file })(
    dependency => { assert.ok(dependencies[dependency], dependency); return dependencies[dependency]; },
    pageModule, pageModule.exports, () => ({}));
  const page = new pageModule.exports();
  page.getUIContext = () => ({ showAlertDialog: value => dialogs.push(value), showActionSheet: value => dialogs.push(value) });
  page.comparison = comparison;
  page.repo = repo;
  page.policy = policy;
  page.loading = false;
  page.choices = comparison.changes.map(change => ({ id: change.id, choice: '' }));
  return { page, dialogs, comparison, calls, setOutcome(value) { outcome = value; }, fail(message) { failure = message; } };
}

test('按文件分区，文件前言独立于任务统计，选择保持各任务身份', () => {
  const { page } = reviewFixture();
  assert.equal(page.fileSummary('a.org'), '新增 1 · 修改 1 · 删除 0');
  assert.equal(page.fileSummary('b.org'), '新增 0 · 修改 0 · 删除 1');
  assert.equal(page.taskChanges('b.org').length, 1);
  assert.equal(page.preambleChanges('b.org').length, 1);
  page.choose('a1', 'local');
  page.choose('b1', 'remote');
  assert.equal(page.choiceFor('a1'), 'local');
  assert.equal(page.choiceFor('b1'), 'remote');
  assert.equal(page.remaining(), 2);
});

test('接受映射本地，丢弃映射远端，删除与修改交叉时按缺席版本统计', () => {
  const { page } = reviewFixture();
  page.choose('a2', 'local');
  page.choose('b1', 'remote');
  assert.equal(page.removed(), 0);
  page.choose('a2', 'remote');
  page.choose('b1', 'local');
  assert.equal(page.removed(), 2);
});

test('未完成选择禁止确认，提交保留两端历史状态且阻止重复提交', async () => {
  const { page, dialogs, comparison, calls } = reviewFixture();
  page.confirm('mergeTasks');
  assert.equal(dialogs.length, 0);
  page.choose('a1', 'local');
  page.choose('a2', 'remote');
  page.choose('b1', 'local');
  page.choose('b2', 'remote');
  page.confirm('mergeTasks');
  assert.match(dialogs[0].message, /2 项不保留/);
  const saving = page.apply('mergeTasks');
  assert.equal(page.onBackPress(), true);
  await page.apply('mergeTasks');
  await saving;
  assert.equal(calls.length, 1);
  const selected = calls[0][1];
  assert.equal(selected.repositoryVersion, comparison.repositoryVersion);
  assert.equal(selected.endpointVersion, comparison.endpointVersion);
  assert.equal(selected.files, comparison.files);
  assert.deepEqual(selected.changes.map(change => change.resolution), ['local', 'remote', 'local', 'remote']);
  for (let index = 0; index < selected.changes.length; index++) {
    const actual = selected.changes[index];
    const original = comparison.changes[index];
    assert.equal(actual.local, original.local);
    assert.equal(actual.remote, original.remote);
    assert.equal(actual.localChange, original.localChange);
    assert.equal(actual.remoteChange, original.remoteChange);
    assert.equal(actual.preamble, original.preamble);
  }
  assert.equal(page.completed, true);
  assert.equal(page.comparison, undefined);
  assert.deepEqual(page.backups, ['a.org → .sync/backups/a.org']);
  await page.apply('mergeTasks');
  assert.equal(calls.length, 1);
});

test('重新比较已有选择须确认，取消不清除接受或丢弃', () => {
  const { page, dialogs } = reviewFixture();
  let loads = 0;
  page.load = async () => { loads++; };
  page.choose('a1', 'local');
  page.recompare();
  assert.equal(loads, 0);
  dialogs[0].primaryButton.action();
  assert.equal(page.choiceFor('a1'), 'local');
  dialogs[0].secondaryButton.action();
  assert.equal(loads, 1);
});

test('全部丢弃可独立确认，失败和部分完成均作废旧比较并保留备份', async () => {
  const first = reviewFixture();
  first.page.confirm('acceptRemote');
  assert.equal(first.dialogs.length, 1);
  first.fail('仓库已变化，请重新比较');
  await first.page.apply('acceptRemote');
  assert.ok(first.calls[0][1].changes.every(change => change.resolution === null));
  assert.equal(first.page.comparison, undefined);
  assert.equal(first.page.saving, false);
  assert.match(first.page.message, /重新比较/);
  const second = reviewFixture();
  second.setOutcome({ result: 'failed', backups: [{ path: 'b.org', backupPath: '.sync/backups/b.org' }] });
  await second.page.apply('acceptRemote');
  assert.equal(second.page.completed, false);
  assert.equal(second.page.comparison, undefined);
  assert.deepEqual(second.page.backups, ['b.org → .sync/backups/b.org']);
});
