#!/usr/bin/env node
// 验证页面数据集的版本、字段增量、提交队列与磁盘缓存。
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const fsp=fs.promises;
const os=require('node:os');
const path=require('node:path');
const vm=require('node:vm');
const crypto=require('node:crypto');
if(process.argv.includes('-h')||process.argv.includes('--help')) { console.log('用法: node scripts/test-data-set-manager.cjs\n验证页面数据集的版本阶段、字段增量提交、事件归并、缓存恢复与关闭。');process.exit(0); }
const ts=require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function until(condition){const limit=Date.now()+2000;while(!condition()){if(Date.now()>limit)throw new Error('等待异步状态超时');await new Promise(resolve=>setTimeout(resolve,1))}}
function gate(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject}}
function load(file,mocks){const module={exports:{}};const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename:file})(name=>{assert.ok(Object.hasOwn(mocks,name),name);return mocks[name]},module,module.exports);return module.exports}
function task(id='A', overrides={}){const states={Todo:{name:'TODO',category:'Todo'},Doing:{name:'NEXT',category:'Doing'},Wait:null,Done:{name:'DONE',category:'Done'},Cancel:null};const priority={name:'B',category:'Middle'};const value={entity:crypto.randomUUID(),id,taskId:id,fullPath:{repoId:'repo',file:'a.org',titles:[id],occurrence:1},fileVersion:'file-1',repoId:'repo',heading:id,projectName:null,category:'Work',headingParts:[{text:id,href:null,isLink:false,count:null,link:null}],state:states.Todo,createdAt:null,closedAt:null,modifiedAt:null,priority:null,priorityOptions:[{name:'A',category:'Hight'},priority],defaultPriority:priority,scheduled:'',deadline:'',tags:[],ownTags:[],inheritedTags:[],supportTags:null,editContent:{ownTags:[],notes:'old',notesHtml:'<p>old</p>',checklist:[],blocks:[],scheduledRepeat:null,deadlineRepeat:null,scheduledPlanning:null,deadlinePlanning:null},filePath:'a.org',fileName:'a.org',level:1,body:'old',bodyFirstLine:'old',addressLinks:[],bodyHtml:'<p>old</p>',logbookHtml:'',logs:[],progress:-1,hasList:false,hasText:true,isRepeating:false,isHabit:false,hasAttach:false,...overrides};value.isDone=()=>['Done','Cancel'].includes(value.state?.category);value.project=()=>value.projectName;value.taskStateOf=category=>states[category];value.taskPriorityOf=category=>value.priorityOptions.find(p=>p.category===category)??null;return value}
function metadata(){const base=task();return{repoId:'repo',path:'a.org',title:'A',titleParts:[],projectName:null,category:'Work',priorityOptions:base.priorityOptions,defaultPriority:base.defaultPriority,tagOptions:[],tagGroups:[],isIgnore:false,hasConflict:false,taskStateCounts:[],byteLength:20,modifiedAt:null,project:()=>null,taskStateOf:base.taskStateOf,taskPriorityOf:base.taskPriorityOf}}
async function fixture(){const directory=await fsp.mkdtemp(path.join(os.tmpdir(),'org-data-set-'));const handles=new Map();const gates=[];let partial=Infinity;let writeFailure=false;let diskDelay;let discarded=0;const io={OpenMode:{CREATE:1,TRUNC:2,READ_WRITE:4},access:async p=>{try{await fsp.access(p);return true}catch(e){if(e.code==='ENOENT')return false;throw e}},stat:p=>fsp.stat(p),readText:p=>fsp.readFile(p,'utf8'),mkdir:(p)=>fsp.mkdir(p,{recursive:true}),listFile:p=>fsp.readdir(p),open:async p=>{const handle=await fsp.open(p,'w+');handles.set(handle.fd,handle);return{fd:handle.fd}},write:async(fd,buffer)=>{if(diskDelay){const pending=diskDelay;diskDelay=undefined;pending.entered.resolve();await pending.promise}if(writeFailure)throw new Error('写盘失败');return(await handles.get(fd).write(Buffer.from(buffer).subarray(0,partial))).bytesWritten},fsync:fd=>handles.get(fd).sync(),close:async file=>{const handle=handles.get(file.fd);handles.delete(file.fd);await handle.close()},rename:(a,b)=>fsp.rename(a,b),unlink:async p=>{await fsp.unlink(p);discarded++}};
 const util={generateRandomUUID:()=>crypto.randomUUID(),TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text)}}};
 const config={repos:[{id:'config',rootDirectory:'/repo',webdavPassword:'PRIVATE_PASSWORD_MARKER'}],todoDefaults:'DEFAULT',coreSettings:{additionStates:[]}};
 const rawCallbacks=new Map();const subscriptions=new Map();let nextSub=1;let rows=[task()];let fileVersion=1;let failNext=false;let delay;let subDelay;let sideEffect=false;let keyPolicy=(_row,index)=>[{value:index,descending:false,missingLast:false}];const calls=[];const groups=[];
 const native={watchDataChanges:async callback=>{const id=nextSub++;rawCallbacks.set(id,callback);return id},stopWatchingDataChanges:id=>rawCallbacks.delete(id),subscribeQuery:async(query,callback,operationId)=>{const id=nextSub++;subscriptions.set(id,{query,callback});calls.push(query);const data=query.type==='file'?{type:'file',result:[metadata()]}:{type:'task',result:{tasks:rows.map((row,index)=>task(row.id,{...row,orderKey:keyPolicy(row,index)})),categories:[{key:'category:Work',category:'Work',count:rows.length}]}};if(subDelay){const pending=subDelay;subDelay=undefined;await pending.promise}return{subscriptionId:id,data,operationId}},unsubscribeQuery:id=>subscriptions.delete(id),querySubscriptionStatus:async()=> 'current',query:async()=>{throw new Error('禁止重新查询')},executeTaskOperations:async group=>{groups.push(group);if(delay){const pending=delay;delay=undefined;await pending.promise}if(failNext){failNext=false;throw new Error('提交失败')}
  for(const expected of group.fileVersions??[]){const current=rows.find(row=>row.repoId===expected.repoId&&row.filePath===expected.file);if(current&&current.fileVersion!==expected.version)throw new Error('文件版本冲突')}
  const old=rows.slice();fileVersion++;
  for(const operation of group.operations){if(operation.type==='Creation'){const data=operation.data;rows=rows.map(item=>item.heading===data.title&&item.fullPath.titles.length===1?task(data.title+'#'+((item.fullPath.occurrence??1)+1),{...item,id:data.title+'#'+((item.fullPath.occurrence??1)+1),taskId:data.title+'#'+((item.fullPath.occurrence??1)+1),fullPath:{...item.fullPath,occurrence:(item.fullPath.occurrence??1)+1}}):item);rows.unshift(task(data.title,{fileVersion:'file-'+fileVersion,heading:data.title,fullPath:{...data.position.parent,titles:[data.title],occurrence:1},state:data.state?{name:data.state,category:'Todo'}:null}))}else{const index=rows.findIndex(item=>JSON.stringify(item.fullPath)===JSON.stringify(operation.data.path));assert.ok(index>=0,'写入必须使用最新路径');if(operation.type==='Deletion')rows.splice(index,1);else if(operation.type==='Modification'){let current=rows[index];for(const change of operation.data.modifications){if(change.field==='TITLE')current=task('renamed-'+change.value,{...current,id:'renamed-'+change.value,taskId:'renamed-'+change.value,heading:change.value,fullPath:{...current.fullPath,titles:[change.value]},headingParts:[{text:change.value,href:null,isLink:false,count:null,link:null}]});else if(change.field==='NOTES')current=task(current.id,{...current,body:change.value,editContent:{...current.editContent,notes:change.value,notesHtml:'<p>'+change.value+'</p>'}});else if(change.field==='PRIORITY')current=task(current.id,{...current,priority:current.priorityOptions.find(p=>p.name===change.value)??null});}rows[index]=current}}}
  rows=rows.map((item,index)=>task(item.id,{...item,fileVersion:'file-'+fileVersion,orderKey:keyPolicy(item,index)}));if(sideEffect)rows=rows.map((item,index)=>index?task(item.id,{...item,body:'CORE RELATED'}):item);
  const raw=(view)=>view?{task:{id:view.id,fullPath:view.fullPath,fileVersion:view.fileVersion},position:{parent:{repoId:'repo',file:'a.org',titles:[]}},view}:null;
  const changes=[];const next=rows.slice();for(let i=0;i<old.length;i++){const after=next.find(item=>item.entity===old[i].entity);if(after)next.splice(next.indexOf(after),1);changes.push({kind:after?'updated':'deleted',before:raw(old[i]),after:raw(after)})}for(const added of next)changes.push({kind:'created',before:null,after:raw(added)});
  for(const callback of rawCallbacks.values())callback({type:'repositoryChanged',repoId:'repo',operationId:group.operationId,files:[],changes:[]});
  for(const item of subscriptions.values())item.callback({type:'repositoryChanged',repoId:'repo',operationId:group.operationId,files:[{before:metadata(),after:metadata(),beforeVersion:'file-'+(fileVersion-1),afterVersion:'file-'+fileVersion,afterView:metadata()}],changes:item.query.type==='file'?[]:changes,categories:[{key:'category:Work',category:'Work',count:rows.length}]});
 }};
 const configListeners=new Set();const service={NativeCoreService:{workspaceFor:async()=>native}};
 const snapshots=load('entry/src/main/ets/services/PageDataSnapshot.ets',{'./NativeCoreService':service});
 const equality=load('entry/src/main/ets/services/PageDataEquality.ets',{'./PageDataSnapshot':snapshots});
 const reorder=load('entry/src/main/ets/ui/TaskChecklistReorder.ets',{});
 const projection=load('entry/src/main/ets/services/PageDataProjection.ets',{'../ui/TaskChecklistReorder':reorder,'@kit.ArkTS':{util},'./PageDataEquality':equality,'./PageDataSnapshot':snapshots});
 const cache=load('entry/src/main/ets/services/PageDataCache.ets',{'@kit.CoreFileKit':{fileIo:io},'@kit.ArkTS':{util}});
 const {DataSetManager}=load('entry/src/main/ets/services/DataSetManager.ets',{'@kit.ArkTS':{util},'./AppConfigService':{AppConfigService:{load:async()=>config,watchChanges:listener=>configListeners.add(listener),stopWatchingChanges:listener=>configListeners.delete(listener)}},'./NativeCoreService':service,'./PageDataCache':cache,'./PageDataEquality':equality,'./PageDataSnapshot':snapshots,'./PageDataProjection':projection,'./MoveToTargetService':{MoveToTargetService:{targets:async()=>[]}}});
 const managers=[];const definitions=[{name:'tasks',query:{type:'task',query:{}}}];return{workspace:native,directory,context:{filesDir:directory},DataSetManager,PageDataCache:cache.PageDataCache,snapshots,external:()=>{for(const callback of rawCallbacks.values())callback({type:'repositoryChanged',repoId:'repo',operationId:null,files:null,changes:[]})},ordering:value=>{keyPolicy=value},configurationChanged:()=>{for(const listener of configListeners)listener()},setRows:value=>{rows=value},rows:()=>rows,calls,groups,subscriptions,config,manager:(page='今天',defs=definitions)=>{const manager=DataSetManager.create({filesDir:directory},page,defs);managers.push(manager);return manager},delay:()=>{delay=gate();gates.push(delay);return delay},delaySubscribe:()=>{subDelay=gate();gates.push(subDelay);return subDelay},fail:()=>{failNext=true},addRow:()=>{rows.push(task('B'))},related:()=>{sideEffect=true},partial:n=>{partial=n},failDisk:value=>{writeFailure=value},delayDisk:()=>{diskDelay=gate();diskDelay.entered=gate();gates.push(diskDelay);return diskDelay},discarded:()=>discarded,file:page=>path.join(directory,'page-data/v1/'+page+'.json'),cleanup:async()=>{for(const pending of gates)pending.resolve();for(const manager of managers)await manager.close().catch(()=>{});await fsp.rm(directory,{recursive:true,force:true})}}}

