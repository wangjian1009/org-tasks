// 验证宿主事件快照刷新及身份映射，不在宿主重新判定冲突。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-core-notifications.cjs\n验证列表订阅、初始回调、仓库范围、过期生命周期、错误保留和冲突路由。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
  const writes=[], callbacks=[], scopes=[], context={}, config={repos:[
    {id:'config-a',name:'个人仓库',rootDirectory:'/a',webdavEnabled:true,webdavUrl:'https://example.test/dav/'},
    {id:'config-b',name:'工作资料',rootDirectory:'/b',webdavEnabled:false,webdavUrl:''}]};
  let configChanged, stops=0, initial=[], failure, gate, nativeRevision=0, nativeValues=[];
  const workspace={async repos(){return [{id:'core-a',rootDirectory:'/a'},{id:'core-b',rootDirectory:'/b'}];},
    async watchNotifications(callback,scope){
      if(failure){const error=failure;failure=undefined;throw error;}
      callbacks.push(callback);scopes.push(scope);
      if(gate){const held=gate;gate=undefined;await held.promise;}
      nativeValues=initial.slice(); callback({type:'snapshot',revision:nativeRevision,notifications:initial});
    },stopWatchingNotifications(){stops++;},async query(){throw new Error('禁止查询通知');}};
  let current=workspace;
  const service=load('services/NotificationManager',{
    './AppConfigService':{AppConfigService:{async load(){return config;},watchChanges(fn){configChanged=fn;},stopWatchingChanges(fn){if(configChanged===fn)configChanged=undefined;}}},
    './NativeCoreService':{NativeCoreService:{async workspaceFor(){return current;}}},
    '../ui/Theme':{repositoryLabel:repo=>repo.name}
  },{setOrCreate(key,value){assert.equal(key,'coreNotifications');writes.push(value);}});
  return {...service,config,context,workspace,writes,callbacks,scopes,stops:()=>stops,
    emit(list){
      const before=nativeValues;const fromRevision=nativeRevision++;
      const changes=before.filter(item=>!list.some(value=>JSON.stringify(item)===JSON.stringify(value))).map(notification=>({kind:'removed',notification}));
      changes.push(...list.filter(item=>!before.some(value=>JSON.stringify(item)===JSON.stringify(value))).map(notification=>({kind:'added',notification})));
      nativeValues=list.slice(); callbacks.at(-1)({type:'changed',fromRevision,revision:nativeRevision,changes});
    },delta(event){callbacks.at(-1)(event);},revision:()=>nativeRevision,values(value){initial=value;},
    fail(error){failure=error;},hold(){gate=deferred();return gate;},configChanged(){configChanged?.();},setWorkspace(value){current=value;},
    settle:()=>new Promise(resolve=>setImmediate(resolve))};
}
const conflict=(repoId='core-a')=>({type:'syncConflict',repoId,rootDirectory:repoId==='core-a'?'/a':'/b',path:'same.org'});

