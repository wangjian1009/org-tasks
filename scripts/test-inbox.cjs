// 验证收件箱的目标分组和宿主调用编排；写入语义由 Rust 集成测试覆盖。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-inbox.cjs\n验证移动目标与最近新增的 CATEGORY／项目平级分组、目标身份、移动、将来，也许、备忘与删除请求。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks) {
  const filename = path.resolve('entry/src/main/ets', file + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,$r){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (name.startsWith('.')) return load(path.relative(path.resolve('entry/src/main/ets'), path.resolve(path.dirname(filename), name)), mocks);
    throw new Error('缺少替身: ' + name);
  }, module, module.exports, name => ({ name }));
  return module.exports;
}

function snapshotFixture() {
  const source = fs.readFileSync('entry/src/main/ets/pages/Inbox.ets', 'utf8');
  const methods = ['applyPageSnapshot', 'prepareRecentLayout'].map(name =>
    source.match(new RegExp('  ' + name + '\\(\\): void \\{[\\s\\S]*?\\n  \\}'))[0]).join('\n');
  const code = ts.transpileModule('export class InboxSnapshot {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, frames = [];
  let editing = false;
  vm.runInThisContext('(function(module,exports,TaskInlineSession,recentDays,InboxLayoutFrame){' + code + '})')(
    module, module.exports, { active: () => editing }, load('ui/InboxPresentation', {}).recentDays,
    class { constructor(callback) { this.callback = callback; } });
  const dataSet = () => ({ data: undefined, error: '', ready: false, isReady() { return this.ready; } });
  const state = Object.assign(new module.exports.InboxSnapshot(), {
    tasksDataSet: dataSet(), targetDataSet: dataSet(), recentDataSet: dataSet(),
    records: [], recentGroups: [], loading: true, recentLayoutReady: false, recentLayoutPending: false,
    listHeight: 0, visible: true, selection: {selecting:false,busy:false},
    measureRows() {}, getUIContext: () => ({ postFrameCallback: frame => frames.push(frame) })
  });
  const task = id => ({ id, createdAt: Date.now(), project: () => null });
  const tasks = values => ({ type: 'task', result: { tasks: values, categories: [] } });
  const target = { type: 'file', result: [{ path: 'inbox.org' }] };
  return { state, frames, task, tasks, target, editing: value => { editing = value; } };
}

test('收件箱首屏等待同批全部快照，不因最近新增先返回而显示临时空态', () => {
  for (const order of [['tasksDataSet', 'targetDataSet', 'recentDataSet'], ['recentDataSet', 'tasksDataSet', 'targetDataSet']]) {
    const f = snapshotFixture(), main = f.task('main'), recent = f.task('recent');
    for (let index = 0; index < order.length; index++) {
      const name = order[index];
      f.state[name].data = name === 'targetDataSet' ? f.target : f.tasks([name === 'tasksDataSet' ? main : recent]);
      f.state.applyPageSnapshot();
      assert.equal(f.state.loading, index < 2);
      if (index < 2) { assert.deepEqual(f.state.records, []); assert.deepEqual(f.state.recentGroups, []); }
    }
    assert.deepEqual(f.state.records, [main]);
    assert.deepEqual(f.state.recentGroups[0].tasks, [recent]);
    assert.equal(f.state.recentLayoutReady, false);
    f.state.listHeight = 600; f.state.prepareRecentLayout(); f.state.prepareRecentLayout();
    assert.equal(f.frames.length, 1);
    f.frames.shift().callback();
    assert.equal(f.state.recentLayoutReady, true);
    assert.equal(f.state.pageReady, false);
    f.state.tasksDataSet.ready = true; f.state.applyPageSnapshot();
    assert.equal(f.state.pageReady, true);
    assert.equal(f.frames.length, 0);
  }
});

test('收件箱缓存先统一显示且只读，首次测量后才显示近期整段，空结果不产生分组', () => {
  const f = snapshotFixture();
  f.state.tasksDataSet.data = f.tasks([f.task('cached')]);
  f.state.targetDataSet.data = f.target;
  f.state.recentDataSet.data = f.tasks([]);
  f.state.applyPageSnapshot();
  assert.equal(f.state.loading, false);
  assert.equal(f.state.pageReady, false);
  assert.deepEqual(f.state.recentGroups, []);
  assert.equal(f.frames.length, 0);
  f.state.listHeight = 600; f.state.prepareRecentLayout();
  f.state.visible = false; f.frames.shift().callback();
  assert.equal(f.state.recentLayoutReady, false);
});

test('近期读取失败结束首屏等待，已有内容在编辑会话结束后统一应用', () => {
  const f = snapshotFixture();
  f.state.tasksDataSet.data = f.tasks([f.task('main')]); f.state.targetDataSet.data = f.target;
  f.state.recentDataSet.error = '读取失败'; f.state.applyPageSnapshot();
  assert.equal(f.state.loading, false); assert.equal(f.state.recentMessage, '读取失败');
  f.editing(true); f.state.recentDataSet.error = ''; f.state.recentDataSet.data = f.tasks([f.task('new')]);
  f.state.applyPageSnapshot(); assert.deepEqual(f.state.recentGroups, []);
  f.editing(false); f.state.applyPageSnapshot();
  assert.equal(f.state.recentMessage, ''); assert.equal(f.state.recentGroups[0].tasks[0].id, 'new');
});

const target = (id, category) => ({ repoId: id, path: 'projects.org', fullPath: { repoId: id, file: 'projects.org', titles: ['Parent', 'Same'], occurrence: 1 }, headingPath: ['Parent', 'Same'],
  position: { line: 1, column: 0, byte_offset: 0 }, category, projectName: null, fileVersion: 'target-version' });
test('按文件 CATEGORY 合并分组，同名目标保持独立，未分类置后', () => {
  const { refileSections } = load('ui/MoveToTargetPresentation', {});
  const targets = [target('a', null), target('b', 'Work'), target('c', 'Work'), target('d', '')];
  const sections = refileSections(targets);
  assert.deepEqual(sections.map(s => s.name), ['Work', '']);
  assert.deepEqual(sections[0].targets, [targets[1], targets[2]]);
  assert.deepEqual(sections[1].targets, [targets[0], targets[3]]);
  assert.equal(targets.length, 4);
});
test('项目名与 CATEGORY 平级，不重复归类，同名项目与分类保留独立分组', () => {
  const { refileSections } = load('ui/MoveToTargetPresentation', {});
  const values = [target('plain', 'Work'),
    { ...target('project-a', 'Work'), projectName: 'Website' },
    { ...target('project-b', 'Home'), projectName: 'Website' },
    { ...target('same-name', 'Home'), projectName: 'Work' },
    { ...target('unnamed', null), projectName: '' }, target('uncategorized', null)];
  const sections = refileSections(values);
  assert.deepEqual(sections.map(s => [s.kind, s.name, s.targets.map(t => t.repoId)]), [
    ['project', 'Website', ['project-a']], ['project', 'Website', ['project-b']], ['category', 'Work', ['plain']],
    ['project', 'Work', ['same-name']], ['project', '未命名项目', ['unnamed']],
    ['category', '', ['uncategorized']]
  ]);
  assert.equal(new Set(sections.map(s => s.key)).size, sections.length);
  assert.deepEqual(sections.flatMap(s => s.targets).sort((a, b) => a.repoId.localeCompare(b.repoId)),
    [...values].sort((a, b) => a.repoId.localeCompare(b.repoId)));
});
function fixture() {
  const requests = [];
  let ignored = false;
  const settings = { id: 'host-id', rootDirectory: '/repo', webdavEnabled: true };
  const repo = { id: 'core-id', rootDirectory: '/repo', async load() {}, async file() { return { fileVersion: 'memo-version', fullPath: { repoId: 'core-id', file: 'memo.org', titles: [] } }; } };
  const task = { id: 'Item', repoId: 'core-id', filePath: 'inbox.org', fileVersion: 'source-version', fullPath: { repoId: 'core-id', file: 'inbox.org', titles: ['Item'], occurrence: 1 } };
  const workspace = { async query(batch) {return batch.map(()=>({type:'file',result:ignored?[]:[{path:'memo.org',isIgnore:false,fileVersion:'memo-version'}]}));}, async refileTargets() { return [target('core-id', 'Work')]; },
    async repos() { return [repo,{id:'system-core',rootDirectory:'/system'}]; }, async executeTaskOperations(group) { requests.push(group); } };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [settings,{id:'org-tasks-system',rootDirectory:'/system'}], memoRepoId: 'host-id', memoFile: 'memo.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.memoRepoId, path: config.memoFile }) },
    './NativeCoreService': { taskResult:value=>value.result, fileResult:value=>value.result, NativeCoreService: { async workspaceFor() { return workspace; } } }
  });
  return { InboxService, requests, task, workspace, setIgnored() { ignored = true; } };
}

