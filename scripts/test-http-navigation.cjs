const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-http-navigation.cjs\n验证导航 HTTP 请求、路径校验、目标身份、并发冲突和编辑保护。'); process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(name, mocks) {
  const file = path.resolve('entry/src/main/ets/services', name+'.ets');
  const module = {exports:{}};
  const code = transpileFixture(ts, fs.readFileSync(file,'utf8'), {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename:file})(name=>{assert.ok(name in mocks,name);return mocks[name]},module,module.exports);
  return module.exports;
}
const {PagePath} = load('PagePath',{});
function fixture() {
  let failSave=false,canLeave=true,busy=false,missing=false,active=true,delay,project=true;
  const applied=[],queries=[],config={repos:[{id:'host',rootDirectory:'/qa'}]};
  const task={id:'memo',repoId:'core',filePath:'memo.org',heading:'真实备忘',fullPath:{repoId:'core',file:'memo.org',titles:['真实备忘']}, isDone(){return false}};
  const navigator={path:new PagePath([{url:'pages/Today'}]),isNavigating:()=>busy,canLeaveExternally:()=>canLeave,
    async setPath(_,value){applied.push(value);navigator.path=value;return true}};
  const workspace={async repos(){return [{id:'core',rootDirectory:'/qa',async historyFile(){if(missing)throw new Error('missing')}}]},
    async query(value){queries.push(value);if(delay)await delay;return [{type:'file',result:missing?[]:[{project:()=>project?'项目':null}]}]},
    async fileAt(){if(missing)throw new Error('missing');return {nodes:()=>[task]}}};
  const service=load('HttpNavigationService',{
    './MemoNavigation': { MemoNavigation: { async findInConfig(_, id) { return !missing && id === 'memo' ? task : undefined; } } },
    './AppConfigService':{AppConfigService:{async load(){return config}}},
    './NativeCoreService':{NativeCoreService:{async workspaceFor(){return workspace}},fileResult:value=>value.result},
    './PageNavigator':{PageNavigator:{shared:navigator}},'./PagePath':{PagePath},
    './TaskInlineService':{TaskInlineSession:{async end(){return !failSave}}}
  }).HttpNavigationService;
  const context={getHostContext:()=>({})};
  const call=async(method,body)=>{const value=await service.handle(context,{method,body:typeof body==='string'?body:JSON.stringify(body)},()=>active);return{status:value.status,body:JSON.parse(value.body)}};
  return {call,navigator,applied,queries,task,missing(){missing=true},plain(){project=false},block(){canLeave=false},busy(){busy=true},failSave(){failSave=true},stop(){active=false},delay(value){delay=value}};
}
const overview=view=>({pages:[{url:'pages/'+view[0].toUpperCase()+view.slice(1)}]});
const projectPath={pages:[{url:'pages/Files'},{url:'pages/OrgFileDetail',params:{repoId:'core',path:'project.org'}}]};
test('GET 返回真实路径，PUT 设置完整带参数路径并返回实际状态',async()=>{
  const f=fixture();assert.deepEqual((await f.call('GET')).body,overview('today'));
  const result=await f.call('PUT',projectPath);assert.equal(result.status,200);assert.deepEqual(result.body,projectPath);
  assert.deepEqual((await f.call('GET')).body,projectPath);assert.equal(f.applied.length,1);
});
test('空路径、错误结构、无效页面、参数类型和视图在跳转前拒绝',async()=>{
  const f=fixture();for(const body of [null,[],{},'{bad',{pages:[]},{pages:Array(33).fill({url:'pages/Files'})},
    {pages:[{url:'pages/Capture'}]},overview('bad'),{pages:[{url:'pages/Files',params:{view:'today'}}]},
    {pages:[{url:'pages/OrgFileDetail',params:{repoId:'core',path:1}}]}, {pages:[{url:'pages/MemoEdit',params:{}}]},
    {pages:[{url:'pages/MemoEdit',params:{create:'true'}}]}, {pages:[{url:'pages/Settings',params:{section:'不存在'}}]}]) {
    const result=await f.call('PUT',body);assert.equal(result.status,400,JSON.stringify(body));
  } assert.equal(f.applied.length,0);
});
test('目标仓库或文件失效返回404，整条路径验证完成前不执行导航',async()=>{
  const f=fixture();f.missing();assert.equal((await f.call('PUT',projectPath)).status,404);
  assert.equal((await f.call('PUT',{pages:[{url:'pages/RepositorySettings',params:{repoId:'missing'}}]})).status,404);
  assert.equal(f.applied.length,0);assert.deepEqual((await f.call('GET')).body,overview('today'));
});
test('编辑保护、保存失败、正在导航返回409并保留原路径',async()=>{
  for(const mode of ['block','failSave','busy']){const f=fixture();f[mode]();assert.equal((await f.call('PUT',overview('planned'))).status,409);assert.equal(f.applied.length,0)}
});
test('并发请求与等待期间关闭服务不执行迟到跳转',async()=>{
  const f=fixture();let release;f.delay(new Promise(resolve=>release=resolve));
  const pending=f.call('PUT',projectPath);await new Promise(resolve=>setImmediate(resolve));
  assert.equal((await f.call('PUT',overview('planned'))).status,409);assert.equal((await f.call('GET')).status,409);
  f.stop();release();assert.equal((await pending).status,409);assert.equal(f.applied.length,0);
  assert.equal((await f.call('GET')).status,503);
});
test('Org 文件入口保留统一路径，省略任务视图时规范化为今天',async()=>{
  const f=fixture();const result=await f.call('PUT',{pages:[{url:'pages/OrgFileDetail',params:{repoId:'core',path:'project.org'}}]});
  assert.equal(result.status,200);assert.equal(result.body.pages[0].url,'pages/OrgFileDetail');
  assert.deepEqual((await f.call('PUT',{pages:[{url:'pages/Today'}]})).body,overview('today'));
});

