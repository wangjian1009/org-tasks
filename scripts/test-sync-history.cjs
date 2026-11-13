// 验证历史列表展开、通知定位、异步生命周期与备份导航；不访问真实仓库。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-sync-history.cjs\n验证同步日志展开、文件状态、通知定位和备份导航。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, name, dependencies) {
  let source = fs.readFileSync(path.resolve('entry/src/main/ets', file + '.ets'), 'utf8');
  if (name) source = source.split('  @Builder')[0].split('  build()')[0]
    .replace(/@Entry\n|@Component\n|@State |@Prop |@StorageLink\('[^']+'\) /g, '')
    .replace('struct ' + name, 'class ' + name) + '\n}\nmodule.exports = ' + name;
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})')(
    id => { assert.ok(id in dependencies, id); return dependencies[id]; }, module, module.exports);
  return module.exports;
}
const presentation = load('ui/SyncLogPresentation', null, {});
function fixture(pageType = 'SyncLog') {
  const items = [{ id: 'new', started_at: 2, transfer: 'download', executionResult: 'succeeded', conflicts: [] },
    { id: 'old', started_at: 1, transfer: 'unchanged', executionResult: 'succeeded', conflicts: [] }];
  const detail = { summary: { id: 'old' }, files: [{ path: 'removed.org', outcome: 'deleted', backup: { path: 'removed.org', modifiedAt: 10 } }], errors: [] };
  const queries = [], routes = [], toasts = [];
  let query = async () => structuredClone(detail), records = items, params = { repoId: 'config', syncId: 'old' };
  const repository = { id: 'config', name: '工作仓库' };
  const dependencies = {
    '../ui/SyncLogPresentation': presentation,
    '../ui/Theme': { repositoryLabel: repo => repo.name, UiColor: {} },
    '../services/CoreNotificationService': { emptyCoreNotificationsState: () => ({ notifications: [], revision: 0 }) },
    '../services/AppConfigService': { AppConfigService: { async load() { return { repos: [repository] }; } } },
    '../services/NativeCoreService': { NativeCoreService: {
      async repository() { return { async historyDetail(id) { queries.push(id); return query(); } }; },
      async repositoryHistory() { return records; }
    }, coreErrorMessage: e => e.message }
  };
  const Type = load(pageType === 'SyncLog' ? 'pages/SyncLog' : 'components/SyncLogDetails', pageType, dependencies);
  const view = new Type();
  view.repoId = 'config'; view.syncId = 'old'; view.repositoryName = '工作仓库';
  view.getUIContext = () => ({ getHostContext: () => ({}), getPromptAction: () => ({ showToast(value) { toasts.push(value); } }),
    getRouter: () => ({ getParams: () => params, async pushUrl(value) { routes.push(value); } }) });
  return { view, detail, queries, routes, toasts, query(value) { query = value; }, records(value) { records = value; }, params(value) { params = value; } };
}

test('通知进入日志列表，精确展开目标并显示无变化记录', async () => {
  const f = fixture(); await f.view.loadLogs();
  assert.equal(f.view.expandedId, 'old'); assert.equal(f.view.showUnchanged, true);
  assert.equal(f.view.visibleItems().length, 2); assert.equal(f.view.initialIndex(), 1);
  assert.equal(f.routes.length, 0); assert.equal(f.queries.length, 0);
});

test('普通列表维持原有筛选，刷新后保留展开身份并更新详情渲染代次', async () => {
  const f = fixture(); f.params({ repoId: 'config' }); await f.view.loadLogs();
  assert.equal(f.view.visibleItems().length, 1); f.view.expandedId = 'new';
  const revision = f.view.revision; await f.view.loadLogs();
  assert.equal(f.view.expandedId, 'new'); assert.equal(f.view.revision, revision + 1);
});

test('目标记录不存在时明确报错，不展开其他日志', async () => {
  const f = fixture(); f.params({ repoId: 'config', syncId: 'missing' }); await f.view.loadLogs();
  assert.match(f.view.message, /已不存在/); assert.equal(f.view.items.length, 0);
});

test('展开项按同步 ID 读取完整文件投影，无变化文件不会过滤', async () => {
  const f = fixture('SyncLogDetails'); f.detail.files.push({ path: 'same.org', outcome: 'unchanged', backup: null });
  await f.view.load(); assert.deepEqual(f.queries, ['old']); assert.equal(f.view.detail.files.length, 2);
  assert.equal(f.view.loading, false);
});

test('收起后较早读取不能更新已销毁详情，读取失败保留重试入口', async () => {
  const f = fixture('SyncLogDetails'); let complete;
  f.query(() => new Promise(resolve => { complete = resolve; }));
  const pending = f.view.load(); await new Promise(resolve => setImmediate(resolve));
  f.view.aboutToDisappear(); complete(f.detail); await pending; assert.equal(f.view.detail, undefined);
  f.query(() => { throw new Error('记录损坏'); }); await f.view.load(); assert.match(f.view.message, /记录损坏/);
  f.query(() => f.detail); await f.view.load(); assert.equal(f.view.message, ''); assert.ok(f.view.detail);
});

test('仅远端删除备份可打开，其余历史文件不产生导航', async () => {
  const f = fixture('SyncLogDetails');
  await f.view.openFile(f.detail.files[0]);
  assert.equal(f.routes[0].url, 'pages/FileDetail');
  assert.equal(f.routes[0].params.path, 'removed.org');
  for (const outcome of ['conflict', 'merged', 'uploaded', 'unchanged', 'created']) {
    await f.view.openFile({ path: 'a.org', outcome, backup: { path: 'a.org' } });
  }
  await f.view.openFile({ path: 'missing.org', outcome: 'deleted', backup: null });
  assert.equal(f.routes.length, 1);
  assert.equal(f.toasts.length, 6);
});

test('新日志标题显示触发原因，旧日志保留原始标题并明确原因未记录', () => {
  const record = { transfer: 'upload', uploadedFiles: 2, executionResult: 'succeeded' };
  for (const [triggerReason, label] of Object.entries({ appStartup: '应用启动', appBackground: '退到后台', manual: '手动同步' })) {
    const current = { ...record, triggerReason };
    assert.equal(presentation.syncLogTriggerLabel(current), label);
    assert.equal(presentation.syncLogTitle(current), `${label} · 上传2个文件`);
  }
  assert.equal(presentation.syncLogTitle(record), '上传2个文件');
  assert.equal(presentation.syncLogTriggerLabel({ ...record, triggerReason: null }), '未记录触发原因');
  assert.equal(presentation.syncLogTitle({ ...record, triggerReason: 'appBackground', executionResult: 'failed', errorMessage: '连接被重置' }),
    '退到后台 · 连接被重置 · 上传2个文件');
});

test('展示六类持久化文件状态及本地上传状态', () => {
  for (const [outcome, label] of Object.entries({ created: '新增', deleted: '删除', unchanged: '无变化', updated: '更新', merged: '合并', conflict: '冲突', uploaded: '本地上传' })) {
    assert.equal(presentation.syncLogFileOutcomeLabel({ outcome }), label);
  }
});
