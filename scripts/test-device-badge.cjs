const { transpileFixture } = require('./helpers/localized-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-device-badge.cjs\n验证共享数据集角标输出、通知联动、并发合并、错误保留及前后台订阅释放。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve;const promise=new Promise(done=>resolve=done);return{promise,resolve};}
function fixture(){
 const writes=[],listeners=new Map(),notices=new Set();let count=5,conflicts=1,ready=true,failWrite=false,startGate,loads=0,started,active=false,noticeReady=true;
 const app={dataSet(name){if(!listeners.has(name))listeners.set(name,new Set());return{subscribe(fn){listeners.get(name).add(fn);return()=>listeners.get(name).delete(fn);}};},
  manager:{async flush(){}},async start(){if(!started)started=(async()=>{loads++;if(startGate)await startGate.promise})();await started;},badgeCount(){return ready?count:undefined}};
 const mocks={
  './AppDataManager':{AppDataManager:{get active(){return active?app:undefined;},shared:()=>{active=true;return app;}}},
  './NotificationManager':{NotificationManager:{subscribe(fn){
   notices.add(fn);
   if(noticeReady)fn({notifications:Array.from({length:conflicts},()=>({type:'syncConflict'}))});
   return()=>notices.delete(fn);
  }}},
  '@kit.NotificationKit':{notificationManager:{async setBadgeNumber(value){if(failWrite)throw new Error('系统服务不可用');writes.push(value);}}}
 };
 const module={exports:{}};const filename='entry/src/main/ets/services/DeviceBadgeService.ets';
 const source=transpileFixture(ts, fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
 vm.runInNewContext(source,{module,exports:module.exports,console:{error(){}},require:name=>{assert.ok(name in mocks,'角标不能访问查询或配置服务: '+name);return mocks[name];}});
 return{closeShared(){active=false;},service:module.exports.DeviceBadgeService,writes,listeners,notices,loads:()=>loads,
  count(value){count=value;},conflicts(value){conflicts=value;for(const fn of notices)fn({notifications:Array.from({length:conflicts},()=>({type:'syncConflict'}))});},ready(value){ready=value;},fail(value){failWrite=value;},
  holdStart(){startGate=deferred();return startGate;},holdNotice(){noticeReady=false;},
  emit(name='badgeDeadline'){for(const fn of listeners.get(name)??[])fn();}};
}

test('角标反复刷新直接复用共享计数，不重新读取数据，零计数清除系统角标',async()=>{
 const f=fixture();await f.service.refresh({});await f.service.refresh({});assert.deepEqual(f.writes,[6,6]);assert.equal(f.loads(),1);
 f.count(0);f.conflicts(0);await f.service.refresh({});assert.equal(f.writes.at(-1),0);
});
test('共享数据暂不可用或系统写入失败时保留原角标，恢复后可以重试',async()=>{
 const f=fixture();await f.service.refresh({});f.ready(false);await f.service.refresh({});assert.deepEqual(f.writes,[6]);
 f.ready(true);f.count(2);f.fail(true);await f.service.refresh({});assert.deepEqual(f.writes,[6]);
 f.fail(false);await f.service.refresh({});assert.deepEqual(f.writes,[6,3]);assert.equal(f.loads(),1);
});
test('等待共享数据时连续请求合并输出最新计数，首次加载只有一次',async()=>{
 const f=fixture(),gate=f.holdStart();const first=f.service.refresh({});await tick();f.count(1);f.conflicts(0);
 const second=f.service.refresh({});f.service.refresh({});gate.resolve();await Promise.all([first,second]);assert.deepEqual(f.writes,[1]);assert.equal(f.loads(),1);
});
test('前台只订阅共享收件箱与截止数据和通知，后台停止任务监听并保留通知快照，销毁时解除订阅',async()=>{
 const f=fixture(),context={};f.service.start(context);await f.service.refresh(context);
 assert.deepEqual([...f.listeners.keys()],['badgeDeadline','inboxTasks','inboxFile']);assert.equal(f.notices.size,1);
 f.count(2);f.emit('inboxTasks');await f.service.refresh(context);assert.equal(f.writes.at(-1),3);
 f.conflicts(3);await f.service.refresh(context);assert.equal(f.writes.at(-1),5);
 const before=f.writes.length;f.service.stop();assert.equal(f.notices.size,1);assert.ok([...f.listeners.values()].every(set=>set.size===0));
 f.count(10);f.emit();await tick();assert.equal(f.writes.length,before);
 f.service.start(context);await f.service.refresh(context);assert.equal(f.writes.at(-1),13);assert.equal(f.loads(),1);f.service.close();assert.equal(f.notices.size,0);
});
test('停止时排除尚未完成的旧输出，后台显式刷新继续复用同一份数据',async()=>{
 const f=fixture();f.holdNotice();f.service.start({});await tick();f.service.stop();f.conflicts(1);await tick();assert.equal(f.writes.length,0);
 await f.service.refresh({});assert.deepEqual(f.writes,[6]);assert.equal(f.loads(),1);
});


test('共享管理器已关闭时同步收尾不重建数据集，后台输出只复用已有实例',async()=>{
 const f=fixture();await f.service.refresh({},true);assert.equal(f.loads(),0);assert.deepEqual(f.writes,[]);
 await f.service.refresh({});f.service.stop();f.count(2);await f.service.refresh({},true);assert.equal(f.writes.at(-1),3);assert.equal(f.loads(),1);
 f.closeShared();const before=f.writes.length;await f.service.refresh({},true);assert.equal(f.writes.length,before);assert.equal(f.loads(),1);
});
