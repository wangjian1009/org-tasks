// 验证各任务页面、最近新增、侧边栏与角标消费同一应用级数据集。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test, afterEach } = require('node:test');
const sidebarInstances = [], appClosers = [];
afterEach(async () => { for (const manager of sidebarInstances.splice(0)) manager.close(); await Promise.all(appClosers.splice(0).map(close=>close())); });
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-page-queries.cjs\n验证页面数据集定义、独立事件、文件有效性、共享通知及侧边栏批次位置。');
  process.exit(0);
}
const root = path.resolve(__dirname, '../entry/src/main/ets');
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function fixture() {
  const batches = [], writes = [], notificationCallbacks = [], dataCallbacks = [], configCallbacks = new Set(), disk = new Map();
  const repos = [{ id:'core-a',rootDirectory:'/a' },{ id:'core-b',rootDirectory:'/b' }];
  const config = { repos:[{id:'host-a',rootDirectory:'/a',name:'仓库甲',webdavEnabled:true,webdavUrl:'https://example.test/dav/'},{id:'host-b',rootDirectory:'/b',name:'仓库乙'}],todoDefaults:'',
    inboxRepoId:'host-a',inboxFile:'same.org',somedayRepoId:'host-b',somedayFile:'same.org',memoRepoId:'host-a',memoFile:'memo.org' };
  let missing = false, fail = false, customQuery, inlineActive = false;
  const metadata = [{repoId:'core-a',path:'same.org',tagOptions:[],tagGroups:[],isIgnore:false},
    {repoId:'core-b',path:'same.org',tagOptions:[],tagGroups:[],isIgnore:false},
    {repoId:'core-a',path:'memo.org',tagOptions:['未使用标签'],tagGroups:[['互斥甲','互斥乙']],isIgnore:false}];
  metadata.forEach(file=>{Object.setPrototypeOf(file,{project:()=>null});});
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
    async watchDataChanges(callback) { dataCallbacks.push(callback); return dataCallbacks.length; }, stopWatchingDataChanges() {}, async watchExternalFileChanges() { return 1; }, stopWatchingExternalFileChanges() {}
  };
  const native = { taskResult:value=>{assert.equal(value.type,'task');return value.result;},
    fileResult:value=>{assert.equal(value.type,'file');for(const file of value.result)if(!file.project)Object.defineProperty(file,'project',{value(){return this.projectName??null;},enumerable:false});return value.result;},
    notificationResult:value=>{assert.equal(value.type,'notification');return value.result;},
    coreErrorMessage:error=>error.message,
    NativeCoreService:{async workspaceFor(actual) { assert.equal(actual,config.repos); return workspace; },
      async query(actual,batch) { assert.equal(actual,config.repos); return workspace.query(batch); }} };
  const managers=[];
  // 页面测试以查询定义集合提供替身结果；真实独立订阅由 DataSet 集成测试验证。
  const managerFactory={DataSetManager:{create(context,pageName,source){
    const data=new Map(),sets=new Map(),overrides=new Map();let ready=false,started,definitions=[];
    const emit=name=>{for(const fn of sets.get(name)?.listeners??[])fn({name,type:'refresh'})};
    const query=async(requestSet,requestToken)=>{
      let nextDefinitions=typeof source==='function'?await source(config):source;
      nextDefinitions=nextDefinitions.filter(item=>!overrides.has(item.name));
      for(const definition of overrides.values())if(definition)nextDefinitions.push(definition);
      if(requestSet)nextDefinitions=nextDefinitions.filter(item=>item.name===requestSet);
      for(const item of nextDefinitions)manager.dataSet(item.name);
      // 模拟工作线程的请求别名解析，页面本身没有仓库列表读取。
      const requests=nextDefinitions.map(item=>{
        const request=structuredClone(item.query),bindings=item.repositoryBindings??[];
        const resolve=id=>{const binding=bindings.find(binding=>binding.id===id);return binding?repos.find(repo=>repo.rootDirectory===binding.rootDirectory).id:id;};
        if(request.repoIds)request.repoIds=request.repoIds.map(resolve);
        for(const key of ['includeFiles','excludeFiles'])for(const file of request.query[key]??[])file.repoId=resolve(file.repoId);
        return request;
      });
      const results=requests.length?await workspace.query(requests):[];
      for(const result of results)if(result.type==='file')native.fileResult(result);
      if(requestSet&&sets.get(requestSet)?.request!==requestToken)return;
      definitions=nextDefinitions;
      for(let i=0;i<definitions.length;i++)data.set(definitions[i].name,{data:results[i],version:1});
      for(const name of sets.keys())if((!requestSet||requestSet===name)&&!definitions.some(item=>item.name===name))data.set(name,{data:{type:'task',result:{tasks:[],categories:[]}},version:1});
      ready=true;for(const set of sets.values())set.error='';for(const name of sets.keys())emit(name);
    };
    const configChanged=()=>{started=undefined;manager.start()};configCallbacks.add(configChanged);
    const manager={hasValidScope:()=>true,isReady:()=>ready,get:name=>data.get(name),
      dataSet(name){if(!sets.has(name))sets.set(name,{identity:name,listeners:new Set(),error:'',hasValidScope:()=>true,isReady:()=>ready,
        get data(){return data.get(name)?.data},get version(){return data.get(name)?.version??0},get(name){return data.get(name)},getConfirmed(){return data.get(name)},taskKey:id=>id,
        subscribe(fn){this.listeners.add(fn);return()=>this.listeners.delete(fn)},
        async refresh(){try{await query()}catch(error){this.error=error.message;emit(name)}},
        async setQuery(value){return manager.setQuery(name,value)}
      });return sets.get(name)},
      async setQuery(name,value,repositoryBindings=[]){const set=manager.dataSet(name),request=Symbol();set.request=request;overrides.set(name,value?{name,query:value,repositoryBindings}:undefined);try{await query(name,request);if(set.request===request)emit(name)}catch(error){if(set.request===request){set.error=error.message;emit(name)}}},
      async start(){if(!started)started=query();try{return await started}catch(error){started=undefined;throw error}},
      async refresh(){started=query();try{return await started}catch(error){for(const set of sets.values())set.error=error.message;for(const name of sets.keys())emit(name);throw error}},async close(){for(const set of sets.values())set.listeners.clear();configCallbacks.delete(configChanged)}};
    managers.push({manager,pageName,definitions});return manager;
  }}};
  let regionOrder=null; const orderCallbacks=new Set();
  const cache = new Map();
  const storage = {setOrCreate(key,value){writes.push({key,value});}};
  function load(name, source) {
    const filename = path.join(root,name+'.ets');
    if (!source && cache.has(filename)) return cache.get(filename).exports;
    const module={exports:{}};
    if (!source) cache.set(filename,module);
    const code=transpileFixture(ts, source||fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    const requireLocal=dependency=>{
      if (dependency==='@ohos.arkui.UIContext') return {FrameCallback:class{}};
      if (dependency.endsWith('/RegionOrderService')) return {RegionOrderService:{async load(){return regionOrder;},watchChanges(fn){orderCallbacks.add(fn);},stopWatchingChanges(fn){orderCallbacks.delete(fn);}}};
      if (dependency.endsWith('/PageDataCache')) return { PageDataCache: class {
        constructor(_, name, scope) { this.key = name + scope; }
        async read() { return structuredClone(disk.get(this.key)); }
        async write(value, guard) { if (guard()) disk.set(this.key, structuredClone(value)); }
      } };
      if (dependency.endsWith('/PageDataSnapshot')) return {
        cacheDataSet: (name, result) => ({name, ...result}), restoreDataSet: ({name, ...result}) => result
      };
      if (dependency.endsWith('/ReminderManager')) return {ReminderManager:{register(){},start(){},async refresh(){},async stop(){}}};
      if (dependency.endsWith('/TrashSettingsService')) return {TrashSettingsService:{retentionDays:async()=>30}};
      if (dependency.endsWith('/TrashService')) return {TrashService:{perform:async()=>{}}};
      if (dependency.endsWith('/CaptureService') || dependency.endsWith('/InboxService')) return {};
      if (dependency.endsWith('/DataSetManager')) return managerFactory;
      if (dependency.endsWith('/NativeCoreService')||dependency==='./NativeCoreService') return native;
      if (dependency.endsWith('/AppConfigService')||dependency==='./AppConfigService') return {AppConfigService:{async load(){return config;},async save(){},watchChanges(fn){configCallbacks.add(fn);},stopWatchingChanges(fn){configCallbacks.delete(fn);}}};
      if (dependency.endsWith('/TaskInlineService')) return {TaskInlineSession:{active:()=>inlineActive,end:async()=>true}};
      if (dependency.startsWith('.')) return load(path.relative(root,path.resolve(path.dirname(filename),dependency)));
      throw new Error('缺少替身: '+dependency);
    };
    vm.runInThisContext('(function(require,module,exports,AppStorage,setInterval){'+code+'\n})',{filename})(requireLocal,module,module.exports,storage,(fn,ms)=>{const timer=setInterval(fn,ms);timer.unref();return timer;});
    if(name==='services/AppDataManager')appClosers.push(()=>module.exports.AppDataManager.close());
    return module.exports;
  }
  function page(name, methods) {
    const filename=path.join(root,name+'.ets'),text=fs.readFileSync(filename,'utf8');
    const prelude=text.slice(0,text.search(/^@(?:Entry|Component)/m));
    if(name==='components/AppShell'&&methods.includes('loadNavigation'))methods=[...methods,'navigationDataManager'];
    if(name==='components/TaskPageContent'&&methods.includes('loadTasks'))methods=[...new Set([...methods.filter(name=>name!=='todayInlineChanged'),'applyPageSnapshot','pageInlineChanged','taskDataSet','supportsBatchActions'])];
    if(name==='pages/Inbox'&&methods.includes('loadRecords'))methods=[...methods,'applyPageSnapshot','prepareRecentLayout'];
    const chunks=methods.map(method=>{
      const oneLine=text.split('\n').find(line=>new RegExp('^  (?:private )?'+method+'\\(').test(line)&&line.trim().endsWith('}'));
      if(oneLine)return oneLine;
      const match=text.match(new RegExp('  (?:async )?'+method+'\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));
      assert.ok(match,'未找到方法 '+method); return match[0];
    });
    const View=load(name,prelude+'\nexport class QueryPage {\n'+chunks.join('\n')+'\n}').QueryPage;
    const view=Object.assign(new View(),{stops:[],selectedPlanRegion:null,planGroups:[],planRegionOptions:[],logbookTaskGroups:[],listHeight:0,recentLayoutReady:false,recentLayoutPending:false,requestId:0,tasks:[],visibleTasks:[],records:[],recentGroups:[],
      selectedTags:[],includeUntagged:false,tagOptions:[],tagGroups:[],sections:[],timedItems:[],priorityOrder:[],visible:false,
      getUIContext:()=>({getHostContext:()=>({})}),selection:{selecting:false,busy:false,blocked:()=>false,connect(){},close(){}},connectSelection(){},closeTargetPopup(){},measureRows(){},async openEntryMemo(){}});
    if (name === 'components/AppShell' && methods.includes('loadNavigation')) sidebarInstances.push(view.navigationDataManager());
    return view;
  }
  let pendingExternal;
  const external=()=>{if(!pendingExternal)pendingExternal=new Promise(resolve=>setTimeout(async()=>{pendingExternal=undefined;await Promise.all(managers.filter(item=>item.pageName==='app').map(item=>item.manager.refresh().catch(()=>{})));resolve();},0));return pendingExternal;};
  return {managers,disk,order(value){regionOrder=value;for(const fn of orderCallbacks)fn(value);},configChanged(){for(const fn of configCallbacks)fn();},emit(){for(const fn of dataCallbacks)fn({repoId:'core-a',operationId:'http/external'});return external();},config,batches,writes,workspace,load,page,notificationCallbacks,dataCallbacks,inline(value){inlineActive=value;},
    missing(){missing=true;}, fail(){fail=true;}, query(fn){customQuery=fn;}};
}

for (const view of ['today','planned','anytime','logbook','someday','memo']) {
  test(view+(view==='today'?' 通过管理类启动固定数据集':' 首次加载复用 App 任务与文件数据集'),async()=>{
    const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
    page.view=view; await page.loadTasks();
    assert.equal(page.message,'');
    assert.equal(f.batches.length,1);
    assert.equal(page.dataManager,f.load('services/AppDataManager').AppDataManager.shared({}).manager);

    assert.equal(page.needsConfiguration,false,'有效空文件不是失效文件');
    page.applyTagFilter({tags:[],includeUntagged:false});
    assert.equal(f.batches.length,1,'展示层标签切换不增加查询');
    if(view==='someday') {
      assert.ok(f.batches[0].some(item=>item.repoIds?.[0]==='core-b'&&item.query.expression==='it.todo'&&item.query.includeFiles[0].path==='same.org'));
    }
    if(view==='memo')assert.deepEqual(page.tagOptions,['未使用标签']);
  });
}

test('今天排序候选通过 Core 排除三个特殊入口文件，宿主 ID 按仓库解析且同名普通文件保留',async()=>{
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='today';await page.loadTasks();
  assert.deepEqual(f.batches[0].find(request=>request.type==='file'&&!request.query.isProject&&request.query.excludeFiles?.length),{type:'file',query:{excludeFiles:[
    {repoId:'core-a',path:'same.org'},{repoId:'core-b',path:'same.org'},{repoId:'core-a',path:'memo.org'}]}});
  const exclusions=f.load('services/FileTargetService').configuredSpecialFileExclusions;
  f.config.somedayRepoId=f.config.inboxRepoId;f.config.somedayFile=f.config.inboxFile;
  f.config.memoRepoId='missing';
  assert.deepEqual(exclusions(f.config),{files:[{repoId:'host-a',path:'same.org'}],repositoryBindings:[{id:'host-a',rootDirectory:'/a'}]});
});

function plannedTask(id, repoId, filePath, category, projectName = null) {
  return { id, repoId, filePath, category, project: () => projectName, heading: id,
    scheduled: '2099-01-01', deadline: '', tags: [] };
}

test('计划分类与项目单选互斥，候选保持完整，结果直接使用 Core 快照', async () => {
  const f = fixture(), page = f.page('components/TaskPageContent',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  const tasks = [plannedTask('a','core-a','project.org','工作','项目甲'),
    plannedTask('b','core-b','project.org','生活','项目甲'), plannedTask('c','core-a','plain.org',null)];
  // 故意返回不符合分类的任务，确认页面不会重新执行分类过滤。
  const categoryTasks = [tasks[2]], projectTasks = [tasks[0]];
  f.query(batch => batch.map((request, index) => request.type === 'file' ?
    {type:'file',result:[]} : {type:'task',result:{tasks:request.query.categories ? categoryTasks : request.repoIds ? projectTasks : tasks,categories:[]}}));
  page.view = 'planned';
  await page.loadTasks();
  const keys = page.planRegionOptions.map(region => region.key);
  const category = page.planRegionOptions.find(region => region.kind === 'category' && region.category === '工作');
  const project = page.planRegionOptions.find(region => region.kind === 'project' && region.repoId === 'core-a');
  await page.selectPlanRegion(category);
  assert.equal(page.tasks, categoryTasks);
  assert.deepEqual(f.batches[1].map(item => item.type), ['task']);
  assert.deepEqual(f.batches[1][0].query.categories, ['工作']);
  assert.equal(f.batches[1][0].repoIds, undefined);
  assert.deepEqual(page.planRegionOptions.map(region => region.key), keys);
  await page.selectPlanRegion(project);
  assert.equal(page.selectedPlanRegion.key, project.key);
  assert.equal(page.tasks, projectTasks);
  assert.equal(f.batches[2][0].query.categories, undefined, '项目选择替换分类条件');
  assert.deepEqual(f.batches[2][0].repoIds, ['core-a']);
  assert.deepEqual(f.batches[2][0].query.includeFiles,[{repoId:'core-a',path:'project.org'}]);
  assert.ok(f.batches[2][0].query.expression.includes('.is.habit'));
  await page.selectPlanRegion(null);
  assert.equal(page.tasks, tasks);
  assert.equal(page.selectedPlanRegion, null);
  assert.equal(f.batches.length,3,'取消筛选直接展示范围数据集，不重新查询');
});

test('计划未分类与字面同名分类保持独立，项目路径通过结构化范围传递', () => {
  const f = fixture(), { plannedRegionQuery } = f.load('services/TaskViewQueries');
  const region = { key:'category',kind:'category',category:null,title:'未分类',repoId:'',filePath:'' };
  assert.deepEqual(plannedRegionQuery(region).query.categories, [null]);
  assert.deepEqual(plannedRegionQuery({...region,category:'未分类'}).query.categories, ['未分类']);
  const project = plannedRegionQuery({...region,kind:'project',repoId:'core-b',filePath:'项目 (a) "b"\\c.org'});
  assert.deepEqual(project.repoIds, ['core-b']);
  assert.deepEqual(project.query.includeFiles, [{repoId:'core-b',path:'项目 (a) \"b\"\\c.org'}]);
});

test('计划刷新清除已消失的选择，同批回退全部，读取失败后可重试', async () => {
  const f = fixture(), page = f.page('components/TaskPageContent',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  let tasks = [plannedTask('a','core-a','project.org','工作','项目甲')];
  f.query(batch => batch.map(request => request.type === 'file' ?
    {type:'file',result:[]} : {type:'task',result:{tasks,categories:[]}}));
  page.view = 'planned';
  await page.loadTasks();
  const selected = page.planRegionOptions.find(region => region.kind === 'project');
  await page.selectPlanRegion(selected);
  tasks = [plannedTask('b','core-b','plain.org','生活')];
  await page.dataManager.refresh();await new Promise(resolve=>setTimeout(resolve,1));
  assert.equal(f.batches.length, 3);
  assert.equal(page.selectedPlanRegion, null);
  assert.equal(page.tasks, tasks);
  tasks=[plannedTask('return','core-a','project.org','工作','项目甲'),...tasks];
  await page.dataManager.refresh();await new Promise(resolve=>setTimeout(resolve,1));
  assert.equal(page.selectedPlanRegion,null,'失效候选重新出现时不恢复已经清除的选择');
  assert.equal(page.tasks,tasks);
  let fail = true;
  f.query(batch => {
    if (fail) throw new Error('读取失败');
    return batch.map(request => request.type === 'file' ? {type:'file',result:[]} :
      {type:'task',result:{tasks,categories:[]}});
  });
  const retrySelection=page.planRegionOptions[0];
  await page.selectPlanRegion(retrySelection);
  assert.match(page.message, /读取失败/);
  assert.equal(page.selectedPlanRegion?.key,retrySelection.key,'查询失败不当作候选失效');
  fail = false;
  await page.tasksDataSet.refresh();
  assert.equal(page.message, '');
  assert.equal(page.tasks, tasks);
});

test('计划快速切换时迟到结果不覆盖最后一次选择与任务', async () => {
  const f = fixture(), page = f.page('components/TaskPageContent',
    ['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
  const tasks = [plannedTask('a','core-a','a.org','工作','项目甲'),
    plannedTask('b','core-b','b.org','生活','项目乙')];
  let release;
  f.query(async batch => {
    const selected = batch.find(request=>request.type==='task'&&(request.query.categories||request.repoIds));
    if (selected?.query.categories) await new Promise(resolve => { release = resolve; });
    return batch.map((request,index) => request.type === 'file' ? {type:'file',result:[]} :
      {type:'task',result:{tasks:request.query.categories||request.repoIds ? [selected?.repoIds ? tasks[1] : tasks[0]] : tasks,categories:[]}});
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

test('日志簿向 Core 请求 Done 与 Cancel 分类，每个返回任务只展示一次关闭记录', async () => {
  const f = fixture(), page = f.page('components/TaskPageContent', ['loadTasks','supportsTagFilter','applyTagFilter']);
  const tasks = [
    { id:'finished', project:()=>null, state:{name:'CUSTOM_FINISH',category:'Done'}, createdAt:1_700_000_000_000, closedAt:1_700_003_600_000 },
    { id:'cancelled', project:()=>null, state:{name:'CUSTOM_ABORT',category:'Cancel'}, createdAt:1_600_000_000_000, closedAt:1_700_000_000_000 },
    { id:'older', project:()=>null, state:{name:'OTHER_CANCEL',category:'Cancel'}, createdAt:1_600_000_000_000, closedAt:null }
  ];
  f.query(batch => batch.map(request => request.type === 'task' ?
    {type:'task',result:{tasks,categories:[]}} : {type:'file',result:[]}));
  page.view = 'logbook';
  await page.loadTasks();
  assert.equal(page.message, '');
  assert.equal(f.batches.length, 1);
  assert.ok(f.batches[0].some(request=>request.query.expression==='it.done'));
  assert.equal(page.tasks, tasks);
  const items = page.logbookTaskGroups.flatMap(group => group.items);
  assert.equal(items.length, tasks.length);
  assert.deepEqual(items.map(item => item.task), tasks);
  assert.equal(items[2].timestamp, null);
});

test('收件箱本页、最近新增、文件元信息与通知只调用一次批量查询',async()=>{
  const f=fixture(),page=f.page('pages/Inbox',['loadRecords']);
  await page.loadRecords();
  assert.equal(page.message,'');assert.equal(f.batches.length,1);
  assert.equal(page.dataManager,f.load('services/AppDataManager').AppDataManager.shared({}).manager);
  assert.deepEqual(f.batches[0].find(item=>item.query.expression==='cr.ge.-2d cr.le.today .o.created').query.excludeFiles,[{repoId:'core-a',path:'same.org'}]);
  assert.equal(page.needsConfiguration,false);
});

test('侧边栏复用全局批次与今天 DataSet，跨仓库同名入口保持隔离',async()=>{
 const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);await page.loadNavigation();
 const batch=f.batches[0];assert.equal(page.navMessage,'');assert.equal(f.batches.length,1);
 assert.equal(batch.filter(request=>request.query.expression==='.it.done .i.wait (s.le.today or d.le.today)').length,1);
 assert.deepEqual(batch.find(request=>request.query.isProject).query,{isProject:true,excludeFiles:[]});
 assert.ok(batch.some(request=>request.query.expression==='it.done'));
 assert.ok(batch.some(request=>request.repoIds?.[0]==='core-a'&&request.query.expression===''));
 assert.ok(batch.some(request=>request.repoIds?.[0]==='core-b'&&request.query.includeFiles[0].path==='same.org'));
 assert.equal(page.inboxCount,0);assert.equal(page.somedayCount,0);assert.equal(page.memoCount,0);
 const today=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);today.view='today';await today.loadTasks();
 assert.equal(f.batches.length,1);assert.equal(page.sidebarManager.app.dataSet('todayTasks'),today.taskDataSet());
});

test('废纸篓计数使用全局命名数据集，关闭抽屉后继续更新，失败保留确认值',async()=>{
 const f=fixture();f.config.repos.push({id:'org-tasks-system',rootDirectory:'/system',webdavEnabled:false});
 (await f.workspace.repos()).push({id:'core-system',rootDirectory:'/system'});let count=3,fail=false;
 f.query(batch=>{if(fail)throw new Error('计数读取失败');return batch.map(request=>request.type==='task'?{type:'task',result:{tasks:Array(request.query.expression==='.o.deleted'?count:0).fill({})}}:{type:request.type,result:[]});});
 const page=f.page('components/AppShell',['loadNavigation']);await page.loadNavigation();
 assert.equal(page.trashCount,3);assert.equal(f.batches.length,1);
 assert.deepEqual(f.batches[0].find(request=>request.query.expression==='.o.deleted').query.includeFiles,[{repoId:'core-system',path:'trash.org'}]);
 page.sidebarManager.close();const restored=f.page('components/AppShell',['loadNavigation']);await restored.loadNavigation();assert.equal(restored.trashCount,3);assert.equal(f.batches.length,1);
 count=1;await f.emit();await restored.sidebarManager.start();assert.equal(restored.trashCount,1);
 fail=true;await f.emit();await restored.sidebarManager.start();assert.equal(restored.trashCount,1);assert.match(restored.navMessage,/计数读取失败/);
 fail=false;count=0;await f.emit();await restored.sidebarManager.start();assert.equal(restored.trashCount,0);
});

test('侧边栏采用共享分区与项目顺序，保存和恢复默认不增加 Core 查询',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  const files=[{repoId:'core-a',path:'a.org',category:'工作',projectName:'甲'},
    {repoId:'core-b',path:'b.org',category:'工作',projectName:'乙'},
    {repoId:'core-a',path:'c.org',category:'生活',projectName:'生活项目'}];
  f.query(batch=>sidebarResults(batch,files));await page.loadNavigation();
  const calls=f.batches.length;
  const order={version:1,regions:['category:生活','category:工作'],projects:[{region:'category:工作',keys:[JSON.stringify(['core-a','a.org'])]}]};
  f.order(order);
  assert.deepEqual(page.projectGroups.map(group=>group.category),['生活','工作']);
  assert.deepEqual(page.projectGroups[1].files.map(file=>file.path),['a.org','b.org']);
  await page.loadNavigation();assert.equal(f.batches.length,calls);
  f.order(null);
  assert.deepEqual(page.projectGroups.map(group=>group.category),['工作','生活']);
  assert.deepEqual(page.projectGroups[0].files.map(file=>file.path),['b.org','a.org']);
  assert.equal(f.batches.length,calls);
});

test('今天红色徽标独立消费关注任务的 Core 结果，不按今天列表重筛或改动总数',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  f.query(batch=>batch.map((request,index)=>request.type==='task'
    ? {type:'task',result:{tasks:Array(request.query.expression==='.it.done .i.wait (s.le.today or d.le.today)'?8:request.query.expression==='it.todo .i.wait ((is.habit s.lt.tomorrow) or d.lt.tomorrow)'?3:0).fill({}),categories:[]}}
    : {type:request.type,result:[]}));
  await page.loadNavigation();
  assert.equal(page.todayCount,8);assert.equal(page.todayAttentionCount,3);
  assert.equal(f.batches.length,1);
});

test('项目按 Core 文件结果保留顺序、空名称和同名身份，新快照清除已删除入口',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  const projects=[{repoId:'core-a',path:'one.org',projectName:'同名项目'},
    {repoId:'core-b',path:'one.org',projectName:'同名项目'},
    {repoId:'core-a',path:'two.org',projectName:''}];
  let current=projects;
  f.query(batch=>batch.map(request=>request.type==='task'?{type:'task',result:{tasks:[],categories:[]}}:
    request.type==='notification'?{type:'file',result:[]}:
    {type:'file',result:request.query.isProject?current:[]}));
  await page.loadNavigation();
  assert.equal(page.projects,current);
  current=[];await f.emit();await page.sidebarManager.start();
  assert.deepEqual(page.projects,[]);
  assert.deepEqual(page.projectGroups,[]);
});

test('项目按文件 CATEGORY 展示分区，保留同名身份与组内顺序，未分类置末',()=>{
  const f=fixture(),{projectSections}=f.load('ui/NotebookPresentation');
  const files=[{repoId:'a',path:'empty.org',category:null},{repoId:'a',path:'work.org',category:'工作',projectName:'同名'},
    {repoId:'b',path:'personal.org',category:'个人'}, {repoId:'b',path:'work.org',category:'工作',projectName:'同名'},
    {repoId:'a',path:'blank.org',category:''},{repoId:'a',path:'named.org',category:'未分类'}];
  for(const file of files)file.project=()=>file.projectName??null;
  const groups=projectSections(files);
  assert.deepEqual(groups.map(group=>group.category),['个人','工作','未分类','']);
  assert.deepEqual(groups[1].files,[files[1],files[3]]);
  assert.deepEqual(groups[3].files,[files[4],files[0]]);
  assert.deepEqual(projectSections([]),[]);
});

test('项目进度按 Core 分类汇总，取消和未分类状态只计入总数',()=>{
  const f=fixture(),{fileTaskCount,fileTaskProgress}=f.load('ui/NotebookPresentation');
  const file={taskStateCounts:[{state:'FINISHED',category:'Done',count:3},{state:'DONE',category:null,count:2},
    {state:'ABORT',category:'Cancel',count:1},{state:'NEXT',category:'Todo',count:4}]};
  assert.equal(fileTaskCount(file),10);assert.equal(fileTaskProgress(file),'3/10');
  assert.equal(fileTaskProgress({taskStateCounts:[]}),'0/0');
});

test('笔记本的文件路径显示解码 Unicode 字符并保留其他路径字符', () => {
  const {filePathLabel} = fixture().load('ui/NotebookPresentation');
  assert.equal(filePathLabel('记录/%E6%97%A5%E6%8A%A5.org'), '记录/日报.org');
  assert.equal(filePathLabel('%E5%B7%A5%E4%BD%9C/%F0%A0%80%80%2F%25.org'), '工作/𠀀%2F%25.org');
  assert.equal(filePathLabel('中文%20名称%ZZ.org'), '中文%20名称%ZZ.org');
  assert.equal(filePathLabel('%FF-%E6%97%A5.org'), '%FF-日.org');
});

test('失效文件和未配置文件不退回全仓库任务，通知仍在同一个批次内加载',async()=>{
  const f=fixture();f.missing();const page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='memo';await page.loadTasks();assert.equal(page.needsConfiguration,true);assert.equal(f.batches.length,1);
  f.config.memoRepoId='';f.configChanged();await page.loadTasks();assert.equal(f.batches.length,2);
  assert.ok(!f.batches[1].some(item=>item.repoIds?.includes('core-a')&&item.query.includeFiles?.some(file=>file.path==='memo.org')));
});

test('批次失败保留通知，页面查询不重复注册应用级通知订阅',async()=>{
  const f=fixture(),PageQueryService=f.load('services/PageQueryService').PageQueryService;
  await PageQueryService.query(f.config,[{type:'task',query:{}}]);
  assert.equal(f.batches.length,1);assert.equal(f.notificationCallbacks.length,0);assert.equal(f.dataCallbacks.length,1);
  f.dataCallbacks[0]({repoId:'core-a',operationId:null});
  assert.equal(f.batches.length,1);
  assert.equal(f.writes.some(write=>write.key==='coreDataChanges'),false);
  const snapshots=f.writes.filter(write=>write.key==='coreNotifications').length;
  f.fail();await assert.rejects(PageQueryService.query(f.config,[]),/整批读取失败/);
  assert.equal(f.writes.filter(write=>write.key==='coreNotifications').length,snapshots);
});

test('页面批次只读取任务与文件，不能写共享通知快照',async()=>{
  const f=fixture(),service=f.load('services/PageQueryService').PageQueryService;
  const values=await service.query(f.config,[{type:'file',query:{includeFiles:[{repoId:'core-b',path:'same.org'}]}},{type:'task',query:{}}]);
  assert.equal(f.batches.length,1);assert.deepEqual(f.batches[0].map(item=>item.type),['file','task']);
  assert.deepEqual(values.map(item=>item.type),['file','task']);assert.equal(values[0].result[0].repoId,'core-b');
  assert.equal(f.writes.some(write=>write.key==='coreNotifications'),false);
});

test('收件箱列表通过同一混合查询接收当前快照，不再维护页面移动源副本',async()=>{
  const f=fixture(),page=f.page('pages/Inbox',['loadRecords']),current={id:'selected'};
  page.selected={id:'selected',fileVersion:'previous'};
  f.query(batch=>batch.map(request=>{
    if(request.type==='notification')return {type:'file',result:[]};
    if(request.type==='file')return {type:'file',result:[{repoId:'core-a',path:'same.org',tagOptions:[],tagGroups:[]}]};
    return {type:'task',result:{tasks:request.query.expression.startsWith('cr.')?[]:[current],categories:[]}};
  }));
  await page.loadRecords();
  assert.equal(page.message,'');assert.equal(f.batches.length,1);assert.deepEqual(page.records,[current]);
});


test('页面重复出现只复用管理对象，AppShell 不再持有底层刷新机制',async()=>{
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  page.view='anytime';await page.loadTasks();const manager=page.dataManager;await page.loadTasks();
  assert.equal(page.dataManager,manager);assert.equal(f.batches.length,1);
  const shell=fs.readFileSync(path.join(root,'components/AppShell.ets'),'utf8');
  assert.doesNotMatch(shell,/CoreDataChangeService|coreDataChanges|managedBody|refreshOnPageShow|synchronized|repositoryDataInvalidated/);
  await manager.close();
});

test('存储库清单只批量读取全部仓库文件元信息',async()=>{
  const f=fixture(),service=f.load('services/NotebookService').NotebookService;
  const groups=await service.list(f.config);
  assert.equal(f.batches.length,1);assert.deepEqual(f.batches[0].map(item=>item.type),['file']);
  assert.deepEqual(groups.map(group=>[group.repoId,group.files.length]),[['core-a',2],['core-b',1]]);
});


test('今天同批读取来源顺序与优先级顺序，标签切换只重组当前快照', async () => {
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  const values=[plannedTask('low','core-a','plain.org','工作'), plannedTask('high','core-a','project.org','工作','项目'),
    plannedTask('default','core-a','plain.org','工作'), plannedTask('project-low','core-a','project.org','工作','项目')];
  values.forEach(task=>{task.tags=task.id==='default'?['隐藏']:['显示'];});
  f.query(batch=>batch.map(request=>request.type==='notification'?{type:'file',result:[]}:
    {type:'task',result:{tasks:request.query.expression?.endsWith('o.priority')?[values[1],values[2],values[3],values[0]]:values,categories:[]}}));
  page.view='today'; await page.loadTasks();
  assert.equal(page.message,'');
  assert.equal(f.batches.length,1);
  assert.equal(f.batches[0][1].query.expression,'.it.done .i.wait (s.le.today or d.le.today) o.priority');
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['high','project-low'],['default'],['low']]);
  page.applyTagFilter({tags:['显示'],includeUntagged:false});
  assert.equal(f.batches.length,1);
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['high','project-low'],['low']]);
});

for (const view of ['anytime', 'waiting']) {
test(`${view} 通过 Core 按优先级和创建时间倒序查询，项目分组与标签筛选保持原顺序`, async () => {
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  const values=[plannedTask('high-new','core-a','plain.org','工作'), plannedTask('project-high','core-a','project.org','工作','项目'),
    plannedTask('high-old','core-a','plain.org','工作'), plannedTask('project-low','core-a','project.org','工作','项目')];
  values.forEach(task=>{task.tags=task.id==='high-new'?['隐藏']:['显示'];});
  f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:
    {type:'task',result:{tasks:values,categories:[]}}));
  page.view=view; await page.loadTasks();
  assert.equal(page.message,'');
  assert.ok(f.batches[0].some(item=>item.query.expression===(view === 'waiting' ? 'i.wait o.priority .o.created' : 'it.todo s.none d.none o.priority .o.created')));
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['high-new'],['high-old'],['project-high','project-low']]);
  page.applyTagFilter({tags:['显示'],includeUntagged:false});
  assert.equal(f.batches.length,1);
  assert.equal(page.tasks.length,4);
  assert.deepEqual(page.sections[0].groups.map(group=>group.items.map(item=>item.task.id)),
    [['high-old'],['project-high','project-low']]);
});
}


