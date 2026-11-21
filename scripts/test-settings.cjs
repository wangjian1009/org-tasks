// 验证设置交互的提交边界与失败恢复，布局由 HAP 编译和设计预览验证。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-settings.cjs\n验证文件选择确认、目录浏览与创建、文件展示选择、仓库添加与同步方式切换，以及保存的失败恢复和既有配置保留。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(relative, name, mocks) {
  const filename = path.resolve('entry/src/main/ets', relative + '.ets');
  let source = fs.readFileSync(filename, 'utf8').split(/  @Builder|  build\(\)/)[0] + '}';
  source = source.replace(/^@(Entry|Component)\n/gm, '').replace(/^  @(State|Link|Prop) /gm, '  ')
    .replace('struct ' + name, 'export class ' + name);
  const output = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + output + '\n})', { filename })(name => {
    if (name.endsWith('/CalendarPermissionService') && !Object.hasOwn(mocks, name)) return {CalendarPermissionService:{state:async()=> 'disabled', request:async()=>true,manage:async()=>{}}};
    if (name.endsWith('/AppLinkService')) return {AppLinkService:{load:async()=>[],update:async()=>{},remove:async()=>{}}};
    if (name.endsWith('/SettingsAutoSave')) return {SettingsAutoSave:class{hasPending(){return false;}async flush(){}schedule(){}}};
    if (name.endsWith('/TaskReminderSettings')) return {TaskReminderSettings:{load:async()=>({enabled:false}),save:async()=>{}}};
    if (name.endsWith('/ReminderManager')) return {ReminderManager:{start(){},stop(){},refresh:async()=>{},configuration:async()=>({enabled:false,eventDurationMinutes:5}),permissionState:async()=> 'disabled',setEnabled:async()=>{},managePermission:async()=>{},summary:()=>'',subscribe:()=>()=>{}}};
    if (name.endsWith('/SystemRepository')) return {SYSTEM_REPOSITORY_ID:'org-tasks-system',TRASH_FILE:'trash.org',isSystemRepository:repo=>repo.id==='org-tasks-system'};
    if (name.endsWith('/TrashSettingsService')) return {TrashSettingsService:{retentionDays:async()=>30}};
    if (name.endsWith('/SystemRepositoryService')) return {SystemRepositoryService:{ensure:async()=>({id:'org-tasks-system',name:'系统仓库',rootDirectory:'/app/system-repository'})}};
    if (name.endsWith('/TrashService')) return {TrashService:{perform:async()=>{throw new Error('本用例不执行删除')}}};
    if (name.endsWith('/PageNavigator')) return require('./helpers/page-navigator.cjs').pageNavigatorMock;
    name = name.replace(/^\.\.\/\.\.\//, '../');
    assert.ok(Object.hasOwn(mocks, name), '缺少平台替身: ' + name);
    return mocks[name];
  }, module, module.exports);
  const value = new module.exports[name]();
  value.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/app/files' }), getRouter: () => ({ getParams: () => ({}) }) });
  return value;
}
const errors = { coreErrorMessage: e => e.message };
function pickerFixture() {
  const writes = [], groups = [{ configId: 'work', name: '工作库', files: [
    { path: 'inbox.org', title: '工作收集' }, { path: 'hidden.org', isIgnore: true }
  ] }, { configId: 'personal', name: '个人库', files: [{ path: 'inbox.org', title: '生活收集' }] }];
  let failure, gate, closed = 0;
  const sheet = load('components/editors/FileTargetSheet', 'FileTargetSheet', {
    '../services/AppConfigService': { AppConfigService: { async load() { return {}; } } },
    '../services/NotebookService': { NotebookService: { async list() { return groups; } } },
    '../services/NativeCoreService': errors,
    '../services/FileTargetService': {
      configuredFileTarget: () => ({ repoId: 'work', path: 'inbox.org' }),
      FileTargetService: { async select(context, kind, repoId, file) {
        writes.push({ kind, repoId, file });
        if (gate) await gate;
        if (failure) throw failure;
      } }
    }
  });
  sheet.busy = false; sheet.saved = () => { closed++; };
  return { sheet, writes, closed: () => closed, fail(e) { failure = e; }, hold(p) { gate = p; }, groups };
}
test('点选同名文件只更改临时选择，确认使用仓库与路径，关闭前不保存', async () => {
  const f = pickerFixture(); await f.sheet.load();
  assert.equal(f.sheet.isSelected('work', 'inbox.org'), true);
  assert.equal(f.sheet.groups[0].files.length, 1);
  f.sheet.select('personal', 'inbox.org');
  assert.equal(f.sheet.isSelected('personal', 'inbox.org'), true);
  assert.equal(f.writes.length, 0);
  await f.sheet.confirm();
  assert.deepEqual(f.writes, [{ kind: 'inbox', repoId: 'personal', file: 'inbox.org' }]);
  assert.equal(f.closed(), 1);
});
test('清除也需确认；保存失败保留选择，不关闭，可再次提交', async () => {
  const f = pickerFixture(); await f.sheet.load(); f.sheet.select('', '');
  assert.equal(f.writes.length, 0);
  f.fail(new Error('文件已失效'));
  await f.sheet.confirm(); assert.equal(f.closed(), 0);
  assert.equal(f.sheet.isSelected('', ''), true); assert.equal(f.sheet.busy, false);
  assert.match(f.sheet.message, /文件已失效/);
  f.fail(undefined); await f.sheet.confirm(); assert.equal(f.closed(), 1);
});
test('保存过程中不能切换选择或重复提交；重试读取时失效目标不回退到同名文件', async () => {
  const f = pickerFixture(); await f.sheet.load();
  let release; f.hold(new Promise(resolve => { release = resolve; }));
  const saving = f.sheet.confirm();
  f.sheet.select('personal', 'inbox.org'); await f.sheet.confirm();
  assert.equal(f.sheet.isSelected('work', 'inbox.org'), true); assert.equal(f.writes.length, 1);
  release(); await saving;
  f.groups[0].files = []; await f.sheet.load();
  assert.equal(f.sheet.selected, undefined); assert.match(f.sheet.message, /失效/);
});
function directoryFixture() {
  const dirs = new Set(['/app/files', '/app/files/Org', '/app/files/Org/工作']);
  const creates = []; let failure;
  const sheet = load('components/editors/LocalDirectorySheet', 'LocalDirectorySheet', {
    '@kit.CoreFileKit': { fileIo: {
      async listFile(dir) {
        if (!dirs.has(dir)) throw new Error('无法访问');
        return [...dirs].filter(x => x.startsWith(dir + '/') && !x.slice(dir.length + 1).includes('/')).map(x => x.slice(dir.length + 1)).concat('note.org');
      },
      async stat(dir) { return { isDirectory: () => dirs.has(dir) }; },
      async mkdir(dir) { creates.push(dir); if (failure) throw failure; dirs.add(dir); }
    } }, '../services/NativeCoreService': errors
  });
  sheet.busy = false;
  return { sheet, creates, fail(e) { failure = e; } };
}
test('目录浏览仅显示文件夹，失败保留上次可用目录和列表', async () => {
  const f = directoryFixture(); await f.sheet.browse('/app/files/Org');
  assert.deepEqual(f.sheet.folders, ['工作']);
  assert.equal(f.sheet.parent(), '/app/files');
  await f.sheet.browse('/inaccessible');
  assert.equal(f.sheet.directory, '/app/files/Org'); assert.deepEqual(f.sheet.folders, ['工作']);
  assert.match(f.sheet.message, /无法访问/);
});
test('新建拒绝路径越界与非法名称，失败保留草稿，成功进入新目录但不提交仓库', async () => {
  const f = directoryFixture(); let selected = 0; f.sheet.selected = () => { selected++; };
  await f.sheet.browse('/app/files/Org');
  for (const name of ['..', '.', 'a/b', 'a\\b', 'a\x00b', ' ']) {
    f.sheet.folderName = name; await f.sheet.createFolder();
  }
  assert.equal(f.creates.length, 0);
  f.sheet.folderName = '新目录'; f.fail(new Error('目录已存在')); await f.sheet.createFolder();
  assert.equal(f.sheet.folderName, '新目录'); assert.equal(f.sheet.busy, false);
  f.fail(undefined); await f.sheet.createFolder();
  assert.equal(f.sheet.directory, '/app/files/Org/新目录'); assert.equal(selected, 0);
});
function settingsFixture() {
  const config = { repos: [{ id: 'fresh-repo' }], todoDefaults: '#+TODO: OPEN | CLOSED',
    coreSettings: { additionStates: [] }, fileDisplayMode: 'rendered' };
  let saved, validationFailure, saveFailure;
  const settings = load('pages/Settings', 'Settings', {
    'liborg_tasks_harmony.so': { async validateConfiguration({coreSettings}) { if (validationFailure) throw validationFailure; return coreSettings; } },
    '../models/OrgTask': { DEFAULT_CONFIG: {} },
    '../services/AppConfigService': { AppConfigService: {
      async load() { return structuredClone(config); }, async save(context, value) { if (saveFailure) throw saveFailure; saved = value; }
    } },
    '../services/NotebookService': {},
    '../services/AppDataManager': {},
    '../services/AppLinkService': { AppLinkManager: { shared: {} } },
    '../services/NativeCoreService': { ...errors, NativeCoreService: { async workspaceFor() {} } },
    '../ui/Theme': {}, '../services/FileTargetService': {},
    '../ui/TaskStatePresentation': { TaskStateCategory: { Todo: 'Todo', Doing: 'Doing', Wait: 'Wait', Done: 'Done', Cancel: 'Cancel' } },
    '../services/NotificationPermissionService': {}
  });
  return { settings, config, saved: () => saved, fail(e) { validationFailure = e; }, failSave(e) { saveFailure = e; } };
}
test('状态分类和展示方式保存保留已有 TODO 流程与新仓库，非法输入不保存且保留草稿', async () => {
  const f = settingsFixture(); f.settings.categoryDraft = 'HOLD';
  await f.settings.changeCategory(2);
  assert.equal(f.saved().todoDefaults, f.config.todoDefaults);
  assert.deepEqual(f.saved().repos, f.config.repos);
  assert.deepEqual(f.saved().coreSettings.additionStates, [{ name: 'HOLD', category: 'Wait' }]);
  f.fail(new Error('重复状态')); f.settings.categoryDraft = 'TODO';
  await f.settings.changeCategory(0);
  assert.equal(f.settings.categoryDraft, 'TODO'); assert.match(f.settings.message, /重复状态/);
  await f.settings.changeDisplayMode('source');
  assert.equal(f.saved().todoDefaults, f.config.todoDefaults); assert.equal(f.saved().fileDisplayMode, 'source');
});

