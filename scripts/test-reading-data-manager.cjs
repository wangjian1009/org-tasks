// 验证完整阅读数据管理对象的订阅、合并、配置切换与迟到结果边界。
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {test}=require('node:test');
if(process.argv.includes('-h')||process.argv.includes('--help')){console.log('用法: node scripts/test-reading-data-manager.cjs\n验证阅读快照管理的外部更新、请求合并、错误保留、配置重绑、同步完成与关闭。');process.exit(0);}
const ts=require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function until(check){const end=Date.now()+2000;while(!check()){if(Date.now()>end)throw new Error('管理对象未完成更新');await new Promise(resolve=>setTimeout(resolve,1));}}
function gate(){let resolve;const promise=new Promise(done=>resolve=done);return{promise,resolve};}
function fixture(){let configChanged,syncChanged,current=1,reads=0,failure,hold,registration;const events=[],stops=[],states=[];
 const makeWorkspace=id=>({id,async watchDataChanges(fn){events.push({id,fn});if(registration){const pending=registration;registration=undefined;await pending.promise;}return id;},stopWatchingDataChanges(id){stops.push(id);}});
 let workspace=makeWorkspace(1);
 const module={exports:{}},mocks={
  './AppConfigService':{AppConfigService:{async load(){return{repos:[]}},watchChanges(fn){configChanged=fn},stopWatchingChanges(fn){if(configChanged===fn)configChanged=undefined}}},
  './NativeCoreService':{NativeCoreService:{async workspaceFor(){return workspace}}},
  './RepositorySyncService':{RepositorySyncService:{watch(fn){syncChanged=fn;fn({running:false})},stopWatching(fn){if(syncChanged===fn)syncChanged=undefined}}}
 };
 const source=ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/SnapshotDataManager.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
 vm.runInNewContext(source,{module,exports:module.exports,setTimeout,clearTimeout,console,require:name=>{assert.ok(name in mocks,name);return mocks[name]}});
 const manager=new module.exports.SnapshotDataManager({},async()=>{reads++;const value=current;if(hold){const pending=hold;hold=undefined;await pending.promise;}if(failure)throw failure;return{value};},event=>event.repoId==='target');
 manager.subscribe(state=>states.push(state));
 return{manager,states,stops,events,reads:()=>reads,value(value){current=value},fail(value){failure=value},hold(){hold=gate();return hold},registerHold(){registration=gate();return registration},emit(id=workspace.id,repoId='target'){events.find(event=>event.id===id)?.fn({repoId})},config(){workspace=makeWorkspace(2);configChanged()},sync(running){syncChanged({running})}};
}
test('首次启动只读取一次，外部事件自动合并读取且不处理范围外事件',async()=>{const f=fixture();try{await f.manager.start();await f.manager.start();assert.equal(f.reads(),1);f.value(2);f.emit(1,'other');await tick();assert.equal(f.reads(),1);f.emit();f.emit();await until(()=>f.states.at(-1).value?.value===2);assert.equal(f.reads(),2);}finally{f.manager.close()}});
test('读取期间新事件使旧结果失效，只发布最后一轮快照',async()=>{const f=fixture();try{await f.manager.start();const hold=f.hold();f.value(2);const reading=f.manager.refresh();await until(()=>f.reads()===2);f.value(3);f.emit();hold.resolve();await reading;assert.equal(f.states.some(state=>state.value?.value===2),false);assert.equal(f.states.at(-1).value.value,3);}finally{f.manager.close()}});
test('配置切换重新绑定 Workspace，旧订阅不能继续发起读取',async()=>{const f=fixture();try{await f.manager.start();f.value(2);f.config();await until(()=>f.states.at(-1).value?.value===2);assert.deepEqual(f.stops,[1]);const reads=f.reads();f.emit(1);await tick();assert.equal(f.reads(),reads);}finally{f.manager.close()}});
test('同步完成由管理层刷新，即使没有业务文件变化也能更新日志',async()=>{const f=fixture();try{await f.manager.start();f.value(2);f.sync(true);f.sync(false);await until(()=>f.states.at(-1).value?.value===2);assert.equal(f.reads(),2);}finally{f.manager.close()}});
test('失败保留最近快照，显式重试恢复，关闭后在途结果不再发布',async()=>{const f=fixture();await f.manager.start();f.fail(new Error('离线'));await f.manager.refresh();assert.equal(f.states.at(-1).value.value,1);assert.match(f.states.at(-1).message,/离线/);f.fail(undefined);f.value(2);await f.manager.refresh();assert.equal(f.states.at(-1).message,'');const hold=f.hold(),reading=f.manager.refresh();await until(()=>f.reads()===4);const before=f.states.length;f.manager.close();hold.resolve();await reading;assert.equal(f.states.length,before);assert.deepEqual(f.stops,[1]);});
test('关闭时尚未完成的订阅注册会清理句柄，不读取文件',async()=>{const f=fixture(),hold=f.registerHold();const reading=f.manager.start();await until(()=>f.events.length===1);f.manager.close();hold.resolve();await reading;assert.deepEqual(f.stops,[1]);assert.equal(f.reads(),0);});

test('笔记本发布可独立复制的元信息模型，界面项目判断不依赖原生方法绑定',async()=>{
 const native={repoId:'repo',path:'project.org',projectName:'项目',category:null,title:'标题',titleParts:[],tagOptions:[],tagGroups:[],isIgnore:false,hasConflict:false,taskStateCounts:[],priorityOptions:[],defaultPriority:{name:'B',category:'Middle'},byteLength:0,modifiedAt:null,
  taskStateOf(){return null},taskPriorityOf(){return null},project(){throw new Error('不能从复制后的界面调用原生方法')}};
 function load(file,mocks){const module={exports:{}};const code=ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/'+file+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;vm.runInNewContext(code,{module,exports:module.exports,require:name=>{assert.ok(name in mocks,name);return mocks[name]}});return module.exports;}
 const snapshots=load('PageDataSnapshot',{'./NativeCoreService':{}});
 const {NotebookDataManager}=load('ReadingDataManager',{'./NotebookService':{NotebookService:{async list(){return[{files:[native]}]}}},'./PageDataSnapshot':snapshots,'./SnapshotDataManager':{SnapshotDataManager:class{constructor(context,reader){this.reader=reader}}},'../ui/Theme':{},'./NativeCoreService':{}});
 const manager=new NotebookDataManager({}),value=await manager.reader({repos:[]});const file=value.groups[0].files[0];
 assert.equal(file.project(),'项目');assert.notEqual(file,native);assert.equal(file.taskStateOf('Todo'),null);
});
