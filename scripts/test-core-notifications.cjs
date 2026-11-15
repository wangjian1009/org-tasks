// 验证宿主事件快照刷新及身份映射，不在宿主重新判定冲突。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-core-notifications.cjs\n验证事件快照、多仓库身份、过期响应、错误保留和文件冲突路由目标。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks, storage, clock = {setTimeout, clearTimeout}) {
  const filename = path.resolve('entry/src/main/ets', file + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,AppStorage,setTimeout,clearTimeout){' + output + '\n})', { filename })(name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    throw new Error('缺少替身: ' + name);
  }, module, module.exports, storage, clock.setTimeout, clock.clearTimeout);
  return module.exports;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const writes=[],context={},config={repos:[{id:'config-a',name:'个人仓库',rootDirectory:'/a'},{id:'config-b',name:'工作资料',rootDirectory:'/b'}]};
  let observer,configChanged,coreId='core-a',loads=0,stops=0,values=[],failure,hold,nextTimer=0;const queries=[],timers=new Map();
  const repo={get id(){return coreId;},async load(){loads++;}};
  const workspace={async watchNotifications(callback){observer=callback;},stopWatchingNotifications(){stops++;},async query(batch){queries.push(batch);const copy=structuredClone(values);if(hold){const pending=hold;hold=undefined;await pending.promise;}if(failure){const error=failure;failure=undefined;throw error;}return[{type:'notification',result:copy}];}};
  let current=workspace;
  const service=load('services/NotificationManager',{
    './AppConfigService':{AppConfigService:{async load(){return config;},watchChanges(fn){configChanged=fn;},stopWatchingChanges(fn){if(configChanged===fn)configChanged=undefined;}}},
    './NativeCoreService':{notificationResult:value=>value.result,NativeCoreService:{async workspaceFor(){return current;},async repository(_,configured){assert.equal(configured.id,'config-a');return repo;}}},
    '../ui/Theme':{repositoryLabel:repo=>repo.name}
  },{setOrCreate(key,value){assert.equal(key,'coreNotifications');writes.push(value);}},{setTimeout(fn){const id=++nextTimer;timers.set(id,fn);return id;},clearTimeout(id){timers.delete(id);}});
  return {...service,config,context,workspace,writes,queries,loads:()=>loads,stops:()=>stops,
    emit(event={type:'globalNotificationsChanged'}){observer(event);},setCoreId(value){coreId=value;},values(value){values=value;},fail(error){failure=error;},hold(){hold=deferred();return hold;},configChanged(){configChanged?.();},setWorkspace(value){current=value;},
    runTimers(){const work=[...timers.values()];timers.clear();for(const fn of work)fn();},settle:()=>new Promise(resolve=>setImmediate(resolve)),
    publish(events){service.NotificationManager.publish(config,events,service.NotificationManager.begin());}};
}
const conflict=(repoId='core-a',paths=['same.org'])=>({type:'syncConflict',repoId,rootDirectory:repoId==='core-a'?'/a':'/b',path:paths[0]});

test('从混合查询结果发布通知，多仓库同名文件与宿主身份保持隔离',()=>{
  const f=fixture(),events=[conflict(),conflict('core-b')];f.publish(events);
  assert.deepEqual(f.writes[0].notifications,events);
  assert.deepEqual(f.writes[0].repositories.map(repo=>[repo.coreRepoId,repo.configRepoId]),[['core-a','config-a'],['core-b','config-b']]);
});

test('较早批次的结果不能恢复已经清除的通知',()=>{
  const f=fixture();f.publish([conflict()]);const old=f.NotificationManager.begin(),current=f.NotificationManager.begin();
  f.NotificationManager.publish(f.config,[],current);
  f.NotificationManager.publish(f.config,[conflict()],old);
  assert.equal(f.writes.length,2);assert.deepEqual(f.writes.at(-1).notifications,[]);
});

