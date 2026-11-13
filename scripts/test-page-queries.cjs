// 验证真实页面编排仅发出一次混合查询；Core 求值由 Rust 测试覆盖。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-page-queries.cjs\n验证收件箱、任务视图、侧边栏的一次混合查询、文件有效性、通知订阅与响应位置。');
  process.exit(0);
}
const root = path.resolve(__dirname, '../entry/src/main/ets');
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function fixture() {
  const batches = [], writes = [], notificationCallbacks = [], dataCallbacks = [];
  const repos = [{ id:'core-a',rootDirectory:'/a' },{ id:'core-b',rootDirectory:'/b' }];
  const config = { repos:[{id:'host-a',rootDirectory:'/a',name:'仓库甲'},{id:'host-b',rootDirectory:'/b',name:'仓库乙'}],todoDefaults:'',
    inboxRepoId:'host-a',inboxFile:'same.org',somedayRepoId:'host-b',somedayFile:'same.org',memoRepoId:'host-a',memoFile:'memo.org' };
  let missing = false, fail = false, customQuery;
  const metadata = [{repoId:'core-a',path:'same.org',tagOptions:[],tagGroups:[],isIgnore:false},
    {repoId:'core-b',path:'same.org',tagOptions:[],tagGroups:[],isIgnore:false},
    {repoId:'core-a',path:'memo.org',tagOptions:['未使用标签'],tagGroups:[['互斥甲','互斥乙']],isIgnore:false}];
  const workspace = {
    async repos() { return repos; },
    async query(batch) {
      batches.push(batch);
      if (fail) throw new Error('整批读取失败');
      if (customQuery) return await customQuery(batch);
      return batch.map(request => {
        if (request.type === 'task') return {type:'task',result:{tasks:[],categories:[]}};
        if (request.type === 'notification') return {type:'notification',result:[{type:'syncRequired'}]};
        assert.equal(request.type, 'file');
        return {type:'file',result:missing?[]:metadata.filter(file => !request.query.includeFiles?.length ||
          request.query.includeFiles.some(ref=>ref.repoId===file.repoId&&ref.path===file.path))};
      });
    },
    async watchNotifications(callback) { notificationCallbacks.push(callback); }, stopWatchingNotifications() {},
    async watchDataChanges(callback) { dataCallbacks.push(callback); return dataCallbacks.length; }, stopWatchingDataChanges() {}
  };
  const native = { taskResult:value=>{assert.equal(value.type,'task');return value.result;},
    fileResult:value=>{assert.equal(value.type,'file');return value.result;},
    notificationResult:value=>{assert.equal(value.type,'notification');return value.result;},
    coreErrorMessage:error=>error.message,
    NativeCoreService:{async workspaceFor(actual) { assert.equal(actual,config.repos); return workspace; },
      async query(actual,batch) { assert.equal(actual,config.repos); return workspace.query(batch); }} };
  const cache = new Map();
  const storage = {setOrCreate(key,value){writes.push({key,value});}};
  function load(name, source) {
    const filename = path.join(root,name+'.ets');
    if (!source && cache.has(filename)) return cache.get(filename).exports;
    const module={exports:{}};
    if (!source) cache.set(filename,module);
    const code=ts.transpileModule(source||fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    const requireLocal=dependency=>{
      if (dependency.endsWith('/NativeCoreService')||dependency==='./NativeCoreService') return native;
      if (dependency.endsWith('/AppConfigService')||dependency==='./AppConfigService') return {AppConfigService:{async load(){return config;},async save(){}}};
      if (dependency.endsWith('/TaskInlineService')) return {TaskInlineSession:{active:()=>false}};
      if (dependency.startsWith('.')) return load(path.relative(root,path.resolve(path.dirname(filename),dependency)));
      throw new Error('缺少替身: '+dependency);
    };
    vm.runInThisContext('(function(require,module,exports,AppStorage){'+code+'\n})',{filename})(requireLocal,module,module.exports,storage);
    return module.exports;
  }
  function page(name, methods) {
    const filename=path.join(root,name+'.ets'),text=fs.readFileSync(filename,'utf8');
    const prelude=text.slice(0,text.search(/^@(?:Entry|Component)/m));
    const chunks=methods.map(method=>{
      const match=text.match(new RegExp('  (?:async )?'+method+'\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));
      assert.ok(match,'未找到方法 '+method); return match[0];
    });
    const View=load(name,prelude+'\nexport class QueryPage {\n'+chunks.join('\n')+'\n}').QueryPage;
    const view=Object.assign(new View(),{requestId:0,navigationRequest:0,tasks:[],visibleTasks:[],records:[],recentGroups:[],
      selectedTags:[],includeUntagged:false,tagOptions:[],tagGroups:[],visible:false,
      getUIContext:()=>({getHostContext:()=>({})}),closeTargetPopup(){},measureRows(){},async openEntryMemo(){}});
    return view;
  }
  return {config,batches,writes,workspace,load,page,notificationCallbacks,dataCallbacks,
    missing(){missing=true;}, fail(){fail=true;}, query(fn){customQuery=fn;}};
}

for (const view of ['today','planned','anytime','logbook','someday','memo']) {
  test(view+' 首次加载只调用一次批量查询，文件元信息与通知在同批返回',async()=>{
    const f=fixture(),page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);
    page.view=view; await page.loadTasks();
    assert.equal(page.message,'');
    assert.equal(f.batches.length,1);
    assert.deepEqual(f.batches[0].map(item=>item.type),view==='someday'||view==='memo'?['task','file','notification']:view==='today'?['task','task','notification']:['task','notification']);
    assert.equal(page.needsConfiguration,false,'有效空文件不是失效文件');
    page.applyTagFilter({tags:[],includeUntagged:false});
    assert.equal(f.batches.length,1,'展示层标签切换不增加查询');
    if(view==='someday') {
      assert.deepEqual(f.batches[0][0].repoIds,['core-b']);
      assert.deepEqual(f.batches[0][0].query,{expression:'b."same.org" it.todo',includeDone:false,includeComposeTasks:true});
    }
    if(view==='memo')assert.deepEqual(page.tagOptions,['未使用标签']);
  });
}

function plannedTask(id, repoId, filePath, category, projectName = null) {
  return { id, repoId, filePath, category, project: () => projectName, heading: id,
    scheduled: '2099-01-01', deadline: '', tags: [] };
}

test('计划分类与项目单选互斥，候选保持完整，结果直接使用 Core 快照', async () => {
  const f = fixture(), page = f.page('pages/TaskOverview',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  const tasks = [plannedTask('a','core-a','project.org','工作','项目甲'),
    plannedTask('b','core-b','project.org','生活','项目甲'), plannedTask('c','core-a','plain.org',null)];
  // 故意返回不符合分类的任务，确认页面不会重新执行分类过滤。
  const categoryTasks = [tasks[2]], projectTasks = [tasks[0]];
  f.query(batch => batch.map((request, index) => request.type === 'notification' ?
    {type:'notification',result:[]} : {type:'task',result:{tasks:index === 0 ? tasks :
      request.repoIds ? projectTasks : categoryTasks,categories:[]}}));
  page.view = 'planned';
  await page.loadTasks();
  const keys = page.planRegionOptions.map(region => region.key);
  const category = page.planRegionOptions.find(region => region.kind === 'category' && region.category === '工作');
  const project = page.planRegionOptions.find(region => region.kind === 'project' && region.repoId === 'core-a');
  await page.selectPlanRegion(category);
  assert.equal(page.tasks, categoryTasks);
  assert.deepEqual(f.batches[1].map(item => item.type), ['task','task','notification']);
  assert.deepEqual(f.batches[1][1].query.categories, ['工作']);
  assert.equal(f.batches[1][1].repoIds, undefined);
  assert.deepEqual(page.planRegionOptions.map(region => region.key), keys);
  await page.selectPlanRegion(project);
  assert.equal(page.selectedPlanRegion.key, project.key);
  assert.equal(page.tasks, projectTasks);
  assert.equal(f.batches[2][1].query.categories, undefined, '项目选择替换分类条件');
  assert.deepEqual(f.batches[2][1].repoIds, ['core-a']);
  assert.ok(f.batches[2][1].query.expression.endsWith('b."project.org"'));
  assert.ok(f.batches[2][1].query.expression.includes('.is.habit'));
  await page.selectPlanRegion(null);
  assert.equal(page.tasks, tasks);
  assert.equal(page.selectedPlanRegion, null);
  assert.deepEqual(f.batches[3].map(item => item.type), ['task','notification']);
});

test('计划未分类与字面同名分类保持独立，项目路径正确转义', () => {
  const f = fixture(), { plannedRegionQuery } = f.load('services/TaskViewQueries');
  const region = { key:'category',kind:'category',category:null,title:'未分类',repoId:'',filePath:'' };
  assert.deepEqual(plannedRegionQuery(region).query.categories, [null]);
  assert.deepEqual(plannedRegionQuery({...region,category:'未分类'}).query.categories, ['未分类']);
  const project = plannedRegionQuery({...region,kind:'project',repoId:'core-b',filePath:'项目 (a) "b"\\c.org'});
  assert.deepEqual(project.repoIds, ['core-b']);
  assert.ok(project.query.expression.endsWith('b."项目 (a) \\"b\\"\\\\c.org"'));
});

test('计划刷新清除已消失的选择，同批回退全部，读取失败后可重试', async () => {
  const f = fixture(), page = f.page('pages/TaskOverview',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  let tasks = [plannedTask('a','core-a','project.org','工作','项目甲')];
  f.query(batch => batch.map(request => request.type === 'notification' ?
    {type:'notification',result:[]} : {type:'task',result:{tasks,categories:[]}}));
  page.view = 'planned';
  await page.loadTasks();
  const selected = page.planRegionOptions.find(region => region.kind === 'project');
  await page.selectPlanRegion(selected);
  tasks = [plannedTask('b','core-b','plain.org','生活')];
  await page.loadTasks();
  assert.equal(f.batches.length, 3);
  assert.equal(page.selectedPlanRegion, null);
  assert.equal(page.tasks, tasks);
  let fail = true;
  f.query(batch => {
    if (fail) throw new Error('读取失败');
    return batch.map(request => request.type === 'notification' ? {type:'notification',result:[]} :
      {type:'task',result:{tasks,categories:[]}});
  });
  await page.selectPlanRegion(page.planRegionOptions[0]);
  assert.match(page.message, /读取失败/);
  fail = false;
  await page.loadTasks();
  assert.equal(page.message, '');
  assert.equal(page.tasks, tasks);
});

test('计划快速切换时迟到结果不覆盖最后一次选择与任务', async () => {
  const f = fixture(), page = f.page('pages/TaskOverview',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  const tasks = [plannedTask('a','core-a','a.org','工作','项目甲'),
    plannedTask('b','core-b','b.org','生活','项目乙')];
  let release;
  f.query(async batch => {
    const selected = batch.length === 3 ? batch[1] : null;
    if (selected?.query.categories) await new Promise(resolve => { release = resolve; });
    return batch.map((request,index) => request.type === 'notification' ? {type:'notification',result:[]} :
      {type:'task',result:{tasks:index === 0 ? tasks : [selected?.repoIds ? tasks[1] : tasks[0]],categories:[]}});
  });
  page.view = 'planned';
  await page.loadTasks();
  const category = page.planRegionOptions.find(region => region.kind === 'category');
  const project = page.planRegionOptions.find(region => region.kind === 'project' && region.repoId === 'core-b');
  const first = page.selectPlanRegion(category);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(typeof release, 'function');
  await page.selectPlanRegion(project);
  release();
  await first;
  assert.equal(page.selectedPlanRegion.key, project.key);
  assert.deepEqual(page.tasks, [tasks[1]]);
  assert.equal(page.loading, false);
});

test('日志簿仅向 Core 请求 Done 分类，每个返回任务只展示一次完成记录', async () => {
  const f = fixture(), page = f.page('pages/TaskOverview', ['loadTasks','supportsTagFilter','applyTagFilter']);
  const tasks = [
    { id:'finished', project:()=>null, state:{name:'CUSTOM_FINISH',category:'Done'}, createdAt:1_700_000_000_000, closedAt:1_700_003_600_000 },
    { id:'older', project:()=>null, state:{name:'OTHER_DONE',category:'Done'}, createdAt:1_600_000_000_000, closedAt:null }
  ];
  f.query(batch => batch.map(request => request.type === 'task' ?
    {type:'task',result:{tasks,categories:[]}} : {type:'notification',result:[]}));
  page.view = 'logbook';
  await page.loadTasks();
  assert.equal(page.message, '');
  assert.equal(f.batches.length, 1);
  assert.deepEqual(f.batches[0][0].query, {expression:'i.done',includeDone:true,includeComposeTasks:true});
  assert.equal(page.tasks, tasks);
  const items = page.logbookTaskGroups.flatMap(group => group.items);
  assert.equal(items.length, tasks.length);
  assert.deepEqual(items.map(item => item.task), tasks);
  assert.equal(items[1].timestamp, null);
});

test('收件箱本页、最近新增、文件元信息与通知只调用一次批量查询',async()=>{
  const f=fixture(),page=f.page('pages/Inbox',['loadRecords']);
  await page.loadRecords();
  assert.equal(page.message,'');assert.equal(f.batches.length,1);
  assert.deepEqual(f.batches[0].map(item=>item.type),['task','file','task','notification']);
  assert.deepEqual(f.batches[0][0].repoIds,['core-a']);
  assert.deepEqual(f.batches[0][2].query.excludedFiles,[{repoId:'core-a',path:'same.org'}]);
  assert.equal(page.needsConfiguration,false);
});

test('侧边栏任务、项目、入口文件和通知合为一个批次，跨仓库同名文件保持隔离',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  await page.loadNavigation();
  assert.equal(page.navMessage,'');assert.equal(f.batches.length,1);assert.equal(f.batches[0].length,13);
  assert.deepEqual(f.batches[0].slice(5).map(item=>item.type),['file','task','file','task','file','task','file','notification']);
  assert.deepEqual(f.batches[0][5].query,{isProject:true});
  assert.deepEqual(f.batches[0][6].repoIds,['core-a']);assert.deepEqual(f.batches[0][8].repoIds,['core-b']);
  assert.deepEqual(f.batches[0][8].query,{expression:'b."same.org" it.todo',includeDone:false,includeComposeTasks:true});
  assert.equal(page.inboxCount,0);assert.equal(page.somedayCount,0);assert.equal(page.memoCount,0);
});

test('项目按 Core 文件结果保留顺序、空名称和同名身份，新快照清除已删除入口',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  const projects=[{repoId:'core-a',path:'one.org',projectName:'同名项目'},
    {repoId:'core-b',path:'one.org',projectName:'同名项目'},
    {repoId:'core-a',path:'two.org',projectName:''}];
  let current=projects;
  f.query(batch=>batch.map(request=>request.type==='task'?{type:'task',result:{tasks:[],categories:[]}}:
    request.type==='notification'?{type:'notification',result:[]}:
    {type:'file',result:request.query.isProject?current:[]}));
  await page.loadNavigation();
  assert.equal(page.projects,current);
  current=[];await page.loadNavigation();
  assert.deepEqual(page.projects,[]);
  assert.deepEqual(page.projectGroups,[]);
});

test('项目按文件 CATEGORY 展示分区，保留同名身份与组内顺序，未分类置末',()=>{
  const f=fixture(),{projectSections}=f.load('ui/NotebookPresentation');
  const files=[{repoId:'a',path:'empty.org',category:null},{repoId:'a',path:'work.org',category:'工作',projectName:'同名'},
    {repoId:'b',path:'personal.org',category:'个人'}, {repoId:'b',path:'work.org',category:'工作',projectName:'同名'},
    {repoId:'a',path:'blank.org',category:''},{repoId:'a',path:'named.org',category:'未分类'}];
  const groups=projectSections(files);
  assert.deepEqual(groups.map(group=>group.category),['工作','个人','未分类','']);
  assert.deepEqual(groups[0].files,[files[1],files[3]]);
  assert.deepEqual(groups[3].files,[files[0],files[4]]);
  assert.deepEqual(projectSections([]),[]);
});

test('项目进度按 Core 分类汇总，取消和未分类状态只计入总数',()=>{
  const f=fixture(),{fileTaskCount,fileTaskProgress}=f.load('ui/NotebookPresentation');
  const file={taskStateCounts:[{state:'FINISHED',category:'Done',count:3},{state:'DONE',category:null,count:2},
    {state:'ABORT',category:'Cancel',count:1},{state:'NEXT',category:'Todo',count:4}]};
  assert.equal(fileTaskCount(file),10);assert.equal(fileTaskProgress(file),'3/10');
  assert.equal(fileTaskProgress({taskStateCounts:[]}),'0/0');
});

test('失效文件和未配置文件不退回全仓库任务，通知仍在同一个批次内加载',async()=>{
  const f=fixture();f.missing();const page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='memo';await page.loadTasks();assert.equal(page.needsConfiguration,true);assert.equal(f.batches.length,1);
  f.config.memoRepoId='';await page.loadTasks();assert.equal(f.batches.length,2);
  assert.deepEqual(f.batches[1].map(item=>item.type),['notification']);
});

test('批次失败不产生通知快照，订阅回调不自行查询通知',async()=>{
  const f=fixture(),PageQueryService=f.load('services/PageQueryService').PageQueryService;
  await PageQueryService.query(f.config,[{type:'task',query:{}}]);
  assert.equal(f.batches.length,1);assert.equal(f.notificationCallbacks.length,1);assert.equal(f.dataCallbacks.length,1);
  f.notificationCallbacks[0]({type:'repositoryChanged',repoId:'core-a'});
  assert.equal(f.batches.length,1);
  f.notificationCallbacks[0]({type:'globalNotificationsChanged'});
  assert.equal(f.batches.length,1);
  assert.ok(f.writes.some(write=>write.key==='coreDataChanges'));
  const snapshots=f.writes.filter(write=>write.key==='coreNotifications').length;
  f.fail();await assert.rejects(PageQueryService.query(f.config,[]),/整批读取失败/);
  assert.equal(f.writes.filter(write=>write.key==='coreNotifications').length,snapshots);
});

test('原位编辑重读卡片时同批发布同步提示，恢复基线后清除，失败保留快照',async()=>{
  const f=fixture(),service=f.load('services/TaskInlineService').TaskInlineService;
  const task={id:'editing',repoId:'core-a',filePath:'same.org',fileVersion:'new',tags:['新增标签']};
  let changed=true;
  f.query(batch=>batch.map(request=>request.type==='notification' ?
    {type:'notification',result:changed?[{type:'syncRequired'}]:[]} : {type:'task',result:{tasks:[task]}}));
  assert.equal(await service.reload({},task),task);
  assert.equal(f.batches.length,1);assert.deepEqual(f.batches[0].map(item=>item.type),['task','notification']);
  assert.deepEqual(f.writes.filter(write=>write.key==='coreNotifications').at(-1).value.notifications,[{type:'syncRequired'}]);
  changed=false;await service.reload({},task);
  assert.deepEqual(f.writes.filter(write=>write.key==='coreNotifications').at(-1).value.notifications,[]);
  const before=f.writes.filter(write=>write.key==='coreNotifications').length;
  f.fail();await assert.rejects(service.reload({},task),/整批读取失败/);
  assert.equal(f.writes.filter(write=>write.key==='coreNotifications').length,before);
});

test('显式通知请求保留原位置，任务和文件结果按输入下标对应',async()=>{
  const f=fixture(),PageQueryService=f.load('services/PageQueryService').PageQueryService;
  const values=await PageQueryService.query(f.config,[{type:'notification',query:{}},{type:'file',query:{includeFiles:[{repoId:'core-b',path:'same.org'}]}},{type:'task',query:{}}]);
  assert.equal(f.batches.length,1);assert.equal(f.batches[0].length,3);
  assert.deepEqual(values.map(item=>item.type),['notification','file','task']);
  assert.equal(values[1].result[0].repoId,'core-b');
});


test('收件箱移动浮层已打开时，列表刷新仍只有一个混合查询',async()=>{
  const f=fixture(),page=f.page('pages/Inbox',['loadRecords']),current={id:'selected'};
  page.selected={id:'selected',fileVersion:'previous'};
  f.query(batch=>batch.map(request=>{
    if(request.type==='notification')return {type:'notification',result:[]};
    if(request.type==='file')return {type:'file',result:[{repoId:'core-a',path:'same.org',tagOptions:[],tagGroups:[]}]};
    return {type:'task',result:{tasks:request.query.expression.startsWith('cr.')?[]:[current],categories:[]}};
  }));
  await page.loadRecords();
  assert.equal(page.message,'');assert.equal(f.batches.length,1);assert.equal(page.selected,current);
});


function pageObserver() {
  const source=fs.readFileSync(path.join(root,'components/AppShell.ets'),'utf8');
  const field=source.match(/  private pageChanged = [\s\S]*?\n  \}/)[0].replace('private ','');
  const changed=source.match(/  dataChanged\(\) \{[\s\S]*?\n  \}/)[0];
  const code=ts.transpileModule('export class Observer {\n'+field+'\n'+changed+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};
  vm.runInThisContext('(function(module,exports,uiObserver){'+code+'\n})')(module,module.exports,{RouterPageState:{ON_PAGE_HIDE:'hide',ON_PAGE_SHOW:'show'}});
  return Object.assign(new module.exports.Observer(),{pageIndex:0,pageVisible:false,refreshOnPageShow:true,
    dataRevision:0,dataChangeState:{revision:1},drawerOpen:false,refreshDataChanges(){},
    repositoryDataInvalidated(){if(this.drawerOpen)this.loadNavigation();else this.synchronized();}});
}

test('页面恢复时 onPageShow 与旧数据版本失效不会重复加载',async()=>{
  const f=fixture(),page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='today';page.drawerOpen=false;
  const observer=pageObserver();observer.synchronized=()=>page.loadTasks();
  observer.pageChanged({index:0,state:'show'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.batches.length,1);assert.equal(observer.dataRevision,1);
});

test('恢复页面时侧边栏仍打开，只加载侧边栏并复用首次出现时的加载',async()=>{
  const f=fixture(),page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='today';page.drawerOpen=true;
  const drawer=f.page('components/AppShell',['loadNavigation']);
  const observer=pageObserver();observer.drawerOpen=true;observer.loadNavigation=()=>drawer.loadNavigation();
  observer.synchronized=()=>page.loadTasks();
  await drawer.loadNavigation();observer.navigationLoadedOnAppear=true;observer.dataRevision=1;
  observer.pageChanged({index:0,state:'show'});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(f.batches.length,1);
  observer.pageChanged({index:0,state:'hide'});observer.pageChanged({index:0,state:'show'});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(f.batches.length,2);
  assert.ok(f.batches.every(batch=>batch.length===13));
});

test('存储库清单的全部仓库文件元信息与通知也使用同一批次',async()=>{
  const f=fixture(),service=f.load('services/NotebookService').NotebookService;
  const groups=await service.list(f.config);
  assert.equal(f.batches.length,1);assert.deepEqual(f.batches[0].map(item=>item.type),['file','notification']);
  assert.deepEqual(groups.map(group=>[group.repoId,group.files.length]),[['core-a',2],['core-b',1]]);
});


test('首次出现已加载时不重复读，加载期间的新数据版本仍触发更新',async()=>{
  const f=fixture(),page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);page.view='today';
  const observer=pageObserver();observer.synchronized=()=>page.loadTasks();observer.dataRevision=1;
  await page.loadTasks();observer.bodyLoadedOnAppear=true;
  observer.pageChanged({index:0,state:'show'});await new Promise(resolve=>setImmediate(resolve));assert.equal(f.batches.length,1);
  observer.bodyLoadedOnAppear=true;observer.dataChangeState={revision:2};
  observer.pageChanged({index:0,state:'show'});await new Promise(resolve=>setImmediate(resolve));assert.equal(f.batches.length,2);
});


test('今天同批读取来源顺序与优先级顺序，标签切换只重组当前快照', async () => {
  const f=fixture(),page=f.page('pages/TaskOverview',['loadTasks','supportsTagFilter','applyTagFilter']);
  const values=[plannedTask('low','core-a','plain.org','工作'), plannedTask('high','core-a','project.org','工作','项目'),
    plannedTask('default','core-a','plain.org','工作'), plannedTask('project-low','core-a','project.org','工作','项目')];
  values.forEach(task=>{task.tags=task.id==='default'?['隐藏']:['显示'];});
  f.query(batch=>batch.map(request=>request.type==='notification'?{type:'notification',result:[]}:
    {type:'task',result:{tasks:request.query.expression.endsWith('o.priority')?[values[1],values[2],values[3],values[0]]:values,categories:[]}}));
  page.view='today'; await page.loadTasks();
  assert.equal(page.message,'');
  assert.equal(f.batches.length,1);
  assert.equal(f.batches[0][1].query.expression,'(s.le.today or d.le.today) o.priority');
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['default'],['high','project-low'],['low']]);
  page.applyTagFilter({tags:['显示'],includeUntagged:false});
  assert.equal(f.batches.length,1);
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['low'],['high','project-low']]);
});
