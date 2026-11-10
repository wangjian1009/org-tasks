// 验证临时预览只记录操作，结束后由页面通过统一数据接口提交。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-conflict-page.cjs\n验证逐点预览、finish 返回操作组、统一提交、编辑返回与失败保护。'); process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents','sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourcePath = { repoId: 'core', file: 'a.org', titles: [], occurrence: 1 };
const nodePath = { ...sourcePath, titles: ['Task'] };
const conflicts = ['first', 'second'].map(id => ({ id, title: id, reason: 'modify', availableActions: ['discard','useLocal'], suggestedTarget: { type: 'existing', data: nodePath }, requiresTarget: false }));
function fixture(params = {repoId:'config',path:'a.org'}) {
  const filename = path.resolve('entry/src/main/ets/pages/ConflictFile.ets');
  const source = fs.readFileSync(filename,'utf8').split('  @Builder\n')[0].replace(/@Entry\n|@Component\n|@State /g,'').replace('struct ConflictFile','class ConflictFile')+'}\nmodule.exports=ConflictFile;';
  const code = ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const requests=[], dialogs=[], events=[], handles=[];
  let failure, submitWait, stageFailure, coreId='core', backs=0, creates=0;
  const makeFile = (repoId='core', file='a.org', version='v1', ids=['first','second'], text='* TODO Task\nremote\n') => ({
    repoId, path:file, fullPath:{repoId,file,titles:[],occurrence:1}, fileVersion:version, conflictIds:ids,
    hasConflict:ids.length>0, sourceBytes:()=>Buffer.from(text), renderHtml:()=>'<details class="heading"><summary>Task</summary></details>', title:()=>null,
    conflicts:()=>conflicts.filter(c=>ids.includes(c.id)).map(c=>({...c,suggestedTarget:{type:'existing',data:{...nodePath,repoId,file}}})),
    nodes:()=>[{repoId,filePath:file,fullPath:{...nodePath,repoId,file},fileVersion:version,heading:'Task'}], editableNodePaths:()=>[{...nodePath,repoId,file}], insertionPositions:()=>[]
  });
  let realFile=makeFile();
  const config={repos:[{id:'config',webdavEnabled:true,rootDirectory:'/repo'}],todoDefaults:'',fileDisplayMode:'rendered'};
  const repo={get id(){return coreId;},async file(){return realFile;}};
  function remap(value) {
    if (Array.isArray(value)) return value.map(remap);
    if (value && typeof value==='object') {
      const result=Object.fromEntries(Object.entries(value).map(([key,value])=>[key,remap(value)]));
      if (result.repoId==='<preview>') {result.repoId='core';result.file='a.org';}
      return result;
    }
    return value;
  }
  const workspace={
    async setPreviewRoot(value){assert.equal(value,'/cache/org-conflict-previews');},
    async fileAt(value){assert.equal(value.repoId,'core');return realFile;},
    async createConflictPreview(request){
      events.push('create');creates++;
      assert.deepEqual(request.file,sourcePath);
      if (request.sourceVersion!==realFile.fileVersion) throw Object.assign(new Error('原文件已变化'),{code:'sourceVersionMismatch'});
      for(const previous of handles)previous.expired=true;
      const id=`uuid-${creates}`, original=realFile, operations=[];
      let copied=makeFile('<preview>',id,'copy1',realFile.conflictIds), done=false;
      const handle={id,fullPath:copied.fullPath,sourcePath,sourceVersion:original.fileVersion,conflictId:request.conflictId,expired:false,
        async file(){if(done||handle.expired)throw new Error('预览已结束');return copied;},
        async sourceFile(){return original;},
        async changes(){return {sourceVersion:original.fileVersion,previewVersion:copied.fileVersion,changes:[{area:'main',kind:'replace',before:null,after:null,lines:[]}]};},
        async finish(options){events.push('finish');assert.equal(options.previewVersion,copied.fileVersion);done=true;return {operations:remap(operations),fileVersions:[{repoId:'core',file:'a.org',version:original.fileVersion}],queueRepoIds:[]};},
        async discard(){events.push('discard');handle.expired=true;},
        change(){copied=makeFile('<preview>',id,'manually-edited',copied.conflictIds,'* TODO Adjusted\n');},
        stage(group){operations.push(...group.operations);copied=makeFile('<preview>',id,'copy2',realFile.conflictIds.filter(value=>value!==request.conflictId),'* TODO Task\nlocal\n');}
      };
      handles.push(handle);return handle;
    },
    async executeTaskOperations(group){
      requests.push(group);
      if(group.fileVersions[0].repoId==='<preview>'){
        events.push('stage');if(stageFailure)throw stageFailure;handles.at(-1).stage(group);
      } else {
        events.push('submit');if(submitWait)await submitWait;if(failure)throw failure;
        if(group.fileVersions[0].version!==realFile.fileVersion)throw new Error('任务文件版本已变化');
        const removed=group.operations.filter(v=>v.type==='ConfilictSelection').map(v=>v.data.id);
        realFile=makeFile('core','a.org','saved',realFile.conflictIds.filter(id=>!removed.includes(id)));
      }
      return {paths:[],fallback:{files:[]},tasks:[]};
    }
  };
  const dependencies={
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:value=>Buffer.from(value).toString('utf8')})}}},
    '../components/OrgFilePreviewView':{OrgFilePreviewNavigation:class{closePanel(){return false;}focusChange(){};}},
    '../services/AppConfigService':{AppConfigService:{async load(){return config;}}},
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message,NativeCoreService:{async workspaceFor(){return workspace;},async repository(){return repo;},async executeTaskOperations(repos,group){return workspace.executeTaskOperations(group);}}},
    '../ui/Theme':{repositoryLabel:()=> '测试仓库'}
  };
  const module={exports:{}};
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(name=>{assert.ok(name in dependencies,name);return dependencies[name];},module,module.exports);
  const page=new module.exports();
  page.getUIContext=()=>({getHostContext:()=>({cacheDir:'/cache'}),showAlertDialog:dialog=>dialogs.push(dialog),getRouter:()=>({getParams:()=>params,back:()=>{backs++;},async pushUrl(){}})});
  return {page,requests,dialogs,events,handles,config,creates:()=>creates,backs:()=>backs,fail:value=>failure=value,stageFail:value=>stageFailure=value,wait:value=>submitWait=value,replaceRepo:()=>coreId='other',externalEdit:()=>realFile=makeFile('core','a.org','external')};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));

