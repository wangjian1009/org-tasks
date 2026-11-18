// 验证项目转换只编排文件创建与完整子树移动，不在宿主解析模板或重建记录。
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
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module = {exports:{}};
  vm.runInThisContext('(function(module,exports,require,$r){'+code+'\n})',{filename:file})(module,module.exports,name=>{if (name.endsWith('/SystemRepository')) return {SYSTEM_REPOSITORY_ID:'org-tasks-system',TRASH_FILE:'trash.org',isSystemRepository:repo=>repo.id==='org-tasks-system'};
    if (name.endsWith('/TrashSettingsService')) return {TrashSettingsService:{retentionDays:async()=>30}};
    if (name.endsWith('/SystemRepositoryService')) return {SystemRepositoryService:{ensure:async()=>({id:'org-tasks-system',name:'系统仓库',rootDirectory:'/app/system-repository'})}};
    if (name.endsWith('/TrashService')) return {TrashService:{perform:async()=>{throw new Error('本用例不执行删除')}}};
    assert.ok(name in mocks,name);return mocks[name]},value=>value);
  return module.exports;
}
const presentation = load('entry/src/main/ets/ui/ProjectCreatePresentation.ets');
const { configuredFileTarget } = load('entry/src/main/ets/services/FileTargetService.ets', {
  './AppConfigService': {}, './NativeCoreService': {}, './PageQueryService': {}, './TaskViewQueries': {}
});
function fixture() {
  const writes = [], reads = [], queries = [];
  let failure, readFailure, repos = [{ id:'core-source',rootDirectory:'/source' },{id:'core-target',rootDirectory:'/target'}];
  const config = {repos:[{id:'host-source',name:'源仓库',rootDirectory:'/source'},{id:'host-target',name:'目标仓库',rootDirectory:'/target'}]};
  const files = [{repoId:'core-source',path:'work.org',category:'工作',isIgnore:false},{repoId:'core-source',path:'life.org',category:'生活',isIgnore:false},{repoId:'core-source',path:'other.org',category:'工作',isIgnore:false},{repoId:'core-target',path:'research.org',category:'研究',isIgnore:false},{repoId:'core-target',path:'hidden.org',category:'隐藏',isIgnore:true}];
  const workspace = {async repos(){return repos}, async query(batch){queries.push(batch);const excluded=batch[0].query.excludeFiles ?? [];return [{type:'file',result:files.filter(file=>!excluded.some(target=>target.repoId===file.repoId && target.path===file.path))}]}, async executeTaskOperations(group){writes.push(group);if(failure)throw failure}};
  const {ProjectCreateService}=load('entry/src/main/ets/services/ProjectCreateService.ets',{
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:value=>Buffer.from(value).toString('utf8')})}}},
    './AppConfigService':{AppConfigService:{async load(){return config}}},
    './FileTargetService':{configuredFileTarget},
    './NativeCoreService':{fileResult:value=>value.result,NativeCoreService:{async workspaceFor(){return workspace}}},
    '../ui/ProjectCreatePresentation':presentation
  });
  const context={resourceManager:{async getRawFileContent(file){reads.push(file);if(readFailure)throw readFailure;return fs.readFileSync(path.join('entry/src/main/resources/rawfile',file))}}};
  const source={id:'task',repoId:'core-source',filePath:'inbox.org',fileVersion:'source-version',category:'工作',fullPath:{repoId:'core-source',file:'inbox.org',titles:['草稿'],occurrence:2}};
  return {ProjectCreateService,context,source,writes,reads,queries,config,files,fail(error){failure=error},failRead(){readFailure=new Error('raw')},removeRepos(){repos=[]}};
}
test('仓库候选使用真实 Core ID，展示名称按宿主目录映射',async()=>{
  const f=fixture();assert.deepEqual(await f.ProjectCreateService.repositories(f.context),[{repoId:'core-source',name:'源仓库',regions:['工作','生活']},{repoId:'core-target',name:'目标仓库',regions:['研究']}]);
});
test('分类候选通过 Core 排除三种配置用途文件，按真实仓库与路径匹配并保留普通文件的同名分类',async()=>{
  const f=fixture();Object.assign(f.config,{inboxRepoId:'host-source',inboxFile:'inbox.org',somedayRepoId:'host-target',somedayFile:'someday.org',memoRepoId:'host-source',memoFile:'memo.org'});
  f.files.push({repoId:'core-source',path:'inbox.org',category:'收件分类'},
    {repoId:'core-target',path:'someday.org',category:'某天分类'},
    {repoId:'core-source',path:'memo.org',category:'工作'},
    {repoId:'core-target',path:'inbox.org',category:'同名普通文件'});
  const options=await f.ProjectCreateService.repositories(f.context);
  assert.deepEqual(f.queries[0],[{type:'file',query:{excludeFiles:[{repoId:'core-source',path:'inbox.org'},{repoId:'core-target',path:'someday.org'},{repoId:'core-source',path:'memo.org'}]}}]);
  assert.deepEqual(options[0].regions,['工作','生活']);
  assert.deepEqual(options[1].regions,['同名普通文件','研究']);
});
test('用途配置缺失、路径为空或仓库失效时不误排除普通文件',async()=>{
  const f=fixture();Object.assign(f.config,{inboxRepoId:'removed',inboxFile:'work.org',somedayRepoId:'host-source',somedayFile:'',memoFile:'life.org'});
  const options=await f.ProjectCreateService.repositories(f.context);
  assert.deepEqual(f.queries[0][0].query.excludeFiles,[]);assert.deepEqual(options[0].regions,['工作','生活']);
});
test('项目面板生成 FileNew 和 Movement，保留源版本与重名序号且不执行写入',async()=>{
  const f=fixture();const group=await f.ProjectCreateService.operationGroup(f.context,f.source,{repoId:'core-target',region:'新 Region'},' 新项目 ','自选文件');
  assert.equal(f.writes.length,0);assert.equal(group.operationId,undefined);
  assert.deepEqual(group.fileVersions,[{repoId:'core-source',file:'inbox.org',version:'source-version'}]);
  assert.deepEqual(group.operations.map(op=>op.type),['FileNew','Movement']);
  const file=group.operations[0].data;assert.deepEqual(file.path,{repoId:'core-target',file:'自选文件.org',titles:[]});
  assert.deepEqual(file.arguments,{'project_name':'新项目','category':'新 Region'});assert.deepEqual(file.initTasks,[]);
  assert.equal(file.templatePath,'');assert.equal(file.templateContent,fs.readFileSync('entry/src/main/resources/rawfile/templates/project.org','utf8'));assert.match(file.templateContent,/\{\{project_name\}\}/);assert.deepEqual(f.reads,['templates/project.org']);
  assert.deepEqual(group.operations[1].data,{path:f.source.fullPath,position:{parent:file.path}});
});
test('模板不可读、目标仓库失效和无效文件名在提交前失败',async()=>{
  const missing=fixture();missing.failRead();await assert.rejects(missing.ProjectCreateService.operationGroup(missing.context,missing.source,{repoId:'core-target',region:'研究'},'项目','项目'),/模板读取失败/);assert.equal(missing.writes.length,0);
  const removed=fixture();removed.removeRepos();await assert.rejects(removed.ProjectCreateService.operationGroup(removed.context,removed.source,{repoId:'core-target',region:'研究'},'项目','项目'),/失效/);assert.equal(removed.writes.length,0);
  const invalid=fixture();await assert.rejects(invalid.ProjectCreateService.operationGroup(invalid.context,invalid.source,{repoId:'core-target',region:'研究'},'项目','../项目'),/文件名/);assert.equal(invalid.writes.length,0);
  assert.equal(presentation.projectFileName(' 项目.ORG '),'项目.org');assert.equal(presentation.projectFileName('项目'),'项目.org');
});
function locationForm() {
  const file='entry/src/main/ets/components/editors/ProjectCreateSheet.ets';
  const source=fs.readFileSync(file,'utf8');
  const methods=['initializeFields','defaultRegion','selectRepository','regionOptions','selectRegion','saveRegion','changeName','changeFileName','isBusy','submit'].map(name=>{
    const match=source.match(new RegExp('  (?:async )?'+name+'\\([^\\n]*\\)(?::[^\\n{]+)? \\{[\\s\\S]*?\\n  \\}'));assert.ok(match,name);return match[0];
  });
  const code=ts.transpileModule('exports.Form = class Form {'+methods.join('\n')+'}',{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
  const exports={};
  vm.runInThisContext('(function(exports,projectInputError,projectFileName,ProjectCreateService,coreErrorMessage){'+code+'\n})')(exports,presentation.projectInputError,presentation.projectFileName,{operationGroup:async(_context,_source,...args)=>{if(_context.generate)return await _context.generate(...args);return {args}}},error=>error.message);
  const calls=[];
  const form=Object.assign(new exports.Form(),{repositories:[{repoId:'source',name:'源仓库',regions:['工作','生活']},{repoId:'target',name:'目标仓库',regions:['研究']}],
    active:true,source:{id:'task'},getUIContext:()=>({getHostContext:()=>({})}),initialRepoId:'source',initialRegion:'工作',initialName:'项目',repoId:'source',region:'工作',newRegions:[],newRegionName:'',name:'项目',fileName:'项目',generated:group=>calls.push(group.args)});
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
  assert.deepEqual(calls,[[{repoId:'source',region:'新 Region'},'项目','项目.org']]);
  form.addingRegion=true;form.newRegionName=' ';await form.submit();assert.equal(calls.length,1);assert.match(form.inputError,/分类/);
  form.newRegionName='工作\n#+TITLE: 覆盖';assert.equal(form.saveRegion(),false);
  assert.match(presentation.projectInputError('source','项目','项目','工作\n其他'),/分类/);
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

test('文件名未编辑时跟随项目名，自定义后折叠不会重置提交值',async()=>{
  const {form,calls}=locationForm();form.changeName('新项目');await form.submit();
  assert.equal(calls[0][2],'新项目.org');
  form.fileNameExpanded=true;form.changeFileName('自定义.ORG');form.fileNameExpanded=false;
  form.changeName('再次改名');await form.submit();
  assert.equal(calls[1][1],'再次改名');assert.equal(calls[1][2],'自定义.org');
});

test('操作组生成期间连续确认只生成一次，面板离开后丢弃迟到结果',async()=>{
  const {form,calls}=locationForm();let finish,count=0;
  form.getUIContext=()=>({getHostContext:()=>({generate:async()=>{count++;return await new Promise(resolve=>finish=resolve)}})});
  const pending=form.submit();assert.equal(form.generating,true);await form.submit();assert.equal(count,1);
  form.active=false;finish({operations:[{type:'FileNew'}]});await pending;
  assert.equal(calls.length,0);assert.equal(form.generating,false);
});
test('操作组生成失败保留面板字段并恢复确认入口',async()=>{
  const {form,calls}=locationForm();
  form.changeFileName('自定义文件');
  form.getUIContext=()=>({getHostContext:()=>({generate:async()=>{throw new Error('项目模板读取失败')}})});
  await form.submit();assert.equal(calls.length,0);assert.equal(form.inputError,'项目模板读取失败');
  assert.equal(form.fileName,'自定义文件');assert.equal(form.name,'项目');assert.equal(form.isBusy(),false);
});
