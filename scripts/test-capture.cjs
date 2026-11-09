// 用本机 SDK 转译宿主编排，平台服务使用内存替身；设备交互仍需模拟器验收。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-capture.cjs\n验证文件入口、捕捉输入与实体识别、草稿、共享会话初始化和分享后的页面跳转。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}

const deveco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(deveco, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');

function etsLoader(mocks = {}, globals = {}) {
  const modules = new Map();
  return function load(name) {
    const filename = path.resolve(sourceRoot, name + '.ets');
    if (modules.has(filename)) return modules.get(filename).exports;
    const module = { exports: {} };
    modules.set(filename, module);
    const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    });
    const localRequire = dependency => {
      if (Object.hasOwn(mocks, dependency)) return mocks[dependency];
      if (dependency.startsWith('.')) return load(path.relative(sourceRoot, path.resolve(path.dirname(filename), dependency)));
      throw new Error('缺少平台替身: ' + dependency);
    };
    vm.runInThisContext('(function(require,module,exports,LocalStorage,canIUse){' + result.outputText + '\n})', { filename })(localRequire, module, module.exports, globals.LocalStorage, globals.canIUse || (() => true));
    return module.exports;
  };
}

function repository(id) {
  return { id, name: id, rootDirectory: '/sandbox/' + id, webdavEnabled: false,
    webdavUrl: '', webdavUsername: '', webdavPassword: '', excludedDirectories: [] };
}

test('分享后的收件箱与任务编辑跳转使用 Want 参数，窗口之间不依赖共享 AppStorage', async () => {
  const EntryAbility = etsLoader({
    '@kit.AbilityKit': { UIAbility: class {} },
    '@kit.ArkData': { preferences: {} },
    '../services/BackgroundSyncService': { BackgroundSyncService: {} },
    '../services/RepositorySyncService': { emptyRepositorySyncState() {} },
    '../ui/Theme': { UiColor: {} }
  }, { LocalStorage: class { constructor(values) { this.values = values; } } })('entryability/EntryAbility').default;
  const ability = new EntryAbility();
  const pages = [], snapshots = [];
  const mainWindow = { async setWindowSystemBarProperties() {}, getUIContext() {
    assert.fail('主窗口应直接加载目标页面');
  } };
  const stage = { async getMainWindow() { return mainWindow; }, getMainWindowSync() { return mainWindow; },
    loadContent(page, storage, callback) { pages.push(page); snapshots.push(storage.values.entryTask); callback({ code: 0 }); } };
  const task = { id: 'updated', heading: '地址任务', body: '[[geo:31.4,120.8][新地址]]', bodyHtml: '<p>新地址</p>' };
  ability.onNewWant({ parameters: { page: 'taskEdit', task: JSON.stringify(task) } }, {});
  await ability.onWindowStageCreate(stage);
  assert.deepEqual(pages, ['pages/Inbox']);
  assert.deepEqual(snapshots[0], task);
  ability.onNewWant({ parameters: { page: 'inbox' } }, {});
  assert.deepEqual(pages, ['pages/Inbox', 'pages/Inbox']);
  assert.equal(snapshots[1], undefined);
  ability.onNewWant({ parameters: { page: 'taskEdit', task: JSON.stringify(task) } }, {});
  assert.deepEqual(pages, ['pages/Inbox', 'pages/Inbox', 'pages/Inbox']);
  assert.deepEqual(snapshots[2], task);
  ability.onNewWant({}, {});
  assert.equal(pages.length, 3);
});