test('每页一个 JSON 文件，缓存恢复版本为0、首次查询为1，原生方法恢复为只读模型方法',async()=>{const f=await fixture();try{const first=f.manager();await first.start();assert.equal(first.get('tasks').version,1);await first.close();const file=f.file('今天');const envelope=JSON.parse(await fsp.readFile(file,'utf8'));assert.equal(envelope.dataSets.length,1);assert.equal(typeof envelope.dataSets[0].tasks,'object');assert.equal((await fsp.readFile(file,'utf8')).includes('PRIVATE_PASSWORD_MARKER'),false);const second=f.manager();const versions=[];second.subscribe(event=>versions.push(event.version));const delay=f.delaySubscribe();const start=second.start();await until(()=>second.get('tasks')?.version===0&&f.calls.length===2);assert.equal(second.get('tasks').version,0);assert.equal(second.findTask('tasks','A').isDone(),false);assert.equal(second.findTask('tasks','A').taskStateOf('Done').name,'DONE');delay.resolve();await start;assert.equal(second.get('tasks').version,1);assert.deepEqual([...new Set(versions)],[0,1]);assert.deepEqual(await fsp.readdir(path.dirname(file)),['今天.json']);}finally{await f.cleanup()}});

test('多个数据集保存到页面的同一文件，定义在创建后固定',async()=>{const f=await fixture();try{const defs=[{name:'tasks',query:{type:'task',query:{}}},{name:'files',query:{type:'file',query:{}}}];const manager=f.manager('计划',defs);defs[0].name='mutated';await manager.start();assert.ok(manager.get('tasks'));assert.equal(manager.get('mutated'),undefined);await manager.flush();assert.deepEqual(JSON.parse(await fsp.readFile(f.file('计划'),'utf8')).dataSets.map(item=>item.name),['tasks','files']);assert.equal(f.calls.length,2);}finally{await f.cleanup()}});

