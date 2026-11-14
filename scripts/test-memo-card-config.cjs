// 验证卡片实例配置隔离、Core 标签查询和确认／取消边界。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-memo-card-config.cjs\n先执行 make build，再验证卡片身份注入、标签配置、Core 查询、预览竞态和保存失败恢复。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(name, mocks, transform = source => source) {
  const filename = path.resolve('entry/src/main/ets/' + name + '.ets');
  const source = ts.transpileModule(transform(fs.readFileSync(filename, 'utf8')), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + source + '\n})', { filename })(dependency => {
    assert.ok(Object.hasOwn(mocks, dependency), `缺少替身：${dependency}`); return mocks[dependency];
  }, module, module.exports);
  return module.exports;
}

function fixture() {
  const disk = new Map(), invalidated = [], queries = [];
  const repository = { id: 'configured-repo' }, config = { repos: [repository], todoDefaults: 'defaults' };
  let tasks = [{ heading: 'Core 返回的标题', tags: ['实际标签'] }], failFlush = false, available = true;
  const formKit = { formInfo: { FormParam: { IDENTITY_KEY: 'identity' } } };
  const mocks = {
    '@kit.FormKit': formKit,
    '@kit.ArkData': { preferences: {
      async removePreferencesFromCache(_, name) { invalidated.push(name); },
      async deletePreferences(_, name) { disk.delete(name); }
    } },
    './AppConfigService': { AppConfigService: { async load(_, credentials) { assert.equal(credentials, false); return config; } } },
    './FileTargetService': { fileTargetRepository: () => repository, FileTargetService: { prepare(_, __, kind) {
      assert.equal(kind, 'memo'); return available ? { reference: {repoId:'core', path:'备忘.org'}, file:{type:'file', query:{includeFiles:[{repoId:'core',path:'备忘.org'}]}} } : undefined;
    } } },
    './NativeCoreService': { taskResult: value => value.result, fileResult: value => value.result, NativeCoreService: {
      async workspaceFor(repos, defaults) {
        assert.equal(repos[0], repository); assert.equal(defaults, 'defaults');
        return { async repos() { return []; }, async query(batch) {
          assert.equal(batch.length, 2);
          return batch.map(request => {
            if (request.type === 'task') { queries.push(request.query); return {type:'task', result:{tasks, categories:[]}}; }
            return {type:'file', result:[{tagOptions:['未使用标签'], tagGroups:[]}]};
          });
        } };
      }
    } },
    './PreferencesStore': { PreferencesStore: { async open(_, name) {
      const local = new Map(disk.get(name));
      return { async get(key, fallback) { return local.get(key) ?? fallback; }, async put(key, value) { local.set(key, value); },
        async flush() { if (failFlush) throw new Error('存储失败'); disk.set(name, local); } };
    } } },
    './TaskViewQueries': load('services/TaskViewQueries', {}),
    '../ui/TaskTagFilterPresentation': load('ui/TaskTagFilterPresentation', {})
  };
  return { ...load('services/MemoCardService', mocks), disk, invalidated, queries,
    tasks(value) { tasks = value; }, failFlush() { failFlush = true; }, invalidate() { available = false; } };
}

test('标签按卡片隔离保存，重新读取和移除一张卡片不影响另一张', async () => {
  const f = fixture();
  assert.equal(await f.MemoCardService.loadTag({}, '123'), '');
  await f.MemoCardService.saveTag({}, '123', '家居');
  await f.MemoCardService.saveTag({}, '456', '工作');
  assert.equal(await f.MemoCardService.loadTag({}, '123'), '家居');
  assert.equal(await f.MemoCardService.loadTag({}, '456'), '工作');
  await f.MemoCardService.remove({}, '123');
  assert.equal(await f.MemoCardService.loadTag({}, '123'), '');
  assert.equal(await f.MemoCardService.loadTag({}, '456'), '工作');
  assert.ok(f.invalidated.includes('org_tasks_memo_card_123'));
  f.failFlush(); await assert.rejects(f.MemoCardService.saveTag({}, '456', '其他'), /存储失败/);
  assert.equal(await f.MemoCardService.loadTag({}, '456'), '工作');
});

