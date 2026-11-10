// 验证展示用 diff 不丢失原文；不访问平台、仓库或 WebDAV。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-merge-diff.cjs\n验证展示用行差异保留完整原文、行号与换行。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