function fixture() {
  const values = new Map();
  const calls = [];
  const config = { repos: [repository('personal')], inboxFile: 'inbox.org', inboxRepoId: 'personal',
    somedayFile: '', somedayRepoId: '', memoFile: '', memoRepoId: '', todoDefaults: '#+TODO: TODO | DONE' };
  const fileLists = new Map([['personal', [{ path: 'inbox.org', isIgnore: false }, { path: 'notes/inbox.org', isIgnore: false }]]]);
  const queries = [];
  let reads = 0;
  let failNextRead = false;
  let entityResults = [], entityError, releaseError, supported = true;
  const recognitionCalls = [];
  let releases = 0;
  const store = {
    async get(key, fallback) {
      if (failNextRead) { failNextRead = false; throw new Error('临时读取失败'); }
      await new Promise(resolve => setImmediate(resolve));
      return values.has(key) ? values.get(key) : fallback;
    },
    async put(key, value) { values.set(key, value); },
    async flush() {}
  };
  const load = etsLoader({
    '@kit.NaturalLanguageKit': { EntityType: { LOCATION: 'location', DATETIME: 'datetime' }, textProcessing: {
      async getEntity(title, options) {
        recognitionCalls.push({ title, options });
        if (entityError) throw entityError;
        return structuredClone(entityResults);
      },
      async release() { releases++; if (releaseError) throw releaseError; return true; }
    } },
    '@kit.ArkData': { preferences: { async getPreferences() { return store; } } },
    '../services/AppConfigService': {},
    './AppConfigService': { AppConfigService: { async load() { return structuredClone(config); }, async save(context, value) { Object.assign(config, value); } } },
    './NativeCoreService': { NativeCoreService: {
      async repository(repos, selected) {
        assert.deepEqual(repos.map(repo => repo.id), [selected.id]);
        return {
          async fileMetadata() { reads++; return fileLists.get(selected.id) || []; },
          id: 'core-' + selected.id,
          async file(path) {
            return { fullPath: { repoId: 'core-' + selected.id, file: path, titles: [] },
              fileVersion: 'version-' + selected.id, todo: { initialState: 'TODO' } };
          }
        };
      },
      async executeTaskOperations(repos, group, todoDefaults) {
        calls.push({ repos, group, todoDefaults });
      },
      async queryTasks(repos, query) {
        queries.push({ repos, query });
        return { tasks: repos.map(repo => ({ id: repo.id + ':inbox.org', heading: repo.name })), categories: [] };
      }
    } }
  }, { canIUse: capability => {
    assert.equal(capability, 'SystemCapability.AI.NaturalLanguage.TextProcessing');
    return supported;
  } });
  return { ...load('services/CaptureService'), ...load('services/FileTargetService'), config, calls, queries, fileLists, values,
    reads: () => reads, failRead() { failNextRead = true; }, recognitionCalls, releases: () => releases,
    entities(value) { entityResults = value; }, failRecognition(error) { entityError = error; },
    failRelease(error) { releaseError = error; }, unsupported() { supported = false; } };
}

test('只把外部文字整理为标题，日期保留原话，URI 正确解码', () => {
  class PlatformURL extends URL { get params() { return this.searchParams; } }
  const load = etsLoader({ '@kit.ArkTS': { url: { URL: PlatformURL }, util: { generateRandomUUID: randomUUID } } });
  const { captureRequest, captureTitle } = load('services/CaptureInput');
  assert.equal(captureTitle(' 周五前\n交报销\t链接 '), '周五前 交报销 链接');
  const request = captureRequest({ uri: 'orgtasks://capture?title=%E4%B9%B0%E7%89%9B%E5%A5%B6&mode=voice' });
  assert.equal(request.title, '买牛奶');
  assert.equal(request.voice, true);
  assert.equal(captureRequest({ parameters: { title: 42 } }).title, '');
  assert.equal(captureRequest({ uri: '::invalid', parameters: { title: '保留显式标题' } }).title, '保留显式标题');
  assert.equal(captureRequest({ uri: 'orgtasks://capture-other?title=wrong' }).title, '');
  assert.equal(captureRequest({ parameters: { title: '明天交报告', file: '/tmp/other.org' } }).title, '明天交报告');
});

test('收件箱必须指定仓库，缺失或失效 ID 均不回退到首个仓库', async () => {
  const f = fixture();
  assert.equal(f.captureRepository(f.config).id, 'personal');
  f.config.repos.push(repository('work'));
  f.config.inboxRepoId = 'work';
  assert.equal(f.captureRepository(f.config).id, 'work');
  for (const id of ['', 'removed']) {
    f.config.inboxRepoId = id;
    assert.equal(f.captureRepository(f.config), undefined);
    assert.equal(await f.FileTargetService.query(f.config, 'inbox'), undefined);
    await assert.rejects(f.CaptureService.save({}, '标题'), /重新选择/);
  }
  assert.equal(f.calls.length, 0);
  assert.equal(f.queries.length, 0);
  assert.equal(f.reads(), 0);
});

