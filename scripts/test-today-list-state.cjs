// 运行列表的真实生命周期与滚动回调，验证路由替换和数据确认不会丢失阅读位置。
const { transpileFixture } = require('./helpers/localized-resources.cjs');
const fs=require('node:fs');const vm=require('node:vm');const assert=require('node:assert/strict');const {test}=require('node:test');
if(process.argv.includes('-h')||process.argv.includes('--help')){console.log('用法: node scripts/test-today-list-state.cjs\n验证今天／随时列表路由返回时恢复位置、首次测量前不覆盖原位置，以及重复布局不会跳回顶部。');process.exit(0);}
const ts=require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function run(source,bindings={}){const module={exports:{}};vm.runInNewContext(transpileFixture(ts, source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{module,exports:module.exports,...bindings});return module.exports;}
const position=run(fs.readFileSync('entry/src/main/ets/services/PageListPosition.ets','utf8')).PageListPosition;
const source=fs.readFileSync('entry/src/main/ets/components/TodayTaskList.ets','utf8');
const appear=source.match(/  aboutToAppear\(\): void \{[\s\S]*?\n  \}/)[0];
const notice=source.match(/  notificationsChanged\(next: boolean\): void \{[\s\S]*?\n  \}/)[0];
const disappear=source.match(/  aboutToDisappear\(\): void \{[\s\S]*?\n  \}/)[0];
const save=source.match(/  private savePosition\(\): void \{[\s\S]*?\n  \}/)[0];
const index=source.match(/\.onScrollIndex\(([^\n]+)\)\n/)[1];
const scroll=source.match(/\.onDidScroll\(([^\n]+)\)\n/)[1];
const area=source.match(/\.onAreaChange\(([\s\S]*?\n\s+\})\)/)[1];
const List=run('export class List {'+appear+save+notice+disappear+' handlers(){return {index:'+index+',scroll:'+scroll+',area:'+area+'}}}',{PageListPosition:position,NotificationManager:{watch:()=>()=>{}},ScrollState:{Idle:0,Scroll:1,Fling:2},NotificationLayoutFrame:class{constructor(callback){this.callback=callback;}}}).List;
function view(key,keys=Array.from({length:50},(_,index)=>'item-'+index),limit=0){
 const list=new List(),calls=[],frames=[];list.bulkOperations=[];list.selection={close(){}};let offset=0;list.regionPreviewLimit=limit;list.notificationLayout=0;list.getUIContext=()=>({postFrameCallback(frame){frames.push(frame);}});list.positionKey=key;list.positionKeys=()=>keys;
 list.listScroller={currentOffset:()=>({yOffset:offset}),getVisibleListContentInfo:()=>({index:list.firstIndex}),getItemRect:index=>({y:index*100-offset}),
  scrollTo(options){calls.push(options);offset=options.yOffset;},scrollBy(_x,y){calls.push({relative:y});offset+=y;}};
 list.aboutToAppear();offset=list.initialIndex*100;
 return{list,calls,frames,handlers:list.handlers(),offset(value){offset=value;},current:()=>offset};
}
test('路由替换后恢复原偏移，初始滚动回调不覆盖已保存位置，重复布局不重定位',()=>{
 const first=view('today');first.handlers.area({}, {height:600});first.offset(820);first.handlers.index(8);first.handlers.scroll(0,1);
 const next=view('today');assert.equal(next.list.initialIndex,8);next.handlers.scroll(0,0);assert.equal(position.read('today').offset,820);
 next.handlers.area({}, {height:600});assert.equal(next.calls.length,1);assert.equal(next.current(),820);
 next.handlers.area({}, {height:640});assert.equal(next.calls.length,1);
 const other=view('anytime');assert.equal(other.list.initialIndex,0);other.handlers.area({}, {height:600});assert.equal(other.calls[0].yOffset,0);
});
test('可见项负偏移按相对位置恢复，不受屏幕外行高估算影响',()=>{
 position.save('anchor',20,934,-33.5);
 const next=view('anchor');next.list.listScroller.getItemRect=()=>({y:0});
 next.handlers.area({}, {height:600});assert.equal(next.calls.length,1);assert.equal(next.calls[0].relative,33.5);
});

test('重进三条预览页时，隐藏任务的旧滚动索引与锚点不再使用',()=>{
 position.save('preview-hidden',18,1800,-20,'hidden-task');
 const next=view('preview-hidden',['notifications','category','task-1','task-2','task-3','more'],3);
 assert.equal(next.list.initialIndex,0);
 next.handlers.area({}, {height:600});assert.equal(next.current(),0);
 assert.equal(next.calls[0].yOffset,0);
});
test('提示行插入和空闲布局不覆盖原记录身份，返回按当前索引恢复同一记录',()=>{
 const first=view('stable');first.handlers.area({}, {height:600});first.offset(820);first.handlers.index(8);first.handlers.scroll(0,1);
 first.offset(0);first.handlers.index(0);first.handlers.scroll(0,0);
 assert.equal(position.read('stable').key,'item-8');
 const next=view('stable',['notice',...Array.from({length:50},(_,index)=>'item-'+index)]);
 assert.equal(next.list.initialIndex,9);next.handlers.area({}, {height:600});assert.equal(next.current(),920);
});

test('通知插入与移除保持同一可见任务及像素位置，离开后不执行迟到补偿',()=>{
 const entries=['notifications',...Array.from({length:50},(_,i)=>'item-'+i)],f=view('notice-change',entries);
 f.list.listScroller.getItemRect=index=>({y:(index===0?0:(index-1)*100+(f.list.showNotifications?60:0))-f.current()});
 f.handlers.area({}, {height:600});f.offset(820);f.handlers.index(9);
 f.list.notificationsChanged(true);f.frames.shift().callback();assert.equal(f.current(),880);
 f.handlers.index(9);f.list.notificationsChanged(false);f.frames.shift().callback();assert.equal(f.current(),820);
 f.handlers.index(9);f.list.notificationsChanged(true);f.list.aboutToDisappear();f.frames.shift().callback();assert.equal(f.current(),820);
});

test('列表位于顶部时直接展示新通知，不滚动将提示藏到屏幕外',()=>{
 const f=view('notice-top');f.handlers.area({}, {height:600});
 f.list.notificationsChanged(true);
 assert.equal(f.list.showNotifications,true);assert.equal(f.frames.length,0);assert.equal(f.current(),0);
});

test('区域展开等待当前编辑保存，失败或离开后不展开，重复点击不重复登记',async()=>{
 const expand=source.match(/  private async expandRegion\([^\n]+\n[\s\S]*?\n  \}/)[0];
 let resolveSave;
 const Region=run('export class Region {'+expand+'}',{todayRegionKey:(section,project)=>JSON.stringify([section,project]),
  TaskInlineSession:{end:()=>new Promise(resolve=>{resolveSave=resolve;})}}).Region;
 const list=new Region();list.active=true;list.expandedRegionKeys=[];
 const pending=list.expandRegion('工作','项目甲');assert.equal(list.expandedRegionKeys.length,0);
 resolveSave(false);await pending;assert.equal(list.expandedRegionKeys.length,0);
 for(let i=0;i<2;i++){const next=list.expandRegion('工作','项目甲');resolveSave(true);await next;}
 assert.equal(list.expandedRegionKeys.length,1);
 const leaving=list.expandRegion('生活','');list.active=false;resolveSave(true);await leaving;
 assert.equal(list.expandedRegionKeys.length,1);
});
