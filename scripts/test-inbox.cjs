// 验证收件箱的目标分组和宿主调用编排；写入语义由 Rust 集成测试覆盖。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-inbox.cjs\n验证收件箱 CATEGORY 分组、目标身份、移动、将来，也许、备忘与删除请求。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks) {
  const filename = path.resolve('entry/src/main/ets', file + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (name.startsWith('.')) return load(path.relative(path.resolve('entry/src/main/ets'), path.resolve(path.dirname(filename), name)), mocks);
    throw new Error('缺少替身: ' + name);
  }, module, module.exports);
  return module.exports;
}
const target = (id, category) => ({ repoId: id, path: 'projects.org', fullPath: { repoId: id, file: 'projects.org', titles: ['Parent', 'Same'], occurrence: 1 }, headingPath: ['Parent', 'Same'],
  position: { line: 1, column: 0, byte_offset: 0 }, category, fileVersion: 'target-version' });
test('按文件 CATEGORY 合并分组，同名目标保持独立，未分类置后', () => {
  const { refileSections } = load('ui/InboxPresentation', {});
  const targets = [target('a', null), target('b', 'Work'), target('c', 'Work'), target('d', '')];
  const sections = refileSections(targets);
  assert.deepEqual(sections.map(s => s.category), ['Work', '']);
  assert.deepEqual(sections[0].targets, [targets[1], targets[2]]);
  assert.deepEqual(sections[1].targets, [targets[0], targets[3]]);
  assert.equal(targets.length, 4);
});
function fixture() {
  const requests = [];
  let ignored = false;
  const settings = { id: 'host-id', rootDirectory: '/repo', webdavEnabled: true };
  const repo = { id: 'core-id', rootDirectory: '/repo', async load() {}, async fileMetadata() {
    return [{ path: 'memo.org', isIgnore: ignored }];
  }, async file() { return { fileVersion: 'memo-version', fullPath: { repoId: 'core-id', file: 'memo.org', titles: [] } }; } };
  const task = { repoId: 'core-id', filePath: 'inbox.org', fileVersion: 'source-version', fullPath: { repoId: 'core-id', file: 'inbox.org', titles: ['Item'], occurrence: 1 } };
  const workspace = { async refileTargets() { return [target('core-id', 'Work')]; },
    async repos() { return [repo]; }, async executeTaskOperations(group) { requests.push(group); } };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [settings], memoRepoId: 'host-id', memoFile: 'memo.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.memoRepoId, path: config.memoFile }) },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return workspace; } } }
  });
  return { InboxService, requests, task, setIgnored() { ignored = true; } };
}
test('直接移动使用原目标位置和双端版本，上传身份来自 Core 仓库', async () => {
  const f = fixture(); const t = target('core-id', 'Work');
  await f.InboxService.perform({}, f.task, 'move', t);
  assert.deepEqual(f.requests[0], { operations: [{ type: 'Movement', data: { path: f.task.fullPath,
    position: { parent: t.fullPath } } }], queueRepoIds: ['core-id'], fileVersions: [
      { repoId: 'core-id', file: 'inbox.org', version: 'source-version' },
      { repoId: 'core-id', file: 'projects.org', version: 'target-version' }
    ] });
});
test('备忘使用配置文件顶部并清除根 TODO；失效目标不提交', async () => {
  const f = fixture();
  await f.InboxService.perform({}, f.task, 'memo');
  assert.deepEqual(f.requests[0].operations, [
    { type: 'Modification', data: { path: f.task.fullPath, modifications: [
      { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
      { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }
    ] } },
    { type: 'Movement', data: { path: f.task.fullPath, position: { parent: { repoId: 'core-id', file: 'memo.org', titles: [] } } } }
  ]);
  f.setIgnored();
  await assert.rejects(f.InboxService.perform({}, f.task, 'memo'), /重新选择/);
  assert.equal(f.requests.length, 1);
});
test('删除只提交源快照，不伪造目标；无目标移动不提交', async () => {
  const f = fixture();
  await f.InboxService.perform({}, f.task, 'delete');
  assert.deepEqual(f.requests[0].operations, [{ type: 'Deletion', data: { path: f.task.fullPath } }]);
  assert.deepEqual(f.requests[0].fileVersions, [{ repoId: 'core-id', file: 'inbox.org', version: 'source-version' }]);
  await assert.rejects(f.InboxService.perform({}, f.task, 'move'), /请选择任务目标/);
  assert.equal(f.requests.length, 1);
});

test('近期日期分组只组织返回快照，保留完成与 CNCL、跨年日期和当天顺序', () => {
  const { recentDays, unplannedSpacer } = load('ui/InboxPresentation', {});
  const tasks = [
    { id: 'done', todoKind: 'done', createdAt: new Date(2026, 0, 1, 12).getTime() },
    { id: 'cancelled', isCancelled: true, createdAt: new Date(2026, 0, 1, 11).getTime() },
    { id: 'memo', todoKind: null, createdAt: new Date(2025, 11, 31, 20).getTime() }
  ];
  const groups = recentDays(tasks, new Date(2026, 0, 2));
  assert.deepEqual(groups.map(g => g.date), ['1月1日', '2025年12月31日']);
  assert.equal(groups[0].weekday, '周四');
  assert.deepEqual(groups.flatMap(g => g.tasks), tasks);
  assert.equal(unplannedSpacer(800, 100), 500);
  assert.equal(unplannedSpacer(800, 900), 48);
  assert.equal(unplannedSpacer(400, 80), 220);
});

test('近期查询使用原有 Workspace.query、今天及前两天的创建日期条件和精确仓库文件排除', async () => {
  const queries = [];
  const task = { id: 'recent', createdAt: 1 };
  const repo = { id: 'core-id', rootDirectory: '/repo', async load() {} };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'host-id', rootDirectory: '/repo' }], inboxRepoId: 'host-id', inboxFile: 'inbox.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.inboxRepoId, path: config.inboxFile }) },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return { async repos() { return [repo]; }, async query(batch) { assert.ok(Array.isArray(batch)); return batch.map(q => { queries.push(q); return { tasks: [task] }; }); } }; } } }
  });
  assert.deepEqual(await InboxService.recent({}), [task]);
  assert.deepEqual(queries[0], { expression: 'cr.ge.-2d cr.le.today .o.created', includeDone: true, includeComposeTasks: true,
    excludedFiles: [{ repoId: 'core-id', path: 'inbox.org' }] });
});