test('同名文件只查询和写入选中的仓库，某天和备忘的完成规则分别传给 Core', async () => {
  const f = fixture();
  f.config.repos.push(repository('work'));
  f.fileLists.set('work', [{ path: 'inbox.org', isIgnore: false }]);
  f.config.inboxRepoId = 'work';
  const result = await f.FileTargetService.query(f.config, 'inbox');
  assert.deepEqual(result.tasks.map(task => task.heading), ['work']);
  assert.deepEqual(f.queries[0].repos.map(repo => repo.id), ['work']);
  assert.equal(f.queries[0].query.expression, 'b."inbox.org"');
  await f.CaptureService.save({}, '标题');
  assert.deepEqual(f.calls[0].group.operations[0].data.position.parent, { repoId: 'core-work', file: 'inbox.org', titles: [] });
  await f.FileTargetService.select({}, 'someday', 'work', 'inbox.org');
  await f.FileTargetService.query(f.config, 'someday');
  assert.equal(f.queries[1].query.includeDone, false);
  await f.FileTargetService.select({}, 'memo', 'personal', 'inbox.org');
  await f.FileTargetService.query(f.config, 'memo');
  assert.equal(f.queries[2].query.includeDone, true);
  assert.equal(f.queries[2].query.expression, 'b."inbox.org" .o.modified');
});

test('文件已删除或被忽略时不查询、不创建同名文件，保留原目标供重新选择', async () => {
  const f = fixture();
  for (const files of [[], [{ path: 'inbox.org', isIgnore: true }]]) {
    f.fileLists.set('personal', files);
    assert.equal(await f.FileTargetService.query(f.config, 'inbox'), undefined);
    await assert.rejects(f.CaptureService.save({}, '标题'), /重新选择/);
    await assert.rejects(f.FileTargetService.select({}, 'memo', 'personal', 'inbox.org'), /重新选择/);
  }
  assert.equal(f.config.inboxFile, 'inbox.org');
  assert.equal(f.calls.length, 0);
  assert.equal(f.queries.length, 0);
});

test('选择与清除只修改对应文件入口，保留其他设置和新选中的目标', async () => {
  const f = fixture();
  f.config.calendarName = '刚修改的日历';
  f.config.todoDefaults = '#+TODO: NEXT | FINISHED';
  await f.FileTargetService.select({}, 'memo', 'personal', 'notes/inbox.org');
  assert.equal(f.config.memoRepoId, 'personal');
  assert.equal(f.config.memoFile, 'notes/inbox.org');
  assert.equal(f.config.inboxFile, 'inbox.org');
  assert.equal(f.config.calendarName, '刚修改的日历');
  assert.equal(f.config.todoDefaults, '#+TODO: NEXT | FINISHED');
  await f.FileTargetService.select({}, 'memo', '', '');
  assert.equal(f.config.memoRepoId, '');
  assert.equal(f.config.memoFile, '');
  assert.equal(f.config.inboxRepoId, 'personal');
});

test('保存提交标题并请求记录创建时间，使用配置 inbox 与既有上传规则', async () => {
  const f = fixture();
  f.config.repos[0].webdavEnabled = true;
  f.config.inboxFile = 'notes/inbox.org';
  await f.CaptureService.save({}, '  周五前交报销  ');
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0], { repos: f.config.repos, group: {
    operations: [{ type: 'Creation', data: { position: { parent: { repoId: 'core-personal', file: 'notes/inbox.org', titles: [] } },
      title: '周五前交报销', body: '', scheduled: null, state: 'TODO', recordCreated: true } }],
    queueRepoIds: ['core-personal'],
    fileVersions: [{ repoId: 'core-personal', file: 'notes/inbox.org', version: 'version-personal' }]
  }, todoDefaults: '#+TODO: TODO | DONE' });
});

function timeEntity(charOffset, ...time) {
  return { type: 'datetime', text: '时间', charOffset, jsonObject: JSON.stringify({ time }) };
}

function addressEntity(text, charOffset) {
  return { type: 'location', text, charOffset, jsonObject: '{}' };
}

