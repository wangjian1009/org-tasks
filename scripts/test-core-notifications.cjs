// 验证宿主事件快照刷新及身份映射，不在宿主重新判定冲突。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-core-notifications.cjs\n验证事件快照、多仓库身份、过期响应、错误保留和同步详情路由目标。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks, storage) {
  const filename = path.resolve('entry/src/main/ets', file + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,AppStorage){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    throw new Error('缺少替身: ' + name);
  }, module, module.exports, storage);
  return module.exports;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const writes = [];
  const context = {};
  const config = { repos: [
    { id: 'config-a', name: '个人仓库', rootDirectory: '/a' },
    { id: 'config-b', name: '工作资料', rootDirectory: '/b' }
  ], todoDefaults: '' };
  let coreId = 'core-a', loads = 0, events = [], query = null;
  const repo = { get id() { return coreId; }, async load() { loads++; } };
  let observer;
  const workspace = { async watchNotifications(callback) { observer = callback; }, stopWatchingNotifications() { observer = undefined; } };
  const service = load('services/CoreNotificationService', {
    './AppConfigService': { AppConfigService: { async load(actual, credentials) {
      assert.equal(actual, context); assert.equal(credentials, false); return structuredClone(config);
    } } },
    './NativeCoreService': { NativeCoreService: {
      async workspaceFor() { return workspace; },
      async notifications() { return query ? query() : events; },
      async repository(repositories, configured) { assert.equal(configured.id, 'config-a'); return repo; }
    } },
    '../ui/Theme': { repositoryLabel(repository) { return repository.name; } }
  }, { setOrCreate(key, value) { assert.equal(key, 'coreNotifications'); writes.push(value); } });
  return { ...service, writes, context, config, setEvents(value) { events = value; },
    setQuery(value) { query = value; }, emit() { observer(); }, setCoreId(value) { coreId = value; }, loads: () => loads };
}
const conflict = (repoId = 'core-a', paths = ['same.org']) => ({ type: 'syncConflict', repoId, rootDirectory: repoId === 'core-a' ? '/a' : '/b', syncId: 'same-sync', paths });

test('多仓库同名文件保持独立，展示名称仅由通知及本地配置得到，不查询其他 Core 接口', async () => {
  const f = fixture(), events = [conflict(), conflict('core-b')];
  f.setEvents(events); await f.CoreNotificationService.refresh(f.context);
  const state = f.writes[0];
  assert.deepEqual(state.notifications, events);
  assert.deepEqual(Object.keys(state.notifications[0]), ['type', 'repoId', 'rootDirectory', 'syncId', 'paths']);
  assert.deepEqual(state.repositories.map(repo => [repo.coreRepoId, repo.configRepoId]), [['core-a', 'config-a'], ['core-b', 'config-b']]);
});

test('解决按钮使用配置身份与精确同步 ID，仓库替换后拒绝旧通知', async () => {
  const f = fixture(), notice = conflict();
  f.setEvents([notice]); await f.CoreNotificationService.refresh(f.context);
  assert.deepEqual(await f.CoreNotificationService.syncConflictTarget(f.context, notice), { repoId: 'config-a', syncId: 'same-sync' });
  assert.equal(f.loads(), 1);
  f.setCoreId('replacement');
  await assert.rejects(f.CoreNotificationService.syncConflictTarget(f.context, notice), /发生变化/);
  f.config.repos = [];
  await assert.rejects(f.CoreNotificationService.syncConflictTarget(f.context, notice), /不存在/);
});

test('较早的慢响应不能恢复已经解决的通知', async () => {
  const f = fixture(), started = deferred(), first = deferred();
  let calls = 0;
  f.setQuery(() => { if (++calls === 1) { started.resolve(); return first.promise; } return []; });
  const old = f.CoreNotificationService.refresh(f.context); await started.promise;
  await f.CoreNotificationService.refresh(f.context); first.resolve([conflict()]); await old;
  assert.equal(f.writes.length, 1); assert.deepEqual(f.writes[0].notifications, []);
});

