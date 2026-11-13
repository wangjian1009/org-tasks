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
  const task={id:'stable',repoId:'core',filePath:'task.org',fileVersion:'old',fullPath:{repoId:'core',file:'task.org',titles:['Original'],occurrence:1},heading:'Original',tags:['local'],editContent:{notes:'notes',checklist:[]}};
  const updated={...task,heading:'New',fileVersion:'new',fullPath:{...task.fullPath,titles:['New']}};
  let conflict=false, current=task, queryOverride;
  const batches=[];
  const config={repos:[{rootDirectory:'/repo',webdavEnabled:true}],todoDefaults:''};
  const workspace={
    repos:async()=>[{id:'core',rootDirectory:'/repo'}],
    query:async batch=>{batches.push(batch);if(queryOverride)return queryOverride(batch);return batch.map(request=>request.type==='notification' ?
      {type:'notification',result:[]} : {type:'task',result:{tasks:Array.isArray(current)?current:current?[current]:[]}})},
    executeTaskOperations:async group=>{requests.push(group);if(conflict)throw new Error('文件版本冲突');}
  };
  const service=load('entry/src/main/ets/services/TaskInlineService.ets',{
    './AppConfigService':{AppConfigService:{load:async()=>config}},
    './PageQueryService':{PageQueryService:{query:async(_,batch)=>workspace.query([...batch,{type:'notification',query:{}}])}},
    './NativeCoreService':{taskResult:value=>value.result,NativeCoreService:{workspaceFor:async()=>workspace}}
  });
  return {task,updated,config,requests,batches,workspace,query:handler=>queryOverride=handler,...service,conflict:()=>conflict=true,setCurrent:value=>current=value};
}
test('标题修改使用原路径版本并只等待 Core 成功',async()=>{
  const f=fixture();await f.TaskInlineService.modify({},f.task,[{field:'TITLE',value:'New'}]);
  assert.deepEqual(f.requests[0],{operations:[{type:'Modification',data:{path:f.task.fullPath,modifications:[{field:'TITLE',value:'New'}]}}],queueRepoIds:['core'],fileVersions:[{repoId:'core',file:'task.org',version:'old'}]});
});
test('备注、标签和清单操作原样交给 Core，不重建正文',async()=>{
  const f=fixture();const changes=[{field:'NOTES',value:'new notes'},{field:'CHECKLIST',value:{type:'setChecked',id:'123',checked:true}},{field:'TAGS',value:['configured','used']}];
  await f.TaskInlineService.modify({},f.task,changes);assert.deepEqual(f.requests[0].operations[0].data.modifications,changes);
});
test('版本冲突向调用方传播，不拿新版本自动覆盖',async()=>{
  const f=fixture();f.conflict();await assert.rejects(f.TaskInlineService.modify({},f.task,[{field:'NOTES',value:'draft'}]),/版本冲突/);assert.equal(f.requests.length,1);
});
test('无 TODO 标题的进度与完整路径出现次序变化后，按 Core 逻辑身份读取新路径', async () => {
  const f = fixture();
  f.setCurrent(f.updated);
  f.updated.fullPath.occurrence = 2;
  assert.equal(await f.TaskInlineService.reload({}, f.task), f.updated);
  await assert.rejects(f.TaskInlineService.reload({}, { ...f.task, id: 'another-task' }), /任务已删除或改名/);
});

