// 验证废纸篓对原有批量入口、真实查询阶段和清理失败保留的接入。
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-trash.cjs\n验证批量 Trash/Restore/清除、版本一致性、查询范围、缓存阶段与过期清理重试。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(name, mocks) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInThisContext('(function(require,module,exports){' + source + '\n})')(name => {
    assert.ok(name in mocks, name); return mocks[name];
  }, module, module.exports);
  return module.exports;
}
const system = load('models/SystemRepository', {});
const config = { repos: [{ id: 'org-tasks-system', rootDirectory: '/sandbox/system' }] };
const task = (id, occurrence = 1, version = 'v1') => ({ id, repoId: 'source', filePath: 'tasks.org', fileVersion: version,
  fullPath: { repoId: 'source', file: 'tasks.org', titles: ['同名任务'], occurrence } });
function serviceFixture() {
  const groups = [];
  const workspace = { repos: async () => [{ id: 'persistent-system', rootDirectory: '/sandbox/system' }],
    executeTaskOperations: async group => { groups.push(group); } };
  const { TrashService } = load('services/TrashService', {
    '../models/SystemRepository': system,
    './AppConfigService': { AppConfigService: { load: async () => config } },
    './NativeCoreService': { NativeCoreService: { workspaceFor: async () => workspace } }
  });
  return { service: TrashService, workspace, groups };
}
test('批量移入废纸篓复用一次提交，目标使用持久 Core 身份，去重但保留重名任务', async () => {
  const f = serviceFixture(), a = task('a'), b = task('b', 2);
  await f.service.perform({}, [a, b, a], 'trash', 'ui-trash');
  assert.equal(f.groups.length, 1);
  const group = f.groups[0];
  assert.equal(group.operationId, 'ui-trash');
  assert.deepEqual(group.fileVersions, [{ repoId: 'source', file: 'tasks.org', version: 'v1' }]);
  assert.deepEqual(group.operations, [a, b].map(item => ({ type: 'Trash', data: { path: item.fullPath,
    target: { repoId: 'persistent-system', path: 'trash.org' } } })));
});
test('批量恢复只组装 Restore，保真复制和保留失败来源交给 Core', async () => {
  const f = serviceFixture(), tasks = [task('a'), task('b', 2)];
  await f.service.perform({}, tasks, 'restore');
  assert.equal(f.groups.length, 1);
  assert.deepEqual(f.groups[0].operations, tasks.map(item => ({ type: 'Restore', data: { path: item.fullPath } })));
});
test('永久清除按同名出现次序倒序一次提交，防止后续路径偏移', async () => {
  const f = serviceFixture();
  await f.service.perform({}, [task('a'), task('b', 2)], 'clear');
  assert.equal(f.groups.length, 1);
  assert.deepEqual(f.groups[0].operations.map(item => [item.type, item.data.path.occurrence]), [['Deletion', 2], ['Deletion', 1]]);
});
test('同文件混合版本或系统目标不可用时不提交部分操作', async () => {
  const f = serviceFixture();
  await assert.rejects(f.service.perform({}, [task('a'), task('b', 2, 'v2')], 'trash'), /版本已变化/);
  await assert.rejects(f.service.group({ repos: [] }, f.workspace, [task('a')], 'trash'), /尚未初始化/);
  assert.equal(f.groups.length, 0);
});
function managerFixture({ version = 1, expired = [task('expired')], fail = false } = {}) {
  const backend = serviceFixture(), definitions = [], operated = [];
  let starts = 0, closes = 0, failure = fail;
  const sets = new Map();
  function dataSet(name) {
    if (!sets.has(name)) sets.set(name, { version, error: '', isReady: () => true,
      data: { type: 'task', result: { tasks: name === 'expired' ? expired : [] } },
      operate: async work => { operated.push(name); if (failure) throw new Error('提交失败'); await work('dataset/cleanup'); },
      settle: async () => {} });
    return sets.get(name);
  }
  const manager = { dataSet, start: async () => { starts++; }, isReady: () => true,
    refresh: async () => { for (const set of sets.values()) set.version = 1; }, close: async () => { closes++; } };
  const { TrashDataManager } = load('services/TrashDataManager', {
    '../models/SystemRepository': system,
    './DataSetManager': { DataSetManager: { create: (_, page, factory) => { assert.equal(page, '废纸篓'); definitions.push(factory); return manager; } } },
    './TrashSettingsService': { TrashSettingsService: { retentionDays: async () => 7 } },
    './TrashService': { TrashService: backend.service }
  });
  const value = new TrashDataManager({});
  // 查询定义在保留天数异步读取之后由真正的 DataSetManager 调用。
  manager.start = async () => { starts++; definitions[0](config).forEach(definition => dataSet(definition.name)); };
  return { value, backend, definitions, sets, operated, starts: () => starts, closes: () => closes, fail: v => { failure = v; } };
}
test('打开时先读设置，三项查询限定系统文件，Core 决定过期成员；并发启动只清理一次', async () => {
  const f = managerFixture();
  await Promise.all([f.value.start(), f.value.start()]);
  const definitions = f.definitions[0](config);
  assert.deepEqual(definitions.map(item => item.query.query.expression), ['.o.deleted', 'deleted.lt.-7d', undefined]);
  for (const definition of definitions) {
    assert.deepEqual(definition.query.query.includeFiles, [{ repoId: 'org-tasks-system', path: 'trash.org' }]);
    assert.deepEqual(definition.repositoryBindings, [{ id: 'org-tasks-system', rootDirectory: '/sandbox/system' }]);
  }
  assert.deepEqual(f.operated, ['tasks']); assert.equal(f.backend.groups.length, 1);
  assert.equal(f.backend.groups[0].operationId, 'dataset/cleanup');
  await f.value.start(); assert.equal(f.backend.groups.length, 1);
  await f.value.close(); assert.equal(f.closes(), 1);
});
test('缓存版本0不能触发永久清理，刷新为真实版本后可以重试', async () => {
  const f = managerFixture({ version: 0 });
  await assert.rejects(f.value.start(), /尚未读取完成/);
  assert.equal(f.backend.groups.length, 0);
  await f.value.refresh(); assert.equal(f.backend.groups.length, 1);
});
test('清理失败保留原快照且允许重试，空过期集合不提交', async () => {
  const f = managerFixture({ fail: true });
  await assert.rejects(f.value.start(), /提交失败/);
  assert.equal(f.sets.get('expired').data.result.tasks.length, 1);
  assert.equal(f.backend.groups.length, 0);
  f.fail(false); await f.value.start(); assert.equal(f.backend.groups.length, 1);
  const empty = managerFixture({ expired: [] }); await empty.value.start(); assert.equal(empty.backend.groups.length, 0);
});