test('连续字段增量依次提交为版本2和3，事件关联更新后仍保留下一阶段字段，不回查',async()=>{const f=await fixture();try{f.addRow();f.related();const manager=f.manager();const events=[];manager.subscribe(event=>events.push(event));await manager.start();await manager.flush();const delay=f.delay();const first=manager.update('tasks','A',[{field:'NOTES',value:'draft'}]);const second=manager.update('tasks','A',[{field:'PRIORITY',value:'A'}]);assert.equal(manager.findTask('tasks','A').editContent.notes,'draft');assert.equal(manager.findTask('tasks','A').priority.name,'A');assert.equal(manager.findTask('tasks','B').body,'old');let saved=false;const save=manager.flush().then(()=>{saved=true});await tick();assert.equal(saved,false);assert.equal(JSON.parse(await fsp.readFile(f.file('今天'),'utf8')).dataSets[0].tasks[0].value.editContent.notes,'old');assert.equal(f.groups.length,1);delay.resolve();await Promise.all([first,second,save]);assert.equal(f.groups.length,2);assert.deepEqual(f.groups.map(group=>group.operations[0].data.modifications),[[{field:'NOTES',value:'draft'}],[{field:'PRIORITY',value:'A'}]]);assert.match(f.groups[0].operationId,/\/2\/update$/);assert.match(f.groups[1].operationId,/\/3\/update$/);assert.equal(f.groups[1].fileVersions[0].version,'file-2');assert.equal(manager.get('tasks').confirmedVersion,3);assert.equal(manager.findTask('tasks','B').body,'CORE RELATED');assert.equal(f.calls.length,1);assert.deepEqual(events.filter(event=>event.type==='complete').map(event=>event.version),[2,3]);assert.equal(events.find(event=>event.type==='complete'&&event.version===2).result.data.result.tasks[0].priority,null);}finally{await f.cleanup()}});