function cardRefreshFixture(emit = true, backend) {
  const filename = 'entry/src/main/ets/components/TaskListItem.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const refresh = source.match(/  dataChanged\(\) \{[\s\S]*?\n  \}\n/)[0];
  const apply = source.match(/  applySnapshot\(current: CoreTask \| undefined, savedCheck: boolean = false\) \{[\s\S]*?\n  \}\n/)[0];
  const persist = source.match(/  async persist\(modifications: CoreTaskModification\[\]\): Promise<boolean> \{[\s\S]*?\n  \}\n/)[0];
  const save = source.match(/  async saveText\(\): Promise<boolean> \{[\s\S]*?\n  \}\n/)[0];
  const remove = source.match(/  removeDeletedTask\(\) \{[\s\S]*?\n  \}\n/)[0];
  const disappear = source.match(/  aboutToDisappear\(\) \{[\s\S]*?\n  \}\n/)[0];
  const code = ts.transpileModule('export class CardRefresh {' + refresh + apply + persist + save + remove + disappear + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  let reads = 0, state;
  const original = backend?.task ?? { id:'task', heading: '任务 [0/2]', editContent: { notes: '备注', checklist: [] }, fileVersion: 'old' };
  const updated = { ...original, heading: '任务 [1/2]', fileVersion: 'new' };
  let current=updated, readError, readOverride;
  const writes=[], released=[];
  let invalidations=0;
  const TaskInlineMissingError = (backend ?? fixture()).TaskInlineMissingError;
  const service = {
    async modify(_context,_task,changes) { if(backend)await backend.TaskInlineService.modify(_context,_task,changes); writes.push(changes); if (emit) { state.dataChanges = {revision: state.dataChanges.revision + 1}; state.dataChanged(); } },
    async findChanged(_context,_task,revision) { reads++; if(readError)throw readError; if(readOverride)return readOverride(revision); return backend ? backend.TaskInlineService.findChanged(_context,_task,revision) : current; }
  };
  vm.runInThisContext('(function(module,exports,TaskInlineService,TaskInlineSession,TaskInlineMissingError,CoreDataChangeService,coreErrorMessage){' + code + '\n})', { filename })(module, module.exports, service,
    {release:key=>released.push(key)},TaskInlineMissingError,{invalidate:()=>invalidations++},error => error.message);
  state = Object.assign(new module.exports.CardRefresh(), {
    task:original,editTask: original, expanded:false,checkFocus:{dispose(){},cancel(){}},heading: original.heading, notes: original.editContent.notes, headingEditing:false,notesEditing:false,
    ownerKey:original.id,appeared:true,dataRevision:0,refreshRequest:0,dataChanges:{revision:0},removed:false,cancelCheckDrag(){},pending: Promise.resolve(), working: false, message: '',
    value() { return this.editTask ?? this.task; }, getUIContext: () => ({ getHostContext: () => ({}) })
  });
  return { state, original, updated, writes,released,invalidations:()=>invalidations,reads: () => reads,
    setCurrent:value=>current=value,fail:error=>readError=error,readWith:fn=>readOverride=fn,
    emit() { state.dataChanges = {revision: state.dataChanges.revision + 1}; state.dataChanged(); } };
}
test('数据事件在写入之后重查卡片，标题草稿同步新进度，后续保存使用新版本', async () => {
  const f = cardRefreshFixture();
  assert.equal(await f.state.persist([{ field: 'CHECKLIST', value: { type: 'setChecked', id: '1', checked: true } }]), true);
  assert.equal(f.reads(), 1);
  assert.equal(f.state.editTask, f.updated);
  assert.equal(f.state.heading, '任务 [1/2]');
  assert.equal(f.state.editTask.fileVersion, 'new');
});
test('提交成功立即读取新快照，事件延迟时也能继续编辑', async () => {
  const f = cardRefreshFixture(false);
  assert.equal(await f.state.persist([{ field: 'TAGS', value: [] }]), true);
  assert.equal(f.reads(), 1);
  assert.equal(f.state.editTask, f.updated);
  f.emit();
  await f.state.pending;
  assert.equal(f.state.heading, '任务 [1/2]');
});

test('连续两次清单修改在事件到达前使用上次提交后的版本和条目 ID', async () => {
  const backend=fixture();
  backend.task.editContent.checklist=[{id:'10',text:'条目',checked:false}];
  let current=backend.task;
  backend.query(batch=>taskBatch(batch,[current]));
  backend.workspace.executeTaskOperations=async group=>{
    assert.equal(group.fileVersions[0].version,current.fileVersion,'不得复用上次保存前的版本');
    backend.requests.push(group);
    current={...current,fileVersion:`version-${backend.requests.length}`,
      editContent:{...current.editContent,checklist:[{id:`${10+backend.requests.length}`,text:'条目',checked:true}]}};
  };
  const card=cardRefreshFixture(false,backend);
  for(let index=0;index<2;index++) {
    const id=card.state.value().editContent.checklist[0].id;
    assert.equal(await card.state.persist([{field:'CHECKLIST',value:{type:'setChecked',id,checked:true}}]),true);
  }
  assert.deepEqual(backend.requests.map(group=>group.fileVersions[0].version),['old','version-1']);
  assert.deepEqual(backend.requests.map(group=>group.operations[0].data.modifications[0].value.id),['10','11']);
  assert.equal(card.state.editTask.fileVersion,'version-2');
  assert.equal(card.state.message,'');
});

test('本次提交清除同一事件中已缓存的旧任务快照', async () => {
  const backend=fixture();
  await backend.TaskInlineService.findChanged({},backend.task,0);
  backend.workspace.executeTaskOperations=async group=>{
    backend.requests.push(group);backend.setCurrent({...backend.task,fileVersion:'after-save'});
  };
  const card=cardRefreshFixture(false,backend);
  assert.equal(await card.state.persist([{field:'TAGS',value:[]}]),true);
  assert.equal(card.state.editTask.fileVersion,'after-save');
});

test('已排队的下一次修改也等待上次提交后的快照更新', async () => {
  const backend=fixture();let current=backend.task;
  backend.query(batch=>taskBatch(batch,[current]));
  backend.workspace.executeTaskOperations=async group=>{
    assert.equal(group.fileVersions[0].version,current.fileVersion);
    backend.requests.push(group);current={...current,fileVersion:`version-${backend.requests.length}`};
  };
  const card=cardRefreshFixture(false,backend);
  assert.deepEqual(await Promise.all([
    card.state.persist([{field:'TAGS',value:['标签']}]),
    card.state.persist([{field:'CHECKLIST',value:{type:'add',text:'条目'}}])
  ]),[true,true]);
  assert.deepEqual(backend.requests.map(group=>group.fileVersions[0].version),['old','version-1']);
});

test('修改已提交但重读失败时阻止旧版本继续写入，事件读成功后恢复', async () => {
  const card=cardRefreshFixture(false);card.fail(new Error('读取失败'));
  const results=await Promise.all([
    card.state.persist([{field:'TAGS',value:['标签']}]),
    card.state.persist([{field:'CHECKLIST',value:{type:'add',text:'条目'}}])
  ]);
  assert.deepEqual(results,[true,false]);assert.equal(card.writes.length,1);
  assert.equal(card.state.snapshotBlocked,true);assert.match(card.state.message,/修改已保存/);
  card.fail(undefined);card.emit();await card.state.pending;
  assert.equal(card.state.snapshotBlocked,false);assert.equal(card.state.editTask,card.updated);assert.equal(card.state.message,'');
  assert.equal(await card.state.persist([{field:'CHECKLIST',value:{type:'add',text:'条目'}}]),true);
});
test('事件刷新保留正在输入的标题和备注', async () => {
  const f = cardRefreshFixture();
  f.state.heading = '尚未保存的标题';
  f.state.notes = '尚未保存的备注';
  f.state.headingEditing = true; f.state.notesEditing = true;
  f.emit();
  await f.state.pending;
  assert.equal(f.state.heading, '尚未保存的标题');
  assert.equal(f.state.notes, '尚未保存的备注');
});

test('清单文字草稿遇到文件变化时保留原快照，防止旧条目 ID 指向另一条记录', async () => {
  const f=cardRefreshFixture(false);
  const original={...f.original,editContent:{notes:'备注',checklist:[
    {id:'10',text:'第一条'},{id:'20',text:'第二条'}]}};
  f.state.editTask=original;f.state.checkId='20';f.state.checkText='第二条的未保存草稿';
  f.setCurrent({...f.updated,editContent:{notes:'外部备注',checklist:[
    {id:'20',text:'第一条'},{id:'30',text:'第二条'}]}});
  f.emit();await f.state.pending;
  assert.equal(f.state.editTask,original);assert.equal(f.state.checkText,'第二条的未保存草稿');
  assert.equal(f.state.snapshotBlocked,true);assert.match(f.state.message,/清单输入已保留/);
  assert.equal(await f.state.persist([{field:'CHECKLIST',value:{type:'edit',id:'20',text:f.state.checkText}}]),false);
  assert.deepEqual(f.writes,[]);
});

test('本次清单保存后的快照更新不被当作外部冲突', async () => {
  const f=cardRefreshFixture(false);f.state.checkId='10';f.state.checkText='已保存文字';
  assert.equal(await f.state.persist([{field:'CHECKLIST',value:{type:'edit',id:'10',text:'已保存文字'}}]),true);
  assert.equal(f.state.editTask,f.updated);assert.equal(f.state.snapshotBlocked,false);assert.equal(f.state.message,'');
});

test('保存其他字段后仍保留清单草稿原版本，不能将旧条目 ID 带入新快照', async () => {
  const f=cardRefreshFixture(false);
  f.state.checkId='20';f.state.checkText='未保存的清单文字';
  assert.equal(await f.state.persist([{field:'TITLE',value:'新标题'}]),true);
  assert.equal(f.state.editTask,f.original);
  assert.equal(f.state.snapshotBlocked,true);
  assert.equal(f.state.checkText,'未保存的清单文字');
  assert.equal(await f.state.persist([{field:'CHECKLIST',value:{type:'edit',id:'20',text:f.state.checkText}}]),false);
  assert.deepEqual(f.writes,[[{field:'TITLE',value:'新标题'}]]);
});

test('正在编辑的字段跨多次外部更新保持草稿，其他字段继续更新',async()=>{
  const f=cardRefreshFixture(false);
  f.state.heading='本地草稿';f.state.headingEditing=true;
  f.setCurrent({...f.updated,heading:'本地草稿',tags:['标签甲'],editContent:{notes:'外部备注甲',checklist:[]}});
  f.emit();await f.state.pending;
  f.setCurrent({...f.updated,heading:'外部标题乙',tags:['标签乙'],fileVersion:'latest',editContent:{notes:'外部备注乙',checklist:[]}});
  f.emit();await f.state.pending;
  assert.equal(f.state.heading,'本地草稿');assert.equal(f.state.notes,'外部备注乙');
  assert.deepEqual(f.state.editTask.tags,['标签乙']);assert.equal(f.state.editTask.fileVersion,'latest');
  await f.state.saveText();
  assert.deepEqual(f.writes,[[{field:'TITLE',value:'本地草稿'}]]);
  assert.equal(f.state.headingEditing,false);
});

test('保存只覆盖指定字段，使用外部变化后的最新路径和文件版本',async()=>{
  const f=fixture();f.setCurrent({...f.task,fileVersion:'external',tags:['外部标签']});
  await f.TaskInlineService.modify({},f.task,[{field:'NOTES',value:'本地备注'}]);
  assert.deepEqual(f.requests[0].fileVersions,[{repoId:'core',file:'task.org',version:'external'}]);
  assert.deepEqual(f.requests[0].operations[0].data.modifications,[{field:'NOTES',value:'本地备注'}]);
  assert.ok(f.batches.every(batch=>batch.some(query=>query.type==='notification')));
});

test('外部删除结束卡片会话，草稿不再提交；读取失败保留卡片',async()=>{
  const deleted=cardRefreshFixture(false);deleted.state.notesEditing=true;deleted.state.notes='未保存备注';
  deleted.setCurrent(undefined);deleted.emit();await deleted.state.pending;
  assert.equal(deleted.state.removed,true);assert.equal(deleted.state.snapshotBlocked,true);
  assert.deepEqual(deleted.released,['task']);assert.equal(deleted.invalidations(),0);
  assert.equal(await deleted.state.saveText(),false);assert.deepEqual(deleted.writes,[]);
  const failed=cardRefreshFixture(false);failed.fail(new Error('读取失败'));
  failed.emit();await failed.state.pending;
  assert.equal(failed.state.removed,false);assert.equal(failed.state.editTask,failed.original);
  assert.equal(failed.state.message,'读取失败');
});

test('删除事件前已排队的字段保存也不会重新提交节点',async()=>{
  const f=cardRefreshFixture(false);f.setCurrent(undefined);
  f.emit();
  assert.equal(await f.state.persist([{field:'NOTES',value:'已排队草稿'}]),false);
  assert.deepEqual(f.writes,[]);assert.equal(f.state.removed,true);
});

test('保存前发现节点已经删除时不执行任何操作',async()=>{
  const f=fixture();f.setCurrent(undefined);
  await assert.rejects(f.TaskInlineService.modify({},f.task,[{field:'NOTES',value:'草稿'}]),/任务已删除/);
  assert.deepEqual(f.requests,[]);
});

test('任务移动后数据事件移除源卡片，不按保留的 Org ID 承接目标任务',async()=>{
  const backend=fixture();backend.task.taskId='org-id';
  const card=cardRefreshFixture(false,backend);
  card.state.expanded=true;card.state.headingEditing=true;card.state.heading='未保存标题';
  const moved={...backend.task,filePath:'projects.org',fullPath:{...backend.task.fullPath,file:'projects.org',titles:['项目','Original']}};
  backend.setCurrent(moved);card.emit();await card.state.pending;
  assert.equal(card.state.removed,true);assert.equal(card.state.expanded,false);
  assert.equal(card.state.message,'');assert.deepEqual(card.released,[backend.task.id]);
  assert.deepEqual(backend.requests,[]);assert.equal(moved.heading,'Original');
});

test('移动事件尚未送达时保存发现源任务消失，立即关闭卡片且不提交旧草稿',async()=>{
  const backend=fixture(),card=cardRefreshFixture(false,backend);
  card.state.expanded=true;card.state.notesEditing=true;card.state.notes='未保存备注';
  backend.setCurrent({...backend.task,filePath:'projects.org'});
  assert.equal(await card.state.saveText(),false);
  assert.equal(card.state.removed,true);assert.equal(card.state.expanded,false);
  assert.equal(card.state.message,'');assert.deepEqual(card.released,[backend.task.id]);
  assert.deepEqual(backend.requests,[]);
  card.emit();await card.state.pending;
  assert.deepEqual(card.released,[backend.task.id]);
});

test('保存遇到版本冲突保留卡片与草稿',async()=>{
  const backend=fixture(),card=cardRefreshFixture(false,backend);backend.conflict();
  card.state.expanded=true;card.state.notesEditing=true;card.state.notes='未保存备注';
  assert.equal(await card.state.saveText(),false);
  assert.equal(card.state.removed,false);assert.equal(card.state.expanded,true);
  assert.equal(card.state.notes,'未保存备注');assert.match(card.state.message,/版本冲突/);
  assert.deepEqual(card.released,[]);
});

test('清单操作含快照条目 ID，仍使用原文件版本以防并发改动后误操作',async()=>{
  const f=fixture();f.setCurrent({...f.task,fileVersion:'external'});
  await f.TaskInlineService.modify({},f.task,[{field:'CHECKLIST',value:{type:'move',id:'item',beforeId:null}}]);
  assert.deepEqual(f.requests[0].fileVersions,[{repoId:'core',file:'task.org',version:'old'}]);
  assert.equal(f.batches.length,0);
});
const tagPresentation = load('entry/src/main/ets/ui/TaskTagsPresentation.ets');
test('标签窗口直接使用任务候选快照，保留已有与继承标签，不混入其他任务候选',()=>{
  const config={tags:['iOS','Android','工作'],groups:[['iOS','Android']]};
  assert.deepEqual(tagPresentation.editableTagNames(config,['existing'],['inherited']),['iOS','Android','工作','existing','inherited']);
  assert.deepEqual(tagPresentation.editableTagNames(null,['existing'],['inherited']),['existing','inherited']);
  assert.deepEqual(tagPresentation.editableTagNames({tags:[],groups:[]},[],[]),[]);
});
test('互斥组分别展示，未分组标签单独排列，选择组内另一项只替换本组',()=>{
  const config={tags:['iOS','Android','BUG','FEAT','工作'],groups:[['iOS','Android'],['BUG','FEAT']]};
  assert.deepEqual(tagPresentation.editableTagGroups(config.tags,config),[['iOS','Android'],['BUG','FEAT'],['工作']]);
  assert.deepEqual(tagPresentation.toggleEditableTag(['iOS','BUG','工作'],'Android',config),['BUG','工作','Android']);
  assert.deepEqual(tagPresentation.toggleEditableTag(['Android','BUG'],'Android',config),['BUG']);
  assert.deepEqual(tagPresentation.toggleEditableTag(['iOS'],'工作',config),['iOS','工作']);
});
test('父标题继承的互斥标签不能在子任务同时选择其同组标签',()=>{
  const config={tags:['iOS','Android','工作'],groups:[['iOS','Android']]};
  assert.equal(tagPresentation.inheritedTagConflict('Android',['iOS'],config),'iOS');
  assert.equal(tagPresentation.inheritedTagConflict('工作',['iOS'],config),undefined);
  assert.equal(tagPresentation.inheritedTagConflict('Android',[],config),undefined);
});
test('已选区域遵循 Core 可见标签，隐藏的内部用途标签在其他标签修改时仍保留',()=>{
  const own=['iOS','REFILE','ARCHIVE'];
  assert.deepEqual(tagPresentation.selectedTagNames(own,['inherited'],['iOS','inherited']),['iOS','inherited']);
  assert.deepEqual(tagPresentation.toggleEditableTag(own,'Android',{tags:['iOS','Android'],groups:[['iOS','Android']]}),['REFILE','ARCHIVE','Android']);
  assert.deepEqual(own,['iOS','REFILE','ARCHIVE']);
});
test('上一编辑会话保存失败时不允许切换任务',async()=>{
  const {TaskInlineSession:s}=fixture();await s.begin('first',async()=>false);
  assert.equal(await s.begin('second',async()=>true),false);assert.equal(storage.get('taskInlineActive'),'first');s.release('first');
});

test('展开标题保留原文草稿，点按后聚焦，保存失败仍保留输入', async () => {
  const source = fs.readFileSync('entry/src/main/ets/components/TaskListItem.ets', 'utf8');
  const methods = ['editHeading', 'finishHeading'].map(name => {
    const match = source.match(new RegExp('  (?:async )?' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?\\n  \\}'));
    assert.ok(match, name);
    return match[0];
  }).join('\n');
  const code = ts.transpileModule('export class Card {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(module,exports){' + code + '\n})')(module, module.exports);
  const requests = [];
  const raw = '测量尿酸 [[id:stable][并记录]]';
  let saved = false;
  const card = Object.assign(new module.exports.Card(), { heading: raw, ownerKey: 'task', headingInput: false,
    checkFocus: { request: key => requests.push(key) }, saveText: async () => saved });
  card.editHeading();
  assert.deepEqual(requests, ['inline_title_task']);
  assert.equal(card.heading, raw);
  await card.finishHeading();
  assert.equal(card.headingInput, true);
  saved = true;
  await card.finishHeading();
  assert.equal(card.headingInput, false);
  assert.equal(card.heading, raw);
  for (const blocked of ['readOnly', 'working', 'draggingCheck', 'snapshotBlocked']) {
    card[blocked] = true;
    card.editHeading();
    assert.equal(card.headingInput, false, blocked);
    card[blocked] = false;
  }
});

function finishFixture(textSaved = true, checkSaved = true) {
  const filename = 'entry/src/main/ets/components/TaskListItem.ets';
  const method = fs.readFileSync(filename, 'utf8').match(/  async finish\(collapse: boolean\): Promise<boolean> \{[\s\S]*?\n  \}\n(?=  inputFocus)/)[0];
  const code = ts.transpileModule('export class InlineFinish {' + method + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, released = [];
  vm.runInThisContext('(function(module,exports,TaskInlineSession,TaskStateCategory){' + code + '\n})', { filename })(module, module.exports, { release: key => released.push(key) }, { Done: 'Done' });
  let checkCalls = 0;
  const state = { ownerKey: 'task', expanded: true, message: '标题不能为空', newCheck: '', checkId: '',
    pending: Promise.resolve(), cancelCheckDrag() {}, checkFocus: { cancel() {} }, headingController: { stopEditing() {} }, notesController: { stopEditing() {} },
    getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }) }),
    saveText: async () => textSaved, saveCheck: async () => { checkCalls++; return checkSaved; } };
  return { state, released, checkCalls: () => checkCalls, finish: () => module.exports.InlineFinish.prototype.finish.call(state, true) };
}

