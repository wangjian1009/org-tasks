// 验证收件箱合并的宿主编排与页面状态；真实 Org 改写由 Core 集成测试覆盖。
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
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,ListScroller,setTimeout,clearTimeout){' + code + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    throw new Error('缺少替身: ' + name);
  }, module, module.exports, class { closeAllSwipeActions() {} scrollToIndex() {} }, () => 1, () => {});
  return module.exports;
}
function fixture() {
  const requests = [], notices = [];
  const config = { repos: [{ id: 'host', rootDirectory: '/repo', webdavEnabled: true }], inboxRepoId: 'host', inboxFile: 'inbox.org' };
  const records = [task('main'), task('source')];
  let failure, queryFailure, commitWait, saveResult = true, queries = 0;
  let loaded = false;
  const repo = { rootDirectory: '/repo', get id() { return loaded ? 'core' : ''; }, async load() { loaded = true; } };
  const workspace = {
    async query(batch) { queries++; if (queryFailure) throw new Error('读取失败'); return batch.map(request =>
      request.type === 'task' ? {type:'task',result:{tasks:records,categories:[]}} : {type:'file',result:[{path:'inbox.org'}]}); },
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
    async executeTaskOperations(group) { requests.push({ kind: 'commit', group }); if (commitWait) await commitWait; if (failure) throw failure; }
  };
  const appConfig = { AppConfigService: { async load() { return config; } } };
  const core = { taskResult:value=>value.result, NativeCoreService: { async workspaceFor() { return workspace; } }, coreErrorMessage: e => e.message };
  const target = { configuredFileTarget: c => ({ repoId: c.inboxRepoId, path: c.inboxFile }), FileTargetService: {
    prepare() { return {reference:{repoId:'core',path:'inbox.org'},task:{type:'task',query:{}},file:{type:'file',query:{}}}; },
    result(task) { return task.result; }
  } };
  const servicePath = path.resolve('entry/src/main/ets/services/InboxService.ets');
  const { InboxService } = compile(fs.readFileSync(servicePath, 'utf8'), servicePath, {
    './AppConfigService': appConfig, './NativeCoreService': core, './FileTargetService': target,
    './PageQueryService':{PageQueryService:{query:(_,batch)=>workspace.query(batch)}}
  });
  const filename = path.resolve('entry/src/main/ets/pages/Inbox.ets');
  const full = fs.readFileSync(filename, 'utf8');
  const prefix = full.split('  @Builder\n')[0].replace(/@Entry\n|@Component\n/g, '')
    .replace(/@(State|StorageLink\([^)]*\)|Watch\([^)]*\))\s*/g, '').replace('struct Inbox', 'class Inbox');
  const loading = full.slice(full.indexOf('  async loadRecords()'), full.indexOf('  build()'));
  const Page = compile(prefix + loading + '}\nmodule.exports = Inbox;', filename, {
    '../services/TaskInlineService': { TaskInlineSession: { active: () => false, async end() { return saveResult; } } },
    '../services/CoreNotificationService': { emptyCoreNotificationsState: () => ({ notifications: [] }) },
    '@kit.ArkUI': { KeyboardAvoidMode: { OFFSET: 0 } },
    '../services/InboxService': { InboxService },
    '../ui/InboxPresentation': { recentDays: () => [] },
    '../services/AppConfigService': appConfig, '../services/FileTargetService': target,
    '../services/NativeCoreService': core
  });
  const page = new Page();
  page.records = [...records]; page.loading = false;
  page.getUIContext = () => ({ getHostContext: () => ({}), getPromptAction: () => ({ showToast: v => notices.push(v) }) });
  page.closeTargetPopup = () => {};
  page.loadRecentRecords = () => {};
  page.measureRows = () => {};
  return { page, records, requests, notices, config, InboxService,
    setFailure(value) { failure = value; }, setQueryFailure() { queryFailure = true; },
    waitCommit(value) { commitWait = value; },
    setSaveResult(value) { saveResult = value; }, get queries() { return queries; } };
}

test('直接合并只提交一组删除和修改，先加载 Core 身份并携带原版本', async () => {
  const f = fixture();
  const result = await f.InboxService.merge({}, [...f.records].reverse());
  assert.equal(result.titles[0], '合并: source');
  assert.deepEqual(f.requests[0], { kind: 'plan', request: { paths: [f.records[1].fullPath, f.records[0].fullPath], fileVersion: 'v1' } });
  const commits = f.requests.filter(r => r.kind === 'commit');
  assert.equal(commits.length, 1);
  assert.deepEqual(commits[0].group.operations.map(op => op.type), ['Deletion', 'Modification']);
  assert.deepEqual(commits[0].group.queueRepoIds, ['core']);
  assert.deepEqual(commits[0].group.fileVersions, [{ repoId: 'core', file: 'inbox.org', version: 'v1' }]);
  f.config.inboxFile = 'changed.org';
  await assert.rejects(f.InboxService.merge({}, f.records), e => e.code === 'invalidState');
  assert.equal(f.requests.filter(r => r.kind === 'commit').length, 1);
});