test('今天页面将当日时刻接入顶部，筛选后清空时间区但仍保留基础快照', async () => {
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
  const today=f.load('ui/Theme').localDate(new Date());
  const values=[plannedTask('timed','core-a','project.org','工作','项目'),plannedTask('ordinary','core-a','plain.org','个人')];
  values[0].scheduled=today;values[0].tags=['工作'];
  values[0].editContent={scheduledPlanning:{date:today,time:{start:'09:30',end:'10:00'}},deadlinePlanning:null};
  values[1].tags=['个人'];
  f.query(batch=>batch.map(request=>request.type==='notification'?{type:'file',result:[]}:
    {type:'task',result:{tasks:values,categories:[]}}));
  page.view='today';page.referenceTime=new Date(2000,0,1).getTime();await page.loadTasks();
  assert.equal(page.message,'');
  assert.deepEqual(page.timedItems.map(item=>item.task.id),['timed']);
  assert.deepEqual(page.sections.flatMap(section=>section.items.map(item=>item.task.id)),['ordinary']);
  page.applyTagFilter({tags:['个人'],includeUntagged:false});
  assert.deepEqual(page.timedItems,[]);assert.equal(page.tasks.length,2);assert.equal(f.batches.length,1);
  page.applyTagFilter({tags:[],includeUntagged:false});
  assert.equal(page.timedItems[0].task,values[0]);assert.equal(f.batches.length,1);
});