test('前一次改名后，已排队字段修改使用事件提供的新身份和最新文件版本',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();const delay=f.delay();const first=manager.update('tasks','A',[{field:'TITLE',value:'Renamed'}]);const second=manager.update('tasks','A',[{field:'NOTES',value:'next'}]);await tick();delay.resolve();await Promise.all([first,second]);assert.deepEqual(f.groups[1].operations[0].data.path.titles,['Renamed']);assert.equal(manager.findTask('tasks','renamed-Renamed').editContent.notes,'next');}finally{await f.cleanup()}});

test('失败只撤销对应阶段，后续排队字段继续提交，不生成刷新查询',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();const delay=f.delay();f.fail();const first=manager.update('tasks','A',[{field:'NOTES',value:'failed'}]);const rejected=assert.rejects(first,/提交失败/);const second=manager.update('tasks','A',[{field:'PRIORITY',value:'A'}]);await tick();delay.resolve();await rejected;await second;assert.equal(manager.findTask('tasks','A').editContent.notes,'old');assert.equal(manager.findTask('tasks','A').priority.name,'A');assert.equal(f.calls.length,1);await manager.flush();assert.equal(JSON.parse(await fsp.readFile(f.file('今天'),'utf8')).dataSets[0].tasks[0].value.editContent.notes,'old');}finally{await f.cleanup()}});