test('展示方式菜单标记已保存值，重复选择不写入，失败保持原选项并可重试', async () => {
  const f = settingsFixture();
  assert.deepEqual(f.settings.displayModeChoices().map(item=>[item.title,item.checked]), [['渲染',true],['原文',false]]);
  await f.settings.changeDisplayMode('rendered'); assert.equal(f.saved(), undefined);
  f.failSave(new Error('写入失败')); await f.settings.changeDisplayMode('source');
  assert.equal(f.settings.fileDisplayMode, 'rendered'); assert.equal(f.settings.saving, false);
  assert.match(f.settings.message, /写入失败/);
  f.failSave(undefined); await f.settings.changeDisplayMode('source');
  assert.deepEqual(f.settings.displayModeChoices().map(item=>item.checked), [false,true]);
});

function repositoryFixture(existing = true) {
  const original = { id: 'repo-1', name: '旧名称', rootDirectory: '/org/work', webdavEnabled: true,
    webdavUrl: 'https://dav.example.com/org/', webdavUsername: 'user', webdavPassword: 'secret',
    excludedDirectories: ['private'] };
  const config = { repos: existing ? [original] : [], inboxRepoId: 'repo-1', inboxFile: 'inbox.org',
    somedayRepoId: '', somedayFile: '', memoRepoId: 'repo-1', memoFile: 'memo.org',
    todoDefaults: '#+TODO: OPEN | CLOSED', coreSettings: { additionStates: [] }, fileDisplayMode: 'source' };
  const writes = [], directories = [], validations = [], connections = [], lifecycle = [];
  let backed = 0, failure, gate, syncFailure, dialog;
  const page = load('pages/RepositorySettings', 'RepositorySettings', {
    '../services/AppConfigService': { AppConfigService: {
      async load() { return structuredClone(writes.at(-1) ?? config); },
      newRepository() { return { ...original, id: 'repo-new', name: '', rootDirectory: '', webdavEnabled: false,
        webdavUrl: '', webdavUsername: '', webdavPassword: '', excludedDirectories: [] }; },
      async save(context, value) { writes.push(value); }
    } },
    '../services/PageQueryService': { PageQueryService: {} },
    '../services/RepositorySyncService': { SyncStartPolicy: { Wait: 'Wait' }, RepositorySyncService: {
      start(context, options) {
        return { kind: 'started', handle: { completion: (async () => {
          await options.beforeSync(structuredClone(writes.at(-1) ?? config));
          lifecycle.push([options.source, options.repositoryId]);
          return syncFailure ? { status: 'failed', message: syncFailure } : { status: 'succeeded' };
        })() } };
      }
    } },
    '../services/RepositorySetupService': { RepositorySetupService: {
      async initialize(context, current, repo) {
        assert.ok(current.repos.some(item => item.id === repo.id));
        return [{ path: 'someday.org', title: '某天' }];
      },
      async listEntries() { return []; },
      bindEntries(current, repo, files) {
        if (!current.somedayRepoId && files.length) {
          current.somedayRepoId = repo.id;
          current.somedayFile = files[0].path;
          return true;
        }
        return false;
      }
    } },
    '@kit.CoreFileKit': { fileIo: { async access() { return false; }, async mkdir(path) { directories.push(path); } } },
    'liborg_tasks_harmony.so': { async defaultSyncOptions() { return { excludedDirectories: ['archive'] }; } },
    '../models/OrgTask': { DEFAULT_CONFIG: {} },
    '../services/NativeCoreService': { ...errors,
      NativeCoreService: { async validateRepository(path) { validations.push(path); },
        async repository() { return { async reset() { lifecycle.push('reset'); } }; } },
      CoreWebDavSyncPolicy: class {
        constructor(...args) { connections.push(args); }
        async testConnection() { if (gate) await gate; if (failure) throw failure; }
      }
    },
    '../ui/Theme': { UiColor: {}, repositoryLabel: repo => repo.name }
  });
  page.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/app/files' }),
    getRouter: () => ({ getParams: () => existing ? { repoId: 'repo-1' } : {}, back() { backed++; } }),
    showAlertDialog(value) { dialog = value; }, getPromptAction: () => ({ showToast() {} }) });
  return { page, config, writes, directories, validations, connections, lifecycle, backed: () => backed,
    failSync(message) { syncFailure = message; }, dialog: () => dialog,
    fail(e) { failure = e; }, hold(p) { gate = p; } };
}
test('已有仓库名称修改返回保存，保留身份、排除规则、入口和其他页面刚更新的设置', async () => {
  const f = repositoryFixture(); await f.page.load();
  assert.equal(f.page.loading, false); assert.equal(f.page.name, '旧名称');
  f.page.name = ' 新名称 ';
  f.config.memoFile = 'new-memo.org';
  f.page.onBackPress();
  // 返回事件启动异步保存，等待其完成。
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.backed(), 1); assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].repos[0].id, 'repo-1'); assert.equal(f.writes[0].repos[0].name, '新名称');
  assert.deepEqual(f.writes[0].repos[0].excludedDirectories, ['private']);
  assert.equal(f.writes[0].memoFile, 'new-memo.org'); assert.equal(f.writes[0].inboxRepoId, 'repo-1');
});
test('新建默认不同步，返回不创建；选择 WebDAV 并明确添加后创建管理目录和默认排除规则', async () => {
  const untouched = repositoryFixture(false); await untouched.page.load();
  assert.equal(untouched.page.webdavEnabled, false);
  untouched.page.name = '未提交草稿'; untouched.page.onBackPress();
  assert.equal(untouched.writes.length, 0); assert.equal(untouched.directories.length, 0); assert.equal(untouched.backed(), 1);
  const f = repositoryFixture(false); await f.page.load();
  f.page.changeSyncMethod(true); f.page.name = '新仓库';
  f.page.webdavUrl = 'https://dav.example.com/org/'; f.page.webdavUsername = 'user'; f.page.webdavPassword = 'secret';
  assert.equal(f.writes.length, 0);
  await f.page.save();
  assert.deepEqual(f.directories, ['/app/files/repositories/repo-new']);
  assert.deepEqual(f.validations, f.directories); assert.equal(f.backed(), 1);
  assert.equal(f.writes[0].repos[0].name, '新仓库'); assert.equal(f.writes[0].repos[0].webdavEnabled, true);
  assert.deepEqual(f.writes[0].repos[0].excludedDirectories, ['archive']);
  assert.deepEqual(f.lifecycle, [['repositoryCreated', 'repo-new']]);
});