test('今天编辑会话期间数据集继续更新，列表重排等会话结束后应用且不重新查询',async()=>{
  const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter','todayInlineChanged']);
  const original=[plannedTask('old','core-a','plain.org','工作')];let rows=original;
  f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:{type:'task',result:{tasks:rows,categories:[]}}));
  page.view='today';await page.loadTasks();assert.equal(page.tasks,original);
  f.inline(true);page.pageInlineActive='editing';page.pageReady=false;rows=[plannedTask('new','core-a','plain.org','工作'),...original];
  await page.dataManager.refresh();await new Promise(resolve=>setTimeout(resolve,1));assert.equal(page.dataManager.get('todayTasks').data.result.tasks,rows);
  assert.equal(page.pageReady,true);assert.equal(page.tasks,original);assert.equal(page.pageLayoutDeferred,true);
  f.inline(false);page.pageInlineActive='';page.pageInlineChanged();
  assert.equal(page.tasks,rows);assert.equal(page.pageLayoutDeferred,false);assert.equal(f.batches.length,2);
});

test('今天内容字段更新与同值确认复用列表容器和参考日期，返回页面不重建分组',async()=>{
 const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
 let rows=[plannedTask('A','core-a','plain.org','工作'),plannedTask('B','core-a','plain.org','工作')];
 f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:{type:'task',result:{tasks:rows,categories:[]}}));
 page.view='today';page.referenceTime=Date.now();await page.loadTasks();
 const sections=page.sections,timed=page.timedItems,time=page.referenceTime;
 rows=rows.map(task=>({...task,bodyHtml:'新备注',fileVersion:'confirmed'}));await page.dataManager.refresh();await new Promise(resolve=>setTimeout(resolve,1));
 assert.equal(page.sections,sections);assert.equal(page.timedItems,timed);assert.equal(page.referenceTime,time);
 await page.loadTasks();assert.equal(page.sections,sections);assert.equal(f.batches.length,2);
});

