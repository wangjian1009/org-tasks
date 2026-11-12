// 验证收件箱的目标分组和宿主调用编排；写入语义由 Rust 集成测试覆盖。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-inbox.cjs\n验证移动目标 CATEGORY 与项目平级分组、目标身份、移动、将来，也许、备忘与删除请求。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
  vm.runInThisContext('(function(require,module,exports){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (name.startsWith('.')) return load(path.relative(path.resolve('entry/src/main/ets'), path.resolve(path.dirname(filename), name)), mocks);
    throw new Error('缺少替身: ' + name);
  }, module, module.exports);
  return module.exports;
}
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
test('项目名与 CATEGORY 平级，不重复归类，同名项目与分类保留独立 Tab', () => {
  const { refileSections } = load('ui/MoveToTargetPresentation', {});
  const values = [target('plain', 'Work'),
    { ...target('project-a', 'Work'), projectName: 'Website' },
    { ...target('project-b', 'Home'), projectName: 'Website' },
    { ...target('same-name', 'Home'), projectName: 'Work' },
    { ...target('unnamed', null), projectName: '' }, target('uncategorized', null)];
  const sections = refileSections(values);
  assert.deepEqual(sections.map(s => [s.kind, s.name, s.targets.map(t => t.repoId)]), [
    ['project', 'Website', ['project-a', 'project-b']], ['category', 'Work', ['plain']],
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
  const task = { repoId: 'core-id', filePath: 'inbox.org', fileVersion: 'source-version', fullPath: { repoId: 'core-id', file: 'inbox.org', titles: ['Item'], occurrence: 1 } };
  const workspace = { async query(batch) {return batch.map(()=>({type:'file',result:ignored?[]:[{path:'memo.org',isIgnore:false}]}));}, async refileTargets() { return [target('core-id', 'Work')]; },
    async repos() { return [repo]; }, async executeTaskOperations(group) { requests.push(group); } };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [settings], memoRepoId: 'host-id', memoFile: 'memo.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.memoRepoId, path: config.memoFile }) },
    './NativeCoreService': { taskResult:value=>value.result, fileResult:value=>value.result, NativeCoreService: { async workspaceFor() { return workspace; } } }
  });
  return { InboxService, requests, task, workspace, setIgnored() { ignored = true; } };
}

function actionFixture() {
  const backend=fixture(), actions=[], messages=[];
  let current={...backend.task,fileVersion:'saved-version'}, finish=async()=>true, findError, reads=0;
  const filename='entry/src/main/ets/pages/Inbox.ets';
  const source=fs.readFileSync(filename,'utf8');
  const method=source.match(/  async prepareAction\(record: CoreTask, action: InboxAction\) \{[\s\S]*?\n  \}\n/)[0];
  const code=ts.transpileModule('export class InboxActions {'+method+'\n}',{
    compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}
  }).outputText;
  const module={exports:{}};
  const session={end:async collapse=>{assert.equal(collapse,false);return await finish();}};
  const service={find:async()=>{reads++;if(findError)throw findError;return current;}};
  vm.runInThisContext('(function(module,exports,TaskInlineSession,TaskInlineService,coreErrorMessage){'+code+'\n})', {filename})(
    module,module.exports,session,service,error=>error.message);
  const state=Object.assign(new module.exports.InboxActions(),{
    visible:true,actionBusy:false,drawerOpen:false,captureOpen:false,selectingRecords:false,selectionStarting:false,
    getUIContext:()=>({getHostContext:()=>({}),getPromptAction:()=>({showToast:({message})=>messages.push(message)})}),
    selectRecord:record=>actions.push({action:'move',record}),
    confirmDelete:record=>actions.push({action:'delete',record}),
    perform:async(action,target,record)=>actions.push({action,record})
  });
  return {backend,state,actions,messages,reads:()=>reads,setCurrent:value=>current=value,
    saveWith:callback=>finish=callback,failFind:error=>findError=error};
}

