const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-page-navigator.cjs\n验证页面路径、深层跳转、一级页返回、订阅更新与路由失败恢复。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(name, mocks = {}) {
  const file = path.resolve('entry/src/main/ets/services', name + '.ets');
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + output + '\n})', { filename: file })(name => {
    assert.ok(name in mocks, '缺少替身 ' + name); return mocks[name];
  }, module, module.exports);
  return module.exports;
}
const paths = load('PagePath');
const { PagePath } = paths;
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(check) { for (let n = 0; n < 200; n++) { if (check()) return; await tick(); } assert.fail('等待状态超时'); }
function fixture() {
  const configCallbacks = new Set(), managers = [], stack = [], messages = [], loads = [];
  let count = 0, configured = true, existing = true, fail = false, delay;
  const workspace = { async repos() { return []; } };
  const { PageNavigator, primaryPage } = load('PageNavigator', {
    './PagePath': paths,
    './AppConfigService': { AppConfigService: { async load() { if (delay) await delay; return {}; },
      watchChanges: fn => configCallbacks.add(fn), stopWatchingChanges: fn => configCallbacks.delete(fn) } },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return workspace; } } },
    './FileTargetService': { FileTargetService: {
      prepare: () => configured ? { task: { type: 'task', query: {} }, file: { type: 'file', query: {} } } : undefined,
      result: (tasks, file) => tasks && file?.result.length ? tasks.result : undefined
    } },
    './DataSetManager': { DataSetManager: { create(context, name, definitions) {
      assert.equal(name, 'page-navigation'); assert.deepEqual(definitions.map(item => item.name), ['inbox', 'file']);
      const listeners = new Set(), values = new Map();
      const manager = { closed: false, hasValidScope: () => !manager.closed,
        dataSet(name) { return { get data() { return values.get(name)?.data; },
          subscribe(fn) { const callback = event => { if(event.name === name) fn(event); }; listeners.add(callback); return () => listeners.delete(callback); } }; },
        update() {
          values.set('inbox', { data: { type: 'task', result: { tasks: Array(count).fill({}), categories: [] } } });
          values.set('file', { data: { type: 'file', result: existing ? [{}] : [] } });
          for (const name of ['inbox','file']) for (const fn of listeners) fn({ name, type: 'refresh' });
        },
        async start() { manager.update(); }, async close() { manager.closed = true; listeners.clear(); }
      }; managers.push(manager); return manager;
    } } }
  });
  const navigator = new PageNavigator();
  stack.push(primaryPage('today'));
  const router = {
    async pushUrl(page) { loads.push(['push',page]); if (fail) throw new Error('路由失败'); if (delay) await delay; stack.push(page); },
    async replaceUrl(page) { loads.push(['replace',page]); if (fail) throw new Error('路由失败'); if (delay) await delay; stack[stack.length - 1] = page; },
    back() { assert.ok(stack.length > 1); stack.pop(); }, clear() { stack.splice(0, stack.length - 1); }
  };
  const context = { getHostContext: () => ({}), getRouter: () => router,
    getPromptAction: () => ({ showToast: value => messages.push(value) }) };
  const verify = () => assert.deepEqual(navigator.path.pages.slice(-stack.length), stack.map(page => ({ url: page.url, params: page.params })));
  return { navigator, primaryPage, context, stack, managers, messages, configCallbacks, verify, loads,
    start: async () => { navigator.start({}); await until(() => managers.length && navigator.dataLoading === undefined); },
    count(value) { count = value; managers.at(-1)?.update(); },
    missing() { existing = false; managers.at(-1)?.update(); },
    configuration(value) { configured = value; for (const fn of configCallbacks) fn(); },
    fail(value) { fail = value; }, delay(value) { delay = value; } };
}