test('应用启动查询通知，真实提交与同步事件合并读取，切换页面不重建订阅',async()=>{
 const f=fixture();await f.NotificationManager.start(f.context);assert.equal(f.queries.length,1);assert.equal(f.writes.length,0);
 await f.NotificationManager.start(f.context);assert.equal(f.queries.length,1);
 f.values([{type:'syncRequired'}]);f.emit({type:'repositoryChanged',repoId:'core-a'});f.emit({type:'repositoryChanged',repoId:'core-a'});f.runTimers();await f.settle();
 assert.equal(f.queries.length,2);assert.equal(f.writes.length,1);assert.equal(f.writes[0].notifications[0].type,'syncRequired');
 f.values([]);f.emit();f.runTimers();await f.settle();assert.equal(f.writes.at(-1).notifications.length,0);
 assert.ok(f.queries.every(batch=>batch.length===1&&batch[0].type==='notification'));f.NotificationManager.stop();assert.equal(f.stops(),1);
});
test('重复通知结果不推进显示版本，查询失败保留上次通知，后续可以恢复',async()=>{
 const f=fixture();f.values([{type:'syncRequired'}]);await f.NotificationManager.start(f.context);const first=f.writes[0];
 f.emit();f.runTimers();await f.settle();assert.equal(f.writes.length,1);
 f.fail(new Error('查询失败'));await assert.rejects(f.NotificationManager.refresh(),/查询失败/);assert.equal(f.writes.at(-1),first);
 f.values([]);await f.NotificationManager.refresh();assert.equal(f.writes.length,2);f.NotificationManager.stop();
});

test('退出判断复用共享同步通知，等待已有失效读取，冲突通知不触发同步',async()=>{
 const f=fixture();await f.NotificationManager.start(f.context);
 assert.equal(await f.NotificationManager.hasSyncRequired(),false);assert.equal(f.queries.length,1);
 f.publish([conflict()]);assert.equal(await f.NotificationManager.hasSyncRequired(),false);assert.equal(f.queries.length,1);
 f.values([{type:'syncRequired'}]);const gate=f.hold();f.emit();
 let finished=false;const check=f.NotificationManager.hasSyncRequired().then(value=>{finished=true;return value;});
 await f.settle();assert.equal(finished,false);assert.equal(f.queries.length,2);
 gate.resolve();assert.equal(await check,true);
 assert.equal(await f.NotificationManager.hasSyncRequired(),true);assert.equal(f.queries.length,2);
 f.NotificationManager.stop();assert.equal(await f.NotificationManager.hasSyncRequired(),false);
});
test('查询期间新变化使旧结果失效，只发布最后一轮结果，停止后不再发布',async()=>{
 const f=fixture();await f.NotificationManager.start(f.context);f.values([{type:'syncRequired'}]);const gate=f.hold();f.emit();f.runTimers();await f.settle();
 f.values([]);f.emit();gate.resolve();await f.settle();assert.equal(f.queries.length,3);assert.equal(f.writes.length,0);
 const stopped=f.hold();f.values([{type:'syncRequired'}]);f.emit();f.runTimers();await f.settle();f.NotificationManager.stop();stopped.resolve();await f.settle();assert.equal(f.writes.length,0);
});
test('配置变化重新绑定 Workspace，旧订阅事件不触发读取',async()=>{
 const f=fixture();await f.NotificationManager.start(f.context);const previous=f.emit;let callback;
 const other={async watchNotifications(fn){callback=fn;},stopWatchingNotifications(){},async query(batch){return[{type:'notification',result:[]}];}};
 f.setWorkspace(other);f.configChanged();f.runTimers();await f.settle();assert.equal(f.stops(),1);
 const count=f.queries.length;previous();f.runTimers();await f.settle();assert.equal(f.queries.length,count);assert.equal(typeof callback,'function');f.NotificationManager.stop();
});

