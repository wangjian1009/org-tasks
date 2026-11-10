// 使用实际 ArkTS 编译结果验证卡片绑定数据的增量重绘。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-memo-card.cjs\n先执行 make build，再验证卡片点击路由、绑定重绘、编辑返回与扩展刷新生命周期。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const compile = source => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function card() {
  const filename = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug_widget/entry/src/main/ets/widget/pages/MemoCard.ts');
  assert.ok(fs.existsSync(filename), '请先执行 make build，生成实际 ArkTS 卡片编译结果');
  let current, sequence = 0, instance;
  const observers = new Map(), texts = new Map(), storage = new Map(), dirty = new Set(), branches = new Map();
  const clicks = new Map(), actions = [];
  function removeChildren(parent) {
    for (const [id, observer] of observers) {
      if (observer.parent !== parent) continue;
      removeChildren(id); observers.delete(id); texts.delete(id); branches.delete(id); dirty.delete(id); clicks.delete(id);
    }
  }
  function render(id, initial) {
    const previous = current, observer = observers.get(id);
    current = id; observer.dependencies.clear(); observer.callback(id, initial); current = previous;
  }
  class ViewPU {
    finalizeConstruction() {}
    createLocalStorageProp(key, fallback) {
      storage.set(key, fallback);
      return {
        get() { if (current !== undefined) observers.get(current).dependencies.add(key); return storage.get(key); },
        set(value) {
          storage.set(key, value);
          for (const [id, observer] of observers) if (observer.dependencies.has(key)) dirty.add(id);
        }
      };
    }
    observeComponentCreation2(callback) {
      const id = ++sequence;
      observers.set(id, { callback, parent: current, dependencies: new Set() }); render(id, true);
    }
    ifElseBranchUpdateFunction(branch, build) {
      if (branches.get(current) === branch) return;
      removeChildren(current); branches.set(current, branch); build();
    }
    forEachUpdateFunction(id, items, build) {
      removeChildren(id); items.forEach(build);
    }
    updateDirtyElements() {
      for (const id of [...dirty].sort((a, b) => a - b)) {
        dirty.delete(id); if (observers.has(id)) render(id, false);
      }
    }
  }
  const noop = () => {};
  const component = name => new Proxy({}, { get: (_, method) => {
    if (name === 'Text' && method === 'create') return text => texts.set(current, text);
    if (method === 'onClick') return callback => clicks.set(current, { name, callback });
    return noop;
  } });
  const sandbox = { ViewPU, loadEtsCard(value) { instance = value; value.initialRender(); },
    ViewStackProcessor: new Proxy({}, { get: () => noop }), postCardAction(_, action) { actions.push(action); } };
  for (const name of ['Column', 'Row', 'Stack', 'Text', 'Rect', 'Blank', 'Button', 'If', 'ForEach']) sandbox[name] = component(name);
  for (const name of ['FontWeight', 'Color', 'ButtonType', 'TextOverflow', 'HorizontalAlign', 'ItemAlign']) {
    sandbox[name] = new Proxy({}, { get: (_, key) => key });
  }
  vm.runInNewContext(compile(fs.readFileSync(filename, 'utf8')), sandbox, { filename });
  return {
    texts: () => [...texts.values()],
    actions,
    click(name, index = 0) { [...clicks.values()].filter(click => click.name === name)[index].callback(); },
    update(items, message = '暂无备忘', ids = []) {
      [instance.itemId1, instance.itemId2, instance.itemId3] = [ids[0] || '', ids[1] || '', ids[2] || ''];
      [instance.item1, instance.item2, instance.item3] = [items[0] || '', items[1] || '', items[2] || ''];
      instance.message = message; instance.rerender();
    }
  };
}

test('实际卡片从初始空快照收到异步数据后显示三条标题，移除加载提示', () => {
  const f = card();
  assert.ok(f.texts().includes('正在读取备忘…'));
  f.update(['鞋柜尺寸', '主卧斗柜', '周末买菜']);
  for (const title of ['鞋柜尺寸', '主卧斗柜', '周末买菜']) assert.ok(f.texts().includes(title), `缺少标题：${title}`);
  assert.ok(!f.texts().includes('正在读取备忘…'));
});