const settleSidebar = () => new Promise(resolve => setImmediate(resolve));
const sidebarResults = (batch, projects, today = 0) => batch.map((request, index) => request.type === 'task'
  ? {type:'task',result:{tasks:Array(index === 0 ? today : 0).fill({}),categories:[]}}
  : {type:request.type,result:request.type === 'file' && request.query.isProject ? projects : []});

test('侧边栏重开直接取得共享项目快照，随后全局数据变化补齐项目',async()=>{
 const f=fixture(),old=[{repoId:'core-a',path:'old.org',projectName:'旧项目'}];f.query(batch=>sidebarResults(batch,old));
 const first=f.page('components/AppShell',['loadNavigation']);await first.loadNavigation();first.sidebarManager.close();
 const page=f.page('components/AppShell',['loadNavigation']);await page.loadNavigation();assert.equal(page.projects,old);assert.equal(f.batches.length,1);
 const all=[...old,{repoId:'core-b',path:'new.org',projectName:'新增项目'}];f.query(batch=>sidebarResults(batch,all,7));await f.emit();await page.loadNavigation();
 assert.equal(page.projects,all);assert.equal(page.todayCount,7);assert.equal(f.batches.length,2);
});

async function waitSidebar(check) {
  const deadline=Date.now()+2000;
  while(!check()) { if(Date.now()>deadline)throw new Error('侧边栏自动刷新超时');await new Promise(resolve=>setTimeout(resolve,1)); }
}

