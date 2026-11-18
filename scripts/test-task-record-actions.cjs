// 验证单条与批量共用的恢复语义、确认、冻结快照和数据集提交。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-record-actions.cjs\n验证重新打开、原位置恢复、永久清除、操作确认、多选快照与失败保留。'); process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(name, mocks = {}) {
  const file = `entry/src/main/ets/${name}.ets`;
  const source = fs.readFileSync(file, 'utf8').replace(/^@Observed\n/gm, '');
  const code = ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module = {exports:{}};
  vm.runInThisContext('(function(require,module,exports,$r){'+code+'\n})', {filename:file})(dependency => {
    assert.ok(Object.hasOwn(mocks,dependency),`缺少替身 ${dependency}`); return mocks[dependency];
  }, module,module.exports, name=>name);
  return module.exports;
}
const actions = compile('ui/TaskActionPresentation');
const groups = compile('services/TaskOperationGroups');
const task = (id, name='NEXT', version='v1') => ({id,repoId:'repo',filePath:'tasks.org',fileVersion:version,heading:id,
  fullPath:{repoId:'repo',file:'tasks.org',titles:[id],occurrence:1},
  taskStateOf(category){assert.equal(category,'Todo');return name ? {name} : null;}});
function fixture() {
  const writes=[],dialogs=[],operations=[],rows=new Map([['A',task('A')],['B',task('B')]]);
  let fail, wait, saveAllowed=true, saveWait;
  const {TaskRecordOperations: service}=compile('services/TaskRecordOperations', {
    './AppConfigService':{AppConfigService:{load:async()=>({repos:[]})}},
    './NativeCoreService':{NativeCoreService:{workspaceFor:async()=>({})}},
    './TrashService':{TrashService:{group:async(_config,_workspace,tasks,action)=>{
      operations.push(action);return groups.mergeTaskOperationGroups(tasks.map(t=>({
        operations:[{type:{trash:'Trash',restore:'Restore',clear:'Deletion'}[action],data:{path:t.fullPath}}],
        fileVersions:[{repoId:t.repoId,file:t.filePath,version:t.fileVersion}]})));
    }}}, './TaskOperationGroups':groups,'../ui/TaskActionPresentation':actions,
    '../ui/TaskStatePresentation':{TaskStateCategory:{Todo:'Todo'}}
  });
  const {TaskRecordActionController: Runner}=compile('ui/TaskRecordActionController',{
    '../services/TaskRecordOperations':{TaskRecordOperations:service},'./TaskActionPresentation':actions,'./Theme':{UiColor:{error:'red'}}});
  const session={end:async()=>{if(saveWait)await saveWait;return saveAllowed}};
  const {TaskSelectionController: Selection}=compile('ui/TaskSelectionController',{
    '../services/NativeCoreService':{coreErrorMessage:error=>error.message},
    '../services/TaskInlineService':{TaskInlineSession:session},
    '../services/TaskRecordOperations':{TaskRecordOperations:service},'./TaskActionPresentation':actions,
    './TaskRecordActionController':{TaskRecordActionController:Runner}
  });
  const dataSet={identity:'scope',isReady:()=>true,error:'',taskKey:id=>id,getTask:id=>rows.get(id),settle:async()=>{},
    submitOperationGroup:async(group,allowed)=>{assert.equal(allowed(),true);writes.push(group);if(wait)await wait;if(fail)throw fail;}};
  const context={getHostContext:()=>({}),showAlertDialog:dialog=>dialogs.push(dialog)};
  const selection=new Selection();let enabled=['delete','reopen','restore','clear'],ready=true;
  selection.connect(dataSet,()=>Array.from(rows.values()),()=>enabled,()=>ready,{closeAllSwipeActions(){}});
  return {service,Runner,selection,dataSet,context,writes,dialogs,rows,operations,
    fail:error=>fail=error,wait:value=>wait=value,save:value=>saveAllowed=value,saveWait:value=>saveWait=value,
    enable:value=>enabled=value,ready:value=>ready=value};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('Reopen 按每个文件有效 Todo 状态规划单组，不清空其他字段；混合版本与缺失状态拒绝整组',async()=>{
  const f=fixture(), a=task('A','NEXT'), b=task('B','OPEN');
  const group=await f.service.group({},[a,b],'reopen');
  assert.deepEqual(group.operations.map(op=>op.data.modifications),[[{field:'TODO',value:'NEXT'}],[{field:'TODO',value:'OPEN'}]]);
  assert.equal(group.fileVersions.length,1);assert.equal(f.writes.length,0);
  await assert.rejects(f.service.group({},[a,task('B',null)],'reopen'),/没有可用/);
  await assert.rejects(f.service.group({},[a,task('B','NEXT','v2')],'reopen'),/版本不一致/);
});
test('Restore、Clear、Delete 语义固定且规划阶段零写入',async()=>{
  const f=fixture();for(const action of ['restore','clear','delete'])await f.service.group({},[task('A')],action);
  assert.deepEqual(f.operations,['restore','clear','trash']);assert.equal(f.writes.length,0);
});
test('清除确认取消、点击遮罩或控件离开都不写入，迟到确认也无效',async()=>{
  for(const mode of ['cancel','mask','leave']){
    const f=fixture(),runner=new f.Runner();let active=true;
    const pending=runner.execute(f.context,f.dataSet,[task('A')],'clear',()=>active);await tick();
    assert.equal(f.writes.length,0);const dialog=f.dialogs[0];assert.match(dialog.message,/无法恢复/);
    if(mode==='leave'){active=false;runner.close();}else if(mode==='cancel')dialog.primaryButton.action();else dialog.cancel();
    dialog.secondaryButton.action();assert.equal((await pending).committed,false);assert.equal(f.writes.length,0);
  }
});
test('删除确认后提交一次冻结版本，确认期间条件失效不写入',async()=>{
  const f=fixture(),runner=new f.Runner();let allowed=true;
  const cancelled=runner.execute(f.context,f.dataSet,[task('A')],'delete',()=>allowed);await tick();
  allowed=false;f.dialogs[0].secondaryButton.action();await cancelled;assert.equal(f.writes.length,0);
  allowed=true;const pending=runner.execute(f.context,f.dataSet,[task('A')],'delete',()=>allowed);await tick();
  f.dialogs[1].secondaryButton.action();f.dialogs[1].secondaryButton.action();await pending;
  assert.equal(f.writes.length,1);assert.equal(f.writes[0].fileVersions[0].version,'v1');
});
test('多选进入等待草稿确认，保存失败、源消失、生命周期结束或数据集重绑均不进入',async()=>{
  const failed=fixture();failed.save(false);await failed.selection.start('A');assert.equal(failed.selection.selecting,false);
  for(const mode of ['missing','closed','rebound']){
    const f=fixture();let finish;f.saveWait(new Promise(resolve=>finish=resolve));const pending=f.selection.start('A');
    assert.equal(f.selection.starting,true);await f.selection.start('B');
    if(mode==='missing')f.rows.delete('A');else if(mode==='closed')f.selection.close();else f.dataSet.identity='new';
    finish();await pending;assert.equal(f.selection.selecting,false);
  }
});
test('外部刷新不覆盖选择顺序或源版本，取消首条后保持其余选择；未启用动作零提交',async()=>{
  const f=fixture();await f.selection.start('A');f.selection.toggle('B');
  f.rows.set('A',task('A','NEXT','v2'));f.rows.set('B',task('B','NEXT','v2'));
  await f.selection.start('B');assert.deepEqual(f.selection.selectedKeys,['A','B']);
  f.enable(['delete']);await f.selection.execute(f.context,'reopen');assert.equal(f.writes.length,0);
  f.enable(['reopen']);f.selection.toggle('A');await f.selection.execute(f.context,'reopen');
  assert.equal(f.writes.length,1);assert.equal(f.writes[0].operations[0].data.path.titles[0],'B');
  assert.equal(f.writes[0].fileVersions[0].version,'v1');assert.equal(f.selection.selecting,false);
});
test('批量提交失败保留选择和快照，提交期间重复动作与退出均被阻止',async()=>{
  const f=fixture();await f.selection.start('A');f.selection.toggle('B');let finish;
  f.wait(new Promise(resolve=>finish=resolve));f.fail(new Error('旧文件版本'));
  const pending=f.selection.execute(f.context,'reopen');await tick();assert.equal(f.selection.busy,true);
  await f.selection.execute(f.context,'reopen');f.selection.reset();f.selection.toggle('A');
  assert.deepEqual(f.selection.selectedKeys,['A','B']);assert.equal(f.writes.length,1);
  finish();await pending;assert.equal(f.selection.busy,false);assert.equal(f.selection.message,'旧文件版本');
  assert.equal(f.selection.selecting,true);assert.deepEqual(f.selection.selectedKeys,['A','B']);
});
test('混合批量恢复只保留失败项，成功后的新废纸篓版本用于再次恢复',async()=>{
  const f=fixture();await f.selection.start('A');f.selection.toggle('B');
  f.dataSet.submitOperationGroup=async(group,allowed)=>{assert.equal(allowed(),true);f.writes.push(group);f.rows.delete('A');f.rows.set('B',task('B','NEXT','v2'));};
  await f.selection.execute(f.context,'restore');assert.deepEqual(f.selection.selectedKeys,['B']);
  assert.match(f.selection.message,/1 条记录原位置不可用/);assert.equal(f.selection.selecting,true);
  f.dataSet.submitOperationGroup=async(group,allowed)=>{assert.equal(allowed(),true);f.writes.push(group);f.rows.delete('B');};
  await f.selection.execute(f.context,'restore');assert.equal(f.writes[1].fileVersions[0].version,'v2');assert.equal(f.selection.selecting,false);
});
test('选择后数据集重绑或删除菜单被撤销时，旧确认不能继续提交',async()=>{
  for(const mode of ['scope','policy']){
    const f=fixture();await f.selection.start('A');const pending=f.selection.execute(f.context,'delete');await tick();
    if(mode==='scope')f.dataSet.identity='new';else f.enable([]);
    f.dialogs[0].secondaryButton.action();await pending;assert.equal(f.writes.length,0);assert.equal(f.selection.selecting,true);
  }
});

test('部分恢复后未选中的存活行仍可加入选择，使用本次成功提交后的确认版本',async()=>{
  const f=fixture();f.rows.set('C',task('C'));await f.selection.start('A');f.selection.toggle('B');
  f.dataSet.submitOperationGroup=async()=>{f.rows.delete('A');f.rows.set('B',task('B','NEXT','v2'));f.rows.set('C',task('C','NEXT','v2'));};
  await f.selection.execute(f.context,'restore');f.selection.toggle('C');assert.deepEqual(f.selection.selectedKeys,['B','C']);
  f.dataSet.submitOperationGroup=async(group)=>{f.writes.push(group);f.rows.clear();};
  await f.selection.execute(f.context,'restore');assert.equal(f.writes[0].fileVersions[0].version,'v2');assert.equal(f.writes[0].operations.length,2);
});