test('真机的扁平时间对象可识别“明天晚上和老婆宝吃完饭”，并将明天写入计划日期', async () => {
  const f = fixture();
  const title = '明天晚上和老婆宝吃完饭';
  f.entities([{ type: 'datetime', text: '明天晚上', charOffset: 0, jsonObject: JSON.stringify({
    containFuzzySection: 'E', inferType: 'RELATIVE_DAY', isChangedIllegal: false, isContainFuzzyTime: true,
    isIllegal: false, maxSection: 'Y', minSection: 'E', rangeDecoration: 'POINT',
    start: '2026-11-10TE', suggestStart: '2026-11-10TE', timestampZone: 'Asia/Shanghai'
  }) }]);
  await f.CaptureService.save({}, title);
  const created = f.calls[0].group.operations[0].data;
  assert.equal(created.title, title);
  assert.equal(created.scheduled, '<2026-11-10>');
  assert.equal(created.body, '');
});

test('扁平时间对象保留精确分钟，非法时间不影响后续有效时间与地址', async () => {
  const f = fixture();
  f.entities([{ type: 'datetime', text: '非法日期', charOffset: 0,
    jsonObject: JSON.stringify({ start: '2026-02-28', isIllegal: true }) },
    { type: 'datetime', text: '精确时间', charOffset: 8,
      jsonObject: JSON.stringify({ start: '2026-11-10T19:30:00', suggestStart: '2026-11-10T19:30:00', isContainFuzzyTime: false }) },
    addressEntity('西湖', 15)]);
  await f.CaptureService.save({}, '原始输入');
  assert.equal(f.calls[0].group.operations[0].data.scheduled, '<2026-11-10 19:30>');
  assert.match(f.calls[0].group.operations[0].data.body, /西湖/);
});

test('捕捉保留完整标题，将去重地址链接与首个有效时间随创建操作一次写入', async () => {
  const f = fixture();
  const title = '明天下午三点去杭州市西湖区文三路开会，然后到西湖';
  f.entities([timeEntity(30, { start: '2026-11-12T08:00:00' }),
    addressEntity('西湖', 29), addressEntity('杭州市西湖区文三路', 10),
    timeEntity(0, { start: '2026-11-10T15:00:00', suggestStart: '2026-11-10T15:00:00' }),
    addressEntity('西湖', 31)]);
  await f.CaptureService.save({}, title);
  assert.deepEqual(f.recognitionCalls, [{ title, options: { entityTypes: ['location', 'datetime'] } }]);
  assert.equal(f.calls.length, 1);
  const created = f.calls[0].group.operations[0].data;
  assert.equal(created.title, title);
  assert.equal(created.scheduled, '<2026-11-10 15:00>');
  assert.equal(created.body, ['杭州市西湖区文三路', '西湖'].map(address => `[[addr:${encodeURIComponent(address)}][${address}]]`).join('\n'));
  assert.equal(created.recordCreated, true);
  assert.equal(f.releases(), 1);
});

test('平台日期、精确时间与模糊时间按返回的本地年月日转换，不自行推理日期或重复器', async () => {
  for (const [time, scheduled] of [
    [{ start: '2026-11-10T08:30:45' }, '<2026-11-10 08:30>'],
    [{ start: '2026-11-10' }, '<2026-11-10>'],
    [{ start: '2026-11-10TM', isContainFuzzyTime: true }, '<2026-11-10>'],
    [{ start: '2026-11-10TA', suggestStart: '2026-11-10T15:00:00', isContainFuzzyTime: true }, '<2026-11-10>'],
    [{ start: '2026-12', suggestStart: '2026-12-01' }, '<2026-12-01>'],
    [{ start: '2028-02-29T00:00:00' }, '<2028-02-29 00:00>'],
    [{ start: 'T08:00:00', repeat: '每天' }, null],
    [{ start: '2026-02-30', isIllegal: true }, null],
    [{ start: '2026-02-28', isChangedIllegal: true }, null],
    [{ start: '2026-02-29' }, null],
    [{ start: '2026-13-01' }, null],
    [{ start: '2026-11-10T24:00:00' }, null],
    [{ start: '2026-11-10T08:60:00' }, null],
    [{ start: '2026-11-10T08:30:60' }, null],
    [{ start: '<2026-11-10>\n* TODO 额外标题' }, null]
  ]) {
    const f = fixture(); f.entities([timeEntity(0, time)]);
    await f.CaptureService.save({}, '保留原话');
    assert.equal(f.calls[0].group.operations[0].data.scheduled, scheduled, JSON.stringify(time));
  }
});