function captureFixture() {
  const filename = 'entry/src/main/ets/pages/Inbox.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const method = source.match(/  async capture\(\) \{[\s\S]*?\n  \}\n/)[0];
  const visibility = source.slice(source.indexOf("}.id('inbox_capture')")).match(/\.visibility\(([^\n]+)\)/)[1];
  const code = ts.transpileModule('export class InboxCapture {' + method + '\nbuttonVisibility() { return ' + visibility + '; }\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, messages = [], calls = [];
  let finish = async () => true, keyboardMode = 'offset';
  vm.runInThisContext('(function(module,exports,TaskInlineSession,KeyboardAvoidMode,Visibility,coreErrorMessage){' + code + '\n})', { filename })(
    module, module.exports, { end: async collapse => { calls.push(collapse); return await finish(); } },
    { RESIZE: 'resize' }, { Hidden: 'hidden', Visible: 'visible' }, error => error.message);
  const state = Object.assign(new module.exports.InboxCapture(), {
    visible: true, captureOpen: false, drawerOpen: false, actionBusy: false, selected: undefined,
    selectingRecords: false, selectionStarting: false, inlineActive: '', inlineTyping: false,
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
  for (const [key, value] of [['drawerOpen', true], ['selected', {}], ['selectingRecords', true], ['selectionStarting', true]]) {
    const previous = f.state[key]; f.state[key] = value;
    assert.equal(f.state.buttonVisibility(), 'hidden');
    f.state[key] = previous;
    assert.equal(f.state.buttonVisibility(), 'visible');
  }
});

test('原位保存后从侧滑菜单移动或删除，提交新源版本并保留目标版本校验',async()=>{
  for(const action of ['move','delete']) {
    const f=actionFixture(),targetSnapshot=target('core-id','Work');
    f.backend.workspace.executeTaskOperations=async group=>{
      assert.equal(group.fileVersions[0].version,'saved-version','侧滑操作不能使用页面最初加载的版本');
      f.backend.requests.push(group);
    };
    await f.state.prepareAction(f.backend.task,action);
    assert.equal(f.actions.length,1);
    await f.backend.InboxService.perform({},f.actions[0].record,action,action==='move'?targetSnapshot:undefined);
    if(action==='move')assert.equal(f.backend.requests[0].fileVersions[1].version,'target-version');
    assert.equal(f.state.actionBusy,false);
  }
});

test('侧滑动作先等待草稿保存，再读取源任务，保存失败不打开菜单或提交',async()=>{
  for(const action of ['move','delete','memo','someday']) {
    const f=actionFixture();let finish;
    f.saveWith(()=>new Promise(resolve=>finish=resolve));
    const pending=f.state.prepareAction(f.backend.task,action);
    assert.equal(f.state.actionBusy,true);assert.equal(f.reads(),0);assert.equal(f.actions.length,0);
    f.setCurrent({...f.backend.task,fileVersion:'after-draft'});finish(true);await pending;
    assert.equal(f.actions[0].record.fileVersion,'after-draft');
    const failed=actionFixture();failed.saveWith(async()=>false);
    await failed.state.prepareAction(failed.backend.task,action);
    assert.equal(failed.reads(),0);assert.deepEqual(failed.actions,[]);assert.equal(failed.state.actionBusy,false);
  }
});

test('源任务已移走或读取失败时不提交旧记录，准备动作不会重复执行',async()=>{
  const missing=actionFixture();missing.setCurrent(undefined);
  await missing.state.prepareAction(missing.backend.task,'move');assert.deepEqual(missing.actions,[]);
  const failed=actionFixture();failed.failFind(new Error('读取失败'));
  await failed.state.prepareAction(failed.backend.task,'delete');
  assert.deepEqual(failed.actions,[]);assert.deepEqual(failed.messages,['读取失败']);assert.equal(failed.state.actionBusy,false);
  const busy=actionFixture();let finish;busy.saveWith(()=>new Promise(resolve=>finish=resolve));
  const pending=busy.state.prepareAction(busy.backend.task,'move');
  await busy.state.prepareAction(busy.backend.task,'move');finish(true);await pending;
  assert.equal(busy.actions.length,1);
});

test('直接移动使用原目标位置和双端版本，上传身份来自 Core 仓库', async () => {
  const f = fixture(); const t = target('core-id', 'Work');
  await f.InboxService.perform({}, f.task, 'move', t);
  assert.deepEqual(f.requests[0], { operations: [{ type: 'Movement', data: { path: f.task.fullPath,
    position: { parent: t.fullPath } } }], queueRepoIds: ['core-id'], fileVersions: [
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
  assert.deepEqual(f.requests[0].operations, [{ type: 'Deletion', data: { path: f.task.fullPath } }]);
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

test('最近新增在创建日期内按分类与项目组织区块，保留普通任务、完成记录和原快照', () => {
  const { recentDays } = load('ui/InboxPresentation', {});
  const record = (id, category, project, day = 12, values = {}) => ({ id, category, project: () => project,
    createdAt: new Date(2026, 10, day, 12).getTime(), ...values });
  const tasks = [record('plain', '工作', null), record('first', '工作', '项目甲'),
    record('memo', '工作', null, 12, { todoKind: null }), record('second', '工作', '项目甲', 12, { todoKind: 'done' }),
    record('other-category', '生活', '项目甲'), record('unnamed', null, ''),
    record('unnamed-again', '', ''), record('yesterday', '工作', '项目甲', 11)];
  const days = recentDays(tasks, new Date(2026, 10, 12));
  assert.deepEqual(days[0].groups.map(group => [group.project, group.tasks.map(task => task.id)]),
    [[null, ['plain']], ['项目甲', ['first', 'second']], [null, ['memo']], ['项目甲', ['other-category']], ['', ['unnamed', 'unnamed-again']]]);
  assert.deepEqual(days[1].groups.map(group => group.tasks), [[tasks[7]]]);
  const displayed = days.flatMap(day => day.groups.flatMap(group => group.tasks));
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
  assert.deepEqual(queries[0][2].query,{expression:'cr.ge.-2d cr.le.today .o.created',includeDone:true,includeComposeTasks:true,excludedFiles:[{repoId:'core-id',path:'inbox.org'}]});
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
  assert.deepEqual(queries, [{ excludedFiles: [
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
    queueRepoIds: ['core-a'], fileVersions: [
      { repoId: 'core-a', file: 'inbox.org', version: 'source-version' },
      { repoId: 'core-b', file: 'projects.org', version: 'target-version' }
    ]
  }]);
});

function moveRetryFixture() {
  const filename = 'entry/src/main/ets/pages/Inbox.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const methods = ['refreshMoveTargets', 'loadTargets', 'closeTargetPopup'].map(name =>
    source.match(new RegExp(`  (?:async )?${name}\\(\\) \\{[\\s\\S]*?\\n  \\}\\n`))[0]).join('');
  const code = ts.transpileModule('export class MoveRetry {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, calls = [];
  const current = { id: 'source', fileVersion: 'fresh-source-version' };
  const freshTarget = { ...target('r', 'Work'), projectName: 'Website', fileVersion: 'fresh-target-version' };
  let find = async () => current, targets = async () => [freshTarget];
  vm.runInThisContext('(function(module,exports,TaskInlineService,MoveToTargetService,refileSections,coreErrorMessage){' + code + '\n})', { filename })(
    module, module.exports,
    { async find(_context, source) { calls.push(['source', source]); return await find(); } },
    { async targets() { calls.push(['targets']); return await targets(); } },
    load('ui/MoveToTargetPresentation', {}).refileSections, error => error.message);
  const original = { id: 'source', fileVersion: 'stale-source-version' };
  const state = Object.assign(new module.exports.MoveRetry(), {
    selected: original, actionBusy: false, targetsLoading: false, targetRequest: 0, visible: true,
    targetSections: [], popupMessage: '文件版本冲突', getUIContext: () => ({ getHostContext: () => ({}) })
  });
  return { state, calls, original, current, freshTarget, findWith: fn => find = fn, targetsWith: fn => targets = fn };
}

test('收件箱移动重试按顺序重读源与目标版本，刷新后归入项目 Tab', async () => {
  const f = moveRetryFixture();
  await f.state.refreshMoveTargets();
  assert.deepEqual(f.calls, [['source', f.original], ['targets']]);
  assert.equal(f.state.selected, f.current);
  assert.equal(f.state.targetSections[0].kind, 'project');
  assert.equal(f.state.targetSections[0].targets[0], f.freshTarget);
  assert.equal(f.state.popupMessage, '');
  assert.equal(f.state.actionBusy, false);
  assert.equal(f.state.targetsLoading, false);
});

test('移动重试在源消失或读取失败时停止，保留错误并阻止重复重读', async () => {
  const missing = moveRetryFixture(); missing.findWith(async () => undefined);
  await missing.state.refreshMoveTargets();
  assert.equal(missing.state.selected, undefined);
  assert.deepEqual(missing.state.targetSections, []);
  assert.equal(missing.calls.length, 1);
  const failed = moveRetryFixture(); failed.findWith(async () => { throw new Error('源读取失败'); });
  await failed.state.refreshMoveTargets();
  assert.equal(failed.state.selected, failed.original);
  assert.equal(failed.state.popupMessage, '源读取失败');
  assert.equal(failed.calls.length, 1);
  const busy = moveRetryFixture(); let finish;
  busy.findWith(() => new Promise(resolve => { finish = resolve; }));
  const pending = busy.state.refreshMoveTargets();
  await busy.state.refreshMoveTargets();
  assert.equal(busy.calls.length, 1);
  finish(busy.current); await pending;
  assert.equal(busy.calls.length, 2);
});

test('将来，也许只使用已配置文件的首个 REFILE，提交 TODO 与清除规划选项', async () => {
  const requests = [];
  const queries = [];
  let hasTargets = true;
  const first = { ...target('core-id', 'Later'), path: 'someday.org', fullPath: { repoId: 'core-id', file: 'someday.org', titles: ['Later'], occurrence: 2 } };
  let initialState = 'OPEN';
  const repo = { id: 'core-id', rootDirectory: '/repo', async load() {} };
  const { InboxService } = load('services/InboxService', {
    './AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'host-id', rootDirectory: '/repo', webdavEnabled: true }], somedayRepoId: 'host-id', somedayFile: 'someday.org' }; } } },
    './FileTargetService': { configuredFileTarget: config => ({ repoId: config.somedayRepoId, path: config.somedayFile }) },
    './NativeCoreService': { taskResult:value=>value.result, fileResult:value=>value.result, NativeCoreService: { async workspaceFor() { return { async repos() { return [repo]; }, async query(batch){return batch.map(()=>({type:'file',result:[{path:'someday.org',isIgnore:false,taskStateOf(category){ assert.equal(category,'Todo'); return initialState ? {name:initialState,category} : null; }}]}));},
      async refileTargets(query) { queries.push(query); return hasTargets ? [first] : []; }, async executeTaskOperations(group) { requests.push(group); } }; } } }
  });
  const task = { repoId: 'source', filePath: 'inbox.org', fileVersion: 'old', fullPath: { repoId: 'source', file: 'inbox.org', titles: ['Item'], occurrence: 2 } };
  await InboxService.perform({}, task, 'someday');
  assert.deepEqual(queries[0], { files: [{ repoId: 'core-id', path: 'someday.org' }] });
  assert.deepEqual(requests[0], { operations: [
    { type: 'Modification', data: { path: task.fullPath, modifications: [
      { field: 'TODO', value: 'OPEN' }, { field: 'SCHEDULE', value: null },
      { field: 'DEADLINE', value: null }
    ] } },
    { type: 'Movement', data: { path: task.fullPath, position: { parent: first.fullPath } } }
  ], fileVersions: [
    { repoId: 'source', file: 'inbox.org', version: 'old' },
    { repoId: 'core-id', file: 'someday.org', version: 'target-version' }
  ], queueRepoIds: ['core-id'] });
  initialState = null;
  await assert.rejects(InboxService.perform({}, task, 'someday'), /待办状态/);
  initialState = 'OPEN';
  hasTargets = false;
  await assert.rejects(InboxService.perform({}, task, 'someday'), /REFILE/);
  assert.equal(requests.length, 1);
});

test('位置浮层按最大分类计算高度，最多四行且小窗口限制高度', () => {
  const { targetPopupHeight } = load('ui/MoveToTargetPresentation', {});
  const section = size => ({ category: String(size), targets: Array.from({ length: size }, () => target('r', 'Work')) });
  const small = targetPopupHeight([section(1)], 800);
  const large = targetPopupHeight([section(2), section(5)], 800);
  assert.ok(small < large);
  assert.equal(large, targetPopupHeight([section(5), section(2)], 800));
  assert.equal(large, targetPopupHeight([section(5)], 800));
  assert.equal(targetPopupHeight([section(4)], 800), targetPopupHeight([section(100)], 800));
  assert.ok(targetPopupHeight([section(100)], 320) <= 320 - 104);
  assert.ok(targetPopupHeight([], 800, true) > 48);
  assert.ok(targetPopupHeight([], 800, false, '目标读取失败') > targetPopupHeight([], 800));
});