test('路径保存参数、不可空，push 与 parent 不修改原路径', () => {
  const page = { url: 'pages/MemoEdit', params: { task: { id: '1' } } };
  const root = new PagePath([{ url: 'pages/Files' }]);
  const deep = root.push(page);
  assert.equal(root.depth, 1); assert.equal(deep.depth, 2);
  assert.equal(deep.current.params.task.id, '1'); assert.deepEqual(deep.parent().pages, root.pages);
  const pages = deep.pages; pages.pop(); assert.equal(deep.depth, 2);
  assert.throws(() => new PagePath([]));
});

test('今天和收件箱互相返回，不受收件箱数量影响，连续返回不堆积原生路由', async () => {
  const f = fixture(); await f.start();
  try { for (const count of [0, 3]) {
    f.count(count);
    await f.navigator.openPrimary(f.context, f.primaryPage('today'));
    await f.navigator.back(f.context); assert.equal(f.navigator.path.current.url, 'pages/Inbox'); f.verify();
    await f.navigator.back(f.context); assert.equal(f.navigator.path.current.url, 'pages/Today'); f.verify();
    assert.equal(f.stack.length, 1);
  } } finally { await f.navigator.close(); }
});

test('所有其他一级页按最新收件箱快照返回；目标失效按空收件箱处理', async () => {
  const f = fixture(); await f.start();
  try { for (const page of ['planned', 'anytime', 'someday', 'memo', 'logbook'].map(f.primaryPage).concat([
    { url: 'pages/Files' }, { url: 'pages/Settings' }, { url: 'pages/ProjectDetail', params: { repoId: 'a', path: 'project.org' } }
  ])) {
    for (const count of [0, 2]) {
      f.count(count); await f.navigator.openPrimary(f.context, page); await f.navigator.back(f.context);
      assert.equal(f.navigator.path.current.url, count ? 'pages/Inbox' : 'pages/Today'); f.verify();
    }
  }
  f.count(4); f.missing(); await f.navigator.openPrimary(f.context, { url: 'pages/Files' }); await f.navigator.back(f.context);
  assert.equal(f.navigator.path.current.url, 'pages/Today');
  } finally { await f.navigator.close(); }
});

test('深层返回恢复带参数的父页；侧边栏重设一级路径清除旧祖先', async () => {
  const f = fixture();
  const page = { url: 'pages/RepositorySettings', params: { repoId: 'a' } };
  await f.navigator.openPrimary(f.context, { url: 'pages/Settings' });
  await f.navigator.pushPage(f.context, page);
  await f.navigator.pushPage(f.context, { url: 'pages/SyncLog', params: { repoId: 'a', syncId: '1' } }); f.verify();
  await f.navigator.back(f.context); assert.deepEqual(f.navigator.path.current, page); f.verify();
  await f.navigator.openPrimary(f.context, { url: 'pages/ProjectDetail', params: { repoId: 'a', path: 'p.org' } });
  assert.equal(f.navigator.path.depth, 1); f.verify();
  await f.navigator.back(f.context); assert.equal(f.navigator.path.current.url, 'pages/Today'); f.verify();
});

test('支持设置完整路径和替换当前页面，保留深层祖先', async () => {
  const f = fixture();
  await f.navigator.setPath(f.context, new PagePath([{ url: 'pages/Files' }, { url: 'pages/FileDetail', params: { path: 'a.org' } }]));
  await f.navigator.replacePage(f.context, { url: 'pages/ProjectDetail', params: { path: 'a.org' } });
  assert.equal(f.navigator.path.depth, 2); f.verify();
  await f.navigator.back(f.context); assert.equal(f.navigator.path.current.url, 'pages/Files'); f.verify();
});