function captureFixture() {
  const filename = 'entry/src/main/ets/pages/Inbox.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const method = source.match(/  async capture\(\) \{[\s\S]*?\n  \}\n/)[0];
  const visibility = source.slice(source.indexOf("}.id('inbox_capture')")).match(/\.visibility\(([\s\S]*?)\)\s*\.enabled/)[1];
  const code = ts.transpileModule('export class InboxCapture {' + method + '\nbuttonVisibility() { return ' + visibility + '; }\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, messages = [], calls = [];
  let finish = async () => true, keyboardMode = 'offset';
  vm.runInThisContext('(function(module,exports,TaskInlineSession,KeyboardAvoidMode,Visibility,coreErrorMessage){' + code + '\n})', { filename })(
    module, module.exports, { end: async collapse => { calls.push(collapse); return await finish(); } },
    { RESIZE: 'resize' }, { Hidden: 'hidden', Visible: 'visible' }, error => error.message);
  const state = Object.assign(new module.exports.InboxCapture(), {
    visible: true, pageReady: true, needsConfiguration: false, captureOpen: false, drawerOpen: false, actionBusy: false, selected: undefined,
    selection: {selecting:false,starting:false}, inlineActive: '', inlineTyping: false,
    captureTitle: '保留的捕捉草稿',
    getUIContext: () => ({ getKeyboardAvoidMode: () => keyboardMode, setKeyboardAvoidMode: mode => { keyboardMode = mode; },
      getPromptAction: () => ({ showToast: ({ message }) => messages.push(message) }) })
  });
  return { state, calls, messages, saveWith: callback => { finish = callback; } };
}

test('收件箱结束文字输入后恢复新增按钮，卡片仍展开也可保存后进入捕捉', async () => {
  const f = captureFixture();
  assert.equal(f.state.buttonVisibility(), 'visible');
  f.state.inlineActive = 'expanded-task'; f.state.inlineTyping = true;
  assert.equal(f.state.buttonVisibility(), 'hidden');
  f.state.inlineTyping = false;
  assert.equal(f.state.buttonVisibility(), 'visible');
  let saved;
  f.saveWith(() => new Promise(resolve => { saved = resolve; }));
  const pending = f.state.capture();
  assert.equal(f.state.captureOpen, false); assert.equal(f.state.actionBusy, true);
  await f.state.capture(); assert.deepEqual(f.calls, [true]);
  f.state.inlineActive = ''; saved(true); await pending;
  assert.equal(f.state.captureOpen, true); assert.equal(f.state.actionBusy, false);
  assert.equal(f.state.captureTitle, '保留的捕捉草稿');
  assert.equal(f.state.buttonVisibility(), 'hidden');
  f.state.captureOpen = false;
  assert.equal(f.state.buttonVisibility(), 'visible');
});

test('原位编辑保存失败或页面离开时不打开捕捉，异常可反馈并重试', async () => {
  const f = captureFixture();
  f.saveWith(async () => false);
  await f.state.capture(); assert.equal(f.state.captureOpen, false); assert.equal(f.state.actionBusy, false);
  f.saveWith(async () => { throw new Error('保存失败'); });
  await f.state.capture(); assert.deepEqual(f.messages, ['保存失败']); assert.equal(f.state.actionBusy, false);
  f.saveWith(async () => { f.state.visible = false; return true; });
  await f.state.capture(); assert.equal(f.state.captureOpen, false);
  f.state.visible = true; f.saveWith(async () => true);
  await f.state.capture(); assert.equal(f.state.captureOpen, true);
});

test('抽屉、移动浮层与多选期间继续隐藏新增按钮，关闭后恢复', () => {
  const f = captureFixture();
  for (const [key, value] of [['pageReady', false], ['needsConfiguration', true], ['drawerOpen', true], ['selection', {selecting:true}], ['selection', {starting:true}]]) {
    const previous = f.state[key]; f.state[key] = value;
    assert.equal(f.state.buttonVisibility(), 'hidden');
    f.state[key] = previous;
    assert.equal(f.state.buttonVisibility(), 'visible');
  }
});

test('直接移动使用原目标位置和双端版本，上传身份来自 Core 仓库', async () => {
  const f = fixture(); const t = target('core-id', 'Work');
  await f.InboxService.perform({}, f.task, 'move', t);
  assert.deepEqual(f.requests[0], { operations: [{ type: 'Movement', data: { path: f.task.fullPath,
    position: { parent: t.fullPath } } }], fileVersions: [
      { repoId: 'core-id', file: 'inbox.org', version: 'source-version' },
      { repoId: 'core-id', file: 'projects.org', version: 'target-version' }
    ] });
});
test('备忘使用配置文件顶部并清除根 TODO；失效目标不提交', async () => {
  const f = fixture();
  await f.InboxService.perform({}, f.task, 'memo');
  assert.deepEqual(f.requests[0].operations, [
    { type: 'Modification', data: { path: f.task.fullPath, modifications: [
      { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
      { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }
    ] } },
    { type: 'Movement', data: { path: f.task.fullPath, position: { parent: { repoId: 'core-id', file: 'memo.org', titles: [] } } } }
  ]);
  f.setIgnored();
  await assert.rejects(f.InboxService.perform({}, f.task, 'memo'), /重新选择/);
  assert.equal(f.requests.length, 1);
});
test('删除只提交源快照，不伪造目标；无目标移动不提交', async () => {
  const f = fixture();
  await f.InboxService.perform({}, f.task, 'delete');
  assert.deepEqual(f.requests[0].operations, [{ type: 'Trash', data: { path: f.task.fullPath, target: {repoId:'system-core',path:'trash.org'} } }]);
  assert.deepEqual(f.requests[0].fileVersions, [{ repoId: 'core-id', file: 'inbox.org', version: 'source-version' }]);
  await assert.rejects(f.InboxService.perform({}, f.task, 'move'), /请选择任务目标/);
  assert.equal(f.requests.length, 1);
});

test('近期日期分组只组织返回快照，保留完成与 CNCL、跨年日期和当天顺序', () => {
  const { recentDays, unplannedSpacer } = load('ui/InboxPresentation', {});
  const tasks = [
    { id: 'done', todoKind: 'done', project: () => null, createdAt: new Date(2026, 0, 1, 12).getTime() },
    { id: 'cancelled', isCancelled: true, project: () => null, createdAt: new Date(2026, 0, 1, 11).getTime() },
    { id: 'memo', todoKind: null, project: () => null, createdAt: new Date(2025, 11, 31, 20).getTime() }
  ];
  const groups = recentDays(tasks, new Date(2026, 0, 2));
  assert.deepEqual(groups.map(g => g.date), ['1月1日', '2025年12月31日']);
  assert.equal(groups[0].weekday, '周四');
  assert.deepEqual(groups.flatMap(g => g.tasks), tasks);
  assert.equal(unplannedSpacer(800, 100), 500);
  assert.equal(unplannedSpacer(800, 900), 48);
  assert.equal(unplannedSpacer(400, 80), 220);
});

test('最近新增按日将分类与项目平级归组，保留普通任务、完成记录与独立项目身份', () => {
  const { recentDays } = load('ui/InboxPresentation', {});
  const record = (id, category, project, day = 12, values = {}) => ({ id, category, project: () => project, repoId: 'repo', filePath: project === null ? 'plain.org' : `${category || 'unnamed'}-${project}.org`,
    createdAt: new Date(2026, 10, day, 12).getTime(), ...values });
  const tasks = [record('plain', '工作', null), record('first', '工作', '项目甲'),
    record('memo', '工作', null, 12, { todoKind: null }), record('second', '工作', '项目甲', 12, { todoKind: 'done' }),
    record('other-category', '生活', '项目甲'), record('unnamed', null, ''),
    record('unnamed-again', '', ''), record('yesterday', '工作', '项目甲', 11)];
  const days = recentDays(tasks, new Date(2026, 10, 12));
  assert.deepEqual(days[0].groups.map(group => [group.kind, group.title, group.items.map(task => task.id)]),
    [['category', '工作', ['plain', 'memo']], ['project', '项目甲', ['first', 'second']], ['project', '项目甲', ['other-category']], ['project', '未命名项目', ['unnamed', 'unnamed-again']]]);
  assert.deepEqual(days[1].groups.map(group => group.items), [[tasks[7]]]);
  const displayed = days.flatMap(day => day.groups.flatMap(group => group.items));
  assert.equal(displayed.length, tasks.length);
  for (const task of tasks) assert.equal(displayed.filter(item => item === task).length, 1);
  assert.deepEqual(recentDays([], new Date(2026, 10, 12)), []);
});

test('收件箱与近期记录在同一批次，最近三天表达式及精确排除保持原样', async () => {
  const queries = [];
  const task = {id:'recent',createdAt:1};
  const config={repos:[{id:'host-id',rootDirectory:'/repo'}],inboxRepoId:'host-id',inboxFile:'inbox.org'};
  const prepared={reference:{repoId:'core-id',path:'inbox.org'},task:{type:'task',query:{}},file:{type:'file',query:{}}};
  const {InboxService}=load('services/InboxService',{
    './AppConfigService':{AppConfigService:{}},
    './FileTargetService':{configuredFileTarget:c=>({repoId:c.inboxRepoId,path:c.inboxFile}),FileTargetService:{prepare:()=>prepared,result:()=>({tasks:[],categories:[]})}},
    './NativeCoreService':{taskResult:value=>value.result,NativeCoreService:{async workspaceFor(){return {async repos(){return [{id:'core-id',rootDirectory:'/repo'}];}};}}},
    './PageQueryService':{PageQueryService:{async query(_,batch){queries.push(batch);return [{type:'task',result:{tasks:[]}},{type:'file',result:[]},{type:'task',result:{tasks:[task]}}];}}}
  });
  assert.deepEqual((await InboxService.load(config)).recent,[task]);
  assert.equal(queries.length,1);
  assert.deepEqual(queries[0][2].query,{expression:'cr.ge.-2d cr.le.today .o.created',excludeFiles:[{repoId:'core-id',path:'inbox.org'}]});
});

test('通用目标查询仅排除配置的具体文件，不为某天快捷入口额外读取元信息', async () => {
  const queries = [];
  const normal = [target('core-a', 'Work'), { ...target('core-b', 'Home'), projectName: 'Website' }];
  const repos = [{ id: 'core-a', rootDirectory: '/a', async load() {} },
    { id: 'core-b', rootDirectory: '/b', async load() {} }];
  const { MoveToTargetService } = load('services/MoveToTargetService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [
      { id: 'host-a', rootDirectory: '/a' }, { id: 'host-b', rootDirectory: '/b' }],
      inboxRepoId: 'host-a', inboxFile: 'inbox.org', somedayRepoId: 'host-a', somedayFile: 'someday.org' }; } } },
    './FileTargetService': { configuredFileTarget: (config, kind) => ({ repoId: config[kind + 'RepoId'], path: config[kind + 'File'] }) },
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return {
      async repos() { return repos; },
      async query() { throw new Error('普通移动不应查询某天文件元信息'); },
      async refileTargets(query) { queries.push(query); return normal; }
    }; } } }
  });
  assert.equal(await MoveToTargetService.targets({}), normal);
  assert.deepEqual(queries, [{ includeProjectRoots: true, excludedFiles: [
    { repoId: 'core-a', path: 'inbox.org' }, { repoId: 'core-a', path: 'someday.org' }
  ] }]);
});

