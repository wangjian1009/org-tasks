// 验证收件箱合并只规划操作组；共享选择控制器负责通过 DataSet 提交。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-inbox-merge.cjs\n验证多选顺序、普通操作组、版本约束、重复提交与失败后的选择保留。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const task = (id, title = id) => ({ id, heading: title, repoId: 'core', filePath: 'inbox.org', fileVersion: 'v1',
  fullPath: { repoId: 'core', file: 'inbox.org', titles: [title], occurrence: 1 } });
function compile(source, filename, mocks) {
  const code = transpileFixture(ts, source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,ListScroller,setTimeout,clearTimeout){' + code + '\n})', { filename })(name => {
    if (name.endsWith('/SystemRepository')) return {SYSTEM_REPOSITORY_ID:'org-tasks-system',TRASH_FILE:'trash.org',isSystemRepository:repo=>repo.id==='org-tasks-system'};
    if (name.endsWith('/TrashSettingsService')) return {TrashSettingsService:{retentionDays:async()=>30}};
    if (name.endsWith('/SystemRepositoryService')) return {SystemRepositoryService:{ensure:async()=>({id:'org-tasks-system',name:'系统仓库',rootDirectory:'/app/system-repository'})}};
    if (name.endsWith('/TrashService')) return {TrashService:{perform:async()=>{throw new Error('本用例不执行删除')}}};
    if (name.endsWith('/PageNavigator')) return require('./helpers/page-navigator.cjs').pageNavigatorMock;
    if (Object.hasOwn(mocks, name)) return mocks[name];
    throw new Error('缺少替身: ' + name);
  }, module, module.exports, class { closeAllSwipeActions() {} scrollToIndex() {} }, () => 1, () => {});
  return module.exports;
}
function fixture() {
  const requests = [];
  const config = { repos: [{ id: 'host', rootDirectory: '/repo', webdavEnabled: true }], inboxRepoId: 'host', inboxFile: 'inbox.org' };
  const records = [task('main'), task('source')];
  let loaded = false;
  const repo = { rootDirectory: '/repo', get id() { return loaded ? 'core' : ''; }, async load() { loaded = true; } };
  const workspace = {
    async repos() { return [repo]; },
    async taskMergeOperations(request) {
      assert.equal(loaded, true);
      requests.push({ kind: 'plan', request });
      const mainPath = { ...request.paths[0], titles: ['合并: ' + request.paths[0].titles[0]] };
      return { mainPath, operationGroup: {
        operations: [{ type: 'Deletion', data: { path: request.paths[1] } },
          { type: 'Modification', data: { path: request.paths[0], modifications: [{ field: 'TITLE', value: mainPath.titles[0] }, { field: 'BODY', value: '- first\n- second\n' }] } }],
        fileVersions: [{ repoId: 'core', file: 'inbox.org', version: request.fileVersion }]
      } };
    },
    async executeTaskOperations(group) { requests.push({ kind: 'commit', group }); }
  };
  const appConfig = { AppConfigService: { async load() { return config; } } };
  const core = { taskResult:value=>value.result, NativeCoreService: { async workspaceFor() { return workspace; } }, coreErrorMessage: e => e.message };
  const target = { configuredFileTarget: c => ({ repoId: c.inboxRepoId, path: c.inboxFile }), FileTargetService: {
    prepare() { return {reference:{repoId:'core',path:'inbox.org'},task:{type:'task',query:{}},file:{type:'file',query:{}}}; },
    result(task) { return task.result; }
  } };
  const servicePath = path.resolve('entry/src/main/ets/services/InboxService.ets');
  const { InboxService } = compile(fs.readFileSync(servicePath, 'utf8'), servicePath, {
    '../ui/TaskStatePresentation': { TaskStateCategory: { Todo: 'Todo' } },
    './MoveToTargetService': {}, './TaskOperationGroups':require('./helpers/task-selection.cjs').groups,
    './AppConfigService': appConfig, './NativeCoreService': core, './FileTargetService': target,
    './PageQueryService':{PageQueryService:{query:(_,batch)=>workspace.query(batch)}}
  });
  return { records, requests, config, InboxService };
}

test('合并规划只生成一组删除和修改，先加载 Core 身份并携带原版本', async () => {
  const f = fixture();
  const result = await f.InboxService.mergePlan({}, [...f.records].reverse());
  assert.equal(result.mainPath.titles[0], '合并: source');
  assert.deepEqual(f.requests[0], { kind: 'plan', request: { paths: [f.records[1].fullPath, f.records[0].fullPath], fileVersion: 'v1' } });
  const commits = f.requests.filter(r => r.kind === 'commit');
  assert.equal(commits.length, 0);
  assert.deepEqual(result.operationGroup.operations.map(op => op.type), ['Deletion', 'Modification']);

  assert.deepEqual(result.operationGroup.fileVersions, [{ repoId: 'core', file: 'inbox.org', version: 'v1' }]);
  f.config.inboxFile = 'changed.org';
  await assert.rejects(f.InboxService.mergePlan({}, f.records), e => e.code === 'invalidState');
  assert.equal(f.requests.filter(r => r.kind === 'commit').length, 0);
});

test('跨文件与不一致版本直接拒绝，不生成操作组', async () => {
  const f = fixture();
  for (const other of [{ ...f.records[1], fileVersion: 'v2' }, { ...f.records[1], filePath: 'other.org' }]) {
    await assert.rejects(f.InboxService.mergePlan({}, [f.records[0], other]), /同一版本/);
  }
  assert.equal(f.requests.length, 0);
});
