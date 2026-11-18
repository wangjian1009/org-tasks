// 验证单条与批量共用的恢复语义、确认、冻结快照和数据集提交。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-task-record-actions.cjs\n验证重新打开、原位置恢复、永久清除、操作确认、多选快照与失败保留。'); process.exit(0);
}
const {compile,fixture,task,groups,actions}=require('./helpers/task-selection.cjs');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('SetTodo 按每个文件有效 Todo 状态规划单组，不清空其他字段；混合版本与缺失状态拒绝整组',async()=>{
  const f=fixture(), a=task('A','NEXT'), b=task('B','OPEN');
  const group=await f.service.group({},[a,b],'setTodo');
  assert.deepEqual(group.operations.map(op=>op.data.modifications),[[{field:'TODO',value:'NEXT'}],[{field:'TODO',value:'OPEN'}]]);
  assert.equal(group.fileVersions.length,1);assert.equal(f.writes.length,0);
  await assert.rejects(f.service.group({},[a,task('B',null)],'setTodo'),/没有可用/);
  await assert.rejects(f.service.group({},[a,task('B','NEXT','v2')],'setTodo'),/版本不一致/);
});
test('RestoreLocation、Clear、Delete 语义固定且规划阶段零写入',async()=>{
  const f=fixture();for(const action of ['restoreLocation','clear','delete'])await f.service.group({},[task('A')],action);
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
  f.enable(['delete']);await f.selection.execute(f.context,'setTodo');assert.equal(f.writes.length,0);
  f.enable(['setTodo']);f.selection.toggle('A');await f.selection.execute(f.context,'setTodo');
  assert.equal(f.writes.length,1);assert.equal(f.writes[0].operations[0].data.path.titles[0],'B');
  assert.equal(f.writes[0].fileVersions[0].version,'v1');assert.equal(f.selection.selecting,false);
});
test('批量提交失败保留选择和快照，提交期间重复动作与退出均被阻止',async()=>{
  const f=fixture();await f.selection.start('A');f.selection.toggle('B');let finish;
  f.wait(new Promise(resolve=>finish=resolve));f.fail(new Error('旧文件版本'));
  const pending=f.selection.execute(f.context,'setTodo');await tick();assert.equal(f.selection.busy,true);
  await f.selection.execute(f.context,'setTodo');f.selection.reset();f.selection.toggle('A');
  assert.deepEqual(f.selection.selectedKeys,['A','B']);assert.equal(f.writes.length,1);
  finish();await pending;assert.equal(f.selection.busy,false);assert.equal(f.selection.message,'旧文件版本');
  assert.equal(f.selection.selecting,true);assert.deepEqual(f.selection.selectedKeys,['A','B']);
});
test('混合批量恢复只保留失败项，成功后的新废纸篓版本用于再次恢复',async()=>{
  const f=fixture();await f.selection.start('A');f.selection.toggle('B');
  f.dataSet.submitOperationGroup=async(group,allowed)=>{assert.equal(allowed(),true);f.writes.push(group);f.rows.delete('A');f.rows.set('B',task('B','NEXT','v2'));};
  await f.selection.execute(f.context,'restoreLocation');assert.deepEqual(f.selection.selectedKeys,['B']);
  assert.match(f.selection.message,/1 条记录原位置不可用/);assert.equal(f.selection.selecting,true);
  f.dataSet.submitOperationGroup=async(group,allowed)=>{assert.equal(allowed(),true);f.writes.push(group);f.rows.delete('B');};
  await f.selection.execute(f.context,'restoreLocation');assert.equal(f.writes[1].fileVersions[0].version,'v2');assert.equal(f.selection.selecting,false);
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
  await f.selection.execute(f.context,'restoreLocation');f.selection.toggle('C');assert.deepEqual(f.selection.selectedKeys,['B','C']);
  f.dataSet.submitOperationGroup=async(group)=>{f.writes.push(group);f.rows.clear();};
  await f.selection.execute(f.context,'restoreLocation');assert.equal(f.writes[0].fileVersions[0].version,'v2');assert.equal(f.writes[0].operations.length,2);
});

test('批量等待使用各文件有效 Wait 状态，仅生成 TODO 修改并一次经 DataSet 提交',async()=>{
 const f=fixture();f.enable(['wait']);f.rows.get('B').taskStateOf=category=>{assert.equal(category,'Wait');return {name:'WAITING'};};
 await f.selection.start('B');f.selection.toggle('A');await f.selection.execute(f.context,'wait');
 assert.equal(f.writes.length,1);assert.deepEqual(f.writes[0].operations.map(op=>op.data.modifications),[
  [{field:'TODO',value:'WAITING'}],[{field:'TODO',value:'HOLD'}]]);
 assert.equal(f.dialogs.length,0);assert.equal(f.selection.selecting,false);
});
test('批量等待遇到缺失状态、混合版本或版本冲突整组拒绝，保留选择',async()=>{
 const f=fixture();f.enable(['wait']);f.rows.set('B',task('B',null));await f.selection.start('A');f.selection.toggle('B');
 await f.selection.execute(f.context,'wait');assert.equal(f.writes.length,0);assert.match(f.selection.message,/等待状态/);
 assert.deepEqual(f.selection.selectedKeys,['A','B']);
 const g=fixture();g.enable(['wait']);g.rows.set('B',task('B','NEXT','v2'));await g.selection.start('A');g.selection.toggle('B');
 await g.selection.execute(g.context,'wait');assert.equal(g.writes.length,0);assert.equal(g.selection.invalid,true);
 const h=fixture();h.enable(['wait']);await h.selection.start('A');h.selection.toggle('B');
 h.fail(Object.assign(new Error('源版本变化'),{code:'invalidState'}));await h.selection.execute(h.context,'wait');
 assert.equal(h.writes.length,1);assert.equal(h.selection.selecting,true);assert.equal(h.selection.invalid,true);
});