test('显式刷新使用带版本的operationId，旧订阅事件不能覆盖新一代结果',async()=>{const f=await fixture();try{const manager=f.manager();const events=[];manager.subscribe(event=>events.push(event));await manager.start();const old=Array.from(f.subscriptions.values())[0].callback;await manager.refresh();assert.equal(manager.get('tasks').version,2);assert.match(events.at(-1).operationId,/\/2\/refresh$/);old({type:'repositoryChanged',repoId:'repo',operationId:null,files:[],changes:[{kind:'deleted',before:{task:{id:'A',fullPath:{repoId:'repo'}}},after:null}]});assert.ok(manager.findTask('tasks','A'));await manager.update('tasks','A',[{field:'NOTES',value:'third'}]);assert.match(f.groups[0].operationId,/\/3\/update$/);assert.equal(f.calls.length,2);}finally{await f.cleanup()}});

test('创建只在指定数据集中立即显示，确认后替换临时行；删除也只提交一次',async()=>{const f=await fixture();try{const manager=f.manager('今天',[{name:'tasks',query:{type:'task',query:{}}},{name:'files',query:{type:'file',query:{}}}]);await manager.start();const delay=f.delay();const create=manager.create('tasks',{position:{parent:{repoId:'repo',file:'a.org',titles:[]}},title:'New',state:'TODO'});assert.ok(manager.get('tasks').data.result.tasks.some(task=>task.id.startsWith('$pending:')));await tick();delay.resolve();await create;assert.equal(manager.get('tasks').data.result.tasks.filter(task=>task.heading==='New').length,1);assert.equal(manager.get('tasks').data.result.tasks[0].heading,'New');assert.equal(manager.get('tasks').data.result.tasks.some(task=>task.id.startsWith('$pending:')),false);await manager.remove('tasks','New');assert.equal(manager.findTask('tasks','New'),undefined);assert.deepEqual(f.groups.map(group=>group.operations[0].type),['Creation','Deletion']);}finally{await f.cleanup()}});

test('短写循环完整保存；保存失败保留旧文件且不泄露临时文件',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();f.partial(7);await manager.flush();const before=await fsp.readFile(f.file('今天'),'utf8');f.failDisk(true);await assert.rejects(manager.flush(),/写盘失败/);assert.equal(await fsp.readFile(f.file('今天'),'utf8'),before);assert.deepEqual(await fsp.readdir(path.dirname(f.file('今天'))),['今天.json']);f.failDisk(false);}finally{await f.cleanup()}});

test('新实例拥有页面缓存写入权，旧页面关闭不会覆盖新实例缓存；损坏缓存回退到一次初始查询',async()=>{const f=await fixture();try{const old=f.manager();await old.start();const newer=f.manager();await newer.start();await newer.update('tasks','A',[{field:'NOTES',value:'newer'}]);await newer.flush();await old.close();assert.equal(JSON.parse(await fsp.readFile(f.file('今天'),'utf8')).dataSets[0].tasks[0].value.editContent.notes,'newer');assert.equal(JSON.parse(await fsp.readFile(f.file('今天'),'utf8')).dataSets[0].version,2);await newer.close();await fsp.writeFile(f.file('今天'),'{broken');const before=f.calls.length;const third=f.manager();await third.start();assert.equal(third.get('tasks').version,1);assert.equal(f.calls.length,before+1);}finally{await f.cleanup()}});


test('位置引用操作保留编辑控件的原始版本，不能在前一阶段完成后静默套用到新文件',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();const delay=f.delay();const first=manager.update('tasks','A',[{field:'NOTES',value:'new notes'}]);const second=manager.update('tasks','A',[{field:'CHECKLIST',value:{type:'setChecked',id:'old-item',checked:true}}],'file-1');const failure=assert.rejects(second,/版本冲突/);await tick();delay.resolve();await first;await failure;assert.equal(f.groups[1].fileVersions[0].version,'file-1');assert.equal(manager.getConfirmed('tasks').version,2);assert.equal(f.calls.length,1);}finally{await f.cleanup()}});

