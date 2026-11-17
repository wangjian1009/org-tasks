// 验证今天分区排序的持久化、延迟失效清理与编辑提交边界。
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-today-region-order.cjs\n验证今天分区和项目排序、普通任务固定在下方、新增项追加、失效记录延迟清理，以及确认、取消、恢复默认和保存失败。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(file, mocks = {}, sheet = false) {
  let source = fs.readFileSync('entry/src/main/ets/' + file + '.ets', 'utf8');
  if (sheet) source = source.split('  @Builder')[0] + '}';
  source = source.replace(/^@Component\n/gm, '').replace(/^  @(State|Prop|Link) /gm, '  ')
    .replace('export struct TodayRegionOrderSheet', 'export class TodayRegionOrderSheet');
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText + '\n})')(name => { assert.ok(name in mocks, name); return mocks[name]; }, module, module.exports);
  return module.exports;
}
const p = load('ui/TodayRegionOrderPresentation');
const projectKey = p.todayOrderProjectKey;
function file(path, category, project, repoId = 'repo') {
  return { repoId, path, category, project: () => project, isIgnore: false };
}
function task(id, category, project = null, path = 'plain.org', repoId = 'repo') {
  return { id, repoId, filePath: path, category, project: () => project };
}
function layout() {
  const plain = task('plain', '工作'), a = task('a', '工作', '项目甲', 'a.org'), b = task('b', '工作', '项目乙', 'b.org');
  return { timedItems: [{task:task('timed','生活')}], sections: [{key:'category:工作',category:'工作',
    items:[plain,a,b].map(task=>({task})),groups:[
      {key:'plain',project:null,items:[{task:plain}]},{key:'b',project:'项目乙',items:[{task:b}]},
      {key:'a',project:'项目甲',items:[{task:a}]}]}] };
}
function catalog() {
  return p.todayOrderCatalog([file('a.org','工作','项目甲'),file('b.org','工作','项目乙'),
    file('empty.org','生活','空项目'),file('uncategorized.org',null,null),file('literal.org','未分类',null)],layout());
}
test('目录覆盖无今日任务的已知项目，缺失分类与字面未分类身份独立，忽略文件不进入编辑目录',()=>{
  const result=catalog();
  assert.equal(result.find(r=>r.key==='category:生活').projects[0].taskCount,0);
  assert.ok(result.some(r=>r.key==='uncategorized'));
  assert.ok(result.some(r=>r.key==='category:未分类'));
  const ignored=file('ignored.org','隐藏','隐藏项目');ignored.isIgnore=true;
  assert.ok(!p.todayOrderCatalog([ignored],{timedItems:[],sections:[]}).some(r=>r.key==='category:隐藏'));
});
test('自定义区域可位于日程之前，项目按保存顺序，普通任务始终在项目之后且不改变区内任务',()=>{
  const input=layout(), order={version:1,regions:['category:工作','schedule'],projects:[{region:'category:工作',keys:[projectKey('repo','b.org'),projectKey('repo','a.org')]}]};
  const result=p.orderTodaySections(input.sections,order);
  assert.deepEqual(result[0].groups.map(g=>g.items[0].task.id),['b','a','plain']);
  assert.deepEqual(input.sections[0].groups.map(g=>g.items[0].task.id),['plain','b','a']);
  assert.equal(result[0].items,input.sections[0].items);
  assert.deepEqual(p.todayVisibleRegionKeys(result,true,order),['category:工作','schedule']);
});
test('新增分类和项目追加到对应层级末尾，展示与目录读取保留已保存的失效记录',()=>{
  const order={version:1,regions:['category:失效','category:生活','schedule'],projects:[{region:'category:工作',keys:['失效项目',projectKey('repo','b.org')]}]};
  const before=JSON.stringify(order), result=p.orderedTodayCatalog(catalog(),order);
  assert.deepEqual(result.slice(0,2).map(r=>r.key),['category:生活','schedule']);
  assert.deepEqual(result.find(r=>r.key==='category:工作').projects.map(p=>p.key),[projectKey('repo','b.org'),projectKey('repo','a.org')]);
  assert.equal(JSON.stringify(order),before);
  const restored={...catalog()[1],key:'category:失效'};
  assert.equal(p.orderedTodayCatalog([...catalog(),restored],order)[0].key,'category:失效');
});
test('再次确认编辑才清理失效项，无今日任务项目仍保留，编辑期间新项追加末尾',()=>{
  const order={version:1,regions:['category:旧','category:生活'],projects:[{region:'category:旧',keys:['gone']},{region:'category:工作',keys:['gone',projectKey('repo','b.org')]}]};
  const draft=p.orderedTodayCatalog(catalog(),order),current=catalog();
  current.find(r=>r.key==='category:工作').projects.push({key:projectKey('repo','new.org'),title:'新增项目',taskCount:0});
  const saved=p.todayOrderFromDraft(draft,current);
  assert.ok(!saved.regions.includes('category:旧'));
  assert.ok(!JSON.stringify(saved).includes('gone'));
  assert.ok(JSON.stringify(saved).includes('empty.org'));
  assert.equal(saved.projects.find(r=>r.region==='category:工作').keys.at(-1),projectKey('repo','new.org'));
});
test('同名项目按仓库文件区分，项目改名保留顺序身份',()=>{
  const l=layout();
  l.sections[0].groups[1].project='改名';
  const order={version:1,regions:[],projects:[{region:'category:工作',keys:[projectKey('repo','b.org')]}]};
  assert.equal(p.orderTodaySections(l.sections,order)[0].groups[0].project,'改名');
  const cat=p.todayOrderCatalog([file('a.org','工作','同名','one'),file('a.org','工作','同名','two')],{sections:[],timedItems:[]});
  assert.equal(new Set(cat[1].projects.map(p=>p.key)).size,2);
});
function storageFixture() {
  let failFlush=0, hold;
  const memory=new Map([['repos','原仓库配置']]),disk=new Map(memory),writes=[];
  const store={async get(key,fallback){return memory.get(key)??fallback;},async put(key,value){writes.push(['put',key]);memory.set(key,value);},
    async delete(key){writes.push(['delete',key]);memory.delete(key);},async flush(){if(hold)await hold;if(failFlush){failFlush--;throw new Error('磁盘写入失败');}disk.clear();for(const [key,value] of memory)disk.set(key,value);}};
  const {TodayRegionOrderService:service}=load('services/TodayRegionOrderService',{
    './AppConfigService':{APP_CONFIG_PREFERENCES:'org_tasks_config'},'./PreferencesStore':{PreferencesStore:{async open(_,name){assert.equal(name,'org_tasks_config');return store;}}}
  });
  return {service,memory,disk,writes,fail(){failFlush=1;},hold(p){hold=p;}};
}
test('排序单键落盘并跨读取恢复，恢复默认删除该键，仓库配置保持原值',async()=>{
  const f=storageFixture(),order=p.todayOrderFromDraft(catalog(),catalog());
  assert.equal(await f.service.load({}),null);
  await f.service.save({},order);
  assert.deepEqual(await f.service.load({}),order);
  assert.equal(f.disk.get('repos'),'原仓库配置');
  assert.deepEqual([...new Set(f.writes.map(w=>w[1]))],['todayRegionOrder']);
  await f.service.save({},null);
  assert.ok(!f.disk.has('todayRegionOrder'));
});
test('写盘失败拒绝保存并恢复旧值，后续重试成功；损坏配置不被自动覆盖',async()=>{
  const f=storageFixture(),before={version:1,regions:['schedule'],projects:[]},after=p.todayOrderFromDraft(catalog(),catalog());
  await f.service.save({},before);f.fail();
  await assert.rejects(f.service.save({},after),/磁盘写入失败/);
  assert.deepEqual(await f.service.load({}),before);
  await f.service.save({},after);assert.deepEqual(await f.service.load({}),after);
  f.memory.set('todayRegionOrder','{bad');
  await assert.rejects(f.service.load({}),/无法读取/);
  assert.equal(f.memory.get('todayRegionOrder'),'{bad');
});
function sheetFixture() {
  const {TodayRegionOrderSheet:Sheet}=load('components/editors/TodayRegionOrderSheet',{
    '../../ui/TodayRegionOrderPresentation':p,'../../services/NativeCoreService':{coreErrorMessage:e=>e.message}
  },true);
  const sheet=new Sheet(),writes=[],dialogs=[];
  sheet.catalog=catalog();sheet.initialOrder=null;sheet.visible=true;sheet.busy=false;
  sheet.getUIContext=()=>({showAlertDialog(options){dialogs.push(options);}});
  sheet.save=async(draft,reset)=>writes.push({draft,reset});sheet.aboutToAppear();
  return {sheet,writes,dialogs};
}
test('拖动只修改草稿，项目局限所属分类，取消与恢复默认均不提前写入',async()=>{
  const f=sheetFixture(),index=f.sheet.draft.findIndex(r=>r.key==='category:工作');
  f.sheet.moveRegion(index,0);f.sheet.moveProject('category:工作',0,1);
  assert.equal(f.writes.length,0);
  f.sheet.cancel();assert.equal(f.dialogs.length,1);assert.equal(f.sheet.visible,true);
  f.dialogs[0].secondaryButton.action();assert.equal(f.sheet.visible,false);
  f.sheet.restoreDefaults();assert.equal(f.writes.length,0);
  f.sheet.visible=true;await f.sheet.confirm();assert.equal(f.writes.length,1);assert.equal(f.writes[0].reset,true);
});
test('保存期间禁止重复确认与拖动，失败保留草稿，重试成功后关闭',async()=>{
  const f=sheetFixture();f.sheet.moveRegion(1,0);
  let release;const pending=new Promise(resolve=>release=resolve);
  f.sheet.save=async()=>{await pending;throw new Error('写入失败');};
  const signature=JSON.stringify(f.sheet.draft),saving=f.sheet.confirm();
  await f.sheet.confirm();f.sheet.moveRegion(0,1);assert.equal(JSON.stringify(f.sheet.draft),signature);
  release();await saving;assert.equal(f.sheet.visible,true);assert.match(f.sheet.message,/写入失败/);
  f.sheet.save=async()=>{};await f.sheet.confirm();assert.equal(f.sheet.visible,false);
});
test('读取失败时只有显式恢复默认后才能保存，恢复后继续拖动仍可保存',async()=>{
  const f=sheetFixture();f.sheet.readError='读取失败';await f.sheet.confirm();assert.equal(f.writes.length,0);
  f.sheet.restoreDefaults();f.sheet.moveRegion(1,0);await f.sheet.confirm();assert.equal(f.writes.length,1);assert.equal(f.writes[0].reset,false);
});
