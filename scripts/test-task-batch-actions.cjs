// 批量 Action 经共享控件规划、确认并通过 DataSet 一次提交。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert=require('node:assert/strict');
const {test}=require('node:test');
if(process.argv.includes('-h')||process.argv.includes('--help')){
  console.log('用法: node scripts/test-task-batch-actions.cjs\n验证批量移动、将来、备忘、日期和合并的顺序、冻结版本、取消、失效会话与单次提交。');process.exit(0);
}
const {fixture,task}=require('./helpers/task-selection.cjs');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function selected(action){const f=fixture();f.enable([action]);await f.selection.start('B');f.selection.toggle('A');return f;}
test('将来、备忘与移动共用 DataSet 单次提交，源记录按列表逆序规划并保留目标数据',async()=>{
  for(const action of ['someday','memo','move']){
    const f=await selected(action);f.selection.toggle('B');f.selection.toggle('B');
    const target={fullPath:{repoId:'other',file:'target.org',titles:[]},fileVersion:'target-v1'};
    await f.selection.execute(f.context,action,target);
    assert.equal(f.writes.length,1);assert.deepEqual(f.planned[0].tasks.map(t=>t.id),['B','A']);
    assert.equal(f.planned[0].target,target);assert.equal(f.planned[0].action,action);
    assert.equal(f.writes[0].fileVersions[0].version,'v1');assert.equal(f.selection.selecting,false);
  }
});
test('合并按选择顺序规划，取消首条再选择不会变成原列表顺序',async()=>{
  const f=await selected('merge');f.selection.toggle('B');f.selection.toggle('B');
  assert.deepEqual(f.selection.tasks().map(t=>t.id),['A','B']);
  f.selection.toggle('A');f.selection.toggle('A');
  await f.selection.execute(f.context,'merge');
  assert.deepEqual(f.planned[0].tasks.map(t=>t.id),['B','A']);assert.equal(f.writes.length,1);
  assert.equal(JSON.parse(f.selection.mergedPath).titles[0],'B');assert.equal(f.selection.selecting,false);
});
test('选择外部变更后仍使用冻结版本；版本错误保留顺序且要求刷新重选',async()=>{
  const f=await selected('memo');f.rows.set('A',task('A','NEXT','v2'));
  f.fail(Object.assign(new Error('版本失效'),{code:'invalidState'}));
  await f.selection.execute(f.context,'memo');await f.selection.execute(f.context,'memo');
  assert.equal(f.writes.length,1);assert.equal(f.writes[0].fileVersions[0].version,'v1');
  assert.deepEqual(f.selection.selectedKeys,['B','A']);assert.equal(f.selection.invalid,true);assert.equal(f.selection.message,'版本失效');
});
test('规划和提交期间防止重复动作，成功后刷新异常不能重复写入',async()=>{
  const f=await selected('merge');let finish;
  f.wait(new Promise(resolve=>finish=resolve));const pending=f.selection.execute(f.context,'merge');await tick();
  await f.selection.execute(f.context,'merge');f.selection.reset();assert.deepEqual(f.selection.selectedKeys,['B','A']);
  finish();await pending;await f.selection.execute(f.context,'merge');assert.equal(f.writes.length,1);
});
test('移动与日期选择不写入并锁定源选择，取消和重新打开使旧窗口会话失效',async()=>{
  for(const action of ['move','schedule','deadline']){
    const f=await selected(action);f.selection.request(f.context,action);const old=f.selection.popupToken();
    assert.equal(f.selection.pendingAction,action);assert.equal(f.selection.blocked(),true);
    f.selection.toggle('A');assert.deepEqual(f.selection.selectedKeys,['B','A']);assert.equal(f.writes.length,0);
    f.selection.cancelPopup();assert.equal(f.selection.blocked(),false);assert.equal(f.selection.popupAvailable(action,old),false);
    f.selection.request(f.context,action);assert.equal(f.selection.popupAvailable(action,old),false);
    f.selection.reset();assert.equal(f.selection.selecting,false);assert.equal(f.writes.length,0);
  }
});
test('批量日期返回的结构化修改原样进入规划，全部记录一次提交',async()=>{
  for(const action of ['schedule','deadline']){
    const f=await selected(action),date={date:'2026-11-20',time:{start:'10:00',end:'11:00'}};
    f.selection.request(f.context,action);f.selection.cancelPopup();
    await f.selection.execute(f.context,action,undefined,date);
    assert.equal(f.planned[0].date,date);assert.equal(f.writes.length,1);assert.equal(f.writes[0].operations.length,2);
  }
});
test('所有批量动作等待期间撤销菜单、切换数据集或页面离开均不提交',async()=>{
  for(const mode of ['policy','scope','leave'])for(const action of ['move','someday','memo','merge','schedule','deadline']){
    const f=await selected(action);let finish;f.planWait(new Promise(resolve=>finish=resolve));
    const pending=f.selection.execute(f.context,action,{fullPath:{}},{date:'2026-11-20'});await tick();
    if(mode==='policy')f.enable([]);else if(mode==='scope')f.dataSet.identity='new';else f.selection.close();
    finish();await pending;assert.equal(f.writes.length,0,mode+'/'+action);
  }
});
test('合并少于两条或未启用时不规划不提交',async()=>{
  const f=fixture();await f.selection.start('A');await f.selection.execute(f.context,'merge');
  f.enable(['merge']);await f.selection.execute(f.context,'merge');assert.equal(f.planned.length,0);assert.equal(f.writes.length,0);
});