test('标题栏、加号与同名条目分别打开列表、新增和所点记录，重排后使用最新身份', () => {
  const f = card();
  f.update(['同名备忘', '同名备忘'], '暂无备忘', ['id-first', 'id-second']);
  f.click('Row', 0);
  f.click('Button');
  f.click('Row', 2);
  assert.deepEqual(f.actions.map(action => JSON.parse(JSON.stringify(action.params))), [
    { page: 'memo' }, { page: 'memo', memoAction: 'create' },
    { page: 'memo', memoAction: 'edit', memoId: 'id-second' }
  ]);
  f.update(['同名备忘', '同名备忘'], '暂无备忘', ['id-second', 'id-first']);
  f.click('Row', 1);
  assert.equal(f.actions.at(-1).params.memoId, 'id-second');
  assert.equal(f.actions.length, 4);
});

test('已显示记录改名、重排、减少和清空后不保留旧标题', () => {
  const f = card();
  f.update(['旧标题', '另一个标题', '旧第三条']);
  f.update(['另一个标题', '新标题']);
  assert.deepEqual(f.texts().filter(text => text !== '全部备忘'), ['另一个标题', '新标题']);
  f.update([], '暂无备忘');
  assert.deepEqual(f.texts().filter(text => text !== '全部备忘'), ['暂无备忘']);
  f.update([], '暂时无法读取备忘，点击打开应用');
  assert.ok(f.texts().includes('暂时无法读取备忘，点击打开应用'));
});

function overview(action = '', memoId = '') {
  const filename = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/TaskOverview.ts');
  const storage = { entryView: 'memo', entryMemoAction: action, entryMemoId: memoId };
  const routes = [], toasts = [];
  let factory, tasks = [], available = true;
  class Property {
    constructor(value) { this.value = value; }
    get() { return this.value; }
    set(value) { this.value = value; }
  }
  class ViewPU {
    constructor(_, localStorage) { this.storage = localStorage; }
    finalizeConstruction() {}
    createLocalStorageProp(key, fallback) { return new Property(this.storage?.[key] ?? fallback); }
    createStorageLink(_, fallback) { return new Property(fallback); }
  }
  vm.runInNewContext(compile(fs.readFileSync(filename, 'utf8')), {
    exports: {}, ViewPU, ObservedPropertySimplePU: Property, ObservedPropertyObjectPU: Property,
    LocalStorage: { getShared: () => storage }, registerNamedRoute(callback) { factory = callback; },
    require(name) {
      if (name.includes('CoreNotificationService')) return { emptyCoreNotificationsState: () => ({}) };
      if (name.includes('AppConfigService')) return { AppConfigService: { async load() { return {}; } } };
      if (name.includes('FileTargetService')) return { FileTargetService: { async query(_, kind) {
        assert.equal(kind, 'memo'); return available ? { tasks } : undefined;
      } } };
      if (name.includes('TaskTagFilterPresentation')) return {
        taskTagOptions: () => [], reconcileTaskTags: selection => selection, filterTasksByTags: tasks => tasks
      };
      if (name.includes('NativeCoreService')) return { coreErrorMessage: error => error.message };
      return {};
    }
  }, { filename });
  const instance = factory();
  instance.getUIContext = () => ({ getHostContext: () => ({}), getRouter: () => ({
    getParams: () => undefined, async pushUrl(route) { routes.push(route); }
  }), getPromptAction: () => ({ showToast(toast) { toasts.push(toast.message); } }) });
  instance.aboutToAppear();
  return { instance, routes, toasts, tasks(value) { tasks = value; }, invalidate() { available = false; } };
}

test('实际编译页面读取窗口启动参数，新增与列表入口分离，返回刷新不会重复打开', async () => {
  const f = overview('create');
  assert.equal(f.instance.view, 'memo');
  await f.instance.loadTasks();
  assert.equal(f.routes[0]?.url, 'pages/MemoEdit');
  assert.equal(f.routes[0]?.params.create, true);
  await f.instance.loadTasks();
  assert.equal(f.routes.length, 1);
  const list = overview();
  await list.instance.loadTasks();
  assert.equal(list.routes.length, 0);
});

test('条目编辑使用最新查询中的对应记录，同名不混淆，失效条目不打开其他记录', async () => {
  const f = overview('edit', 'second');
  const latest = { id: 'second', heading: '同名', body: '最新正文', fileVersion: 'new-version' };
  f.tasks([{ id: 'first', heading: '同名' }, latest]);
  await f.instance.loadTasks();
  assert.equal(f.routes[0]?.params.task, latest);
  await f.instance.loadTasks();
  assert.equal(f.routes.length, 1);
  const removed = overview('edit', 'removed');
  removed.tasks([{ id: 'another', heading: '同名' }]);
  await removed.instance.loadTasks();
  assert.equal(removed.routes.length, 0);
  assert.match(removed.toasts[0], /变更或删除/);
  const invalid = overview('edit', 'second');
  invalid.invalidate();
  await invalid.instance.loadTasks();
  assert.equal(invalid.routes.length, 0);
  assert.equal(invalid.instance.needsConfiguration, true);
});