test('通用移动保留跨仓库源目标版本与身份，只为启用同步的仓库排队', async () => {
  const requests = [];
  const { MoveToTargetService } = load('services/MoveToTargetService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [
      { id: 'host-a', rootDirectory: '/a', webdavEnabled: true },
      { id: 'host-b', rootDirectory: '/b', webdavEnabled: false }
    ] }; } } },
    './FileTargetService': {},
    './NativeCoreService': { NativeCoreService: { async workspaceFor() { return {
      async repos() { return [{ id: 'core-a', rootDirectory: '/a', async load() {} },
        { id: 'core-b', rootDirectory: '/b', async load() {} }]; },
      async executeTaskOperations(group) { requests.push(group); }
    }; } } }
  });
  const source = { repoId: 'core-a', filePath: 'inbox.org', fileVersion: 'source-version',
    fullPath: { repoId: 'core-a', file: 'inbox.org', titles: ['Source'] } };
  const selected = { ...target('core-b', 'Home'), projectName: 'Website' };
  await MoveToTargetService.move({}, source, selected);
  assert.deepEqual(requests, [{
    operations: [{ type: 'Movement', data: { path: source.fullPath, position: { parent: selected.fullPath } } }],
 fileVersions: [
      { repoId: 'core-a', file: 'inbox.org', version: 'source-version' },
      { repoId: 'core-b', file: 'projects.org', version: 'target-version' }
    ]
  }]);
});