test('任务定位参数只接受当前工作文件内的完整任务路径', async () => {
  const f = fixture();
  const focusTask = {repoId:'core', file:'project.org', titles:['章节', '任务'], occurrence:2};
  const page = params => ({pages:[{url:'pages/OrgFileDetail', params:{repoId:'core', path:'project.org', ...params}}]});
  const state = page({focusTask});
  assert.deepEqual((await f.call('PUT',state)).body,state);
  for (const params of [
    {focusTask:{...focusTask, file:'other.org'}}, {focusTask:{...focusTask, occurrence:0}},
    {focusTask:{...focusTask, titles:[]}}, {focusTask,syncId:'backup'}
  ]) assert.equal((await f.call('PUT',page(params))).status,400);
});
test('备忘按稳定身份读取真实 native Task，JSON 不能伪造编辑快照',async()=>{
  const f=fixture();const result=await f.call('PUT',{pages:[{url:'pages/MemoEdit',params:{task:{repoId:'core',filePath:'memo.org',id:'memo',heading:'伪造旧标题'}}}]});
  assert.equal(result.status,200);assert.equal(f.applied[0].current.params.task,f.task);
  assert.equal(result.body.pages[0].params.task.heading,'真实备忘');
  assert.equal((await f.call('PUT',{pages:[{url:'pages/MemoEdit',params:{task:{repoId:'core',filePath:'memo.org',id:'missing'}}}]})).status,404);
});


test('memoId 与卡片入口共用当前备忘文件身份解析，目标失效返回404', async () => {
  const f=fixture();
  const page={pages:[{url:'pages/Memo'},{url:'pages/MemoEdit',params:{memoId:'memo'}}]};
  assert.equal((await f.call('PUT',page)).status,200);assert.equal(f.applied[0].current.params.task,f.task);
  f.missing();assert.equal((await f.call('PUT',page)).status,404);
  assert.equal((await f.call('PUT',{pages:[{url:'pages/MemoEdit',params:{create:true,memoId:'memo'}}]})).status,400);
});
