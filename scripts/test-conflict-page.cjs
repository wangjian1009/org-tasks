// 验证本版冲突页只通过普通操作组丢弃全部冲突，不调用专用比较或解决接口。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-conflict-page.cjs\n验证冲突页读取、丢弃确认、普通操作组提交与失败保护。'); process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents','sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function fixture() {
  const filename=path.resolve('entry/src/main/ets/pages/ConflictFile.ets');
  const source=fs.readFileSync(filename,'utf8').split('  build()')[0].replace(/@Entry\n|@Component\n|@State /g,'').replace('struct ConflictFile','class ConflictFile')+'}\nmodule.exports=ConflictFile;';
  const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  let failure,navigationFailure,backs=0,coreId='core',file;
  const requests=[],dialogs=[];
  const repo={ get id(){return coreId;},async file(value){assert.equal(value,'a.org');return file;} };
  const config={repos:[{id:'config',webdavEnabled:true}],todoDefaults:''};
  const dependencies={
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:value=>Buffer.from(value).toString('utf8')})}}},
    '../services/AppConfigService':{AppConfigService:{async load(){return config;}}},
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message,NativeCoreService:{async repository(){return repo;},async executeTaskOperations(repos,group){requests.push(group);await new Promise(resolve=>setImmediate(resolve));if(failure)throw failure;}}}
  };
  const module={exports:{}};vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(name=>{assert.ok(name in dependencies,name);return dependencies[name];},module,module.exports);
  const page=new module.exports();page.getUIContext=()=>({getHostContext:()=>({}),showAlertDialog:dialog=>dialogs.push(dialog),getRouter:()=>({getParams:()=>({repoId:'config',path:'a.org'}),back:()=>{if(navigationFailure)throw new Error('导航失败');backs++;}})});
  file={fileVersion:'version',conflictIds:['first','second'],sourceBytes:()=>Buffer.from('* 同步冲突 :CONFLICT:\n'),renderHtml:()=>'<h1>同步冲突</h1>'};
  return {page,requests,dialogs,backs:()=>backs,fail:value=>failure=value,navigationFail:()=>navigationFailure=true,replaceRepo:()=>coreId='other',clear:()=>file={...file,conflictIds:[]},config};
}

test('读取使用普通文件对象，显示内容和定位 ID，不产生写入',async()=>{
  const f=fixture();await f.page.load();assert.deepEqual(f.page.file.conflictIds,['first','second']);assert.match(f.page.content,/同步冲突/);assert.equal(f.requests.length,0);
});
test('顶部丢弃需确认，取消不修改文件',async()=>{
  const f=fixture();await f.page.load();f.page.confirmDiscard();assert.equal(f.dialogs.length,1);f.dialogs[0].primaryButton.action();assert.equal(f.requests.length,0);assert.equal(f.backs(),0);
});
test('一次操作组丢弃全部 ID，携带快照版本，提交期间阻止返回和重复保存',async()=>{
  const f=fixture();await f.page.load();const pending=f.page.discardAll();await new Promise(resolve=>setImmediate(resolve));assert.equal(f.page.onBackPress(),true);await f.page.discardAll();await pending;
  assert.equal(f.requests.length,1);assert.deepEqual(f.requests[0],{operations:[{type:'ConfilictSelection',data:{id:'first',action:'discard'}},{type:'ConfilictSelection',data:{id:'second',action:'discard'}}],fileVersions:[{repoId:'core',file:'a.org',version:'version'}],queueRepoIds:['core']});assert.equal(f.backs(),1);
});
test('版本或存储失败不返回，保留文件快照供重新读取',async()=>{
  const f=fixture();await f.page.load();f.fail(new Error('文件已改变'));await f.page.discardAll();assert.equal(f.backs(),0);assert.match(f.page.message,/文件已改变/);assert.ok(f.page.file);assert.equal(f.page.saving,false);
});
test('仓库身份变化拒绝写入，本地仓库不登记上传意图',async()=>{
  const f=fixture();await f.page.load();f.replaceRepo();await f.page.discardAll();assert.equal(f.requests.length,0);assert.match(f.page.message,/仓库已改变/);
  const local=fixture();local.config.repos[0].webdavEnabled=false;await local.page.load();await local.page.discardAll();assert.deepEqual(local.requests[0].queueRepoIds,[]);
});
test('无冲突时无写入，成功后导航失败也不会重复提交',async()=>{
  const f=fixture();f.clear();await f.page.load();await f.page.discardAll();assert.equal(f.requests.length,0);
  const failed=fixture();await failed.page.load();failed.navigationFail();await failed.page.discardAll();assert.match(failed.page.message,/已丢弃/);await failed.page.discardAll();assert.equal(failed.requests.length,1);
});