test('侧边栏订阅整个 Workspace，缓存之外文件的新项目自动出现，空快照也能新增',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  let projects=[];f.query(batch=>sidebarResults(batch,projects));await page.loadNavigation();
  const first=[{repoId:'core-a',path:'outside-cache.org',projectName:'新项目'}];
  projects=first;f.emit();f.emit();await waitSidebar(()=>page.projects===first);
  assert.deepEqual(page.projects,first);assert.equal(f.batches.length,2,'连续事件合并为一次查询');
  projects=[...first,{repoId:'core-b',path:'elsewhere.org',projectName:'另一仓库项目'}];
  await f.emit();await page.sidebarManager.start();assert.deepEqual(page.projects,projects);
  projects=[];await f.emit();await page.sidebarManager.start();assert.deepEqual(page.projectGroups,[]);
  assert.ok(f.batches.every(batch=>batch.find(request=>request.query.isProject) && !batch.find(request=>request.query.isProject).query.includeFiles));
});

test('侧边栏只消费全局数据集，项目与今天计数由同批共享结果更新',async()=>{
 const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);f.query(batch=>sidebarResults(batch,[]));await page.loadNavigation();
 const projects=[{repoId:'core-b',path:'latest.org'}];f.query(batch=>sidebarResults(batch,projects,9));await f.emit();await page.loadNavigation();
 const app=f.load('services/AppDataManager').AppDataManager.shared({});assert.equal(page.projects,app.dataSet('projects').data.result);
 assert.equal(page.todayCount,app.dataSet('todayTasks').data.result.tasks.length);assert.equal(page.todayCount,9);
});

