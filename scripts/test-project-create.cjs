// 验证项目转换只编排文件创建与完整子树移动，不在宿主解析模板或重建记录。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-project-create.cjs\n验证项目仓库身份、文件名、随包模板、操作组生成、零写入及表单校验。');process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(file, mocks = {}) {
  const code = transpileFixture(ts, fs.readFileSync(file, 'utf8'), {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module = {exports:{}};
  vm.runInThisContext('(function(module,exports,require,$r){'+code+'\n})',{filename:file})(module,module.exports,name=>{if (name.endsWith('/SystemRepository')) return {SYSTEM_REPOSITORY_ID:'org-tasks-system',TRASH_FILE:'trash.org',isSystemRepository:repo=>repo.id==='org-tasks-system'};
    if (name.endsWith('/TrashSettingsService')) return {TrashSettingsService:{retentionDays:async()=>30}};
    if (name.endsWith('/SystemRepositoryService')) return {SystemRepositoryService:{ensure:async()=>({id:'org-tasks-system',name:'系统仓库',rootDirectory:'/app/system-repository'})}};
    if (name.endsWith('/TrashService')) return {TrashService:{perform:async()=>{throw new Error('本用例不执行删除')}}};
    assert.ok(name in mocks,name);return mocks[name]},value=>value);
  return module.exports;
}
const presentation = load('entry/src/main/ets/ui/OrgFileCreatePresentation.ets');
const { configuredFileTarget } = load('entry/src/main/ets/services/FileTargetService.ets', {
  './AppConfigService': {}, './NativeCoreService': {}, './PageQueryService': {}, './TaskViewQueries': {}
});
function fixture() {
  const writes = [], reads = [], queries = [];
  let sharedFiles;
  let failure, readFailure, repos = [{ id:'core-source',rootDirectory:'/source' },{id:'core-target',rootDirectory:'/target'}];
  const config = {repos:[{id:'host-source',name:'源仓库',rootDirectory:'/source'},{id:'host-target',name:'目标仓库',rootDirectory:'/target'}]};
  const files = [{repoId:'core-source',path:'work.org',category:'工作',isIgnore:false},{repoId:'core-source',path:'life.org',category:'生活',isIgnore:false},{repoId:'core-source',path:'other.org',category:'工作',isIgnore:false},{repoId:'core-target',path:'research.org',category:'研究',isIgnore:false},{repoId:'core-target',path:'hidden.org',category:'隐藏',isIgnore:true}];
  const workspace = {async repos(){return repos}, async query(batch){queries.push(batch);const excluded=batch[0].query.excludeFiles ?? [];return [{type:'file',result:files.filter(file=>!excluded.some(target=>target.repoId===file.repoId && target.path===file.path))}]}, async executeTaskOperations(group){writes.push(group);if(failure)throw failure}};
  const {OrgFileCreateService}=load('entry/src/main/ets/services/OrgFileCreateService.ets',{
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:value=>Buffer.from(value).toString('utf8')})}}},
    './AppConfigService':{AppConfigService:{async load(){return config}}},
    './FileTargetService':{configuredFileTarget},
    './AppDataManager':{AppDataManager:{shared:()=>({start:async()=>{},configuration:config,manager:{get repositoryInfo(){return repos}},dataSet:name=>{assert.equal(name,'categories');return{isReady:()=>true,error:'',data:{type:'file',result:sharedFiles??files}}}})}},
    './NativeCoreService':{fileResult:value=>value.result,NativeCoreService:{async workspaceFor(){return workspace}}},
    '../ui/OrgFileCreatePresentation':presentation
  });
  const context={resourceManager:{async getRawFileContent(file){reads.push(file);if(readFailure)throw readFailure;return fs.readFileSync(path.join('entry/src/main/resources/rawfile',file))}}};
  const source={id:'task',repoId:'core-source',filePath:'inbox.org',fileVersion:'source-version',category:'工作',fullPath:{repoId:'core-source',file:'inbox.org',titles:['草稿'],occurrence:2}};
  return {OrgFileCreateService,context,source,writes,reads,queries,config,files,setCategories(value){sharedFiles=value},fail(error){failure=error},failRead(){readFailure=new Error('raw')},removeRepos(){repos=[]}};
}
test('仓库候选使用真实 Core ID，展示名称按宿主目录映射',async()=>{
  const f=fixture();assert.deepEqual(await f.OrgFileCreateService.repositories(f.context),[{repoId:'core-source',name:'源仓库',regions:['工作','生活']},{repoId:'core-target',name:'目标仓库',regions:['研究']}]);
});
test('分类候选直接消费全局已筛选的元信息，不再查询仓库',async()=>{
  const f=fixture();f.setCategories([{repoId:'core-source',path:'other.org',category:'工作',isIgnore:false},
    {repoId:'core-target',path:'inbox.org',category:'同名普通文件',isIgnore:false},
    {repoId:'core-target',path:'hidden.org',category:'隐藏',isIgnore:true}]);
  const options=await f.OrgFileCreateService.repositories(f.context);
  assert.equal(f.queries.length,0);assert.deepEqual(options[0].regions,['工作']);assert.deepEqual(options[1].regions,['同名普通文件']);
});
test('每次打开面板读取全局当前快照，分类变化不会保留上次候选',async()=>{
  const f=fixture();await f.OrgFileCreateService.repositories(f.context);
  f.setCategories([{repoId:'core-source',path:'new.org',category:'新分类',isIgnore:false}]);
  const options=await f.OrgFileCreateService.repositories(f.context);
  assert.deepEqual(options[0].regions,['新分类']);assert.deepEqual(options[1].regions,[]);assert.equal(f.queries.length,0);
});
test('项目面板生成 FileNew 和 Movement，保留源版本与重名序号且不执行写入',async()=>{
  const f=fixture();const group=await f.OrgFileCreateService.operationGroup(f.context,f.source,{repoId:'core-target',region:'新 Region',title:' 文件标题 ',projectName:' 新项目 ',fileName:'自选文件'});
  assert.equal(f.writes.length,0);assert.equal(group.operationId,undefined);
  assert.deepEqual(group.fileVersions,[{repoId:'core-source',file:'inbox.org',version:'source-version'}]);
  assert.deepEqual(group.operations.map(op=>op.type),['FileNew','Movement']);
  const file=group.operations[0].data;assert.deepEqual(file.path,{repoId:'core-target',file:'自选文件.org',titles:[]});
  assert.deepEqual(file.arguments,{title:'文件标题',project_name:'新项目',category:'新 Region'});assert.deepEqual(file.initTasks,[]);
  assert.equal(file.templatePath,'');assert.equal(file.templateContent,fs.readFileSync('entry/src/main/resources/rawfile/templates/project.org','utf8'));assert.match(file.templateContent,/\{\{project_name\}\}/);assert.deepEqual(f.reads,['templates/project.org']);
  assert.deepEqual(group.operations[1].data,{path:f.source.fullPath,position:{parent:file.path}});
});
test('笔记本新增项目只生成空项目的 FileNew 操作', async () => {
  const f = fixture();
  const group = await f.OrgFileCreateService.operationGroup(
    f.context, undefined, { repoId: 'core-target', region: '研究', title: '文件标题', projectName: '新项目', fileName: '自定义文件' }
  );
  assert.deepEqual(group.operations.map(operation => operation.type), ['FileNew']);
  const file = group.operations[0].data;
  assert.deepEqual(file.path, { repoId: 'core-target', file: '自定义文件.org', titles: [] });
  assert.deepEqual(file.arguments, { title: '文件标题', project_name: '新项目', category: '研究' });
  assert.deepEqual(file.initTasks, []);
  assert.equal(group.fileVersions, undefined);
  assert.deepEqual(f.writes, []);
});
test('项目名称留空时使用 tasks 模板，文件名留空时使用标题', async () => {
  const f = fixture();
  const group = await f.OrgFileCreateService.operationGroup(f.context, undefined, {
    repoId: 'core-target', region: '', title: '任务清单', projectName: ' ', fileName: ''
  });
  const file = group.operations[0].data;
  assert.equal(file.path.file, '任务清单.org');
  assert.deepEqual(f.reads, ['templates/tasks.org']);
  assert.match(file.templateContent, /^#\+TITLE: \{\{title\}\}$/m);
  assert.match(file.templateContent, /^#\+FILETAGS: :todo:$/m);
  assert.equal(file.arguments.title, '任务清单');
});

test('模板不可读、目标仓库失效和无效文件名在提交前失败',async()=>{
  const missing=fixture();missing.failRead();await assert.rejects(missing.OrgFileCreateService.operationGroup(missing.context,missing.source,{repoId:'core-target',region:'研究',title:'标题',projectName:'项目',fileName:''}),/模板读取失败/);assert.equal(missing.writes.length,0);
  const removed=fixture();removed.removeRepos();await assert.rejects(removed.OrgFileCreateService.operationGroup(removed.context,removed.source,{repoId:'core-target',region:'研究',title:'标题',projectName:'项目',fileName:''}),/失效/);assert.equal(removed.writes.length,0);
  const invalid=fixture();await assert.rejects(invalid.OrgFileCreateService.operationGroup(invalid.context,invalid.source,{repoId:'core-target',region:'研究',title:'标题',projectName:'项目',fileName:'../项目'}),/文件名/);assert.equal(invalid.writes.length,0);
  assert.equal(presentation.orgFileName(' 项目.ORG '),'项目.org');assert.equal(presentation.orgFileName('项目'),'项目.org');
});
function locationForm() {
  const file='entry/src/main/ets/components/editors/OrgFileCreateSheet.ets';
  const source=fs.readFileSync(file,'utf8');
  const methods=['initializeFields','defaultRegion','selectRepository','regionOptions','selectRegion','saveRegion','isBusy','submit'].map(name=>{
    const match=source.match(new RegExp('  (?:async )?'+name+'\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));assert.ok(match,name);return match[0];
  });
  const code=transpileFixture(ts, 'exports.Form = class Form {'+methods.join('\n')+'}',{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
  const exports={};
  vm.runInThisContext('(function(exports,orgFileInputError,OrgFileCreateService,coreErrorMessage){'+code+'\n})')(exports,presentation.orgFileInputError,{operationGroup:async(_context,_source,...args)=>{if(_context.generate)return await _context.generate(...args);return {args}}},error=>error.message);
  const calls=[];
  const form=Object.assign(new exports.Form(),{repositories:[{repoId:'source',name:'源仓库',regions:['工作','生活']},{repoId:'target',name:'目标仓库',regions:['研究']}],
    active:true,source:{id:'task'},getUIContext:()=>({getHostContext:()=>({})}),initialRepoId:'source',initialRegion:'工作',initialName:'项目',repoId:'source',region:'工作',newRegions:[],newRegionName:'',title:'标题',projectName:'项目',fileName:'',generated:group=>calls.push(group.args)});
  return {form,calls};
}

test('切换仓库默认选择有效 Category，候选仅来自所选仓库',()=>{
  const {form}=locationForm();form.selectRepository(1);
  assert.equal(form.repoId,'target');assert.equal(form.region,'研究');assert.deepEqual(form.regionOptions(),['研究']);
  form.selectRepository(0);assert.deepEqual(form.regionOptions(),['工作','生活']);
});

test('新建 Region 仅保存在当前仓库草稿，切换后不泄漏到其他仓库',()=>{
  const {form}=locationForm();form.selectRepository(1);form.newRegionName=' 产品 ';assert.equal(form.saveRegion(),true);
  assert.equal(form.region,'产品');assert.deepEqual(form.regionOptions(),['产品','研究']);
  form.selectRepository(0);assert.deepEqual(form.regionOptions(),['工作','生活']);
  form.newRegionName='工作';assert.equal(form.saveRegion(),true);assert.equal(form.newRegions.length,1);
  form.selectRepository(1);assert.deepEqual(form.regionOptions(),['产品','研究']);
});

test('提交可以同时确认新 Region，并把位置和项目字段完整生成操作组',async()=>{
  const {form,calls}=locationForm();form.addingRegion=true;form.newRegionName='新 Region';await form.submit();
  assert.deepEqual(calls,[[{repoId:'source',region:'新 Region',title:'标题',projectName:'项目',fileName:''}]]);
  form.addingRegion=true;form.newRegionName=' ';await form.submit();assert.equal(calls.length,1);assert.match(form.inputError,/分类/);
  form.newRegionName='工作\n#+TITLE: 覆盖';assert.equal(form.saveRegion(),false);
  assert.match(presentation.orgFileInputError({repoId:'source',title:'标题',projectName:'项目',fileName:'',region:'工作\n其他'}),/分类/);
  form.busy=true;form.newRegionName='提交中';const count=form.newRegions.length;assert.equal(form.saveRegion(),false);assert.equal(form.newRegions.length,count);
});


test('初始位置优先源库与源 Category，失效选择回落到有效候选',()=>{
  const {form}=locationForm();form.initialRegion='生活';form.initializeFields();
  assert.equal(form.repoId,'source');assert.equal(form.region,'生活');
  form.initialRegion='已失效';form.initializeFields();assert.equal(form.region,'工作');
  form.initialRepoId='已移除';form.initialRegion='研究';form.initializeFields();
  assert.equal(form.repoId,'source');assert.equal(form.region,'工作');
  form.repositories=[];form.initializeFields();assert.equal(form.repoId,'');assert.equal(form.region,'');
});

test('没有分类的库可以不设置 Region，并从菜单独立新建',()=>{
  const {form}=locationForm();form.repositories.push({repoId:'empty',name:'空库',regions:[]});form.selectRepository(2);
  assert.equal(form.region,'');form.selectRegion(1);assert.equal(form.addingRegion,true);
  form.newRegionName='新增';assert.equal(form.saveRegion(),true);assert.equal(form.region,'新增');
  form.selectRegion(0);assert.equal(form.region,'');form.selectRegion(1);assert.equal(form.region,'新增');
});

test('标题、项目名称与文件名分别保留，仓库入口固定目标', async () => {
  const { form, calls } = locationForm();
  form.repositoryHidden = true;
  form.selectRepository(1);
  form.fileName = '独立文件名.ORG';
  form.title = '独立标题';
  await form.submit();
  assert.deepEqual(calls[0], [{ repoId: 'source', region: '工作', title: '独立标题', projectName: '项目', fileName: '独立文件名.ORG' }]);
});

test('转换表单用项目名称作为隐藏的标题，项目留空时回退到源记录标题', async () => {
  const { form, calls } = locationForm();
  form.converting = true;
  form.titleHidden = true;
  form.initialName = '源标题';
  form.projectName = '改名后的项目';
  await form.submit();
  form.projectName = '';
  await form.submit();
  assert.equal(calls[0][0].title, '改名后的项目');
  assert.equal(calls[1][0].title, '源标题');
  assert.equal(calls[1][0].projectName, '');
});

test('操作组生成期间连续确认只生成一次，面板离开后丢弃迟到结果',async()=>{
  const {form,calls}=locationForm();let finish,count=0;
  form.getUIContext=()=>({getHostContext:()=>({generate:async()=>{count++;return await new Promise(resolve=>finish=resolve)}})});
  const pending=form.submit();assert.equal(form.generating,true);await form.submit();assert.equal(count,1);
  form.active=false;finish({operations:[{type:'FileNew'}]});await pending;
  assert.equal(calls.length,0);assert.equal(form.generating,false);
});
test('转换表单缺少源记录时拒绝生成独立项目', async () => {
  const { form, calls } = locationForm();
  form.converting = true;
  form.source = undefined;
  await form.submit();
  assert.match(form.inputError, /原记录已失效/);
  assert.deepEqual(calls, []);
});

test('操作组生成失败保留面板字段并恢复确认入口',async()=>{
  const {form,calls}=locationForm();
  form.fileName = '自定义文件';
  form.getUIContext=()=>({getHostContext:()=>({generate:async()=>{throw new Error('项目模板读取失败')}})});
  await form.submit();assert.equal(calls.length,0);assert.equal(form.inputError,'项目模板读取失败');
  assert.equal(form.fileName,'自定义文件');assert.equal(form.projectName,'项目');assert.equal(form.isBusy(),false);
});