test('页面缓存只读取并解析一次，范围不同的缓存不恢复',async()=>{const f=await fixture();try{const cache=new f.PageDataCache(f.context,'解析','scope-A');await cache.write([f.snapshots.cacheDataSet('tasks',{type:'task',result:{tasks:[task()],categories:[]}})]);const original=JSON.parse;let parses=0;JSON.parse=function(...args){parses++;return original(...args)};let data;try{data=await cache.read()}finally{JSON.parse=original}assert.equal(parses,1);assert.equal(data.length,1);const other=new f.PageDataCache(f.context,'解析','scope-B');assert.equal(await other.read(),undefined);}finally{await f.cleanup()}});


test('创建重名节点后，临时行排队修改跟随新建节点，不误改出现序号变化的旧节点',async()=>{const f=await fixture();try{const manager=f.manager('今天',[{name:'tasks',query:{type:'task',query:{}}},{name:'files',query:{type:'file',query:{}}}]);await manager.start();const oldKey=manager.itemKey('tasks','A');const delay=f.delay();const create=manager.create('tasks',{position:{parent:{repoId:'repo',file:'a.org',titles:[]}},title:'A',state:'TODO'});const draft=manager.get('tasks').data.result.tasks.find(task=>task.id.startsWith('$pending:'));const update=manager.update('tasks',draft.id,[{field:'NOTES',value:'新建节点的修改'}]);await tick();delay.resolve();await Promise.all([create,update]);assert.equal(manager.findTask('tasks','A').editContent.notes,'新建节点的修改');assert.equal(manager.findTask('tasks','A#2').editContent.notes,'old');assert.equal(manager.itemKey('tasks','A#2'),oldKey);assert.notEqual(manager.itemKey('tasks','A'),oldKey);}finally{await f.cleanup()}});


test('临时缓存写入期间出现新修改时，不替换旧缓存，等待全部提交及事件完成后重取快照',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();await manager.flush();const before=await fsp.readFile(f.file('今天'),'utf8');const disk=f.delayDisk();let saved=false;const saving=manager.flush().then(()=>{saved=true});await disk.entered.promise;const mutation=f.delay();const update=manager.update('tasks','A',[{field:'NOTES',value:'最后阶段'}]);await until(()=>f.groups.length===1);disk.resolve();await until(()=>f.discarded()===1);assert.equal(saved,false);assert.equal(await fsp.readFile(f.file('今天'),'utf8'),before);mutation.resolve();await Promise.all([update,saving]);assert.equal(JSON.parse(await fsp.readFile(f.file('今天'),'utf8')).dataSets[0].tasks[0].value.editContent.notes,'最后阶段');}finally{await f.cleanup()}});


test('清单只乐观修改用户选择的条目，不预测父项统计；失败后恢复确认字段',async()=>{const f=await fixture();try{const base=task();const items=[{id:'one',siblingGroup:'group',text:'First',checked:false,partial:false,depth:0},{id:'two',siblingGroup:'group',text:'Second',checked:false,partial:false,depth:0}];f.setRows([task('A',{editContent:{...base.editContent,checklist:items,blocks:[{id:'block',kind:'checklist',paragraph:false,blankLinesBefore:0,source:'',html:'',items}]}})]);const manager=f.manager();await manager.start();const delay=f.delay();f.fail();const work=manager.update('tasks','A',[{field:'CHECKLIST',value:{type:'setChecked',id:'one',checked:true}}],'file-1');const failure=assert.rejects(work,/提交失败/);const optimistic=manager.findTask('tasks','A');assert.equal(optimistic.editContent.checklist[0].checked,true);assert.equal(optimistic.editContent.checklist[1].checked,false);assert.equal(optimistic.editContent.blocks[0].items[0].checked,true);assert.equal(optimistic.heading,'A');await tick();delay.resolve();await failure;assert.equal(manager.findTask('tasks','A').editContent.checklist[0].checked,false);assert.equal(f.calls.length,1);}finally{await f.cleanup()}});


test('固定配置范围变化后停止编辑和缓存，不把新范围数据写入旧页面缓存',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();await manager.flush();const before=await fsp.readFile(f.file('今天'),'utf8');f.configurationChanged();await assert.rejects(manager.update('tasks','A',[{field:'NOTES',value:'not written'}]),/不可编辑/);await assert.rejects(manager.refresh(),/范围已变化/);await manager.flush();assert.equal(f.groups.length,0);assert.equal(f.calls.length,1);assert.equal(await fsp.readFile(f.file('今天'),'utf8'),before);}finally{await f.cleanup()}});