test('单个损坏或非法时间不影响地址与后续有效时间，地址中的换行与括号不会破坏链接', async () => {
  const f = fixture();
  f.entities([{ type: 'datetime', text: '损坏时间', charOffset: 0, jsonObject: '{' },
    timeEntity(1, { start: '2026-02-30' }),
    { type: 'datetime', text: '错误类型', charOffset: 2, jsonObject: '{"time":{}}' },
    timeEntity(3, { start: '2026-11-11T09:00:00' }), addressEntity(' 杭州[西湖]\n北门 ', 8)]);
  await f.CaptureService.save({}, '输入');
  const created = f.calls[0].group.operations[0].data;
  assert.equal(created.scheduled, '<2026-11-11 09:00>');
  assert.equal(created.body, `[[addr:${encodeURIComponent('杭州[西湖] 北门')}][杭州［西湖］ 北门]]`);
});

test('实体服务异常或超时仍保存标题，下一次捕捉可以重新识别；释放失败保留已识别字段', async () => {
  const f = fixture();
  for (const code of [200, 1011200002]) {
    f.failRecognition(Object.assign(new Error('平台异常'), { code }));
    await f.CaptureService.save({}, '明天到西湖');
    const created = f.calls.at(-1).group.operations[0].data;
    assert.equal(created.title, '明天到西湖');
    assert.equal(created.body, ''); assert.equal(created.scheduled, null);
  }
  f.failRecognition(undefined); f.failRelease(new Error('释放失败'));
  f.entities([addressEntity('西湖', 3), timeEntity(0, { start: '2026-11-10' })]);
  await f.CaptureService.save({}, '明天到西湖');
  assert.equal(f.calls.at(-1).group.operations[0].data.scheduled, '<2026-11-10>');
  assert.match(f.calls.at(-1).group.operations[0].data.body, /西湖/);
  assert.equal(f.releases(), 3);
});

test('设备不支持或输入超过平台长度限制时跳过实体识别，完整保留标题', async () => {
  for (const unsupported of [true, false]) {
    const f = fixture(); if (unsupported) f.unsupported();
    const title = unsupported ? '明天到西湖' : '长'.repeat(1001);
    await f.CaptureService.save({}, title);
    assert.equal(f.recognitionCalls.length, 0);
    assert.equal(f.releases(), 0);
    assert.equal(f.calls[0].group.operations[0].data.title, title);
  }
});

test('同进程并发捕捉串行调用实体识别并等待引擎释放，结果对应各自输入', async () => {
  let active = false; const events = [];
  const load = etsLoader({ '@kit.NaturalLanguageKit': {
    EntityType: { LOCATION: 'location', DATETIME: 'datetime' }, textProcessing: {
      async getEntity(title) {
        assert.equal(active, false); active = true; events.push('识别:' + title);
        await new Promise(resolve => setImmediate(resolve));
        return [addressEntity(title, 0)];
      },
      async release() {
        await new Promise(resolve => setImmediate(resolve));
        events.push('释放'); active = false;
      }
    }
  } });
  const { CaptureEntityService } = load('services/CaptureEntityService');
  const result = await Promise.all(['西湖', '故宫'].map(title => CaptureEntityService.recognize(title)));
  assert.deepEqual(events, ['识别:西湖', '释放', '识别:故宫', '释放']);
  assert.match(result[0].body, /西湖/); assert.match(result[1].body, /故宫/);
});

test('缺少标题、收件箱或明确目标时不调用写入', async () => {
  const f = fixture();
  await assert.rejects(f.CaptureService.save({}, ' '));
  f.config.inboxFile = '';
  await assert.rejects(f.CaptureService.save({}, '标题'));
  f.config.inboxFile = 'inbox.org';
  f.config.repos.push(repository('work'));
  await f.CaptureService.save({}, '标题');
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].group.operations[0].data.position.parent.repoId, 'core-personal');
});

test('多入口草稿并发更新保留不同标题，清理后不恢复已提交内容', async () => {
  const { CaptureService } = fixture();
  const writes = [];
  for (let index = 0; index < 20; index++) {
    writes.push(CaptureService.putDraft({}, { id: 'typing', title: '标题' + index }));
    writes.push(CaptureService.putDraft({}, { id: 'share-' + index, title: '分享' + index }));
  }
  writes.push(CaptureService.removeDraft({}, 'typing'));
  await Promise.all(writes);
  const drafts = await CaptureService.drafts({});
  assert.equal(drafts.length, 20);
  assert.equal(drafts.some(draft => draft.id === 'typing'), false);
  assert.equal(new Set(drafts.map(draft => draft.id)).size, 20);
});