function somedayFixture() {
  const requests = [], queries = [];
  const config = { repos: [{ id: 'host-id', rootDirectory: '/repo' }], somedayRepoId: 'host-id', somedayFile: 'someday.org' };
  let metadata = { path: 'someday.org', isIgnore: false, fileVersion: 'target-version' };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return config; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.somedayRepoId, path: config.somedayFile }) },
    './NativeCoreService': { taskResult: value => value.result, fileResult: value => value.result,
      NativeCoreService: { async workspaceFor() { return {
        async repos() { return [{ id: 'core-id', rootDirectory: '/repo' }]; },
        async query(batch) { queries.push(batch); return [{ type: 'file', result: metadata ? [metadata] : [] }]; },
        async refileTargets() { assert.fail('Trash 到指定文件不查询 REFILE'); },
        async executeTaskOperations(group) { requests.push(group); }
      }; } }
    }
  });
  const task = { repoId: 'source', filePath: 'inbox.org', fileVersion: 'old',
    fullPath: { repoId: 'source', file: 'inbox.org', titles: ['Item'], occurrence: 2 },
    state: { name: 'DOING', category: 'Doing' }, scheduled: '2026-11-20', deadline: '2026-11-21' };
  return { InboxService, requests, queries, config, task, metadata: value => { metadata = value; } };
}