test('跨文件与不一致版本直接拒绝，不生成操作组', async () => {
  const f = fixture();
  for (const other of [{ ...f.records[1], fileVersion: 'v2' }, { ...f.records[1], filePath: 'other.org' }]) {
    await assert.rejects(f.InboxService.merge({}, [f.records[0], other]), /同一版本/);
  }
  assert.equal(f.requests.length, 0);
});

test('进入多选等待草稿保存，失败不进入；多选期间刷新保持当前选择快照', async () => {
  const f = fixture();
  f.setSaveResult(false);
  await f.page.startSelection(f.records[0]);
  assert.equal(f.page.selectingRecords, false);
  assert.equal(f.queries, 0);
  f.setSaveResult(true);
  await f.page.startSelection(f.records[0]);
  assert.equal(f.page.selectingRecords, true);
  assert.deepEqual(f.page.selectedRecordIds, ['main']);
  await f.page.loadRecords();
  assert.equal(f.queries, 1);
  assert.deepEqual(f.page.selectedRecordIds, ['main']);
});

test('选择顺序决定结果标题，取消选择第一条后下一条成为第一条', () => {
  const f = fixture();
  f.page.selectingRecords = true;
  f.page.toggleRecord(f.records[1]); f.page.toggleRecord(f.records[0]);
  assert.deepEqual(f.page.selectedRecords().map(r => r.id), ['source', 'main']);
  f.page.toggleRecord(f.records[1]);
  assert.deepEqual(f.page.selectedRecords().map(r => r.id), ['main']);
  f.page.cancelSelection();
  assert.deepEqual(f.page.selectedRecordIds, []);
  assert.equal(f.requests.length, 0);
});

test('多选期间再次触发长按入口，保留原顺序与快照，不重新读取或写入', async () => {
  const f = fixture();
  await f.page.startSelection(f.records[1]);
  f.page.toggleRecord(f.records[0]);
  const queries = f.queries;
  await f.page.startSelection(f.records[0]);
  assert.deepEqual(f.page.selectedRecordIds, ['source', 'main']);
  assert.equal(f.queries, queries);
  assert.equal(f.requests.length, 0);
});

test('重新读取后当前记录已消失，不进入旧的空选择界面', async () => {
  const f = fixture();
  const record = f.records.shift();
  await f.page.startSelection(record);
  assert.equal(f.page.selectingRecords, false);
  assert.deepEqual(f.page.selectedRecordIds, []);
  assert.equal(f.requests.length, 0);
});

test('直接合并连续点击只提交一次；提交成功但刷新失败不能再次提交', async () => {
  const f = fixture(); let resolve;
  f.waitCommit(new Promise(r => { resolve = r; })); f.setQueryFailure();
  f.page.selectingRecords = true; f.page.selectedRecordIds = ['source', 'main'];
  const pending = f.page.mergeSelected();
  assert.equal(f.page.onBackPress(), true);
  f.page.cancelSelection();
  assert.equal(f.page.selectingRecords, true);
  await f.page.mergeSelected();
  resolve(); await pending;
  await f.page.mergeSelected();
  assert.equal(f.requests.filter(r => r.kind === 'commit').length, 1);
  assert.equal(f.requests[0].request.paths[0].titles[0], 'source');
  assert.equal(f.page.selectingRecords, false);
  assert.match(f.page.message, /读取失败/);
  assert.equal(f.notices.length, 1);
});

test('过期文件拒绝后保留原选择顺序，禁止用原版本重复合并', async () => {
  const f = fixture();
  f.page.selectingRecords = true; f.page.selectedRecordIds = ['source', 'main'];
  f.setFailure(Object.assign(new Error('任务文件版本已变化，请刷新后重试'), { code: 'invalidState' }));
  await f.page.mergeSelected(); await f.page.mergeSelected();
  assert.equal(f.page.selectingRecords, true);
  assert.deepEqual(f.page.selectedRecordIds, ['source', 'main']);
  assert.equal(f.page.mergeInvalid, true);
  assert.equal(f.requests.filter(r => r.kind === 'commit').length, 1);
  assert.equal(f.notices.length, 0);
});
