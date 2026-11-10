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
    query:async()=>({tasks:[updated]}),
    executeTaskOperations:async group=>{requests.push(group);if(conflict)throw new Error('文件版本冲突');}
  };
  const service=load('entry/src/main/ets/services/TaskInlineService.ets',{
    './AppConfigService':{AppConfigService:{load:async()=>config}},
    './NativeCoreService':{NativeCoreService:{workspaceFor:async()=>workspace}}
  });
  return {task,updated,config,requests,...service,conflict:()=>conflict=true};
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

function finishFixture(textSaved = true, checkSaved = true) {
  const filename = 'entry/src/main/ets/components/TaskListItem.ets';
  const method = fs.readFileSync(filename, 'utf8').match(/  async finish\(collapse: boolean\): Promise<boolean> \{[\s\S]*?\n  \}\n(?=  inputFocus)/)[0];
  const code = ts.transpileModule('export class InlineFinish {' + method + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }, released = [];
  vm.runInThisContext('(function(module,exports,TaskInlineSession){' + code + '\n})', { filename })(module, module.exports, { release: key => released.push(key) });
  let checkCalls = 0;
  const state = { ownerKey: 'task', expanded: true, message: '标题不能为空', newCheck: '', checkId: '',
    pending: Promise.resolve(), checkFocus: { cancel() {} }, headingController: { stopEditing() {} }, notesController: { stopEditing() {} },
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
test('随时请求只匹配无计划和无截止的待办任务，由 Core 求值', () => {
  assert.deepEqual(overviewTaskQuery('anytime'), {
    expression:'it.todo s.none d.none',includeDone:false,includeComposeTasks:true
  });
});