test('将来只规划到配置文件的 Trash，保留源和目标版本，不要求 REFILE 或待办配置', async () => {
  const f = somedayFixture();
  const groups = await f.InboxService.operationGroups({}, [f.task], 'someday');
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.queries, [[{ type: 'file', query: { includeFiles: [{ repoId: 'core-id', path: 'someday.org' }] } }]]);
  assert.deepEqual(groups, [{ operations: [{ type: 'Trash', data: { path: f.task.fullPath,
    target: { repoId: 'core-id', path: 'someday.org' } } }], fileVersions: [
    { repoId: 'source', file: 'inbox.org', version: 'old' },
    { repoId: 'core-id', file: 'someday.org', version: 'target-version' }
  ] }]);
  assert.equal(f.task.state.name, 'DOING');assert.equal(f.task.scheduled, '2026-11-20');
});

test('批量将来合并全部 Trash 后一次提交，目标只读取一次且不生成字段修改或 Movement', async () => {
  const f = somedayFixture(), second = { ...f.task, fullPath: { ...f.task.fullPath, titles: ['Second'] } };
  await f.InboxService.performMany({}, [f.task, second], 'someday');
  assert.equal(f.requests.length, 1);assert.equal(f.queries.length, 1);
  assert.deepEqual(f.requests[0].operations, [f.task, second].map(task => ({ type: 'Trash', data: {
    path: task.fullPath, target: { repoId: 'core-id', path: 'someday.org' } } })));
  assert.equal(f.requests[0].fileVersions.length, 2);
});