test('共享读取失败保留侧边栏确认数据，后续事件恢复，关闭仅停止展示订阅',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  const projects=[{repoId:'core-a',path:'keep.org'}];let fail=false;
  f.query(batch=>{if(fail)throw new Error('读取失败');return sidebarResults(batch,projects,5);});
  await page.loadNavigation();fail=true;await f.emit();await page.sidebarManager.start();
  assert.deepEqual(page.projects,projects);assert.equal(page.todayCount,5);assert.match(page.navMessage,/读取失败/);
  fail=false;await f.emit();await page.sidebarManager.start();assert.equal(page.navMessage,'');
  const calls=f.batches.length;page.sidebarManager.close();await f.emit();await page.sidebarManager.start();
  assert.equal(f.batches.length,calls+1,'关闭展示层后全局管理器继续处理变化');
});

test('侧边栏配置改变使旧查询与缓存失效，入口状态按新配置重建',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);await page.loadNavigation();
  assert.equal(page.inboxCount,0);
  f.config.inboxFile='';f.configChanged();await page.sidebarManager.start();
  assert.equal(page.inboxCount,-1);assert.equal(f.batches.at(-1).length,20);
  assert.equal(f.disk.size,0,'侧边栏不再持有独立缓存');
});


test('侧边栏所有非零计数按原批次位置读取，重复打开不再次查询',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  f.query(batch=>batch.map((request,index)=>request.type==='task'
    ?{type:'task',result:{tasks:Array(index+1).fill({}),categories:[]}}
    :{type:request.type,result:request.type==='file'?[{}]:[]}));
  await page.loadNavigation();await page.loadNavigation();
  assert.deepEqual([page.todayCount,page.todayAttentionCount,page.plannedCount,page.anytimeCount,page.logbookCount],[1,5,6,8,10]);
  assert.deepEqual([page.inboxCount,page.somedayCount,page.memoCount],[15,17,19]);assert.equal(page.waitingCount,9);assert.equal(f.batches.length,1);
});

