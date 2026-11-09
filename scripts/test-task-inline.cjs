// 验证卡片编辑的版本约束、最新任务投影和月历自然日行为。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-inline.cjs\n验证卡片编辑的结构化请求、版本冲突、会话切换及月历布局。');
  process.exit(0);
}
const sdk = '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks = {}) {
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS } }).outputText;
  const result = {exports:{}};
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename:file})(name=>{
    assert.ok(Object.hasOwn(mocks,name),name);return mocks[name];
  },result,result.exports);
  return result.exports;
}
const storage = new Map();
global.AppStorage = {setOrCreate:(key,value)=>storage.set(key,value)};
function fixture() {
  const requests=[];
  const task={repoId:'core',filePath:'task.org',fileVersion:'old',fullPath:{repoId:'core',file:'task.org',titles:['Original'],occurrence:1},heading:'Original',tags:['local'],editContent:{notes:'notes',checklist:[]}};
  const updated={...task,heading:'New',fileVersion:'new',fullPath:{...task.fullPath,titles:['New']}};
  let conflict=false;
  const config={repos:[{rootDirectory:'/repo',webdavEnabled:true}],todoDefaults:''};
  const workspace={
    repos:async()=>[{id:'core',rootDirectory:'/repo',fileMetadata:async()=>[{path:'task.org',tagOptions:['configured']},{path:'other.org',tagOptions:['excluded']}]}],
    query:async()=>({tasks:[{tags:['used']}]}),
    executeTaskOperations:async group=>{requests.push(group);if(conflict)throw new Error('文件版本冲突');return {paths:[updated.fullPath],tasks:[updated]};}
  };
  const service=load('entry/src/main/ets/services/TaskInlineService.ets',{
    './AppConfigService':{AppConfigService:{load:async()=>config}},
    './NativeCoreService':{NativeCoreService:{workspaceFor:async()=>workspace}}
  });
  return {task,updated,config,requests,...service,conflict:()=>conflict=true};
}
test('标题修改使用原路径版本，返回新名称对应的最新快照',async()=>{
  const f=fixture();assert.equal(await f.TaskInlineService.modify({},f.task,[{field:'TITLE',value:'New'}]),f.updated);
  assert.deepEqual(f.requests[0],{operations:[{type:'Modification',data:{path:f.task.fullPath,modifications:[{field:'TITLE',value:'New'}]}}],queueRepoIds:['core'],fileVersions:[{repoId:'core',file:'task.org',version:'old'}]});
});
test('备注、标签和清单操作原样交给 Core，不重建正文',async()=>{
  const f=fixture();const changes=[{field:'NOTES',value:'new notes'},{field:'CHECKLIST',value:{type:'setChecked',id:'123',checked:true}},{field:'TAGS',value:['configured','used']}];
  await f.TaskInlineService.modify({},f.task,changes);assert.deepEqual(f.requests[0].operations[0].data.modifications,changes);
});
test('版本冲突向调用方传播，不拿新版本自动覆盖',async()=>{
  const f=fixture();f.conflict();await assert.rejects(f.TaskInlineService.modify({},f.task,[{field:'NOTES',value:'draft'}]),/版本冲突/);assert.equal(f.requests.length,1);
});
test('标签候选保留文件配置与已有名称，不混入其他文件未使用候选',async()=>{
  const f=fixture();assert.deepEqual(await f.TaskInlineService.tagOptions({},f.task),['configured','local','used']);
});
test('上一编辑会话保存失败时不允许切换任务',async()=>{
  const {TaskInlineSession:s}=fixture();await s.begin('first',async()=>false);
  assert.equal(await s.begin('second',async()=>true),false);assert.equal(storage.get('taskInlineActive'),'first');s.release('first');
});
const dates=load('entry/src/main/ets/ui/TaskInlinePresentation.ets');
test('月历跨年、闰月、今天与已选日期独立且固定42格',()=>{
  const days=dates.taskCalendarDays(2028,1,'2028-02-29',new Date(2028,1,28,12));
  assert.equal(days.length,42);assert.equal(days[0].date,'2028-01-31');
  assert.equal(days.find(d=>d.date==='2028-02-29').selected,true);assert.equal(days.find(d=>d.date==='2028-02-28').today,true);
  const january=dates.taskCalendarDays(2027,0,'2026-11-16',new Date(2026,10,9,12));assert.equal(january[0].date,'2026-12-28');assert.equal(january.filter(d=>d.selected).length,0);
});
test('明天按本地自然日计算，跨月跨年标签正确',()=>{
  assert.equal(dates.inlineDateLabel('2027-01-01',new Date(2026,11,31,12)),'明天');
  assert.equal(dates.inlineDateLabel('2026-11-09',new Date(2026,10,9,12)),'今天');
});