function popup(name,selection){
  const fs=require('node:fs'),vm=require('node:vm');
  const ts=require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
  const source=fs.readFileSync('entry/src/main/ets/components/editors/'+name+'.ets','utf8')
    .replace(/@(Component|Builder)\n/g,'').replace(/@(ObjectLink|State|Prop)\s*/g,'').replace('export struct '+name,'export class '+name);
  const code=transpileFixture(ts, source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}},dialogs=[];
  class Dialog{constructor(options){this.options=options;dialogs.push(options);}open(){}close(){this.options.cancel?.();}}
  vm.runInNewContext(code,{module,exports:module.exports,CustomDialogController:Dialog,DialogAlignment:{Center:'center'},
    require:dependency=>{
      if(dependency.endsWith('/TaskActionPresentation'))return require('./helpers/task-selection.cjs').actions;
      if(dependency.endsWith('/NativeCoreService'))return {coreErrorMessage:error=>error.message};
      if(dependency==='./TaskEditor')return {TaskMovePreview:()=>{}};
      if(dependency.endsWith('/MoveToTargetPresentation'))return {refileSections:targets=>targets};
      if(dependency==='./TaskDateDialog')return {TaskDateDialog:options=>options};
      if(dependency==='./MoveToTarget')return {MoveToTarget:()=>{}};
      throw new Error('缺少弹窗替身 '+dependency);
    }});
  const state=new module.exports[name]();state.selection=selection;
  return {state,dialogs};
}
test('专用日期窗口取消零写入，旧窗口确认失效；新窗口确认只提交一次',async()=>{
  for(const action of ['schedule','deadline']){
    const f=await selected(action);f.selection.request(f.context,action);
    const old=popup('TaskBatchDateDialog',f.selection);old.state.deadline=action==='deadline';old.state.getUIContext=()=>f.context;old.state.aboutToAppear();
    old.dialogs[0].builder.closed();assert.equal(f.selection.pendingAction,'');assert.equal(f.writes.length,0);
    f.selection.request(f.context,action);
    const date={field:action==='deadline'?'DEADLINE':'SCHEDULE',value:{date:'2026-11-20'}};
    old.dialogs[0].builder.confirmed(date);assert.equal(f.writes.length,0);
    const current=popup('TaskBatchDateDialog',f.selection);current.state.deadline=action==='deadline';current.state.getUIContext=()=>f.context;current.state.aboutToAppear();
    current.dialogs[0].builder.confirmed(date);current.dialogs[0].builder.confirmed(date);await tick();
    assert.equal(f.writes.length,1);assert.equal(f.planned[0].date,date.value);assert.equal(f.selection.pendingAction,'');
    current.state.aboutToDisappear();old.state.aboutToDisappear();assert.equal(f.writes.length,1);
  }
});
test('专用移动面板的目标加载失败可重读，关闭或重新打开后旧读取结果不能回填',async()=>{
  const f=await selected('move');let finish;
  f.dataSet.moveTargets=()=>new Promise(resolve=>finish=resolve);f.selection.request(f.context,'move');
  const old=popup('TaskBatchMoveSheet',f.selection);old.state.aboutToAppear();
  old.state.dismiss();old.state.aboutToDisappear();f.selection.request(f.context,'move');
  finish({targets:[{fileVersion:'old'}], repositoryNames:new Map()});await tick();assert.equal(old.state.sections.length,0);
  f.dataSet.moveTargets=async()=>{throw new Error('目标读取失败');};
  const current=popup('TaskBatchMoveSheet',f.selection);current.state.aboutToAppear();await tick();
  assert.equal(current.state.message,'目标读取失败');assert.equal(current.state.loading,false);
  f.dataSet.moveTargets=async()=>({targets:[{fileVersion:'new'}], repositoryNames:new Map()});await current.state.load();
  assert.equal(current.state.sections[0].fileVersion,'new');assert.equal(current.state.message,'');
  assert.equal(f.writes.length,0);current.state.dismiss();assert.equal(f.selection.pendingAction,'');
});