test('草稿存储失败会显式拒绝，后续写入仍可恢复', async () => {
  const f = fixture();
  f.failRead();
  await assert.rejects(f.CaptureService.putDraft({}, { id: 'draft', title: '保留我' }));
  await f.CaptureService.putDraft({}, { id: 'draft', title: '恢复保存' });
  assert.deepEqual(await f.CaptureService.drafts({}), [{ id: 'draft', title: '恢复保存' }]);
});

test('旧路径配置不猜测仓库，明确绑定能持久化，删除仓库后保持失效身份', async () => {
  const values = new Map([
    ['repos', JSON.stringify([repository('personal')])],
    ['inboxFile', 'inbox.org'], ['memoFile', 'notes.org']
  ]);
  const load = etsLoader({
    'liborg_tasks_harmony.so': {
      Workspace: class { async setTodoDefaults() {} },
      async defaultTodoSettings() { return '#+TODO: TODO | DONE'; },
      async defaultSyncOptions() { return { excludedDirectories: [] }; },
      async normalizeSyncOptions(value) { return value; }
    },
    '@kit.ArkData': { preferences: { async getPreferences() {
      return { async get(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
        async put(key, value) { values.set(key, value); }, async flush() {} };
    } } },
    './CredentialService': { CredentialService: {
      async getWebDavPassword() { return ''; }, async setWebDavPassword() {}, async clearWebDavPassword() {}
    } },
    './NativeCoreService': { NativeCoreService: {} }
  });
  const { AppConfigService } = load('services/AppConfigService');
  const { fileTargetRepository } = load('services/FileTargetService');
  const old = await AppConfigService.load({}, false);
  assert.equal(old.inboxFile, 'inbox.org');
  assert.equal(old.inboxRepoId, '');
  assert.equal(fileTargetRepository(old, 'inbox'), undefined);
  old.inboxRepoId = 'personal';
  old.memoRepoId = 'personal';
  await AppConfigService.save({}, old);
  const restored = await AppConfigService.load({}, false);
  assert.equal(restored.inboxRepoId, 'personal');
  assert.equal(restored.memoFile, 'notes.org');
  await AppConfigService.removeRepository({}, 'personal');
  const removed = await AppConfigService.load({}, false);
  assert.equal(removed.inboxRepoId, 'personal');
  assert.equal(removed.inboxFile, 'inbox.org');
  removed.repos.push(repository('replacement'));
  assert.equal(fileTargetRepository(removed, 'inbox'), undefined);
});

test('两个窗口冷启动只创建一个共享 workspace，继续复用同一仓库对象', async () => {
  let created = 0;
  class Workspace {
    constructor() { created++; this.repositories = []; }
    async setTodoDefaults() { await new Promise(resolve => setImmediate(resolve)); }
    async addRepo(rootDirectory) { const repo = { rootDirectory }; this.repositories.push(repo); return repo; }
    async repos() { return this.repositories; }
  }
  const load = etsLoader({ 'liborg_tasks_harmony.so': { Workspace, async defaultTodoSettings() { return '#+TODO: TODO | DONE'; } } });
  const { NativeCoreService } = load('services/NativeCoreService');
  const repos = [repository('personal')];
  const sessions = await Promise.all(Array.from({ length: 8 }, () => NativeCoreService.workspaceFor(repos)));
  assert.equal(created, 1);
  assert.ok(sessions.every(session => session === sessions[0]));
  assert.equal((await sessions[0].repos()).length, 1);
});

test('仅捕捉本地标题时不读取安全存储，常规配置读取仍保留凭据', async () => {
  const repo = repository('personal');
  repo.webdavEnabled = true;
  let credentialReads = 0;
  const load = etsLoader({
    'liborg_tasks_harmony.so': { async defaultTodoSettings() { return '#+TODO: TODO | DONE'; }, async defaultSyncOptions() { return { excludedDirectories: [] }; } },
    '@kit.ArkData': { preferences: { async getPreferences() { return { async get(key, fallback) { return key === 'repos' ? JSON.stringify([repo]) : fallback; } }; } } },
    './CredentialService': { CredentialService: { async getWebDavPassword() { credentialReads++; return 'test-password'; } } }
  });
  const { AppConfigService } = load('services/AppConfigService');
  const captureConfig = await AppConfigService.load({}, false);
  assert.equal(credentialReads, 0);
  assert.equal(captureConfig.repos[0].webdavEnabled, true);
  assert.equal(captureConfig.repos[0].webdavPassword, '');
  const completeConfig = await AppConfigService.load({});
  assert.equal(credentialReads, 1);
  assert.equal(completeConfig.repos[0].webdavPassword, 'test-password');
});

function speechFixture(granted = true, offlineAvailable = true, onlineAvailable = true, startImmediately = true) {
  let listener;
  let read;
  let session;
  let engines = 0;
  let releases = 0;
  let shutdowns = 0;
  const frames = [];
  const engine = {
    setListener(value) { listener = value; },
    startListening(value) { session = value.sessionId; if (startImmediately) listener.onStart(session, ''); },
    writeAudio(id, bytes) { assert.equal(id, session); frames.push(bytes.slice()); },
    finish(id) { listener.onComplete(id, ''); },
    cancel() {},
    shutdown() { shutdowns++; }
  };
  const microphone = {
    on(name, callback) { read = callback; }, off() { read = undefined; },
    async start() {}, async stop() {}, async release() { releases++; }
  };
  const load = etsLoader({
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({
      async requestPermissionsFromUser() { return { authResults: [granted ? 0 : -1] }; }
    }) } },
    '@kit.CoreSpeechKit': { speechRecognizer: { async createEngine(params) {
      engines++;
      if (params.online === 1 && !offlineAvailable || params.online === 0 && !onlineAvailable) throw new Error('引擎不可用');
      return engine;
    } } },
    '@kit.AudioKit': { audio: {
      async createAudioCapturer() { return microphone; },
      AudioSamplingRate: { SAMPLE_RATE_16000: 16000 }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, SourceType: { SOURCE_TYPE_MIC: 0 }
    } },
    '@kit.ArkTS': { util: { generateRandomUUID: randomUUID } }
  });
  const { CaptureSpeechService } = load('services/CaptureSpeechService');
  return { service: new CaptureSpeechService(), frames, counters: () => ({ engines, releases, shutdowns }),
    feed(bytes) { read(bytes.buffer); }, result(value) { listener.onResult(session, value); }, begin() { listener.onStart(session, ''); } };
}

