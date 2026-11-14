// 验证设置交互的提交边界与失败恢复，布局由 HAP 编译和设计预览验证。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-settings.cjs\n验证文件选择确认、目录浏览与创建、设置保存的失败恢复和既有配置保留。');
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
  let saved, validationFailure;
  const settings = load('pages/Settings', 'Settings', {
    'liborg_tasks_harmony.so': { Workspace: class {
      async setSettings(value) { if (validationFailure) throw validationFailure; this.value = value; }
      async getSettings() { return this.value; }
    } },
    '../models/OrgTask': { DEFAULT_CONFIG: {} },
    '../services/AppConfigService': { AppConfigService: {
      async load() { return structuredClone(config); }, async save(context, value) { saved = value; }
    } },
    '../services/NotebookService': {},
    '../services/NativeCoreService': { ...errors, NativeCoreService: { async workspaceFor() {} } },
    '../ui/Theme': {}, '../services/FileTargetService': {},
    '../ui/TaskStatePresentation': { TaskStateCategory: { Todo: 'Todo', Doing: 'Doing', Wait: 'Wait', Done: 'Done', Cancel: 'Cancel' } },
    '../services/NotificationPermissionService': {}
  });
  return { settings, config, saved: () => saved, fail(e) { validationFailure = e; } };
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