test('候选保留未使用的声明标签，筛选包含转义后的标签并沿用 Core 顺序', async () => {
  const f = fixture();
  const all = await f.MemoCardService.snapshot({}, '');
  assert.deepEqual(all.tags, ['实际标签', '未使用标签']);
  assert.equal(f.queries[0].expression, 'b."备忘.org" .o.modified');
  const selected = await f.MemoCardService.snapshot({}, 'a"\\ or t.other');
  assert.equal(f.queries[1].expression, 'b."备忘.org" t."a\\"\\\\ or t.other" .o.modified');
  assert.equal(selected.data.memoCardItem1, 'Core 返回的标题');
  assert.deepEqual(Object.keys(f.queries[1]).sort(), ['expression', 'includeComposeTasks']);
  assert.equal(f.queries[1].includeComposeTasks, true);
  f.tasks([]);
  const empty = await f.MemoCardService.snapshot({}, '已删除标签');
  assert.equal(empty.data.memoCardTitle, '已删除标签'); assert.match(empty.data.memoCardMessage, /暂无备忘/);
  f.invalidate(); assert.equal((await f.MemoCardService.snapshot({}, '已删除标签')).available, false);
});

test('卡片标题与记录身份保持对应，跳过空标题后不按原行号错配，清空同时清除身份', () => {
  const { memoCardData } = fixture();
  const data = memoCardData([
    { id: 'blank', heading: ' ' }, { id: 'first', heading: ' 同名 ' },
    { id: 'second', heading: '同名' }, { id: 'third', heading: '第三条' }, { id: 'fourth', heading: '第四条' }
  ]);
  assert.deepEqual([data.memoCardItem1, data.memoCardItem2, data.memoCardItem3], ['同名', '同名', '第三条']);
  assert.deepEqual([data.memoCardItemId1, data.memoCardItemId2, data.memoCardItemId3], ['first', 'second', 'third']);
  const empty = memoCardData();
  assert.deepEqual([empty.memoCardItemId1, empty.memoCardItemId2, empty.memoCardItemId3], ['', '', '']);
});

test('卡片身份保持完整字符串，缺失和不安全参数不能写入设置', async () => {
  const f = fixture();
  assert.equal(f.memoCardFormId({ parameters: { identity: '12345678901234567890' } }), '12345678901234567890');
  assert.equal(f.memoCardFormId({ parameters: { identity: 123 } }), '');
  assert.equal(f.memoCardFormId({}), '');
  await assert.rejects(f.MemoCardService.saveTag({}, '../config', 'tag'), /无法识别/);
  assert.equal(f.disk.size, 0);
});