test('增量按 Core 给出的标量键排序，保留降序与缺失值策略，不解析查询表达式',async()=>{
  for(const [descending,missingLast] of [[true,true],[false,false],[true,false]]){
    const f=await fixture();try{
      const a=task('A',{modifiedAt:1}),b=task('B',{modifiedAt:null}),c=task('C',{modifiedAt:3});
      f.setRows(descending?[c,a,b]:[b,a,c]);
      f.ordering(row=>[{value:row.modifiedAt,descending,missingLast}]);
      const manager=f.manager();await manager.start();
      const old=f.rows().slice();
      const after=old.map(row=>task(row.id,{...row,modifiedAt:row.id==='A'?5:row.modifiedAt,fileVersion:'file-2',orderKey:[{value:row.id==='A'?5:row.modifiedAt,descending,missingLast}]}));
      const event={type:'repositoryChanged',repoId:'repo',operationId:null,files:[{after:metadata(),afterView:metadata(),afterVersion:'file-2'}],
        changes:old.map((row,index)=>({kind:'updated',before:{task:{id:row.id,fullPath:row.fullPath}},after:{task:{id:after[index].id,fullPath:after[index].fullPath},view:after[index]}}))};
      for(const subscription of f.subscriptions.values())subscription.callback(event);
      assert.deepEqual(manager.get('tasks').data.result.tasks.map(row=>row.id),descending?['A','C','B']:['B','C','A']);
      assert.equal(f.calls.length,1);
    }finally{await f.cleanup()}
  }
});


test('外部更新由管理类合并通知并启动刷新，本实例修改完成不回查',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();await manager.update('tasks','A',[{field:'NOTES',value:'own'}]);await new Promise(resolve=>setTimeout(resolve,80));assert.equal(f.calls.length,1);f.external();f.external();await until(()=>f.calls.length===2&&manager.isReady());assert.equal(manager.get('tasks').version,3);}finally{await f.cleanup()}});

test('提交错误标明目标记录，回滚后保留其他行的确认数据',async()=>{const f=await fixture();try{f.addRow();const manager=f.manager();await manager.start();const events=[];manager.subscribe(event=>events.push(event));f.fail();await assert.rejects(manager.update('tasks','A',[{field:'NOTES',value:'failed'}]),/提交失败/);const error=events.find(event=>event.type==='error');assert.equal(error.targetKey,JSON.stringify(['repo','A']));assert.equal(manager.findTask('tasks','A').editContent.notes,'old');assert.equal(manager.findTask('tasks','B').heading,'B');}finally{await f.cleanup()}});

test('已有确认快照在刷新过程中保持可编辑，避免只读切换触发输入框失焦提交',async()=>{const f=await fixture();try{const manager=f.manager();await manager.start();const row=manager.itemKey('tasks','A');const delay=f.delaySubscribe();const refreshing=manager.refresh();await until(()=>f.calls.length===2);assert.equal(manager.isReady(),true);assert.equal(manager.itemKey('tasks','A'),row);delay.resolve();await refreshing;assert.equal(manager.isReady(),true);}finally{await f.cleanup()}});

test('本地字段立即返回，底层确认只推进版本，不重复通知相同内容或同文件其他任务',async()=>{
 const f=await fixture();try{
  f.addRow();const manager=f.manager();await manager.start();const events=[];manager.subscribe(event=>events.push(event));
  const revision=manager.get('tasks').revision;const row=manager.itemKey('tasks','A');const delay=f.delay();
  const local=manager.updateFields('tasks','A',[{field:'PRIORITY',value:'A'}]);
  assert.equal(local.priority.name,'A');assert.equal(manager.get('tasks').revision,revision+1);
  assert.equal(events.length,1);assert.deepEqual(events[0].updated,[JSON.stringify(['repo','A'])]);
  await until(()=>f.groups.length===1);assert.equal(manager.getConfirmed('tasks').version,1);
  delay.resolve();await manager.flush();
  assert.equal(manager.getConfirmed('tasks').version,2);assert.equal(manager.findTask('tasks','B').fileVersion,'file-2');
  assert.equal(manager.get('tasks').revision,revision+1);assert.equal(manager.itemKey('tasks','A'),row);
  assert.equal(events.filter(event=>event.type!=='complete').length,1);assert.equal(events.at(-1).type,'complete');
 }finally{await f.cleanup()}
});
test('同值编辑和无内容变化的全量刷新不发布数据变化，生命周期与缓存版本仍更新',async()=>{
 const f=await fixture();try{
  const manager=f.manager();await manager.start();const revision=manager.get('tasks').revision;const events=[];manager.subscribe(event=>events.push(event));
  await manager.update('tasks','A',[{field:'PRIORITY',value:null}]);
  assert.equal(events.filter(event=>!['complete','ready'].includes(event.type)).length,0);
  assert.equal(manager.get('tasks').revision,revision);
  await manager.refresh();assert.equal(manager.get('tasks').revision,revision);
  assert.equal(events.filter(event=>!['complete','ready'].includes(event.type)).length,0);
  assert.equal(manager.getConfirmed('tasks').version,3);
 }finally{await f.cleanup()}
});