test('将来目标未配置、已消失或被忽略时拒绝，保留源且不回退到其他文件', async () => {
  for (const mode of ['unconfigured', 'missing', 'ignored']) {
    const f = somedayFixture();
    if (mode === 'unconfigured') f.config.somedayFile = '';
    else f.metadata(mode === 'missing' ? undefined : { path: 'someday.org', isIgnore: true, fileVersion: 'new' });
    await assert.rejects(f.InboxService.perform({}, f.task, 'someday'), /设置.*选择|失效/);
    assert.equal(f.requests.length, 0);
  }
});

test('移动分组与组内目标按最近选择排序，身份忽略版本与字节位置', () => {
  const { refileSections, recentRefileSections, refileTargetKey, refileTargetTitle } = load('ui/MoveToTargetPresentation', {});
  const a = target('a', 'Work'), b = target('b', 'Home'), c = target('c', 'Work');
  const sections = refileSections([a, b, c]);
  const recent = [refileTargetKey(c), refileTargetKey(b)];
  const ordered = recentRefileSections(sections, recent);
  assert.deepEqual(ordered.map(s => [s.name, s.targets.map(t => t.repoId)]), [['Work', ['c', 'a']], ['Home', ['b']]]);
  assert.deepEqual(recentRefileSections(sections, ['missing']).map(s => s.name), sections.map(s => s.name));
  assert.deepEqual(sections.flatMap(s => s.targets), [b, a, c]);
  assert.equal(refileTargetKey(a), refileTargetKey({ ...a, fileVersion: 'new', position: { byte_offset: 999 } }));
  assert.notEqual(refileTargetKey(a), refileTargetKey({ ...a, fullPath: { ...a.fullPath, occurrence: 2 } }));
  assert.equal(refileTargetTitle({ ...a, titleParts: [{ text: '项目 ', count: null }] }), '项目');
  assert.equal(refileTargetTitle({ ...a, titleParts: [] }), '未命名位置');
  const root = { ...a, projectName: '项目', fullPath: { ...a.fullPath, titles: [] }, titleParts: [] };
  assert.equal(refileTargetTitle(root), '项目开头');
  assert.notEqual(refileTargetKey(root), refileTargetKey(a));
  assert.equal(recentRefileSections(refileSections([a, root]), [refileTargetKey(root)])[0].targets[0], root);
});