test('WebDAV 重置先清空，再同步，失败后的重试沿用原因且不再清空', async () => {
  const f = repositoryFixture();
  await f.page.load();
  f.failSync('网络不可用');
  await f.page.resetRepository('/org/work');
  assert.match(f.page.message, /本地目录已重置/);
  assert.equal(f.page.syncRetry, 'repositoryReset');
  f.failSync(undefined);
  await f.page.retrySync();
  assert.deepEqual(f.lifecycle, ['reset', ['repositoryReset', 'repo-1'], ['repositoryReset', 'repo-1']]);
  assert.equal(f.page.syncRetry, '');
});

test('切换为本地仓库须确认，取消保留连接，确认后清除远端配置', async () => {
  const f = repositoryFixture(); await f.page.load();
  f.page.testMessage = '连接成功'; f.page.testSucceeded = true;
  f.page.changeSyncMethod(false);
  assert.equal(f.page.testMessage, ''); assert.equal(f.page.testSucceeded, false);
  await f.page.testConnection(); assert.equal(f.connections.length, 0);
  assert.deepEqual(f.page.syncMethodChoices().map(item=>[item.title,item.checked]), [['不同步',true],['WebDAV',false]]);
  f.page.changeSyncMethod(true);
  assert.deepEqual(f.page.draft(), { ...f.config.repos[0], webdavCleanupPending: undefined });
  f.page.changeSyncMethod(false); f.page.webdavUrl = '';
  await f.page.save();
  assert.match(f.dialog().message, /同路径文件将采用远端版本/);
  assert.equal(f.writes.length, 0);
  f.dialog().primaryButton.action();
  assert.equal(f.page.webdavEnabled, true);
  f.page.changeSyncMethod(false);
  await f.page.save();
  f.dialog().secondaryButton.action();
  await new Promise(resolve => setImmediate(resolve));
  const saved = f.writes[0].repos[0];
  assert.equal(saved.webdavEnabled, false); assert.equal(saved.id, 'repo-1');
  assert.equal(saved.rootDirectory, '/org/work'); assert.equal(saved.webdavPassword, '');
  assert.equal(saved.webdavUsername, '');
  assert.equal(saved.webdavCleanupPending, true);
  assert.deepEqual(saved.excludedDirectories, []);
});