test('订阅携带远程仓库范围，首次列表直接发布，页面启动不查询通知',async()=>{
  const f=fixture();f.values([{type:'syncRequired'}]);await f.NotificationManager.start(f.context);
  assert.deepEqual(f.scopes,[['core-a']]);assert.equal(f.writes.length,1);
  await f.NotificationManager.start(f.context);assert.equal(f.callbacks.length,1);
  f.config.repos[0].webdavEnabled=false;f.configChanged();await f.settle();assert.deepEqual(f.scopes.at(-1),[]);
  f.config.repos[0].webdavEnabled=true;f.config.repos[0].webdavUrl=' ';f.configChanged();await f.settle();assert.deepEqual(f.scopes.at(-1),[]);
  f.NotificationManager.stop();
});
test('列表回调更新共享快照，多仓库同名文件保持身份，重复列表不推进版本',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);f.emit([conflict(),conflict('core-b')]);
  assert.deepEqual(f.writes[0].repositories.map(repo=>[repo.coreRepoId,repo.configRepoId]),[['core-a','config-a'],['core-b','config-b']]);
  f.emit([conflict(),conflict('core-b')]);assert.equal(f.writes.length,1);
  f.emit([]);assert.equal(f.writes.length,2);assert.deepEqual(f.writes.at(-1).notifications,[]);f.NotificationManager.stop();
});
test('首次异步绑定后向订阅者推送空快照，后续推送列表变化',async()=>{
  const f=fixture(),gate=f.hold();const started=f.NotificationManager.start(f.context);
  const received=[];f.NotificationManager.subscribe(snapshot=>received.push(snapshot.notifications));
  await f.settle();assert.deepEqual(received,[]);gate.resolve();await started;assert.deepEqual(received,[[]]);
  f.emit([{type:'syncRequired'}]);assert.deepEqual(received.at(-1),[{type:'syncRequired'}]);
  f.NotificationManager.stop();assert.equal(received.length,2);
});
test('配置重绑和停止后，旧回调不能覆盖新快照',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);const old=f.callbacks[0];
  f.values([{type:'syncRequired'}]);f.configChanged();await f.settle();old({type:'snapshot',revision:0,notifications:[]});
  assert.deepEqual(f.writes.at(-1).notifications,[{type:'syncRequired'}]);
  f.NotificationManager.stop();f.emit([]);assert.equal(f.writes.length,1);
});
test('订阅注册失败保留旧快照，下一次绑定恢复',async()=>{
  const f=fixture();f.values([{type:'syncRequired'}]);await f.NotificationManager.start(f.context);const first=f.writes[0];
  f.fail(new Error('注册失败'));f.configChanged();await f.settle();assert.equal(f.writes.at(-1),first);
  f.values([]);f.NotificationManager.resume();await f.settle();assert.equal(f.writes.length,2);f.NotificationManager.stop();
});
test('异步注册期间停止重启，旧生命周期回调被忽略',async()=>{
  const f=fixture(),gate=f.hold();f.values([{type:'syncRequired'}]);const old=f.NotificationManager.start(f.context);
  await f.settle();f.NotificationManager.stop();f.values([]);const current=f.NotificationManager.start(f.context);
  gate.resolve();await Promise.all([old,current]);assert.equal(f.writes.length,0);f.NotificationManager.stop();
});
test('配置变化重新订阅，相同 Workspace 也替换范围',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);f.config.repos[1].webdavEnabled=true;f.config.repos[1].webdavUrl='https://example.test/work/';
  f.configChanged();await f.settle();assert.deepEqual(f.scopes.at(-1),['core-a','core-b']);f.NotificationManager.stop();
});
test('订阅者立即收到已绑定的共享内容，解除后不再接收变化',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);const received=[];
  const unsubscribe=f.NotificationManager.subscribe(snapshot=>received.push(snapshot));
  assert.deepEqual(received[0].notifications,[]);
  f.emit([conflict(),{type:'syncRequired'}]);assert.equal(received[1].notifications.length,2);
  unsubscribe();f.emit([]);assert.equal(received.length,2);f.NotificationManager.stop();
});

test('健康订阅恢复前台时继续使用原回调',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);
  f.NotificationManager.resume();await f.settle();
  assert.equal(f.callbacks.length,1);assert.equal(f.stops(),0);f.NotificationManager.stop();
});

test('完整值替换基线异常，增量原子去重且旧版本不覆盖缓存',async()=>{
  const f=fixture();await f.NotificationManager.start(f.context);
  const first={type:'syncBaselineUnavailable',repoId:'core-a',rootDirectory:'/a',reason:'missing'};
  f.emit([first]);assert.equal(f.writes.at(-1).repositories[0].configRepoId,'config-a');
  const next={...first,reason:'invalid'};
  const fromRevision=f.revision();
  f.delta({type:'changed',fromRevision,revision:fromRevision+1,changes:[{kind:'updated',before:first,after:next},{kind:'added',notification:next}]});
  assert.deepEqual(f.writes.at(-1).notifications,[next]);
  const writes=f.writes.length;
  f.delta({type:'changed',fromRevision,revision:fromRevision+2,changes:[{kind:'removed',notification:next}]});
  assert.equal(f.writes.length,writes);f.NotificationManager.stop();
});