test('页面批次抢先读取后失败时，独立通知读取不会永久丢失结果',async()=>{
 const f=fixture();await f.NotificationManager.start(f.context);
 f.values([{type:'syncRequired'}]);const gate=f.hold();f.emit();f.runTimers();await f.settle();
 f.NotificationManager.begin();gate.resolve();await f.settle();
 assert.equal(f.queries.length,3);assert.equal(f.writes.length,1);
 assert.deepEqual(f.writes[0].notifications,[{type:'syncRequired'}]);f.NotificationManager.stop();
});

test('停止时尚未注册完成的监控先清理，重启后只保留新生命周期',async()=>{
 const f=fixture(),gate=deferred(),callbacks=[];let registrations=0,stops=0;
 const workspace={async watchNotifications(callback){callbacks.push(callback);if(++registrations===1)await gate.promise;},stopWatchingNotifications(){stops++;},async query(){return[{type:'notification',result:[{type:'syncRequired'}]}];}};
 f.setWorkspace(workspace);const first=f.NotificationManager.start(f.context);await f.settle();
 f.NotificationManager.stop();const restarted=f.NotificationManager.start(f.context);await f.settle();assert.equal(registrations,1);
 gate.resolve();await Promise.all([first,restarted]);assert.equal(registrations,2);assert.equal(stops,2);assert.equal(f.writes.length,1);
 const revision=f.writes[0].revision;callbacks[0]();f.runTimers();await f.settle();assert.equal(f.writes[0].revision,revision);
 f.NotificationManager.stop();
});

test('解决按钮使用配置身份与精确文件路径，仓库替换后拒绝旧通知',async()=>{
  const f=fixture(),notice=conflict();f.publish([notice]);
  assert.deepEqual(await f.NotificationManager.syncConflictTarget(f.context,notice),{repoId:'config-a',path:'same.org'});
  assert.equal(f.loads(),1);f.setCoreId('replacement');
  await assert.rejects(f.NotificationManager.syncConflictTarget(f.context,notice),/发生变化/);
  f.config.repos=[];await assert.rejects(f.NotificationManager.syncConflictTarget(f.context,notice),/不存在/);
});

test('全局同步提示按 Core 结果发布，相同结果不重复发布且不消费通知',()=>{
  const f=fixture(),events=[{type:'syncRequired'},conflict()];f.publish(events);f.publish(events);
  assert.deepEqual(f.writes.at(-1).notifications,events);assert.equal(f.writes.at(-1).repositories.length,1);assert.equal(f.writes.length,1);
});

test('冲突路径更新改变渲染键，仓库改名采用新的宿主上下文',()=>{
  const view=load('ui/CoreNotificationPresentation',{},{}),notice=conflict();
  assert.notEqual(view.coreNotificationRenderKey(notice),view.coreNotificationRenderKey(conflict('core-a',['other.org'])));
  assert.equal(view.syncConflictRepositoryName(notice,[{coreRepoId:'core-a',name:'新名字'}]),'新名字');
});

test('点击同步提示以 Wait 提交请求，排队期间立即释放 UI，页面禁用时跳过', async () => {
  const filename = path.resolve('entry/src/main/ets/components/SyncRequiredNotificationView.ets');
  const source = fs.readFileSync(filename, 'utf8').split('  build()')[0]
    .replace(/@Component\n|@State |@Prop |@StorageLink\('[^']+'\) /g, '')
    .replace('export struct SyncRequiredNotificationView', 'export class SyncRequiredNotificationView') + '}';
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  let calls = 0;
  const context = {};
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})', { filename })(() => ({
    SyncStartPolicy: { Wait: 'Wait' },
    RepositorySyncService: { start(actual, options) {
      assert.equal(actual, context); assert.deepEqual(options, { triggerReason: 'manual', policy: 'Wait' });
      calls++; return { kind: 'queued', handle: { completion: new Promise(() => {}) } };
    } }
  }), module, module.exports);
  const view = new module.exports.SyncRequiredNotificationView();
  view.getUIContext = () => ({ getHostContext: () => context });
  view.synchronize();
  assert.equal(calls, 1);
  assert.equal(view.starting, false);
  view.synchronize(); assert.equal(calls, 2);
  view.disabled = true; view.synchronize(); assert.equal(calls, 2);
});