test('新建本地仓库由添加提交；切换同步不覆盖用户所选目录', async () => {
  const f = repositoryFixture(false); await f.page.load();
  f.page.rootDirectory = '/org/local'; f.page.changeSyncMethod(true); f.page.changeSyncMethod(false);
  assert.equal(f.page.rootDirectory, '/org/local');
  await f.page.save();
  assert.equal(f.writes[0].repos[0].webdavEnabled, false);
  assert.equal(f.writes[0].somedayRepoId, 'repo-new');
  assert.equal(f.writes[0].somedayFile, 'someday.org');
  assert.equal(f.writes[0].inboxRepoId, 'repo-1');
  assert.deepEqual(f.validations, ['/org/local']); assert.deepEqual(f.directories, []);
});
test('连接测试只使用草稿，不保存或同步；执行中阻止重复和返回，失败恢复后可再次测试', async () => {
  const f = repositoryFixture(); await f.page.load();
  f.page.webdavUrl = 'https://dav.example.com/draft/';
  let release; f.hold(new Promise(resolve => { release = resolve; }));
  f.fail(new Error('认证失败'));
  const testing = f.page.testConnection();
  f.page.changeSyncMethod(false); assert.equal(f.page.webdavEnabled, true);
  await f.page.testConnection(); f.page.onBackPress();
  assert.equal(f.connections.length, 1); assert.equal(f.backed(), 0); assert.equal(f.writes.length, 0);
  release(); await testing;
  assert.equal(f.page.testing, false); assert.match(f.page.testMessage, /认证失败/);
  assert.equal(f.page.webdavUrl, 'https://dav.example.com/draft/');
  f.fail(undefined); f.hold(undefined); await f.page.testConnection();
  assert.equal(f.page.testSucceeded, true); assert.equal(f.writes.length, 0);
  assert.equal(f.validations.length, 0); assert.equal(f.directories.length, 0);
});