test('内嵌正文区块的修改先更新本地区块，失败回滚只影响该用户字段',async()=>{
 const f=await fixture();try{
  const base=task();const blocks=[{id:'one',kind:'text',paragraph:true,blankLinesBefore:0,source:'原文',html:'<p>原文</p>',items:[]},
   {id:'two',kind:'text',paragraph:true,blankLinesBefore:1,source:'保留',html:'<p>保留</p>',items:[]}];
  f.setRows([task('A',{editContent:{...base.editContent,blocks}})]);const manager=f.manager();await manager.start();
  const delay=f.delay();f.fail();const local=manager.updateFields('tasks','A',[{field:'CONTENT_BLOCK',value:{type:'replace',id:'one',source:'新内容'}}],'file-1');
  assert.equal(local.editContent.blocks[0].source,'新内容');assert.equal(local.editContent.blocks[0].html,'<p>新内容</p>');
  assert.equal(local.editContent.blocks[1].source,'保留');assert.equal(local.heading,'A');
  await until(()=>f.groups.length===1);delay.resolve();await manager.flush();
  assert.equal(manager.findTask('tasks','A').editContent.blocks[0].source,'原文');
 }finally{await f.cleanup()}
});


test('受管理的批量操作使用同一阶段编号，通过查询事件确认且不重新查询',async()=>{
 const f=await fixture();try{const manager=f.manager();await manager.start();const events=[];manager.subscribe(event=>events.push(event));
 await manager.runOperation('tasks',async operationId=>{await f.workspace.executeTaskOperations({operationId,operations:[{type:'Modification',data:{path:f.rows()[0].fullPath,modifications:[{field:'NOTES',value:'批量更新'}]}}]});});
 assert.match(f.groups[0].operationId,/dataset\/.*\/2\/operation/);assert.equal(manager.get('tasks').version,2);assert.equal(manager.findTask('tasks','A').editContent.notes,'批量更新');
 assert.equal(events.filter(event=>event.type==='complete').length,1);await manager.flush();assert.equal(f.calls.length,1);
 }finally{await f.cleanup()}
});
test('批量操作与字段编辑共用队列，改名事件将排队字段映射到新身份',async()=>{
 const f=await fixture();try{const manager=f.manager();await manager.start();const hold=f.delay();
 const first=manager.runOperation('tasks',async operationId=>{await f.workspace.executeTaskOperations({operationId,operations:[{type:'Modification',data:{path:f.rows()[0].fullPath,modifications:[{field:'TITLE',value:'New'}]}}]});});
 await until(()=>f.groups.length===1);const second=manager.update('tasks','A',[{field:'NOTES',value:'排队备注'}]);hold.resolve();await Promise.all([first,second]);
 assert.equal(f.groups.length,2);assert.equal(f.groups[1].operations[0].data.path.titles[0],'New');assert.equal(manager.findTask('tasks','renamed-New').editContent.notes,'排队备注');assert.equal(f.calls.length,1);
 }finally{await f.cleanup()}
});
test('批量操作失败不推进确认快照，错误不产生额外操作',async()=>{
 const f=await fixture();try{const manager=f.manager();await manager.start();const original=manager.getConfirmed('tasks');
 await assert.rejects(manager.runOperation('tasks',async()=>{throw new Error('批量失败')}),/批量失败/);assert.equal(manager.getConfirmed('tasks').version,original.version);assert.equal(f.groups.length,0);await manager.flush();
 }finally{await f.cleanup()}
});