test('侧边栏关闭后在途查询不能覆盖展示或写入缓存',async()=>{
  const f=fixture(),page=f.page('components/AppShell',['loadNavigation']);
  let release;const hold=new Promise(resolve=>release=resolve);
  f.query(async batch=>{await hold;return sidebarResults(batch,[{repoId:'core-a',path:'late.org'}],3);});
  const loading=page.loadNavigation();await settleSidebar();page.sidebarManager.close();release();await loading;
  assert.deepEqual(page.projects,[]);assert.equal(page.todayCount,-1);assert.equal(f.disk.size,0);
});


test('今天页挂载时先展示已恢复的共享缓存，不等待仍在进行的首次查询',async()=>{
 const f=fixture(),first=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
 const rows=[plannedTask('cached','core-a','plain.org','工作')];f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:{type:'task',result:{tasks:rows,categories:[]}}));
 first.view='today';await first.loadTasks();const manager=first.dataManager;manager.get('todayTasks').version=0;manager.dataSet('todayTasks').isReady=()=>false;
 let release;manager.start=()=>new Promise(resolve=>release=resolve);
 const page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);page.view='today';const loading=page.loadTasks();
 await settleSidebar();assert.equal(page.tasks,rows);assert.equal(page.loading,false);assert.equal(page.pageReady,false);assert.equal(f.batches.length,1);
 release();await loading;
});