function pullFixture() {
  const filename = path.resolve('entry/src/main/ets/components/RepositorySyncView.ets');
  const source = fs.readFileSync(filename, 'utf8').split('  @Builder\n  pullIndicator()')[0]
    .replace(/@Component\n|@State |@Prop |@BuilderParam |@StorageLink\('[^']+'\)(?: @Watch\('[^']+'\))? /g, '')
    .replace('export struct RepositorySyncView', 'export class RepositorySyncView') + '}';
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} }, starts = [], toasts = [], context = {};
  let pageIndex = 0;
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})', { filename })(() => ({
    emptyRepositorySyncState: () => ({ running: false }),
    SyncStartPolicy: { Wait: 'Wait' },
    RepositorySyncService: { start(actual, options) {
      assert.deepEqual(options, { triggerReason: 'manual', policy: 'Wait' });
      starts.push(actual); return { kind: 'queued', handle: { completion: new Promise(() => {}) } };
    } }
  }), module, module.exports);
  const view = new module.exports.RepositorySyncView();
  view.pullEnabled = true;
  view.getUIContext = () => ({ getHostContext: () => context,
    getRouter: () => ({ getState: () => ({ index: pageIndex }) }),
    getPromptAction: () => ({ showToast: value => toasts.push(value) }) });
  return { view, starts, toasts, context, leave: () => pageIndex++ };
}

test('展开卡片下拉先等待保存，保存期间连续下拉只执行一次同步', async () => {
  const f = pullFixture(), saved = deferred();
  let saves = 0;
  f.view.beforePull = async () => { saves++; return await saved.promise; };
  const first = f.view.syncFromPull();
  await f.view.syncFromPull();
  assert.equal(saves, 1); assert.equal(f.starts.length, 0);
  saved.resolve(true); await first;
  assert.deepEqual(f.starts, [f.context]);
});

test('下拉前保存失败不发起同步，后续修正后仍可重试', async () => {
  const f = pullFixture();
  f.view.beforePull = async () => false;
  await f.view.syncFromPull(); assert.equal(f.starts.length, 0);
  f.view.beforePull = async () => true;
  await f.view.syncFromPull(); assert.equal(f.starts.length, 1);
});

test('等待保存时离开页面或页面变忙，不在旧页面启动同步', async () => {
  for (const change of [f => f.leave(), f => f.view.disabled = true]) {
    const f = pullFixture(), saved = deferred();
    f.view.beforePull = () => saved.promise;
    const first = f.view.syncFromPull(); change(f); saved.resolve(true); await first;
    assert.equal(f.starts.length, 0);
  }
});

test('已有同步时仍可下拉排队，未完成的同步不会持有 UI 保存锁', async () => {
  const f = pullFixture(); f.view.syncState.running = true;
  await f.view.syncFromPull(); assert.equal(f.starts.length, 1);
  assert.equal(f.view.preparingPull, false);
  await f.view.syncFromPull(); assert.equal(f.starts.length, 2);
});

test('保存意外失败有反馈并释放下拉锁，禁用时不结束编辑会话', async () => {
  const f = pullFixture();
  f.view.beforePull = async () => { throw new Error('保存失败'); };
  await f.view.syncFromPull();
  assert.equal(f.starts.length, 0); assert.equal(f.toasts.length, 1);
  f.view.disabled = true;
  await f.view.syncFromPull(); assert.equal(f.toasts.length, 1);
  f.view.disabled = false; f.view.beforePull = async () => true;
  await f.view.syncFromPull(); assert.equal(f.starts.length, 1);
});