function extension() {
  const calls = [], updates = [];
  let tasks = [{ heading: ' 第一条 ' }, { heading: '第二条' }], failRead = false, failUpdate = false, readGate;
  const mocks = {
    '@kit.FormKit': { FormExtensionAbility: class {}, formInfo: { FormParam: { IDENTITY_KEY: 'id' }, VisibilityType: { FORM_VISIBLE: 1 } },
      formBindingData: { createFormBindingData: data => data }, formProvider: { async updateForm(id, data) {
        if (failUpdate) { failUpdate = false; throw { code: 1 }; } updates.push({ id, data });
      } } },
    '@kit.ArkData': { preferences: { async removePreferencesFromCache() { calls.push('invalidate'); } } },
    '../services/AppConfigService': { APP_CONFIG_PREFERENCES: 'config' },
    '../services/MemoCardService': { memoCardData: (tasks = [], tag = '', message = '暂无备忘') => ({
      memoCardTitle: tag || '全部备忘', memoCardItem1: tasks[0]?.heading.trim() || '', memoCardItem2: tasks[1]?.heading.trim() || '',
      memoCardItem3: tasks[2]?.heading.trim() || '', memoCardMessage: message
    }), MemoCardService: {
      async loadTag() { calls.push('settings'); return '家居'; },
      async remove(id) { calls.push('remove'); },
      async snapshot(_, tag) {
        assert.equal(tag, '家居'); calls.push('query'); if (readGate) await readGate;
        if (failRead) throw { code: 2 };
        return { data: mocks['../services/MemoCardService'].memoCardData(tasks, tag) };
      }
    } }
  };
  const filename = path.resolve('entry/src/main/ets/entryability/MemoFormExtension.ets');
  const module = { exports: {} };
  vm.runInNewContext(compile(fs.readFileSync(filename, 'utf8')), {
    require(name) { assert.ok(mocks[name], `缺少替身：${name}`); return mocks[name]; }, module, exports: module.exports,
    console: { error() {} }
  }, { filename });
  const instance = new module.exports.default(); instance.context = {};
  return { instance, calls, updates, idle: () => instance.pendingRefresh,
    tasks(value) { tasks = value; }, failRead() { failRead = true; }, failUpdate() { failUpdate = true; },
    defer() { readGate = new Promise(resolve => { this.resume = resolve; }); } };
}

test('创建与扩展重启后重新可见均先读最新配置和文件，再发布数据', async () => {
  const f = extension();
  assert.equal(f.instance.onAddForm({ parameters: { id: 'one' } }).memoCardMessage, '正在读取备忘…');
  await f.idle();
  assert.deepEqual(f.calls, ['invalidate', 'settings', 'query']);
  assert.equal(f.updates[0].data.memoCardTitle, '家居');
  assert.equal(f.updates[0].data.memoCardItem1, '第一条');
  f.tasks([{ heading: '修改后' }]);
  f.instance.onChangeFormVisibility({ restored: 1, hidden: 2 }); await f.idle();
  assert.equal(f.updates.at(-1).id, 'restored');
  assert.equal(f.updates.at(-1).data.memoCardItem1, '修改后');
});

test('卡片移除后不发布在途结果，更新失败后下次刷新仍可执行', async () => {
  const f = extension(); f.defer();
  f.instance.onUpdateForm('removed');
  await new Promise(setImmediate);
  f.instance.onRemoveForm('removed'); f.resume(); await f.idle();
  assert.equal(f.updates.length, 0);
  f.failUpdate(); f.instance.onUpdateForm('retry'); await f.idle();
  f.instance.onUpdateForm('retry'); await f.idle();
  assert.equal(f.updates.at(-1).id, 'retry');
  f.failRead(); f.instance.onUpdateForm('retry'); await f.idle();
  assert.equal(f.updates.at(-1).data.memoCardItem1, '');
  assert.match(f.updates.at(-1).data.memoCardMessage, /无法读取/);
});