test('读取冲突列表不会复制或修改文件',async()=>{
 const f=fixture();await f.page.load();assert.equal(f.page.conflicts.length,2);assert.equal(f.creates(),0);assert.equal(f.requests.length,0);
});
test('逐点预览只编辑副本，finish 后才经统一接口提交源操作',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');
 assert.equal(f.requests.length,1);assert.equal(f.requests[0].fileVersions[0].repoId,'<preview>');assert.deepEqual(f.requests[0].queueRepoIds,[]);assert.equal(f.page.file.conflictIds.length,2);
 await f.page.applyPreview();assert.deepEqual(f.events.filter(e=>['create','stage','finish','submit'].includes(e)),['create','stage','finish','submit']);
 const applied=f.requests[1];assert.equal(applied.operations[0].data.path.repoId,'core');assert.equal(applied.operations[0].data.target.data.file,'a.org');assert.deepEqual(applied.fileVersions,[{repoId:'core',file:'a.org',version:'v1'}]);assert.deepEqual(applied.queueRepoIds,['core']);assert.equal(f.page.conflicts.length,1);assert.equal(f.page.preview,undefined);
});
test('统一提交失败可重试同一操作组，不重复 finish 或再次读取已结束副本',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'discard');f.fail(new Error('存储失败'));await f.page.applyPreview();assert.match(f.page.message,/存储失败/);assert.ok(f.page.pendingGroup);assert.ok(f.page.previewFile);
 f.fail(undefined);f.page.message='';await f.page.applyPreview();assert.equal(f.events.filter(e=>e==='finish').length,1);assert.equal(f.events.filter(e=>e==='submit').length,2);
});
test('源文件变化拒绝提交，保留调整快照并禁用应用',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');f.externalEdit();await f.page.applyPreview();assert.equal(f.page.stale,true);assert.equal(f.page.canApply(),false);assert.ok(f.page.previewFile);
});
test('任务编辑返回重读同一 preview，不重新复制；切换先确认放弃调整',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');f.handles[0].change();await f.page.refreshPreview();assert.equal(f.page.manuallyEdited,true);assert.equal(f.creates(),1);
 f.page.selectConflict(f.page.conflicts[1]);assert.equal(f.dialogs.length,1);f.dialogs[0].primaryButton.action();assert.equal(f.creates(),1);assert.equal(f.page.selectedId,'first');
});
test('提交期间阻止重复应用和返回，丢弃全部需确认并校验仓库身份',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'discard');let complete;f.wait(new Promise(resolve=>complete=resolve));const pending=f.page.applyPreview();await tick();assert.equal(f.page.onBackPress(),true);await f.page.applyPreview();assert.equal(f.events.filter(e=>e==='finish').length,1);complete();await pending;
 const g=fixture();await g.page.load();g.page.confirmDiscard();assert.equal(g.requests.length,0);g.dialogs[0].primaryButton.action();g.replaceRepo();await g.page.discardAll();assert.equal(g.requests.length,0);assert.match(g.page.message,/仓库已改变/);
});
test('本地仓库提交不排队上传，取消预览不提交真实操作',async()=>{
 const f=fixture();f.config.repos[0].webdavEnabled=false;await f.page.load();await f.page.prepare(f.page.conflicts[0],'discard');await f.page.applyPreview();assert.deepEqual(f.requests.at(-1).queueRepoIds,[]);
 const g=fixture();await g.page.load();await g.page.prepare(g.page.conflicts[0],'useLocal');await g.page.leave();assert.equal(g.events.includes('submit'),false);assert.equal(g.backs(),1);
});

function repositoryRow(hasConflict) {
 const filename=path.resolve('entry/src/main/ets/components/NotebookFileRow.ets');
 const source=fs.readFileSync(filename,'utf8').split('  build()')[0].replace(/@Component\n|@Prop /g,'').replace('export struct NotebookFileRow','class NotebookFileRow')+'}\nmodule.exports=NotebookFileRow;';
 const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
 const module={exports:{}};
 vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(()=>({}),module,module.exports);
 const row=new module.exports();
 row.file={repoId:'core',path:'a.org',hasConflict};row.configRepoId='config';
 let target;row.getUIContext=()=>({getRouter:()=>({pushUrl(value){target=value;}})});
 row.openFile();return target;
}
test('仓库冲突文件使用配置 ID 打开唯一解决页，Core ID 与配置 ID 不同也能加载',async()=>{
 const target=repositoryRow(true);
 assert.equal(target.url,'pages/ConflictFile');assert.deepEqual(target.params,{repoId:'config',path:'a.org'});
 const f=fixture(target.params);await f.page.load();assert.equal(f.page.message,'');assert.equal(f.page.conflicts.length,2);
});
test('仓库普通文件继续使用 Core ID 打开文件阅读页',()=>{
 const target=repositoryRow(false);assert.equal(target.url,'pages/FileDetail');assert.deepEqual(target.params,{repoId:'core',path:'a.org'});
});