test('移动面板自动选中有效的最近目标，刷新时使用新快照并跳过失效历史', () => {
  const source = fs.readFileSync('entry/src/main/ets/components/editors/MoveToTarget.ets', 'utf8');
  const methods = ['sectionsChanged', 'resetSelection'].map(name =>
    source.match(new RegExp(`  ${name}\\([^\\n]*\\) (?:: boolean )?\\{[\\s\\S]*?\\n  \\}\\n`))?.[0] ||
    source.match(new RegExp(`  ${name}\\([^\\n]*\\) \\{[^\\n]*\\}`))?.[0]).join('\n');
  const output = ts.transpileModule('class Picker {' + methods + '} globalThis.Picker = Picker;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const context = { ...load('ui/MoveToTargetPresentation', {}) };
  vm.runInNewContext(output, context);
  const a = target('a', 'Work'), b = target('b', 'Home');
  const picker = Object.assign(new context.Picker(), { sections: context.refileSections([a, b]),
    recent: ['missing', context.refileTargetKey(b), context.refileTargetKey(a)], historyReady: true });
  picker.sectionsChanged();
  assert.equal(picker.selectedTarget, b);
  const fresh = { ...b, fileVersion: 'fresh' };
  picker.sections = context.refileSections([a, fresh]);picker.sectionsChanged();
  assert.equal(picker.selectedTarget, fresh);
  picker.sections = context.refileSections([a]);picker.sectionsChanged();
  assert.equal(picker.selectedTarget, a);
  picker.sections = [];picker.sectionsChanged();
  assert.equal(picker.selectedTarget, undefined);
});

test('最近移动选择串行持久化、去重并在重新加载后保留顺序', async () => {
  let saved = '[]';
  const writes = [];
  let fail = false;
  const { MoveTargetHistoryService } = load('services/MoveTargetHistoryService', {
    './PreferencesStore': { PreferencesStore: { async open(_, name) {
      assert.equal(name, 'org_tasks_move_targets');
      return { async get(key) { assert.equal(key, 'recentTargets'); return saved; },
        async put(_key, value) { if (fail) throw new Error('保存失败'); saved = value; writes.push(value); }, async flush() {} };
    } } }
  });
  const history = MoveTargetHistoryService;
  assert.deepEqual(await history.load({}), []);
  await Promise.all([history.remember({}, 'a'), history.remember({}, 'b'), history.remember({}, 'a')]);
  assert.deepEqual(await history.load({}), ['a', 'b']);
  assert.equal(writes.length, 3);
  fail = true;
  await assert.rejects(history.remember({}, 'c'), /保存失败/);
  fail = false;
  await history.remember({}, 'd');
  assert.deepEqual(await history.load({}), ['d', 'a', 'b']);
  for (let i = 0; i < 105; i++) await history.remember({}, String(i));
  assert.equal((await history.load({})).length, 100);
});

test('批量分配与截止只提交一次，携带全部源版本并使用结构化规划值保留已有时刻与重复规则', async () => {
  for (const [action, field] of [['schedule', 'SCHEDULE'], ['deadline', 'DEADLINE']]) {
    const f = fixture(), tasks = [f.task, { ...f.task, id: 'Second', fullPath: { ...f.task.fullPath, titles: ['Second'] } }];
    await f.InboxService.performMany({}, tasks, action, undefined, { date: '2026-11-20' });
    assert.equal(f.requests.length, 1);
    assert.deepEqual(f.requests[0].operations, tasks.map(task => ({ type: 'Modification', data: {
      path: task.fullPath, modifications: [{ field, value: { date: '2026-11-20' } }]
    } })));
    assert.deepEqual(f.requests[0].fileVersions, Array.from(new Map(tasks.map(task => [JSON.stringify([task.repoId, task.filePath]), { repoId: task.repoId, file: task.filePath, version: task.fileVersion }])).values()));
    await assert.rejects(f.InboxService.performMany({}, tasks, action), /请选择日期/);
    assert.equal(f.requests.length, 1);
  }
});

test('批量移动一次提交所有源与共同目标，取消目标时不写入', async () => {
  const f = fixture(), tasks = [f.task, { ...f.task, id: 'Second', fullPath: { ...f.task.fullPath, titles: ['Second'] } }];
  const selected = target('core-id', 'Work');
  await assert.rejects(f.InboxService.performMany({}, tasks, 'move'), /请选择任务目标/);
  assert.equal(f.requests.length, 0);
  await f.InboxService.performMany({}, tasks, 'move', selected);
  assert.equal(f.requests.length, 1);
  assert.deepEqual(f.requests[0].operations, tasks.map(task => ({ type: 'Movement', data: { path: task.fullPath, position: { parent: selected.fullPath } } })));
  assert.deepEqual(f.requests[0].fileVersions.at(-1), { repoId: selected.repoId, file: selected.path, version: selected.fileVersion });
});

test('批量备忘只读取一次共同目标；批量删除不拆成多次提交', async () => {
  for (const action of ['memo', 'delete']) {
    const f = fixture(), tasks = [f.task, { ...f.task, id: 'Second', fullPath: { ...f.task.fullPath, titles: ['Second'] } }];
    let queries = 0;
    const query = f.workspace.query;
    f.workspace.query = async batch => { queries++; return await query(batch); };
    await f.InboxService.performMany({}, tasks, action);
    assert.equal(f.requests.length, 1);
    assert.equal(queries, action === 'memo' ? 1 : 0);
    assert.deepEqual(f.requests[0].operations.map(op => op.type), action === 'memo' ? ['Modification', 'Movement', 'Modification', 'Movement'] : ['Trash', 'Trash']);
  }
});

test('规划批量备忘只返回逐条修改组并固定源与目标版本，不执行请求', async () => {
  const f = fixture(); const tasks = [f.task, { ...f.task, fullPath: { ...f.task.fullPath, titles: ['Second'] } }];
  const groups = await f.InboxService.operationGroups({}, tasks, 'memo');
  assert.equal(f.requests.length, 0); assert.equal(groups.length, 2);
  assert.deepEqual(groups[0].operations.map(op => op.type), ['Modification', 'Movement']);
  assert.deepEqual(groups[0].fileVersions, [{ repoId: 'core-id', file: 'inbox.org', version: 'source-version' }, { repoId: 'core-id', file: 'memo.org', version: 'memo-version' }]);
  assert.equal(groups[0].operationId, undefined);
});
