// 使用实际 ArkTS 编译结果验证卡片绑定数据的增量重绘。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-memo-card.cjs\n先执行 make build，再验证卡片绑定重绘与扩展刷新生命周期。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
  function removeChildren(parent) {
    for (const [id, observer] of observers) {
      if (observer.parent !== parent) continue;
      removeChildren(id); observers.delete(id); texts.delete(id); branches.delete(id); dirty.delete(id);
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
    return noop;
  } });
  const sandbox = { ViewPU, loadEtsCard(value) { instance = value; value.initialRender(); },
    ViewStackProcessor: new Proxy({}, { get: () => noop }), postCardAction: noop };
  for (const name of ['Column', 'Row', 'Stack', 'Text', 'Rect', 'Blank', 'Button', 'If', 'ForEach']) sandbox[name] = component(name);
  for (const name of ['FontWeight', 'Color', 'ButtonType', 'TextOverflow', 'HorizontalAlign', 'ItemAlign']) {
    sandbox[name] = new Proxy({}, { get: (_, key) => key });
  }
  vm.runInNewContext(compile(fs.readFileSync(filename, 'utf8')), sandbox, { filename });
  return {
    texts: () => [...texts.values()],
    update(items, message = '暂无备忘') {
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

function extension() {
  const calls = [], updates = [];
  let tasks = [{ heading: ' 第一条 ' }, { heading: '第二条' }], failRead = false, failUpdate = false, readGate;
  const repository = { id: 'repo' }, config = { repos: [repository], todoDefaults: '' };
  const mocks = {
    '@kit.FormKit': { FormExtensionAbility: class {}, formInfo: { FormParam: { IDENTITY_KEY: 'id' }, VisibilityType: { FORM_VISIBLE: 1 } },
      formBindingData: { createFormBindingData: data => data }, formProvider: { async updateForm(id, data) {
        if (failUpdate) { failUpdate = false; throw { code: 1 }; } updates.push({ id, data });
      } } },
    '@kit.ArkData': { preferences: { async removePreferencesFromCache() { calls.push('invalidate'); } } },
    '../services/AppConfigService': { APP_CONFIG_PREFERENCES: 'config', AppConfigService: { async load(_, credentials) {
      assert.equal(credentials, false); calls.push('config'); return config;
    } } },
    '../services/FileTargetService': { fileTargetRepository: () => repository, FileTargetService: { async query() {
      calls.push('query'); if (readGate) await readGate; if (failRead) throw { code: 2 }; return { tasks };
    } } },
    '../services/NativeCoreService': { NativeCoreService: { async repository() {
      return { async load() { calls.push('reload'); } };
    } } }
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
  assert.deepEqual(f.calls, ['invalidate', 'config', 'reload', 'query']);
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