test('普通 CATEGORY 查询在 Core 排除收件箱和某天文件，快捷入口独立查询具体文件', async () => {
  const queries = [];
  const normal = [target('core-a', 'Work')];
  const first = { ...target('core-a', '必须排除的分类'), path: 'someday.org', headingPath: ['Later'], position: { line: 1, column: 0, byte_offset: 0 } };
  const second = { ...first, headingPath: ['Other'], position: { line: 2, column: 0, byte_offset: 40 } };
  const repo = { id: 'core-a', rootDirectory: '/a', async load() {}, async fileMetadata() { return [{ path: 'someday.org', isIgnore: false }]; } };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'host-a', rootDirectory: '/a' }],
      inboxRepoId: 'host-a', inboxFile: 'inbox.org', somedayRepoId: 'host-a', somedayFile: 'someday.org' }; } } },
    './FileTargetService': { configuredFileTarget: (config, kind) => ({ repoId: config[kind + 'RepoId'], path: config[kind + 'File'] }) },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return { async repos() { return [repo]; },
      async refileTargets(query) { queries.push(query); return query.files ? [first, second] : normal; } }; } } }
  });
  const result = await InboxService.targets({});
  assert.deepEqual(queries, [
    { excludedFiles: [{ repoId: 'core-a', path: 'inbox.org' }, { repoId: 'core-a', path: 'someday.org' }] },
    { files: [{ repoId: 'core-a', path: 'someday.org' }] }
  ]);
  assert.equal(result.targets, normal);
  assert.equal(result.somedayTarget, first);
  assert.equal(result.somedayHint, '');
});

test('将来，也许只使用已配置文件的首个 REFILE，提交 TODO 与清除规划选项', async () => {
  const requests = [];
  const queries = [];
  let hasTargets = true;
  const first = { ...target('core-id', 'Later'), path: 'someday.org', fullPath: { repoId: 'core-id', file: 'someday.org', titles: ['Later'], occurrence: 2 } };
  const repo = { id: 'core-id', rootDirectory: '/repo', async load() {}, async fileMetadata() { return [{ path: 'someday.org', isIgnore: false }]; } };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'host-id', rootDirectory: '/repo', webdavEnabled: true }], somedayRepoId: 'host-id', somedayFile: 'someday.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.somedayRepoId, path: config.somedayFile }) },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return { async repos() { return [repo]; },
      async refileTargets(query) { queries.push(query); return hasTargets ? [first] : []; }, async executeTaskOperations(group) { requests.push(group); } }; } } }
  });
  const task = { repoId: 'source', filePath: 'inbox.org', fileVersion: 'old', fullPath: { repoId: 'source', file: 'inbox.org', titles: ['Item'], occurrence: 2 } };
  await InboxService.perform({}, task, 'someday');
  assert.deepEqual(queries[0], { files: [{ repoId: 'core-id', path: 'someday.org' }] });
  assert.deepEqual(requests[0], { operations: [
    { type: 'Modification', data: { path: task.fullPath, modifications: [
      { field: 'TODO', value: 'TODO' }, { field: 'SCHEDULE', value: null },
      { field: 'DEADLINE', value: null }
    ] } },
    { type: 'Movement', data: { path: task.fullPath, position: { parent: first.fullPath } } }
  ], fileVersions: [
    { repoId: 'source', file: 'inbox.org', version: 'old' },
    { repoId: 'core-id', file: 'someday.org', version: 'target-version' }
  ], queueRepoIds: ['core-id'] });
  hasTargets = false;
  await assert.rejects(InboxService.perform({}, task, 'someday'), /REFILE/);
  assert.equal(requests.length, 1);
});

test('位置浮层按最大分类计算高度，最多四行且小窗口限制高度', () => {
  const { targetPopupHeight } = load('ui/InboxPresentation', {});
  const section = size => ({ category: String(size), targets: Array.from({ length: size }, () => target('r', 'Work')) });
  const small = targetPopupHeight([section(1)], 800);
  const large = targetPopupHeight([section(2), section(5)], 800);
  assert.ok(small < large);
  assert.equal(large, targetPopupHeight([section(5), section(2)], 800));
  assert.equal(large, targetPopupHeight([section(5)], 800));
  assert.equal(targetPopupHeight([section(4)], 800), targetPopupHeight([section(100)], 800));
  assert.ok(targetPopupHeight([section(100)], 320) <= 320 - 104);
  assert.ok(targetPopupHeight([], 800, true) > 48);
  assert.ok(targetPopupHeight([], 800, false, '目标读取失败') > targetPopupHeight([], 800));
});