test('读取失败保留最近成功快照，并向调用方报告错误', async () => {
  const f = fixture(); f.setEvents([conflict()]); await f.CoreNotificationService.refresh(f.context);
  f.setQuery(() => { throw new Error('读取失败'); });
  await assert.rejects(f.CoreNotificationService.refresh(f.context), /读取失败/);
  assert.equal(f.writes.length, 1); assert.equal(f.writes[0].notifications.length, 1);
});

test('较早请求的失败不覆盖新快照，也不干扰新页面', async () => {
  const f = fixture(), started = deferred(), first = deferred(); let calls = 0;
  f.setQuery(() => { if (++calls === 1) { started.resolve(); return first.promise; } return []; });
  const old = f.CoreNotificationService.refresh(f.context); await started.promise;
  await f.CoreNotificationService.refresh(f.context); first.reject(new Error('过期失败')); await old;
  assert.equal(f.writes.length, 1); assert.deepEqual(f.writes[0].notifications, []);
});

test('冲突路径更新改变渲染键，仓库改名采用新的宿主上下文', () => {
  const view = load('ui/CoreNotificationPresentation', {}, {});
  const notice = conflict();
  assert.notEqual(view.coreNotificationRenderKey(notice), view.coreNotificationRenderKey(conflict('core-a', ['other.org'])));
  assert.equal(view.syncConflictRepositoryName(notice, [{ coreRepoId: 'core-a', name: '新名字' }]), '新名字');
});

test('只有通知更新回调提高数据版本，空通知也触发页面数据失效', async () => {
  const f=fixture();
  await f.CoreNotificationService.refresh(f.context);
  assert.equal(f.writes.at(-1).revision,0);
  f.emit();
  assert.equal(f.writes.at(-1).revision,1);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.writes.at(-1).revision,1);
  assert.deepEqual(f.writes.at(-1).notifications,[]);
  await f.CoreNotificationService.refresh(f.context);
  assert.equal(f.writes.at(-1).revision,1,'手动读取通知不伪造数据更新事件');
});

test('全局同步提示无需仓库或日志身份，重新读取不在宿主生成或消费通知', async () => {
  const f = fixture();
  const events = [{ type: 'syncRequired' }, conflict()];
  f.setEvents(events);
  await f.CoreNotificationService.refresh(f.context);
  await f.CoreNotificationService.refresh(f.context);
  assert.deepEqual(f.writes.at(-1).notifications, events);
  assert.equal(f.writes.at(-1).repositories.length, 1);
  assert.deepEqual(f.writes.at(-1).notifications[0], { type: 'syncRequired' });
});

test('点击同步提示调用共享同步 service，忙碌或连续点击不会并发，也不在页面清除提示', async () => {
  const filename = path.resolve('entry/src/main/ets/components/SyncRequiredNotificationView.ets');
  const source = fs.readFileSync(filename, 'utf8').split('  build()')[0]
    .replace(/@Component\n|@State |@Prop |@StorageLink\('[^']+'\) /g, '')
    .replace('export struct SyncRequiredNotificationView', 'export class SyncRequiredNotificationView') + '}';
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  const pending = deferred();
  let calls = 0;
  const context = {};
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})', { filename })(() => ({
    emptyRepositorySyncState: () => ({ running: false }),
    RepositorySyncService: { async start(actual) { assert.equal(actual, context); calls++; await pending.promise; } }
  }), module, module.exports);
  const view = new module.exports.SyncRequiredNotificationView();
  view.getUIContext = () => ({ getHostContext: () => context });
  const first = view.synchronize();
  await view.synchronize();
  assert.equal(calls, 1);
  pending.resolve(); await first;
  assert.equal(view.starting, false);
  view.syncState.running = true;
  await view.synchronize();
  assert.equal(calls, 1);
  assert.equal(view.syncState.running, true);
});