test('语音启动等待麦克风就绪，避免保存时抢先停止尚未启动的录音', async t => {
  const f = speechFixture(true, true, true, false);
  t.after(() => f.service.cancel());
  let started = false;
  const events = { started() {}, result() {}, completed() {}, failed(message) { assert.fail(message); } };
  const starting = f.service.start({}, events).then(() => { started = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(started, false);
  f.begin();
  await starting;
  assert.equal(started, true);
});

test('拒绝麦克风权限不会创建引擎或开始采集', async () => {
  const f = speechFixture(false);
  await assert.rejects(f.service.start({}, {}));
  assert.deepEqual(f.counters(), { engines: 0, releases: 0, shutdowns: 0 });
});

test('离线引擎不可用时回退在线引擎', async () => {
  const f = speechFixture(true, false);
  await f.service.start({}, { started() {}, result() {}, completed() {}, failed(message) { assert.fail(message); } });
  await f.service.cancel();
  assert.deepEqual(f.counters(), { engines: 2, releases: 1, shutdowns: 1 });
});

test('两种引擎均不可用时返回明确的文字回退提示', async () => {
  const f = speechFixture(true, false, false);
  await assert.rejects(f.service.start({}, {}), /语音服务暂时不可用，可以继续输入标题/);
  assert.deepEqual(f.counters(), { engines: 2, releases: 0, shutdowns: 0 });
});

test('语音按 640 字节分帧，完成时处理尾帧并释放引擎和麦克风', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = speechFixture();
  let completed = 0;
  const events = { started() {}, result() {}, completed() { completed++; }, failed(message) { assert.fail(message); } };
  await f.service.start({}, events);
  f.feed(new Uint8Array(1000).fill(1));
  f.feed(new Uint8Array(400).fill(2));
  assert.equal(f.frames.length, 2);
  assert.equal(await f.service.finish(events), true);
  await new Promise(resolve => setImmediate(resolve));
  t.mock.timers.tick(60001);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.frames.map(frame => frame.length), [640, 640, 640]);
  assert.equal(f.frames[2][119], 2);
  assert.equal(f.frames[2][120], 0);
  assert.equal(completed, 1);
  assert.deepEqual(f.counters(), { engines: 1, releases: 1, shutdowns: 1 });
});