function pageFixture() {
  const calls = [], deferred = new Map();
  let failUpdate = false;
  const { memoCardData } = fixture();
  const service = { async loadTag() { return '旧标签'; }, async snapshot(_, tag) {
    if (deferred.has(tag)) return deferred.get(tag);
    return { data: memoCardData([{ heading: tag || '全部记录' }], tag), tags: ['家居', '工作'], available: true };
  }, async saveTag(_, id, tag) { calls.push(['save', id, tag]); } };
  const module = load('pages/MemoCardConfig', {
    '../services/MemoCardService': { MemoCardService: service, memoCardData },
    '../services/NativeCoreService': { coreErrorMessage: error => error.message },
    '@kit.FormKit': { formBindingData: { createFormBindingData: data => data }, formProvider: { async updateForm(id, data) {
      calls.push(['update', id, data.memoCardTitle]); if (failUpdate) throw new Error('卡片暂不可更新');
    } } }
  }, source => (source.slice(0, source.indexOf('\n  @Builder')) + '\n}')
    .replace(/^@(Entry(?:\(.*\))?|Component)\n/gm, '').replace(/^  @(State|LocalStorageProp\('[^']+'\)) /gm, '  ')
    .replace('struct MemoCardConfig', 'export class MemoCardConfig'));
  const instance = new module.MemoCardConfig(); instance.formId = '123';
  instance.getUIContext = () => ({ getHostContext: () => ({ async terminateSelf() { calls.push(['close']); } }) });
  return { instance, calls, service, memoCardData, failUpdate() { failUpdate = true; },
    defer(tag) { let resolve; deferred.set(tag, new Promise(done => { resolve = done; })); return resolve; } };
}

test('恢复原选择与预览，修改后取消不写入；确定只保存并更新当前实例', async () => {
  const f = pageFixture(); await f.instance.load();
  assert.equal(f.instance.selectedTag, '旧标签');
  assert.ok(f.instance.options.some(option => option.tag === '旧标签'));
  await f.instance.selectTag('家居'); await f.instance.cancel();
  assert.deepEqual(f.calls, [['close']]); f.calls.length = 0;
  await f.instance.confirm();
  assert.deepEqual(f.calls, [['save', '123', '家居'], ['update', '123', '家居'], ['close']]);
});

test('快速选择时旧预览不能覆盖新选择；更新失败保留编辑页供重试', async () => {
  const f = pageFixture(); await f.instance.load();
  const resolve = f.defer('慢标签'); const old = f.instance.selectTag('慢标签');
  await f.instance.selectTag('工作');
  resolve({ data: f.memoCardData([{ heading: '过期结果' }], '慢标签'), available: true }); await old;
  assert.equal(f.instance.selectedTag, '工作'); assert.equal(f.instance.preview.memoCardItem1, '工作');
  f.failUpdate(); await f.instance.confirm();
  assert.match(f.instance.message, /设置已保存/);
  assert.ok(!f.calls.some(call => call[0] === 'close'));
  assert.equal(f.instance.working, false);
});

test('桌面编辑入口对应已注册的独立 Ability 和页面', () => {
  const read = filename => JSON.parse(fs.readFileSync(filename, 'utf8'));
  const form = read('entry/src/main/resources/base/profile/memo_forms.json').forms[0];
  const name = form.formConfigAbility.replace('ability://', '');
  const ability = read('entry/src/main/module.json5').module.abilities.find(ability => ability.name === name);
  assert.ok(ability?.exported);
  assert.equal(ability.launchType, 'multiton');
  assert.ok(fs.existsSync(path.join('entry/src/main', ability.srcEntry)));
  assert.ok(read('entry/src/main/resources/base/profile/main_pages.json').src.includes('pages/MemoCardConfig'));
});

test('实际编译页面从 WindowStage 的共享存储取得当前卡片身份', () => {
  const filename = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/MemoCardConfig.ts');
  assert.ok(fs.existsSync(filename), '请先执行 make build');
  let factory, formId = '12345678901234567890';
  class Property {
    constructor(value) { this.value = value; }
    get() { return this.value; }
    set(value) { this.value = value; }
  }
  class ViewPU {
    constructor(_, storage) { this.storage = storage; }
    finalizeConstruction() {}
    createLocalStorageProp(key, fallback) { return new Property(this.storage?.[key] ?? fallback); }
  }
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, {
    exports: {}, ViewPU, ObservedPropertySimplePU: Property, ObservedPropertyObjectPU: Property,
    LocalStorage: { getShared: () => ({ memoCardFormId: formId }) },
    registerNamedRoute(callback) { factory = callback; },
    require(name) { return name.includes('MemoCardService') ? { memoCardData: () => ({}) } : {}; }
  }, { filename });
  const first = factory();
  assert.equal(first.formId, formId);
  formId = '456';
  assert.equal(factory().formId, '456');
  assert.equal(first.formId, '12345678901234567890');
});
