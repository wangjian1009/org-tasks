// 共享选择控件的宿主替身，真实执行控制器与操作组组装。
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
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
  taskStateOf(category){assert.ok(['Todo','Wait'].includes(category));return name ? {name:category==='Wait'?'HOLD':name} : null;}});
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
    '../ui/TaskStatePresentation':{TaskStateCategory:{Todo:'Todo',Wait:'Wait',Cancel:'Cancel'}}
  });
  const confirmation=compile('components/editors/TaskRecordConfirmation', {
    '../../ui/TaskActionPresentation':actions,'../../ui/Theme':{UiColor:{error:'red'}}});
  const {TaskRecordActionController: Runner}=compile('ui/TaskRecordActionController',{
    '../services/TaskRecordOperations':{TaskRecordOperations:service},'./TaskActionPresentation':actions,'../components/editors/TaskRecordConfirmation':confirmation});
  const planned=[];
  let planWait;
  const planner={async operationGroups(_context,tasks,action,target,date){
    planned.push({tasks,action,target,date});if(planWait)await planWait;
    return tasks.map(t=>({operations:[{type:'Movement',data:{path:t.fullPath,action,target,date}}],fileVersions:[{repoId:t.repoId,file:t.filePath,version:t.fileVersion}]}));
  },async mergePlan(_context,tasks){
    planned.push({tasks,action:'merge'});if(planWait)await planWait;
    return {mainPath:tasks[0].fullPath,operationGroup:groups.mergeTaskOperationGroups(tasks.map(t=>({operations:[{type:'Modification',data:{path:t.fullPath}}],fileVersions:[{repoId:t.repoId,file:t.filePath,version:t.fileVersion}]})))};
  }};
  const batch=compile('services/TaskBatchOperations',{'./InboxService':{InboxService:planner},'./TaskOperationGroups':groups,'../ui/TaskActionPresentation':actions});
  const session={end:async()=>{if(saveWait)await saveWait;return saveAllowed}};
  const {TaskSelectionController: Selection}=compile('ui/TaskSelectionController',{
    '../services/NativeCoreService':{coreErrorMessage:error=>error.message},
    '../services/TaskInlineService':{TaskInlineSession:session},
    '../services/TaskRecordOperations':{TaskRecordOperations:service},'./TaskActionPresentation':actions,
    './TaskRecordActionController':{TaskRecordActionController:Runner},'../services/TaskBatchOperations':batch
  });
  const dataSet={identity:'scope',isReady:()=>true,error:'',taskKey:id=>id,getTask:id=>rows.get(id),settle:async()=>{},
    submitOperationGroup:async(group,allowed)=>{assert.equal(allowed(),true);writes.push(group);if(wait)await wait;if(fail)throw fail;}};
  const context={getHostContext:()=>({}),showAlertDialog:dialog=>dialogs.push(dialog)};
  const selection=new Selection();let enabled=['delete','reopen','restore','clear'],ready=true;
  selection.connect(dataSet,()=>Array.from(rows.values()),()=>enabled,()=>ready,{closeAllSwipeActions(){}});
  return {service,Runner,selection,dataSet,context,writes,dialogs,rows,operations,planned,planWait:value=>planWait=value,
    fail:error=>fail=error,wait:value=>wait=value,save:value=>saveAllowed=value,saveWait:value=>saveWait=value,
    enable:value=>enabled=value,ready:value=>ready=value};
}

module.exports={compile,fixture,task,groups,actions};