test('保存等待识别最后一句完成，最终结果返回前不会提前结束', async () => {
  let listener;
  let session;
  const engine = {
    setListener(value) { listener = value; },
    startListening(value) { session = value.sessionId; listener.onStart(session, ''); },
    writeAudio() {}, finish() {}, cancel() {}, shutdown() {}
  };
  const load = etsLoader({
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({ async requestPermissionsFromUser() { return { authResults: [0] }; } }) } },
    '@kit.CoreSpeechKit': { speechRecognizer: { async createEngine() { return engine; } } },
    '@kit.AudioKit': { audio: {
      async createAudioCapturer() { return { on() {}, off() {}, async start() {}, async stop() {}, async release() {} }; },
      AudioSamplingRate: {}, AudioChannel: {}, AudioSampleFormat: {}, AudioEncodingType: {}, SourceType: {}
    } },
    '@kit.ArkTS': { util: { generateRandomUUID: randomUUID } }
  });
  const { CaptureSpeechService } = load('services/CaptureSpeechService');
  const service = new CaptureSpeechService();
  let finalTitle = '';
  const events = { started() {}, result(text) { finalTitle = text; }, completed() {}, failed(message) { assert.fail(message); } };
  await service.start({}, events);
  let finished = false;
  const finish = service.finish(events).then(result => { finished = true; return result; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(finished, false);
  listener.onResult(session, { result: '最后一句标题', isFinal: true, isLast: true });
  assert.equal(await finish, true);
  assert.equal(finalTitle, '最后一句标题');
});

test('取消识别会结束待保存的识别等待，返回未完成状态', async () => {
  const f = speechFixture();
  const events = { started() {}, result() {}, completed() {}, failed(message) { assert.fail(message); } };
  await f.service.start({}, events);
  await f.service.cancel();
  assert.equal(await f.service.finish(events), false);
});

test('保存会话构造不加载 Core，后台初始化期间可继续录入，保存等待初始化结束', async () => {
  const { CaptureSaveSession } = etsLoader()('services/CaptureSaveSession');
  let loads = 0;
  let resolvePreparation;
  let resolveLoader;
  const submitted = [];
  const preparation = new Promise(resolve => { resolvePreparation = resolve; });
  const loader = new Promise(resolve => { resolveLoader = resolve; });
  const session = new CaptureSaveSession({}, () => { loads++; return loader; });
  assert.equal(loads, 0);
  session.warmUp();
  resolveLoader({ async prepare() { await preparation; }, async save(context, title) { submitted.push(title); } });
  const save = session.save('不等待初始化即可输入的标题');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(loads, 1);
  assert.deepEqual(submitted, []);
  resolvePreparation();
  await save;
  assert.deepEqual(submitted, ['不等待初始化即可输入的标题']);
});

test('后台初始化失败到保存时才报告，随后可重试；空标题不加载 Core', async () => {
  const { CaptureSaveSession } = etsLoader()('services/CaptureSaveSession');
  let attempts = 0;
  const submitted = [];
  const session = new CaptureSaveSession({}, async () => ({
    async prepare() { if (++attempts === 1) throw new Error('仓库暂不可用'); },
    async save(context, title) { submitted.push(title); }
  }));
  await assert.rejects(session.save(' '), /请输入标题/);
  assert.equal(attempts, 0);
  session.warmUp();
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(session.save('保留标题'), /仓库暂不可用/);
  await session.save('保留标题');
  assert.deepEqual(submitted, ['保留标题']);
});

test('取消后忽略旧会话识别结果，避免覆盖已保留标题', async () => {
  const f = speechFixture();
  const results = [];
  const events = { started() {}, result(text) { results.push(text); }, completed() {}, failed(message) { assert.fail(message); } };
  await f.service.start({}, events);
  f.result({ result: '买牛奶', isFinal: false, isLast: false });
  await f.service.cancel();
  f.result({ result: '过期结果', isFinal: true, isLast: true });
  assert.deepEqual(results, ['买牛奶']);
  assert.deepEqual(f.counters(), { engines: 1, releases: 1, shutdowns: 1 });
});
