// 验证 TaskEditor 的绑定数据集契约与兼容管理层，编辑器不消费底层事件。
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');const {test}=require('node:test');
if(process.argv.includes('-h')||process.argv.includes('--help')){console.log('用法: node scripts/test-task-editor-manager.cjs\n验证单数据集绑定、本地修改、初始快照、变化过滤、身份映射、错误定位及取消监听。');process.exit(0);}
const ts=require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function fixture(){let watch,stopped=0,raw;const changes=[];const rows=new Map();const source={repoId:'repo',id:'A',heading:'旧快照',fileVersion:'one'};const key=t=>JSON.stringify([t.repoId,t.id]);rows.set(key(source),{...source,heading:'当前快照'});
 const manager={itemKey:()=> 'stable-row',findTask:(_,id)=>rows.get(id),subscribe(callback){watch=callback;return()=>stopped++;},updateFields(name,id,fields,version){changes.push({name,id,fields,version});const next={...rows.get(id),priority:'A'};rows.set(id,next);return next;}};
 const module={exports:{}};const mocks={'./TaskInlineService':{TaskInlineService:{findChanged:()=>new Promise(resolve=>{raw=resolve;})},TaskInlineMissingError:class extends Error{}},'./MoveToTargetService':{},'./CoreDataChangeService':{CoreDataChangeService:{watch(){assert.fail('本地管理不能注册底层监控');}},emptyCoreDataChangeState:()=>({revision:0})},'./NativeCoreService':{},'./DataSetManager':{}};
 const code=ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/TaskEditorDataManager.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
 vm.runInNewContext(code,{module,exports:module.exports,require(name){assert.ok(name in mocks,name);return mocks[name];}});
 const facade=module.exports.TaskEditorDataManager.managed(manager,'today');const data=facade.dataSet(source);const events=[];const stop=facade.watchDataSet(data,event=>events.push(event));
 return{source,key,rows,facade,data,events,changes,stop,stopped:()=>stopped,emit:value=>watch(value)};
}
test('绑定单个DataSet并立即读取当前本地快照，修改只交给管理层',async()=>{
 const f=fixture();assert.equal(f.events.length,1);assert.equal(f.events[0].task.heading,'当前快照');
 await f.facade.modify(f.data,f.source,[{field:'PRIORITY',value:'A'}]);
 assert.equal((await f.facade.current(f.data)).priority,'A');
 assert.equal(f.changes.length,1);assert.equal(f.changes[0].version,'one');f.stop();assert.equal(f.stopped(),1);
});
test('确认、准备完成、其他记录变化与同身份映射不会重复通知当前编辑器',()=>{
 const f=fixture(),key=f.key(f.source);const event={name:'today',added:[],removed:[],updated:[],identities:[{before:key,after:key}]};
 for(const type of ['complete','ready','update'])f.emit({...event,type});
 f.emit({...event,type:'update',updated:['other']});f.emit({...event,name:'other',type:'update',updated:[key]});
 assert.equal(f.events.length,1);f.emit({...event,type:'update',updated:[key]});assert.equal(f.events.length,2);
});
test('身份改名在管理层映射，错误只投递目标数据集，删除单独通知',async()=>{
 const f=fixture(),before=f.key(f.source),changed={...f.source,id:'Renamed',heading:'新标题'},after=f.key(changed);
 f.rows.delete(before);f.rows.set(after,changed);
 const event={name:'today',added:[after],removed:[before],updated:[],identities:[{before,after}],type:'update'};
 f.emit(event);assert.equal(f.data.key,'stable-row');assert.equal((await f.facade.current(f.data)).heading,'新标题');assert.equal(f.events.at(-1).removed,undefined);
 f.emit({...event,type:'error',targetKey:'other',message:'错误'});assert.equal(f.events.length,2);
 f.emit({...event,type:'error',targetKey:after,message:'文件版本已变化'});assert.equal(f.events.at(-1).blocked,true);
 f.emit({...event,identities:[],added:[],removed:[after],type:'remove'});assert.equal(f.events.at(-1).removed,true);
});