test('结束编辑必须检查保存结果，任一保存失败均保留展开会话', async () => {
  for (const [textSaved, checkSaved] of [[false, true], [true, false]]) {
    const f = finishFixture(textSaved, checkSaved);
    assert.equal(await f.finish(), false); assert.equal(f.state.expanded, true); assert.deepEqual(f.released, []);
    if (!textSaved) assert.equal(f.checkCalls(), 0);
  }
});

test('保存后快照仍不可用时，结束编辑不能放行后续操作', async () => {
  const f=finishFixture();f.state.snapshotBlocked=true;f.state.message='修改已保存，读取最新内容失败';
  assert.equal(await f.finish(),false);assert.equal(f.state.expanded,true);
  assert.match(f.state.message,/读取最新内容失败/);assert.deepEqual(f.released,[]);
});

test('校验错误修正为原内容后，成功保存可以清除旧错误并结束会话', async () => {
  const f = finishFixture();
  assert.equal(await f.finish(), true); assert.equal(f.state.expanded, false);
  assert.equal(f.state.message, ''); assert.deepEqual(f.released, ['task']);
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

const { TaskInlineFocus } = load('entry/src/main/ets/ui/TaskInlineFocus.ets');
function focusFixture() {
  const frames = [], focused = [];
  let failure;
  const focus = new TaskInlineFocus(callback => frames.push(callback), key => {
    if (failure) throw failure;
    focused.push(key);
  });
  return { focus, focused, flush() { while (frames.length) frames.shift()(); }, fail(error) { failure = error; } };
}
test('新增输入挂载前不抢焦点，挂载后的布局帧才执行', () => {
  const f=focusFixture();f.focus.request('new');f.flush();assert.deepEqual(f.focused,[]);
  f.focus.appeared('new');f.flush();assert.deepEqual(f.focused,['new']);
});
test('输入已被移除时取消旧布局帧，重新挂载可重新聚焦', () => {
  const f=focusFixture();f.focus.request('new');f.focus.appeared('new');f.focus.disappeared('new');
  f.flush();assert.deepEqual(f.focused,[]);f.focus.appeared('new');f.flush();assert.deepEqual(f.focused,['new']);
});
test('界面结束输入或组件销毁后不执行过期聚焦', () => {
  for(const action of ['cancel','dispose']) {
    const f=focusFixture();f.focus.appeared('new');f.focus.request('new');f.focus[action]();f.flush();
    assert.deepEqual(f.focused,[]);
  }
});
test('150003 聚焦异常不会逃出布局回调，输入可见后可重试', () => {
  const f=focusFixture();f.fail(Object.assign(new Error('component not visible'),{code:150003}));
  f.focus.appeared('new');f.focus.request('new');assert.doesNotThrow(()=>f.flush());
  f.fail(undefined);f.focus.visible('new');f.flush();assert.deepEqual(f.focused,['new']);
});
test('快速切换输入时只聚焦最后一次请求，不复活旧输入', () => {
  const f=focusFixture();f.focus.appeared('old');f.focus.appeared('new');
  f.focus.request('old');f.focus.request('new');f.flush();assert.deepEqual(f.focused,['new']);
});

const { overviewTaskQuery } = load('entry/src/main/ets/services/TaskViewQueries.ets');
test('计划请求在整个未来日期范围排除习惯任务，由 Core 求值', () => {
  assert.deepEqual(overviewTaskQuery('planned'), {
    expression:'.is.habit ((s.ge.tomorrow d.ge.tomorrow) or (s.ge.tomorrow d.none) or (s.none d.ge.tomorrow))',
    includeDone:false,includeComposeTasks:true
  });
});
test('随时请求只匹配无计划和无截止的待办任务，由 Core 求值', () => {
  assert.deepEqual(overviewTaskQuery('anytime'), {
    expression:'it.todo s.none d.none',includeDone:false,includeComposeTasks:true
  });
});

const reorder = load('entry/src/main/ets/ui/TaskChecklistReorder.ets');
function checklistItem(id, depth = 0, siblingGroup = 'root') {
  return {id, text:id, depth, siblingGroup, checked:id === 'a', partial:id === 'b'};
}
const ids = items => items.map(item => item.id);
test('清单预览移动父项及嵌套内容，只调整同级顺序并保留状态', () => {
  const items=[checklistItem('a'),checklistItem('child',1,'nested'),checklistItem('b'),checklistItem('other',0,'separate')];
  const moved=reorder.checklistMovePreview(items,'a',null);
  assert.deepEqual(ids(moved),['b','a','child','other']);
  assert.equal(moved[1],items[0]);assert.equal(moved[2],items[1]);
  assert.deepEqual(ids(items),['a','child','b','other']);
  assert.deepEqual(ids(reorder.checklistMovePreview(items,'a','child')),ids(items));
  assert.deepEqual(ids(reorder.checklistMovePreview(items,'a','other')),ids(items));
});
test('嵌套同级的上移、下移及末尾不改变父项或其他列表', () => {
  const items=[checklistItem('parent'),checklistItem('x',1,'nested'),checklistItem('y',1,'nested'),checklistItem('b')];
  assert.deepEqual(ids(reorder.checklistMovePreview(items,'x',null)),['parent','y','x','b']);
  assert.deepEqual(ids(reorder.checklistMovePreview(items,'y','x')),['parent','y','x','b']);
  assert.deepEqual(ids(reorder.checklistMovePreview(items,'y',null)),ids(items));
});
test('拖动按实际行高计算浮层和占位，不按44像素索引定位', () => {
  const items=[checklistItem('a'),checklistItem('child',1,'nested'),checklistItem('b'),checklistItem('c')];
  const heights=new Map([['a',88],['child',66],['b',44],['c',110]]);
  const drag=new reorder.TaskChecklistDrag(items,'a',heights,22);
  assert.equal(drag.height,154);assert.equal(drag.grab,22);assert.equal(drag.changed(),false);
  drag.update(290,true);
  assert.equal(drag.valid,true);assert.equal(drag.beforeId,null);assert.equal(drag.top,268);
  assert.deepEqual(ids(drag.preview()),['b','c','a','child']);assert.equal(drag.placeholderTop(),154);
  assert.equal(drag.contains('child'),true);
  drag.update(22,true);assert.equal(drag.changed(),false);
});
test('拖出同级组或水平方向离开卡片后无合法落点，取消不改变快照', () => {
  const items=[checklistItem('parent'),checklistItem('x',1,'nested'),checklistItem('y',1,'nested'),checklistItem('b')];
  const drag=new reorder.TaskChecklistDrag(items,'x',new Map(),60);
  assert.equal(drag.minY,44);assert.equal(drag.maxY,132);
  drag.update(120,true);assert.equal(drag.valid,true);assert.equal(drag.beforeId,null);
  drag.update(160,true);assert.equal(drag.valid,false);
  drag.update(120,false);assert.equal(drag.valid,false);
  assert.deepEqual(ids(items),['parent','x','y','b']);
});
test('边缘滚动仅在可见区域40vp边缘触发，速度有上限', () => {
  assert.equal(reorder.checklistEdgeScroll(100,100,600),-240);
  assert.equal(reorder.checklistEdgeScroll(120,100,600),-120);
  assert.equal(reorder.checklistEdgeScroll(300,100,600),0);
  assert.equal(reorder.checklistEdgeScroll(580,100,600),120);
  assert.equal(reorder.checklistEdgeScroll(600,100,600),240);
  assert.equal(reorder.checklistEdgeScroll(601,100,600),0);
});

function sortFixture({writeError,reloadError}={}) {
  const filename='entry/src/main/ets/components/TaskListItem.ets';
  const source=fs.readFileSync(filename,'utf8');
  const method=source.match(/  async sortCheck\(id: string, beforeId: string \| null\) \{[\s\S]*?\n  \}\n(?=  accessibleCheckOrder)/)[0];
  const code=ts.transpileModule('export class SortCheck {'+method+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}}, requests=[];
  const items=[checklistItem('a'),checklistItem('b')];
  let current={fileVersion:'old',heading:'Title',editContent:{notes:'Notes',checklist:items}};
  const updated={fileVersion:'new',heading:'Changed title',editContent:{notes:'Changed notes',checklist:[items[1],items[0]]}};
  let reloadCalls=0;
  const service={modify:async(context,task,changes)=>{requests.push({task,changes});if(writeError)throw new Error(writeError);},reload:async()=>{reloadCalls++;if(reloadError)throw new Error(reloadError);return updated;}};
  vm.runInThisContext('(function(module,exports,TaskInlineService,TaskInlineMissingError,checklistMovePreview,coreErrorMessage){'+code+'\n})',{filename})(module,module.exports,service,fixture().TaskInlineMissingError,reorder.checklistMovePreview,error=>error.message);
  const state={pending:Promise.resolve(),working:false,snapshotBlocked:false,draggingCheck:false,checkPreview:[],message:'',
    heading:'Title',notes:'Notes',canSortCheck(){return !this.snapshotBlocked&&!this.working;},
    value(){return this.editTask??current;},getUIContext:()=>({getHostContext:()=>({})})};
  return {state,requests,updated,reloadCalls:()=>reloadCalls,sort:()=>module.exports.SortCheck.prototype.sortCheck.call(state,'a',null)};
}
test('清单排序只提交一次原版本请求，成功后采用新快照并清除预览', async()=>{
  const f=sortFixture();await f.sort();assert.equal(f.requests.length,1);assert.equal(f.requests[0].task.fileVersion,'old');
  assert.deepEqual(f.requests[0].changes,[{field:'CHECKLIST',value:{type:'move',id:'a',beforeId:null}}]);
  assert.equal(f.state.editTask,f.updated);assert.deepEqual(f.state.checkPreview,[]);assert.equal(f.state.working,false);
});
test('排序提交失败恢复旧顺序；版本冲突只重读，不再次写入',async()=>{
  const failed=sortFixture({writeError:'磁盘写入失败'});await failed.sort();
  assert.deepEqual(ids(failed.state.value().editContent.checklist),['a','b']);assert.equal(failed.state.message,'排序未保存，请重试');assert.equal(failed.reloadCalls(),0);
  const conflict=sortFixture({writeError:'任务文件版本已变化'});await conflict.sort();
  assert.equal(conflict.requests.length,1);assert.equal(conflict.reloadCalls(),1);assert.equal(conflict.state.editTask,conflict.updated);
  assert.equal(conflict.state.heading,'Changed title');assert.equal(conflict.state.notes,'Changed notes');
});
test('排序已写入但重读失败时停用后续写入，防止旧条目ID重复提交',async()=>{
  const f=sortFixture({reloadError:'读取失败'});await f.sort();
  assert.equal(f.requests.length,1);assert.equal(f.state.snapshotBlocked,true);assert.match(f.state.message,/顺序已保存/);
  await f.sort();assert.equal(f.requests.length,1);assert.deepEqual(f.state.checkPreview,[]);
});

function completionFixture(methodName = 'complete') {
  const filename = 'entry/src/main/ets/components/TaskListItem.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const method = source.match(new RegExp('  async ' + methodName + '\\(\\) \\{[\\s\\S]*?\\n  \\}\\n'))[0];
  const code = ts.transpileModule('export class Completion {' + method + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  const writes = [], released = [];
  vm.runInThisContext('(function(module,exports,TaskInlineSession,TaskStateCategory){' + code + '\n})', { filename })(
    module, module.exports, { release: key => released.push(key) }, { Done: 'Done', Todo: 'Todo', Doing: 'Doing' });
  const task = { state: { name: 'ACTIVE', category: 'Doing' }, targetState: { name: 'FINISHED', category: 'Done' },
    reopenState: { name: 'READY', category: 'Todo' }, doingState: { name: 'ACTIVE', category: 'Doing' },
    taskStateOf(category) { return category === 'Todo' ? this.reopenState : category === 'Doing' ? this.doingState : this.targetState; },
    isDone() { return this.state?.category === 'Done' || this.state?.category === 'Cancel'; } };
  const state = Object.assign(new module.exports.Completion(), {
    completing: false, working: false, snapshotBlocked: false, expanded: false, ownerKey: 'task', rightSwipeAction: 'doing',
    value: () => task, prepare: async () => true, finish: async () => true,
    persist: async changes => { writes.push(changes); return true; }
  });
  return { state, task, writes, released };
}
test('今天右滑按 Core 分类切换进行中和待办，保留卡片展开状态', async () => {
  for (const category of ['Todo', 'Doing', 'Wait']) {
    const f = completionFixture('toggleDoing');
    f.task.state = { name: 'CUSTOM', category }; f.state.expanded = true;
    await f.state.toggleDoing();
    assert.deepEqual(f.writes, [[{ field: 'TODO', value: category === 'Doing' ? 'READY' : 'ACTIVE' }]]);
    assert.equal(f.state.expanded, true); assert.equal(f.state.completing, false);
    assert.deepEqual(f.released, []);
  }
});
test('今天右滑缺少状态、已关闭、未启用或编辑忙碌时不提交', async () => {
  for (const changes of [{ state: null }, { state: { name: 'DONE', category: 'Done' } },
    { state: { name: 'CNCL', category: 'Cancel' } }, { reopenState: null },
    { state: { name: 'READY', category: 'Todo' }, doingState: null }]) {
    const f = completionFixture('toggleDoing'); Object.assign(f.task, changes);
    await f.state.toggleDoing(); assert.deepEqual(f.writes, []);
  }
  for (const changes of [{ rightSwipeAction: 'schedule' }, { rightSwipeAction: 'move' }, { rightSwipeAction: 'none' }, { completing: true }, { working: true },
    { snapshotBlocked: true }, { draggingCheck: true }, { typing: true }]) {
    const f = completionFixture('toggleDoing'); Object.assign(f.state, changes);
    await f.state.toggleDoing(); assert.deepEqual(f.writes, []);
  }
});
test('今天右滑在草稿失败或保存期间状态与配置变化时停止提交', async () => {
  for (const finish of [async () => false,
    async f => { f.task.state = { name: 'READY', category: 'Todo' }; return true; },
    async f => { f.task.state = null; return true; },
    async f => { f.task.reopenState = null; return true; }]) {
    const f = completionFixture('toggleDoing'); f.state.expanded = true;
    f.state.finish = () => finish(f);
    await f.state.toggleDoing(); assert.deepEqual(f.writes, []);
    assert.equal(f.state.expanded, true); assert.equal(f.state.completing, false);
  }
});
test('今天连续右滑只提交一次，失败释放收起卡片会话并允许重试', async () => {
  const f = completionFixture('toggleDoing'); let finishWrite;
  f.state.persist = async changes => { f.writes.push(changes); return new Promise(resolve => { finishWrite = resolve; }); };
  const pending = f.state.toggleDoing();
  await Promise.resolve(); await Promise.resolve();
  await f.state.toggleDoing(); assert.equal(f.writes.length, 1);
  finishWrite(false); await pending;
  assert.equal(f.state.completing, false); assert.deepEqual(f.released, ['task']);
  f.state.persist = async changes => { f.writes.push(changes); return true; };
  await f.state.toggleDoing(); assert.equal(f.writes.length, 2);
});
test('任务 checkbox 使用 Core 的 Done 分类目标而不误选在前的取消状态，成功后结束会话', async () => {
  const f = completionFixture();
  await f.state.complete();
  assert.deepEqual(f.writes, [[{ field: 'TODO', value: 'FINISHED' }]]);
  assert.equal(f.state.completing, false);
  assert.ok(f.released.includes('task'));
});
test('完成任务保存草稿失败时不提交状态，保留展开态', async () => {
  const f = completionFixture();
  f.state.expanded = true; f.state.finish = async () => false;
  await f.state.complete();
  assert.equal(f.writes.length, 0); assert.equal(f.state.expanded, true);
  assert.equal(f.released.length, 0);
});
test('完成任务重复点击只提交一次，写入失败保留展开态', async () => {
  const f = completionFixture();
  let finishWrite;
  f.state.expanded = true;
  f.state.persist = async changes => { f.writes.push(changes); return await new Promise(resolve => { finishWrite = resolve; }); };
  const pending = f.state.complete();
  await Promise.resolve(); await Promise.resolve();
  await f.state.complete();
  assert.equal(f.writes.length, 1);
  finishWrite(false); await pending;
  assert.equal(f.state.expanded, true); assert.equal(f.state.completing, false);
});
test('无状态、无目标状态配置或不可用快照不提交', async () => {
  for (const changes of [{ state: null }, { targetState: null },
    { state: { name: 'FINISHED', category: 'Done' }, reopenState: null },
    { state: { name: 'STOP', category: 'Cancel' }, reopenState: null }]) {
    const f = completionFixture(); Object.assign(f.task, changes);
    await f.state.complete(); assert.equal(f.writes.length, 0);
  }
  const f = completionFixture(); f.state.snapshotBlocked = true;
  await f.state.complete(); assert.equal(f.writes.length, 0);
});


test('完成和取消任务点击 checkbox 均使用 Core 的 Todo 目标重新打开', async () => {
  for (const category of ['Done', 'Cancel']) {
    const f = completionFixture();
    f.task.state = { name: category === 'Done' ? 'FINISHED' : 'STOP', category };
    f.state.expanded = true;
    await f.state.complete();
    assert.deepEqual(f.writes, [[{ field: 'TODO', value: 'READY' }]]);
    assert.equal(f.state.expanded, false);
    assert.ok(f.released.includes('task'));
  }
});
test('重新打开时草稿保存失败、提交失败和重复点击均沿用完成操作的保护', async () => {
  const f = completionFixture();
  f.task.state = { name: 'FINISHED', category: 'Done' };
  f.state.expanded = true;
  f.state.finish = async () => false;
  await f.state.complete();
  assert.equal(f.writes.length, 0);
  assert.equal(f.state.expanded, true);
  let finishWrite;
  f.state.finish = async () => true;
  f.state.persist = async changes => { f.writes.push(changes); return new Promise(resolve => { finishWrite = resolve; }); };
  const pending = f.state.complete();
  await Promise.resolve(); await Promise.resolve();
  await f.state.complete();
  assert.deepEqual(f.writes, [[{ field: 'TODO', value: 'READY' }]]);
  finishWrite(false); await pending;
  assert.equal(f.state.expanded, true);
  assert.equal(f.state.completing, false);
});
test('保存草稿期间任务被外部完成或重新打开时，不反向切换状态', async () => {
  for (const closed of [false, true]) {
    const f = completionFixture();
    if (closed) f.task.state = { name: 'FINISHED', category: 'Done' };
    f.state.finish = async () => {
      f.task.state = closed ? { name: 'READY', category: 'Todo' } : { name: 'FINISHED', category: 'Done' };
      return true;
    };
    await f.state.complete();
    assert.equal(f.writes.length, 0);
  }
});
test('保存草稿后重新检查 Core 目标状态，配置消失时不提交', async () => {
  const f = completionFixture();
  f.task.state = { name: 'FINISHED', category: 'Done' };
  f.state.finish = async () => { f.task.reopenState = null; return true; };
  await f.state.complete();
  assert.equal(f.writes.length, 0);
});

const repeats = load('entry/src/main/ets/ui/TaskRepeatPresentation.ets');
test('重复编辑把新日期和规则一次提交给 Core，停止只清除当前字段', () => {
  const rule = { mode: 'afterCompletion', interval: 2, unit: 'week' };
  assert.deepEqual(repeats.repeatModifications(false, '', '2026-11-11', rule), [
    { field: 'SCHEDULE_DATE', value: '2026-11-11' }, { field: 'SCHEDULE_REPEAT', value: rule }
  ]);
  assert.deepEqual(repeats.repeatModifications(true, '2026-11-11', '2026-11-11', rule), [
    { field: 'DEADLINE_REPEAT', value: rule }
  ]);
  assert.deepEqual(repeats.repeatModifications(true, '2026-11-11', '2026-12-01', null), [
    { field: 'DEADLINE_REPEAT', value: null }
  ]);
  assert.equal(repeats.repeatSummary({ mode: 'catchUp', interval: 1, unit: 'month' }), '每 1 月 · 跳过已错过的日期');
});

function deferredRead() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function taskBatch(batch, tasks) {
  return batch.map(item => item.type === 'notification' ? {type:'notification',result:[]} : {type:'task',result:{tasks}});
}
const eventTick = () => new Promise(resolve => setImmediate(resolve));

test('同次联动事件的来源、目标和后续关联行共享一次任务与通知查询', async () => {
  const f = fixture();
  const source = {...f.task,state:{name:'OPEN',category:'Todo'},scheduled:'2026-11-13',fileVersion:'linked'};
  const target = {...f.task,id:'target',state:{name:'FINISHED',category:'Done'},scheduled:'2026-11-14',fileVersion:'linked'};
  f.setCurrent([source,target]);
  const values = await Promise.all([
    f.TaskInlineService.findChanged({},f.task,10),
    f.TaskInlineService.findChanged({},target,10)
  ]);
  assert.deepEqual(values,[source,target]);
  assert.equal(await f.TaskInlineService.findChanged({},target,10),target);
  assert.equal(f.batches.length,1);
  assert.deepEqual(f.batches[0],[{type:'task',query:{includeDone:true,includeComposeTasks:true}},{type:'notification',query:{}}]);
  f.setCurrent({...source,fileVersion:'next'});
  assert.equal((await f.TaskInlineService.findChanged({},f.task,11)).fileVersion,'next');
  assert.equal(f.batches.length,2);
});

test('事件快照只用于刷新，后续写入仍重新读取当前路径和版本', async () => {
  const f = fixture();
  await f.TaskInlineService.findChanged({},f.task,1);
  f.setCurrent({...f.task,fileVersion:'outside'});
  await f.TaskInlineService.modify({},f.task,[{field:'NOTES',value:'草稿'}]);
  assert.equal(f.batches.length,2);
  assert.equal(f.requests[0].fileVersions[0].version,'outside');
});

test('同次事件读取失败由所有行接收，重试同一版本会重新读取', async () => {
  const f = fixture(); let attempts=0;
  f.query(async batch => { if (++attempts===1) throw new Error('共享读取失败'); return taskBatch(batch,[f.updated]); });
  const values=await Promise.allSettled([
    f.TaskInlineService.findChanged({},f.task,1), f.TaskInlineService.findChanged({},f.task,1)
  ]);
  assert.ok(values.every(value=>value.status==='rejected' && /共享读取失败/.test(value.reason.message)));
  assert.equal(f.batches.length,1);
  assert.equal(await f.TaskInlineService.findChanged({},f.task,1),f.updated);
  assert.equal(f.batches.length,2);
});

test('旧版本读取失败不会清除较新联动事件的共享快照', async () => {
  const f=fixture(),old=deferredRead(),fresh=deferredRead();
  f.query(batch=>f.batches.length===1?old.promise:fresh.promise);
  const first=f.TaskInlineService.findChanged({},f.task,1);
  const failure=assert.rejects(first,/旧读取失败/);
  await eventTick();
  const second=f.TaskInlineService.findChanged({},f.task,2);
  await eventTick();
  fresh.resolve(taskBatch(f.batches[1],[f.updated]));
  assert.equal(await second,f.updated);
  old.reject(new Error('旧读取失败')); await failure;
  assert.equal(await f.TaskInlineService.findChanged({},f.task,2),f.updated);
  assert.equal(f.batches.length,2);
});

test('联动后从任务变为无状态条目时，按同一记录身份继续刷新', async () => {
  const f=fixture();
  const original={...f.task,taskId:'identity'},updated={...f.task,taskId:null,state:null};
  f.setCurrent([{...updated,repoId:'other'},{...updated,filePath:'other.org'},updated]);
  assert.equal(await f.TaskInlineService.findChanged({},original,1),updated);
  assert.equal(await f.TaskInlineService.reload({},original),updated);
});

test('未展开过的关联行也由事件更新状态、日期和计数，保持收起状态', async () => {
  const f=cardRefreshFixture(false);
  f.state.editTask=undefined; f.state.heading=''; f.state.notes='';
  const updated={...f.updated,state:{name:'FINISHED',category:'Done'},scheduled:'2026-11-13',deadline:'2026-11-20',tags:['联动']};
  f.setCurrent(updated); f.emit(); await f.state.pending;
  assert.equal(f.state.editTask,updated);
  assert.equal(f.state.heading,'任务 [1/2]');
  assert.equal(f.state.value().scheduled,'2026-11-13');
  assert.equal(f.state.value().state.category,'Done');
  assert.deepEqual(f.state.value().tags,['联动']);
  assert.equal(f.state.expanded,false); assert.equal(f.reads(),1);
});

test('已排队但尚未读取的连续事件只查询最新版本，同一版本不重复消费', async () => {
  const f=cardRefreshFixture(false); const revisions=[];
  f.readWith(revision=>{revisions.push(revision);return f.updated;});
  f.emit(); f.emit(); f.emit(); await f.state.pending;
  assert.deepEqual(revisions,[3]); assert.equal(f.reads(),1);
  f.state.dataChanged(); await f.state.pending;
  assert.equal(f.reads(),1);
});

test('旧联动读取完成时不回写旧值，较新事件继续刷新且保留文字草稿', async () => {
  const f=cardRefreshFixture(false),old=deferredRead(),fresh=deferredRead();
  f.state.heading='未保存草稿';f.state.headingEditing=true;
  f.readWith(revision=>revision===1?old.promise:fresh.promise);
  f.emit(); await eventTick(); const first=f.state.pending;
  f.emit(); const second=f.state.pending;
  old.resolve({...f.updated,heading:'旧标题',editContent:{notes:'旧备注'}}); await first;
  assert.equal(f.state.editTask,f.original); assert.equal(f.state.notes,'备注');
  fresh.resolve({...f.updated,editContent:{notes:'新备注'}}); await second;
  assert.equal(f.state.heading,'未保存草稿');assert.equal(f.state.notes,'新备注');
  assert.equal(f.state.editTask.fileVersion,'new');assert.equal(f.reads(),2);
});

test('卡片离开后，排队事件不读取，在途删除或错误不再改写状态或结束新会话', async () => {
  const queued=cardRefreshFixture(false);queued.emit();queued.state.aboutToDisappear();await queued.state.pending;
  assert.equal(queued.reads(),0);assert.equal(queued.state.removed,false);
  for(const error of [false,true]) {
    const f=cardRefreshFixture(false),read=deferredRead();f.readWith(()=>read.promise);
    f.emit();await eventTick();f.state.aboutToDisappear();
    if(error)read.reject(new Error('离开后失败'));else read.resolve(undefined);
    await f.state.pending;
    assert.equal(f.state.editTask,f.original);assert.equal(f.state.message,'');
    assert.equal(f.state.removed,false);assert.deepEqual(f.released,['task']);assert.equal(f.invalidations(),0);
  }
});


function priorityFixture() {
  const filename = 'entry/src/main/ets/components/TaskListItem.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const methods = source.slice(source.indexOf('  async priorities()'), source.indexOf('  @Builder\n  priorityPopup()'));
  const code = ts.transpileModule('export class Priority {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(module,exports){' + code + '\n})', { filename })(module,module.exports);
  const writes = [];
  const value = { priority: { name: 'D', category: 'Low' }, taskPriorityOf(category) {
    assert.equal(category,'Hight'); return { name: 'B', category: 'Hight' };
  } };
  const state = { priorityOpen: false, priorityBusy: false, working: false, snapshotBlocked: false,
    value: () => value, prepare: async () => true, finish: async () => true,
    persist: async changes => { writes.push(changes); return true; } };
  return { state, writes, proto: module.exports.Priority.prototype };
}
test('优先级选择先保存草稿',async()=>{
  const f=priorityFixture(); f.state.finish=async()=>false;
  await f.proto.priorities.call(f.state); assert.equal(f.state.priorityOpen,false);
  assert.equal(f.writes.length,0);
  f.state.finish=async()=>true;
  await f.proto.priorities.call(f.state); assert.equal(f.state.priorityOpen,true);
  assert.equal(f.writes.length,0);
});
test('选择同一优先级只关闭；清除写入null；保存失败保留选择器',async()=>{
  const f=priorityFixture();f.state.priorityOpen=true;
  await f.proto.choosePriority.call(f.state,'D');assert.equal(f.writes.length,0);assert.equal(f.state.priorityOpen,false);
  f.state.priorityOpen=true;await f.proto.choosePriority.call(f.state,null);
  assert.deepEqual(f.writes,[[{field:'PRIORITY',value:null}]]);assert.equal(f.state.priorityOpen,false);
  f.state.priorityOpen=true;f.state.persist=async()=>false;
  await f.proto.choosePriority.call(f.state,'B');assert.equal(f.state.priorityOpen,true);assert.equal(f.state.priorityBusy,false);
});
test('优先级保存进行中禁止重复提交，失效快照不写入',async()=>{
  const f=priorityFixture();let resolve;
  f.state.persist=()=>new Promise(r=>{resolve=r});
  const first=f.proto.choosePriority.call(f.state,'B');
  await f.proto.choosePriority.call(f.state,'C');assert.equal(f.state.priorityBusy,true);
  resolve(true);await first;assert.equal(f.state.priorityBusy,false);
  f.state.snapshotBlocked=true;f.state.persist=async changes=>{f.writes.push(changes);return true};
  await f.proto.choosePriority.call(f.state,'C');assert.equal(f.writes.length,0);
});