test('平台跳转失败恢复原路径，重复点击不会重入跳转', async () => {
  const f = fixture(), before = f.navigator.path;
  f.fail(true); assert.equal(await f.navigator.pushPage(f.context, { url: 'pages/MemoEdit' }), false);
  assert.equal(f.navigator.path, before); f.verify();
  assert.equal(await f.navigator.openPrimary(f.context, { url: 'pages/Files' }), false); f.verify();
  f.fail(false); let resolve; f.delay(new Promise(done => { resolve = done; }));
  const pending = f.navigator.pushPage(f.context, { url: 'pages/MemoEdit' });
  assert.equal(await f.navigator.pushPage(f.context, { url: 'pages/MemoEdit' }), false);
  resolve(); await pending; assert.equal(f.navigator.path.depth, 2); f.verify();
});

test('配置变化关闭旧订阅并重建数据集；关闭清理监听和数据集', async () => {
  const f = fixture(); await f.start(); f.count(4);
  f.configuration(false); await until(() => f.navigator.dataLoading === undefined);
  assert.equal(f.managers[0].closed, true);
  await f.navigator.openPrimary(f.context, { url: 'pages/Files' }); await f.navigator.back(f.context);
  assert.equal(f.navigator.path.current.url, 'pages/Today');
  f.configuration(true); await until(() => f.managers.length === 2 && f.navigator.dataLoading === undefined);
  f.count(1); await f.navigator.openPrimary(f.context, { url: 'pages/Settings' }); await f.navigator.back(f.context);
  assert.equal(f.navigator.path.current.url, 'pages/Inbox');
  await f.navigator.close(); assert.equal(f.configCallbacks.size, 0); assert.equal(f.managers[1].closed, true);
});


test('完整路径只加载末级页面，返回才加载未创建的祖先并保留参数', async () => {
  const f = fixture();
  const root = { url: 'pages/Memo' };
  const middle = { url: 'pages/ProjectDetail', params: { repoId: 'r', path: 'p.org' } };
  const edit = { url: 'pages/MemoEdit', params: { memoId: 'id' } };
  await f.navigator.setPath(f.context, new PagePath([root, middle, edit]));
  assert.equal(f.loads.length, 1); assert.deepEqual(f.loads[0], ['replace',edit]);
  assert.equal(f.stack.length, 1); assert.equal(f.navigator.path.depth, 3); f.verify();
  await f.navigator.pushPage(f.context, { url: 'pages/FileDetail', params: { path: 'a.org' } });
  await f.navigator.back(f.context); assert.equal(f.loads.length, 2); assert.deepEqual(f.navigator.path.current, edit); f.verify();
  await f.navigator.back(f.context); assert.deepEqual(f.navigator.path.current, middle); assert.equal(f.loads.length, 3); f.verify();
  await f.navigator.back(f.context); assert.equal(f.navigator.path.current.url, root.url); assert.equal(f.loads.length, 4); f.verify();
});

test('直接加载路径后返回失败保留当前页面，替换末级不会丢失懒加载祖先', async () => {
  const f = fixture(), root = { url: 'pages/Files' }, edit = { url: 'pages/MemoEdit', params: { create: true } };
  await f.navigator.setPath(f.context, new PagePath([root, edit]));
  const before = f.navigator.path; f.fail(true);
  assert.equal(await f.navigator.back(f.context), false); assert.equal(f.navigator.path, before); f.verify();
  f.fail(false); await f.navigator.replacePage(f.context, { url: 'pages/ProjectDetail', params: { path: 'p.org' } });
  await f.navigator.back(f.context); assert.deepEqual(f.navigator.path.current, {url:root.url, params:root.params}); f.verify();
});


test('窗口直接恢复完整路径不会创建父页，第一次返回按父参数加载', async () => {
  const f=fixture(), root={url:'pages/Memo'}, edit={url:'pages/MemoEdit',params:{create:true}};
  f.stack[0]=edit;f.navigator.restore(new PagePath([root,edit]));
  assert.equal(f.loads.length,0);f.verify();await f.navigator.back(f.context);
  assert.equal(f.loads.length,1);assert.equal(f.loads[0][0], 'replace'); assert.equal(f.loads[0][1].url, root.url);f.verify();
});
