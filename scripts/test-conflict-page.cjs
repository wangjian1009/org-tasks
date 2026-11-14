// 验证临时预览只记录操作，结束后由页面通过统一数据接口提交。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-conflict-page.cjs\n验证逐点预览、finish 返回操作组、统一提交、预览刷新与失败保护。'); process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents','sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const treeModule={exports:{}};
vm.runInThisContext('(function(require,module,exports){'+ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/ConflictTargetTree.ets','utf8'),
 {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText+'\n})')(()=>({}),treeModule,treeModule.exports);
const targetTree=treeModule.exports;
const sourcePath = { repoId: 'core', file: 'a.org', titles: [], occurrence: 1 };
const nodePath = { ...sourcePath, titles: ['Task'] };
const conflicts = ['first', 'second'].map(id => ({ id, title: id, reason: 'modify', availableActions: ['discard','useLocal'], suggestedTarget: { type: 'existing', data: nodePath }, requiresTarget: false, candidateContent:'local '+id, candidateHtml:'<p>local '+id+'</p>', displayAnchor:null, displayAtTarget:false }));
function fixture(params = {repoId:'config',path:'a.org'}) {
  const filename = path.resolve('entry/src/main/ets/pages/ConflictFile.ets');
  const source = fs.readFileSync(filename,'utf8').split('  @Builder\n')[0].replace(/@Entry\n|@Component\n|@State /g,'').replace('struct ConflictFile','class ConflictFile')+'}\nmodule.exports=ConflictFile;';
  const code = ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const requests=[], dialogs=[], events=[], handles=[];
  let failure, submitWait, stageFailure, projectionFailure, projectionWait, targetRequired=false, coreId='core', backs=0, creates=0;
  const makeFile = (repoId='core', file='a.org', version='v1', ids=['first','second'], text) => ({
    repoId, path:file, fullPath:{repoId,file,titles:[],occurrence:1}, fileVersion:version, conflictIds:ids,
    hasConflict:ids.length>0, sourceBytes:()=>Buffer.from(text ?? ('* TODO Task\nremote\n' + (ids.length ? '\n* 同步冲突 :CONFLICT:ARCHIVE:\n** 候选\n:CONFILICT_ID: hidden\n' : ''))), renderHtml:()=>'<details class="heading"><summary>Task</summary></details>' + (ids.length ? '<details><summary>同步冲突</summary></details>' : ''), title:()=>null, titleParts:()=>[],
    conflicts:()=>conflicts.filter(c=>ids.includes(c.id)).map(c=>({...c,requiresTarget:targetRequired,suggestedTarget:targetRequired?null:{type:'existing',data:{...nodePath,repoId,file}}})),
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
      let copied=makeFile('<preview>',id,'copy1',[]), done=false, pending=[...realFile.conflictIds];
      const handle={id,fullPath:copied.fullPath,sourcePath,sourceVersion:original.fileVersion,conflictId:request.conflictId,expired:false,
        async file(){if(done||handle.expired)throw new Error('预览已结束');return copied;},
        async sourceFile(){return makeFile('core','a.org','main-source',[]);},
        async conflicts(){return makeFile('<preview>',id,'materials',pending).conflicts();},
        async changes(){return {sourceVersion:original.fileVersion,previewVersion:copied.fileVersion,changes:copied.sourceBytes().toString('utf8')==='* TODO Task\nremote\n'?[]:[{area:'main',kind:'replace',before:null,after:null,lines:[]}]};},
        async project(request){
          events.push('project');if(projectionWait)await projectionWait;if(projectionFailure)throw projectionFailure;
          assert.equal(request.previewVersion,copied.fileVersion);
          const needsTarget=targetRequired&&!request.target;
          return {conflictId:request.conflictId,workingVersion:copied.fileVersion,status:needsTarget?'targetRequired':'ready',
            beforeText:needsTarget?'':'remote\n',afterText:`local ${request.conflictId}\n`,
            content:needsTarget?'* TODO Task\nremote\n':`* TODO Task\nlocal ${request.conflictId}\n`,renderedHtml:`<p>local ${request.conflictId}</p>`,
            changes:{sourceVersion:original.fileVersion,previewVersion:needsTarget?copied.fileVersion:`projection-${request.conflictId}`,changes:needsTarget?[]:[{area:'main',kind:'replace',before:null,after:null,lines:[{kind:'removed',text:'remote\n'},{kind:'added',text:`local ${request.conflictId}\n`}]}]}};
        },
        async finish(options){events.push('finish');assert.equal(options.previewVersion,copied.fileVersion);done=true;return {operations:remap(operations),fileVersions:[{repoId:'core',file:'a.org',version:original.fileVersion}],queueRepoIds:[]};},
        async discard(){events.push('discard');handle.expired=true;},
        change(){copied=makeFile('<preview>',id,'manually-edited',copied.conflictIds,'* TODO Adjusted\n');},
        stage(group){operations.push(...group.operations);pending=pending.filter(value=>!group.operations.some(op=>op.type==='ConfilictSelection'&&op.data.id===value));copied=makeFile('<preview>',id,'copy2',[],group.operations.some(op=>op.data.action==='useLocal')?'* TODO Task\nlocal\n':copied.sourceBytes().toString('utf8'));}
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
    '../components/OrgFilePreviewView':{OrgFilePreviewNavigation:class{closePanel(){return false;}focusChange(){} focusFooter(){} focusConflictCard(id){this.focused=id;} async capturePosition(){return 240;}restorePosition(){};}},
    '../ui/ConflictTargetTree':targetTree,
    '../services/AppConfigService':{AppConfigService:{async load(){return config;}}},
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message,NativeCoreService:{async workspaceFor(){return workspace;},async repository(){return repo;},async executeTaskOperations(repos,group){return workspace.executeTaskOperations(group);}}},
    '../ui/Theme':{repositoryLabel:()=> '测试仓库', UiColor:{error:'#FF7592'}}
  };
  const module={exports:{}};
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(name=>{assert.ok(name in dependencies,name);return dependencies[name];},module,module.exports);
  const page=new module.exports();
  page.getUIContext=()=>({getHostContext:()=>({cacheDir:'/cache'}),showAlertDialog:dialog=>dialogs.push(dialog),getRouter:()=>({getParams:()=>params,back:()=>{backs++;},async pushUrl(){}})});
  return {page,requests,dialogs,events,handles,config,creates:()=>creates,backs:()=>backs,requireTarget:()=>targetRequired=true,fail:value=>failure=value,stageFail:value=>stageFailure=value,projectionFail:value=>projectionFailure=value,projectionWait:value=>projectionWait=value,wait:value=>submitWait=value,replaceRepo:()=>coreId='other',externalEdit:()=>realFile=makeFile('core','a.org','external')};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));

test('进入页面创建纯主树预览，独立读取冲突列表且不提交源文件',async()=>{
 const f=fixture();await f.page.load();assert.equal(f.page.conflicts.length,2);assert.equal(f.creates(),1);assert.equal(f.requests.length,0);assert.equal(f.page.baseFile.hasConflict,false);assert.equal(f.page.previewFile.conflicts().length,0);
 assert.equal(f.page.selectedId,'first');assert.equal(f.page.beforeText,'');assert.equal(f.page.afterText,'');assert.equal(f.events.includes('project'),false);assert.equal(f.page.stagedAction,'');assert.equal(f.page.canApply(),false);
});
test('定位卡片保留全部文档和卡片，不读取投影、不执行取舍',async()=>{
 const f=fixture();await f.page.load();const html=f.page.html,content=f.page.content,revision=f.page.renderRevision;
 f.page.selectConflict(f.page.conflicts[1]);await tick();
 assert.equal(f.page.selectedId,'second');assert.equal(f.page.navigation.focused,'second');
 assert.equal(f.page.content,content);assert.equal(f.page.html,html);assert.equal(f.page.renderRevision,revision);
 assert.equal(f.events.includes('project'),false);assert.equal(f.requests.length,0);assert.equal(f.creates(),1);
 assert.equal(f.page.conflictCards().length,2);
});
test('底部左右按钮循环切换当前冲突',async()=>{
 const f=fixture();await f.page.load();f.page.selectAdjacent(1);await tick();assert.equal(f.page.selectedId,'second');
 f.page.selectAdjacent(1);await tick();assert.equal(f.page.selectedId,'first');assert.equal(f.requests.length,0);
});
test('详情卡应用按钮按冲突原因显示插入放置删除',async()=>{
 const f=fixture();await f.page.load();assert.equal(f.page.applyLabel(),'应用');
 f.page.conflicts[0].reason='create';assert.equal(f.page.applyLabel(),'插入');
 f.page.conflicts[0].reason='missing-parent';assert.equal(f.page.applyLabel(),'放置');
 f.page.conflicts[0].reason='delete';assert.equal(f.page.applyLabel(),'删除');
});
test('差异读取失败保留冲突身份与当前主树，重试不提前取舍',async()=>{
 const f=fixture();await f.page.load();f.projectionFail(new Error('差异读取失败'));f.page.selectConflict(f.page.conflicts[1]);await f.page.applyChoice();
 assert.equal(f.page.selectedId,'second');assert.equal(f.page.projection,undefined);assert.equal(f.page.afterText,'');assert.match(f.page.content,/remote/);assert.match(f.page.message,/差异读取失败/);
 assert.equal(f.page.canApply(),false);f.projectionFail(undefined);await f.page.retryPreview();assert.equal(f.page.afterText,'local second\n');assert.equal(f.requests.length,0);
});
test('过期的异步差异不会覆盖新冲突详情',async()=>{
 const f=fixture();await f.page.load();let release;f.projectionWait(new Promise(resolve=>release=resolve));
 const old=f.page.readProjection();f.page.requestId++;f.page.selectedId='second';release();await old;
 assert.equal(f.page.selectedId,'second');assert.equal(f.page.afterText,'');
 f.projectionWait(undefined);await f.page.readProjection();assert.equal(f.page.afterText,'local second\n');
});
test('目标未确定时展示候选，选择目标只读取差异，确认采用才记录操作',async()=>{
 const f=fixture();f.requireTarget();await f.page.load();await f.page.readProjection();
 assert.equal(f.page.projection.status,'targetRequired');assert.equal(f.page.summaryText(true),'待选择目标后比较');assert.equal(f.page.mainChangeCount(),0);assert.equal(f.requests.length,0);
 f.page.openTargets();await f.page.chooseTarget(f.page.targetRows().find(row=>row.target));
 assert.equal(f.page.projection.status,'ready');assert.equal(f.page.canApply(),false);assert.equal(f.requests.length,0);
 await f.page.stage('useLocal',f.page.selectedTarget);assert.equal(f.requests.length,1);assert.equal(f.page.canApply(),true);
});
test('逐点预览只编辑副本，finish 后才经统一接口提交源操作',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');
 assert.equal(f.requests.length,1);assert.equal(f.requests[0].fileVersions[0].repoId,'<preview>');assert.deepEqual(f.requests[0].queueRepoIds,[]);assert.equal(f.page.file.conflictIds.length,2);
 await f.page.applyPreview();assert.deepEqual(f.events.filter(e=>['create','stage','finish','submit'].includes(e)).slice(0,4),['create','stage','finish','submit']);
 const applied=f.requests[1];assert.equal(applied.operations[0].data.path.repoId,'core');assert.equal(applied.operations[0].data.target.data.file,'a.org');assert.deepEqual(applied.fileVersions,[{repoId:'core',file:'a.org',version:'v1'}]);assert.deepEqual(applied.queueRepoIds,['core']);assert.equal(f.page.conflicts.length,1);assert.equal(f.page.preview.conflictId,'second');assert.equal(f.page.previewFile.hasConflict,false);
});
test('统一提交失败可重试同一操作组，不重复 finish 或再次读取已结束副本',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'discard');f.fail(new Error('存储失败'));await f.page.applyPreview();assert.match(f.page.message,/存储失败/);assert.ok(f.page.pendingGroup);assert.ok(f.page.previewFile);
 f.fail(undefined);f.page.message='';await f.page.applyPreview();assert.equal(f.events.filter(e=>e==='finish').length,1);assert.equal(f.events.filter(e=>e==='submit').length,2);
});
test('源文件变化拒绝提交，保留调整快照并禁用应用',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');f.externalEdit();await f.page.applyPreview();assert.equal(f.page.stale,true);assert.equal(f.page.canApply(),false);assert.ok(f.page.previewFile);
});
test('预览版本变化后重读同一 preview，不重新复制；切换先确认放弃调整',async()=>{
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

function repositoryRow(hasConflict, project = null) {
 const filename=path.resolve('entry/src/main/ets/components/NotebookFileRow.ets');
 const source=fs.readFileSync(filename,'utf8').split('  build()')[0].replace(/@Component\n|@Prop /g,'').replace('export struct NotebookFileRow','class NotebookFileRow')+'}\nmodule.exports=NotebookFileRow;';
 const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
 const module={exports:{}};
 vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(()=>({}),module,module.exports);
 const row=new module.exports();
 row.file={repoId:'core',path:'a.org',hasConflict,project:()=>project};row.configRepoId='config';
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

test('正文、当前文件和预览只展示主树，原文件的候选仍由独立列表读取',async()=>{
 const f=fixture();await f.page.load();
 assert.match(f.page.file.sourceBytes().toString('utf8'),/同步冲突/);
 assert.doesNotMatch(f.page.content,/同步冲突|CONFILICT_ID/);
 assert.doesNotMatch(f.page.html,/同步冲突/);
 assert.equal(f.page.conflicts.length,2);
 await f.page.prepare(f.page.conflicts[0],'useLocal');
 assert.match(f.page.baseFile.sourceBytes().toString('utf8'),/remote/);assert.doesNotMatch(f.page.baseFile.sourceBytes().toString('utf8'),/同步冲突|CONFILICT_ID/);
 assert.match(f.page.content,/local/);assert.doesNotMatch(f.page.content,/同步冲突|CONFILICT_ID/);
});

test('已读取差异时点击一次应用即完成真实提交，且保留其他冲突',async()=>{
 const f=fixture();await f.page.load();await f.page.applyChoice();
 assert.deepEqual(f.events.filter(e=>['stage','finish','submit'].includes(e)),['stage','finish','submit']);
 assert.equal(f.page.conflicts.length,1);assert.equal(f.page.conflicts[0].id,'second');
 f.page.selectAdjacent(1);await tick();assert.equal(f.page.selectedId,'second');
});
test('单次丢弃只移除当前冲突，失败可重试且不重复 finish',async()=>{
 const f=fixture();await f.page.load();f.fail(new Error('存储失败'));await f.page.discardChoice();
 assert.match(f.page.message,/存储失败/);assert.ok(f.page.pendingGroup);
 assert.equal(f.requests.at(-1).operations[0].data.action,'discard');
 f.fail(undefined);f.page.message='';await f.page.applyPreview();
 assert.equal(f.events.filter(e=>e==='finish').length,1);assert.equal(f.page.conflicts.length,1);
});
test('替换主树明确确认范围，确认一次即提交；提交期间阻止重复点击',async()=>{
 const f=fixture();await f.page.load();f.page.conflicts[0].reason='structure';
 assert.equal(f.page.applyLabel(),'替换主树');await f.page.applyChoice();assert.equal(f.requests.length,0);
 let release;f.wait(new Promise(resolve=>release=resolve));f.dialogs[0].secondaryButton.action();await tick();
 assert.equal(f.page.saving,true);await f.page.applyChoice();assert.equal(f.events.filter(e=>e==='submit').length,1);
 assert.deepEqual(f.requests.at(-1).operations[0].data.target,{type:'replaceMain'});
 release();await tick();await tick();assert.equal(f.page.conflicts.length,1);
});
test('手动编辑后丢弃先确认，只提交当前冲突的丢弃而不提交手动内容',async()=>{
 const f=fixture();await f.page.load();await f.page.prepare(f.page.conflicts[0],'useLocal');
 f.handles.at(-1).change();await f.page.refreshPreview();assert.equal(f.page.manuallyEdited,true);
 await f.page.discardChoice();assert.equal(f.events.includes('submit'),false);assert.equal(f.dialogs.length,1);
 f.dialogs[0].primaryButton.action();assert.equal(f.page.manuallyEdited,true);
 await f.page.discardChoice();f.dialogs[1].secondaryButton.action();await tick();await tick();
 assert.equal(f.events.filter(e=>e==='submit').length,1);
 assert.deepEqual(f.requests.at(-1).operations.map(op=>op.data.action),['discard']);
 assert.equal(f.page.conflicts.length,1);
});
test('副本取舍失败时不 finish、不提交，原文件与其他冲突保持原样',async()=>{
 const f=fixture();await f.page.load();f.stageFail(new Error('副本写入失败'));await f.page.applyChoice();
 assert.equal(f.events.includes('finish'),false);assert.equal(f.events.includes('submit'),false);
 assert.match(f.page.message,/副本写入失败/);assert.equal(f.page.conflicts.length,2);
 f.stageFail(undefined);f.page.message='';await f.page.applyChoice();
 assert.equal(f.events.filter(e=>e==='submit').length,1);assert.equal(f.page.conflicts.length,1);
});
test('未选目标时卡片操作才打开目标面板，选择不提交，之后单次应用提交',async()=>{
 const f=fixture();f.requireTarget();await f.page.load();assert.equal(f.page.targetsVisible,false);await f.page.applyChoice();
 assert.equal(f.page.targetsVisible,true);assert.ok(f.page.targetRoot);
 await f.page.applyChoice();assert.equal(f.requests.length,0);
 const row=f.page.targetRows().find(row=>row.target);await f.page.chooseTarget(row);
 assert.equal(f.requests.length,0);assert.equal(f.page.targetsVisible,false);
 assert.equal(f.page.selectedTargetLabel(),'Task');await f.page.applyChoice();
 assert.equal(f.events.filter(e=>e==='submit').length,1);
});
test('树形目标保留重名父级身份及所有 Core 插入位置，折叠只影响展示',()=>{
 const path=(titles,occurrence=1)=>({...nodePath,titles,occurrence});
 const paths=[path(['分组']),path(['分组','子任务']),path(['分组'],2),path(['分组','子任务'],2)];
 const positions=[{parent:sourcePath}];
 for(let i=0;i<paths.length;i++)positions.push({parent:paths[i]},{parent:i%2?paths[i-1]:sourcePath,after:paths[i]});
 const file={fullPath:sourcePath,path:'a.org',title:()=> 'A',
  nodes:()=>paths.map(p=>({fullPath:p,heading:p.titles.at(-1)})),insertionPositions:()=>positions};
 const root=targetTree.conflictTargetTree(file,'missing-parent');
 assert.equal(root.children.length,2);assert.equal(root.children[0].children.length,1);
 assert.equal(root.children[1].children[0].path.occurrence,2);
 const expanded=[root.key,...root.children.map(n=>n.key),...root.children.flatMap(n=>n.children.map(c=>c.key))];
 const rows=targetTree.conflictTargetRows(root,expanded);assert.equal(new Set(rows.map(r=>r.key)).size,rows.length);
 assert.deepEqual(rows.filter(r=>r.target).map(r=>r.target.data),[
  positions[0],positions[1],positions[3],positions[4],positions[2],positions[5],positions[7],positions[8],positions[6]]);
 assert.equal(targetTree.conflictTargetRows(root,[]).length,1);
 const existing=targetTree.conflictTargetTree(file,'modify');
 assert.equal(existing.target,undefined);assert.equal(existing.children[1].target.data.occurrence,2);
});


test('仓库项目文件使用 Core 身份进入项目文档，冲突入口优先',()=>{
 assert.equal(repositoryRow(false,'项目').url,'pages/ProjectDetail');
 assert.deepEqual(repositoryRow(false,'项目').params,{repoId:'core',path:'a.org'});
 assert.equal(repositoryRow(false,'').url,'pages/ProjectDetail');
 assert.equal(repositoryRow(true,'项目').url,'pages/ConflictFile');
});