test('计划多选期间固定已加载布局并阻止范围切换，结束后应用最新成员',async()=>{
 const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter','selectPlanRegion']);
 let rows=[plannedTask('selected','core-a','plan.org','工作','选择项目')];
 f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:{type:'task',result:{tasks:rows,categories:[]}}));
 page.view='planned';await page.loadTasks();const groups=page.planGroups;const selected=page.planRegionOptions.find(region=>region.kind==='project');page.selectedPlanRegion=selected;
 page.selection.selecting=true;rows=[];await page.rangeDataSet.refresh();
 assert.equal(page.tasks.length,1);assert.equal(page.planGroups,groups);assert.equal(page.selectedPlanRegion,selected);
 const calls=f.batches.length;await page.selectPlanRegion({key:'other',kind:'category',category:'其他'});
 assert.equal(page.selectedPlanRegion,selected);assert.equal(f.batches.length,calls);
 page.selection.selecting=false;page.applyPageSnapshot();assert.deepEqual(page.tasks,[]);assert.ok(page.planGroups.every(group=>group.items.length===0));
});

test('所有任务入口和最近新增复用唯一 App 实例，依次进入与离开不新增基础查询',async()=>{
 const f=fixture(),app=f.load('services/AppDataManager').AppDataManager.shared({});await app.start();
 const manager=app.manager;
 for(const view of ['today','planned','waiting','anytime','someday','memo','logbook']){
  const page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter','aboutToDisappear']);
  page.view=view;page.selection.close=()=>{};await page.loadTasks();assert.equal(page.dataManager,manager,view);
  assert.equal(page.taskDataSet(),app.taskDataSet(view),view);page.aboutToDisappear();
 }
 const inbox=f.page('pages/Inbox',['loadRecords']);await inbox.loadRecords();
 assert.equal(inbox.tasksDataSet,app.dataSet('inboxTasks'));assert.equal(inbox.recentDataSet,app.dataSet('inboxRecent'));
 assert.equal(inbox.targetDataSet,app.dataSet('inboxFile'));assert.equal(inbox.loading,false,'共享数据已就绪时首次进入收件箱应立即显示');assert.equal(f.batches.length,1);
 assert.deepEqual(f.managers.map(item=>item.pageName),['app']);
 assert.ok(!f.batches[0].some(item=>item.query.categories),'启动时计划筛选使用基础范围');
 assert.ok(!f.batches[0].some(item=>item.query.expression?.startsWith('deleted.lt.')),'启动不触发过期清理查询');
});

for (const view of ['anytime','someday']) {
  test(view+' 多选期间冻结源布局，外部刷新在退出后应用', async () => {
    const f=fixture(),page=f.page('components/TaskPageContent',['loadTasks','supportsTagFilter','applyTagFilter']);
    let rows=[plannedTask('selected','core-a','plan.org','工作','选择项目')];
    f.query(batch=>batch.map(request=>request.type==='file'?{type:'file',result:[]}:{type:'task',result:{tasks:rows,categories:[]}}));
    page.view=view;await page.loadTasks();const previous=page.tasks;
    assert.equal(page.supportsBatchActions(),true);
    page.selection.selecting=true;rows=[];await page.taskDataSet().refresh();
    assert.equal(page.tasks,previous);assert.equal(page.tasks.length,1);
    page.selection.selecting=false;page.applyPageSnapshot();assert.deepEqual(page.tasks,[]);
  });
}
