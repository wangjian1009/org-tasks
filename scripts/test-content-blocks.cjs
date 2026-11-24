// 验证正文区块会话、只读保护、项目编辑版本与日志显示策略。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-content-blocks.cjs\n验证区块只读保护、草稿保存、项目版本约束与日志显示策略。');
  process.exit(0);
}
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents', 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const base = 'entry/src/main/ets/';
function load(name, mocks = {}, transform = s => s) {
  const filename = base + name + '.ets';
  const source = ts.transpileModule(transform(fs.readFileSync(filename, 'utf8')), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + source + '\n})', { filename })(name => {
    assert.ok(name in mocks, name);return mocks[name];
  }, module, module.exports);
  return module.exports;
}
const controller = load('ui/TaskBlockController');
const policy = load('ui/TaskLogPresentation');
const prefix = name => source => source.split('  build()')[0].replace(/@Component\n|@(Prop|State|Watch\([^)]*\))\s*/g, '')
  .replace('export struct ' + name, 'export class ' + name) + '}';

const equality = load('services/PageDataEquality', { './PageDataSnapshot': {} });
const { reconcileTaskContent } = load('ui/TaskContentPresentation', { '../services/PageDataEquality': equality });
const contentBlock = (id, source, kind = 'text') => ({ id, kind, source, html: '<p>' + source + '</p>',
  paragraph: kind === 'text', blankLinesBefore: 0, items: [] });
test('正文未变化复用同一列表与节点，只修改一个区块时保留其他分支', () => {
  const initial = reconcileTaskContent([], [contentBlock('1','第一段'), contentBlock('20','第二段')]);
  assert.equal(reconcileTaskContent(initial, initial.map(slot => ({...slot.block}))), initial);
  const changed = reconcileTaskContent(initial, [contentBlock('1','第一段'), contentBlock('20','新段落')]);
  assert.equal(changed[0], initial[0]); assert.equal(changed[1].key, initial[1].key);
  assert.equal(changed[1].block.source, '新段落'); assert.notEqual(changed[1], initial[1]);
});
test('前方插入与字节位置移动不销毁后续控件，删除和重排只调整成员', () => {
  const initial = reconcileTaskContent([], [contentBlock('1','段落'),contentBlock('20','表格','table')]);
  const inserted = reconcileTaskContent(initial, [contentBlock('1','新段落'),contentBlock('30','段落'),contentBlock('50','表格','table')]);
  assert.equal(inserted[1].key, initial[0].key); assert.equal(inserted[2].key, initial[1].key);
  assert.equal(inserted[1].block.id, '30');
  const reordered = reconcileTaskContent(inserted, [inserted[2].block, inserted[1].block]);
  assert.equal(reordered[0], inserted[2]); assert.equal(reordered[1], inserted[1]);
});
test('重复内容保留独立身份，类型变化建立新的控件', () => {
  const initial = reconcileTaskContent([], [contentBlock('1','相同'),contentBlock('20','相同')]);
  assert.notEqual(initial[0].key,initial[1].key);
  const same = reconcileTaskContent(initial, [contentBlock('2','相同'),contentBlock('21','相同')]);
  assert.deepEqual(same.map(slot=>slot.key),initial.map(slot=>slot.key));
  const changed = reconcileTaskContent(same, [contentBlock('2','表格','table'),same[1].block]);
  assert.notEqual(changed[0].key,same[0].key); assert.equal(changed[1],same[1]);
});
function blockFixture() {
  const copies = [], messages = [];
  const { TaskBlockView } = load('components/editors/TaskBlockView', {
    '../../ui/TaskBlockController': controller, '../LinkView': { LinkEditController: class {
      static protectInteraction() {} async finish() { return true; }
    } },
    '../../ui/TaskInlineFocus': load('ui/TaskInlineFocus'),
    './TaskChecklistBlock': { ChecklistFocusFrame: class {} },
    '../../ui/Theme': { UiColor: { taskCard: 'card' } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({width:390}) } },
    '@kit.BasicServicesKit': { pasteboard: { MIMETYPE_TEXT_PLAIN:'text/plain', createData: (type,value) => ({type,value}),
      getSystemPasteboard: () => ({async setData(data) { copies.push(data); }}) } }
  }, source => 'const $r = name => name; class TextAreaController {}\n' + prefix('TaskBlockView')(source.split('  @Builder\n')[0].replace(/@BuilderParam /g,'')));
  const editor = new TaskBlockView();
  const writes = [], events = [];
  editor.getUIContext = () => ({px2vp:value=>value,postFrameCallback(){},getPromptAction:()=>({showToast:({message})=>messages.push(message)})});
  editor.inputKey = 'block'; editor.block = { id: '1', kind: 'text', source: 'Original', html: '<p>Original</p>', items: [] };
  editor.readonly = false;editor.disabled = false;
  editor.begin = async () => true;
  editor.save = async (block, source) => { writes.push({ block, source });return true; };
  editor.editingChanged = value => events.push(value);
  return { editor, writes, events, copies, messages };
}

test('所有区块拷贝整段 Org 原文；只读菜单仅拷贝且不能修改', async () => {
  for (const kind of ['text','list','table','checklist']) {
    const f=blockFixture();f.editor.block={...f.editor.block,kind,source:'- [ ] 一\n  - [X] 二'};
    f.editor.openMenu(10,20);
    assert.deepEqual(f.editor.menuItems().map(item=>item.title),['拷贝','编辑','删除']);
    assert.equal(f.editor.menuItems()[2].dangerous,true);
    f.editor.readonly=true;
    assert.deepEqual(f.editor.menuItems().map(item=>item.title),['拷贝']);
    await f.editor.copySelected();assert.equal(f.copies[0].value,f.editor.block.source);
    assert.equal(await f.editor.deleteSelected(),false);assert.deepEqual(f.writes,[]);
  }
});

test('在两个相邻列表之间插入独立列表时保留前后列表的分隔', async () => {
  const f = blockFixture();
  f.editor.block = {...f.editor.block, kind:'list', source:'- 原列表'};
  f.editor.nextBlock = {kind:'checklist', blankLinesBefore:1};
  f.editor.insertBelow = true;
  f.editor.openMenu(10,20);
  f.editor.allowMove = true;
  assert.deepEqual(f.editor.menuItems().map(item=>item.title),['拷贝','编辑','移动…','段落','列表','删除']);
  await f.editor.edit(f.editor.block, f.editor.revision, 'list');
  assert.equal(f.editor.draft, '');
  assert.equal(await f.editor.finish(), true);
  assert.deepEqual(f.writes, []);
  await f.editor.edit(f.editor.block, f.editor.revision, 'list');
  let followed = false;
  f.editor.followChecklist = async finish => { followed = await finish(); };
  f.editor.draft = '新条目';
  await f.editor.submitDraft();
  assert.equal(followed, true);
  assert.equal(f.writes[0].source, '- 原列表\n\n\n- [ ] 新条目\n');
});

test('回车提交有内容的段落，空白新增输入结束时不打开下一段', async () => {
  const f = blockFixture();
  let nextParagraphs = 0;
  f.editor.followParagraph = async finish => { if (await finish()) nextParagraphs++; };
  await f.editor.edit();
  f.editor.draft = '更新后的段落';
  await f.editor.submitDraft();
  assert.equal(nextParagraphs, 1);
  assert.equal(f.writes[0].source, '更新后的段落');
  await f.editor.edit(f.editor.block, f.editor.revision, 'paragraph');
  await f.editor.submitDraft();
  assert.equal(nextParagraphs, 1);
  assert.equal(f.writes.length, 1);
  assert.equal(f.editor.editing, false);
});

test('删除只提交选中的原区块，结束其他草稿失败或快照变化时不删除', async () => {
  const f=blockFixture();f.editor.revision='v1';f.editor.openMenu(10,20);
  const block=f.editor.block;
  assert.equal(await f.editor.deleteSelected(),true);
  assert.deepEqual(f.writes,[{block,source:''}]);assert.deepEqual(f.events,[true,false]);
  for (const failure of ['草稿失败','版本变化','同位置区块变化']) {
    const g=blockFixture();g.editor.revision='v1';g.editor.openMenu(10,20);
    if(failure==='草稿失败')g.editor.linkEditor.finish=async()=>false;
    if(failure==='版本变化')g.editor.revision='v2';
    if(failure==='同位置区块变化')g.editor.block={...g.editor.block,source:'其他内容'};
    assert.equal(await g.editor.deleteSelected(),false);assert.deepEqual(g.writes,[]);assert.deepEqual(g.events,[]);
  }
});

test('菜单自动关闭后编辑仍使用点选时的快照；清单输入期间不弹出区块菜单', async () => {
  const f=blockFixture();f.editor.revision='v1';f.editor.openMenu(1,2);
  const action=f.editor.menuItems().find(item=>item.title==='编辑').action;
  f.editor.menuVisible=false;f.editor.revision='v2';action();await new Promise(setImmediate);
  assert.equal(f.editor.editing,false);
  f.editor.checklistEditing=true;f.editor.openMenu(1,2);assert.equal(f.editor.menuVisible,false);
  f.editor.checklistEditing=false;f.editor.openMenu(1,2);assert.equal(f.editor.menuVisible,true);
});
test('切换区块先保存旧草稿；失败保留当前会话并阻止切换', async () => {
  const editor = new controller.TaskBlockController();
  let success = false, saves = 0;
  await editor.begin('a', async () => { saves++;return success; });
  assert.equal(await editor.begin('b', async () => true), false);
  success = true;
  assert.equal(await editor.begin('b', async () => true), true);
  assert.equal(saves, 2);
});
test('并发结束输入只提交一次，取消只丢弃当前草稿', async () => {
  const editor = new controller.TaskBlockController();
  let resolve, saves = 0, cancels = 0;
  await editor.begin('a', () => { saves++;return new Promise(done => { resolve = done; }); });
  const first = editor.finish(), second = editor.finish();resolve(true);
  assert.deepEqual(await Promise.all([first, second]), [true, true]);assert.equal(saves, 1);
  await editor.begin('b', async () => { assert.fail('取消不保存'); }, () => { cancels++; });
  editor.cancel();assert.equal(cancels, 1);assert.equal(await editor.finish(), true);
});
test('readonly 不打开输入，不提交替换；已打开的草稿切到只读后退出输入', async () => {
  const f = blockFixture();f.editor.readonly = true;
  await f.editor.edit();assert.equal(f.editor.editing, false);assert.deepEqual(f.writes, []);
  f.editor.readonly = false;await f.editor.edit();f.editor.draft = 'Changed';
  f.editor.readonly = true;assert.equal(await f.editor.finish(), false);
  f.editor.readonlyChanged();assert.equal(f.editor.editing, false);assert.deepEqual(f.writes, []);
});
test('未修改不写入，取消不写入，失败保留原块身份和完整草稿', async () => {
  const f = blockFixture();await f.editor.edit();assert.equal(await f.editor.finish(), true);assert.deepEqual(f.writes, []);
  await f.editor.edit();f.editor.draft = 'Cancelled';f.editor.cancel();assert.deepEqual(f.writes, []);
  await f.editor.edit();const original = f.editor.original;f.editor.draft = '| A | B |';
  f.editor.save = async () => false;
  assert.equal(await f.editor.finish(), false);assert.equal(f.editor.editing, true);assert.equal(f.editor.original, original);assert.equal(f.editor.draft, '| A | B |');
});
test('日志默认随开关，Always 始终展示并与开关状态无关', () => {
  for (const switched of [false, true]) {
    assert.equal(policy.taskLogVisible(policy.LogShowPolicy.LogShowBySwitch, switched), switched);
    assert.equal(policy.taskLogVisible(policy.LogShowPolicy.LogShowAlways, switched), true);
  }
});
function projectFixture() {
  const writes = [];
  let releases = 0;
  let fail, reloadFail;
  const task = { id: 'task', fileVersion: 'v1', editContent: { blocks: [], checklist: [{id:'42',text:'First'},{id:'43',text:'Second'}] } };
  let refreshed = { ...task, fileVersion: 'v2' };
  const service = { async modify(context, snapshot, changes) {
    writes.push({ snapshot, changes });if (fail) throw fail;
  }, async reload() { if (reloadFail) throw reloadFail;return refreshed; } };
  const { TaskDocumentContent } = load('components/editors/TaskDocumentContent', {
    '../../services/NativeCoreService': { coreErrorMessage: e => e.message },
    '../../services/DataSetManager':{},
    '../controls/DangerousConfirmation': {},
    '../../services/TaskInlineService': { TaskInlineSession: { async begin() { return true; }, release() { releases++; } } },
    '../../ui/TaskChecklistReorder': load('ui/TaskChecklistReorder'),
    '../../ui/TaskInlineFocus': load('ui/TaskInlineFocus'),
    './TaskChecklistBlock': { ChecklistFocusFrame: class {} },
    '../../ui/TaskBlockController': controller, '../LinkView': { LinkEditController: class { async finish() { return true; } } },
    '../../ui/Theme': { UiColor: { surface: 'surface' } }, '@kit.ArkUI': { KeyboardAvoidMode: { RESIZE: 1 } }
  }, source => prefix('TaskDocumentContent')(source.split('  @Builder\n')[0]));
  const editor = new TaskDocumentContent();editor.active = true;editor.task = task;editor.modify=async(snapshot,changes)=>{await service.modify({},snapshot,changes);try{return await service.reload()}catch(error){error.committed=true;throw error;}};editor.getUIContext = () => ({ getHostContext: () => ({}), setKeyboardAvoidMode() {} });
  return { editor, task, writes, releases: () => releases, refreshWith: value => { refreshed = value; }, fail: value => { fail = value; }, reloadFail: value => { reloadFail = value; } };
}
test('项目区块保留原版本提交，成功重读；只读前言不提交', async () => {
  const f = projectFixture();assert.equal(await f.editor.session(), true);
  await f.editor.saveBlock({ id: '42' }, 'Changed');assert.equal(f.writes[0].snapshot, f.task);
  assert.deepEqual(f.writes[0].changes, [{field:'CONTENT_BLOCK',value:{type:'replace',id:'42',source:'Changed'}}]);
  assert.equal(f.editor.current.fileVersion, 'v2');
  f.editor.readonly = true;assert.equal(await f.editor.saveBlock({id:'42'}, 'Blocked'), false);assert.equal(f.writes.length, 1);
});
test('项目写入失败可重试，提交成功而重读失败时阻止再次写入', async () => {
  const f = projectFixture();await f.editor.session();f.fail(new Error('写入失败'));
  assert.equal(await f.editor.saveBlock({id:'42'}, 'Changed'), false);assert.equal(f.editor.current, f.task);assert.equal(f.editor.blocked, false);
  f.fail(undefined);f.reloadFail(new Error('读取失败'));
  assert.equal(await f.editor.saveBlock({id:'42'}, 'Changed'), false);assert.equal(f.editor.blocked, true);assert.match(f.editor.message, /修改已保存/);
  assert.equal(await f.editor.saveBlock({id:'42'}, 'Again'), false);assert.equal(f.writes.length, 2);
});

test('项目清单直接勾选后释放空闲会话，让同文件标题与进度响应数据刷新', async () => {
  const f = projectFixture();
  await f.editor.changeCheck({type:'setChecked',id:'42',checked:true});
  assert.equal(f.writes.length, 1);assert.equal(f.releases(), 1);
  assert.equal(f.editor.current.fileVersion, 'v2');
});

const emittedChecklist = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/editors/TaskChecklistBlock.ts';
test('编译后的清单在只读与可写状态保留相同字号、颜色、行高与缩进，只读事件不修改内容', { skip: !fs.existsSync(emittedChecklist) }, () => {
  const source = ts.createSourceFile(emittedChecklist, fs.readFileSync(emittedChecklist, 'utf8'), ts.ScriptTarget.Latest, true);
  let row;
  function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name?.getText(source) === 'row') row = node.getText(source);
    ts.forEachChild(node, visit);
  }
  visit(source);assert.ok(row);
  const code = ts.transpileModule('class Rendered {' + row + '}\nmodule.exports = Rendered;', {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  function render(readonly, checked, partial) {
    const root = { type: 'root', children: [] }, stack = [root], callbacks = [];
    let writes = 0;
    const keep = new Set(['width','height','constraintSize','padding','fontSize','fontColor','backgroundColor','layoutWeight','decoration','maxLines','textOverflow']);
    function ui(type) {
      return new Proxy({}, {get(_, action) {
        if (action === 'pop') return () => stack.pop();
        if (action === 'create' || action === 'createWithLabel') return value => {
          const node = {type, value, style:{}, children:[]};stack.at(-1).children.push(node);stack.push(node);
        };
        if (action === 'onClick') return callback => callbacks.push(callback);
        return value => { if (keep.has(action)) stack.at(-1).style[action] = value; };
      }});
    }
    const Row = ui('row'), Button = ui('button'), Text = ui('text');
    const globals = { module: {exports:{}}, Row, Button, Text, If:{create(){},pop(){}},
      UiColor:{text:'text',disabled:'disabled',secondary:'secondary'}, Color:{Transparent:'transparent'},
      TextDecorationType:{LineThrough:'strike',None:'none'}, VerticalAlign:{Top:'top',Center:'center'},
      checklistSiblings:items=>items };
    vm.runInNewContext(code, globals);
    const item = {id:'first',text:'这是应当完整换行的很长清单文字，不能在只读状态切换成单行省略',checked,partial,depth:2};
    const component = Object.assign(new globals.module.exports(), {readonly,disabled:false,dragging:false,editingId:'',sorting:true,items:[item,{...item,id:'second'}],
      indentStep:12,marker:()=>undefined,projectedBody:()=>[],observeComponentCreation2(callback){callback(0,true);},ifElseBranchUpdateFunction(_,callback){callback();},
      grip(){Row.create();Row.width(44);Row.height(44);Row.pop();},toggle(){writes++;},edit(){writes++;}});
    component.row(item);
    for(const callback of callbacks)callback();
    return {tree:JSON.parse(JSON.stringify(root)),writes};
  }
  for(const [checked,partial] of [[false,false],[true,false],[false,true]]){
    const writable=render(false,checked,partial),readonly=render(true,checked,partial);
    assert.deepEqual(readonly.tree,writable.tree);
    assert.equal(readonly.writes,0);assert.equal(writable.writes,2);
    const row=readonly.tree.children[0];assert.equal(row.style.constraintSize.minHeight,44);assert.equal(row.style.padding.left,24);
    const text=row.children.find(n=>n.type==='text');assert.equal(text.style.fontSize,14);assert.equal(text.style.maxLines,undefined);assert.equal(text.style.textOverflow,undefined);
  }
});

test('项目先保存清单文字后，后续勾选使用同一条目的新 ID，不套用旧位置', async () => {
  const f = projectFixture();await f.editor.session();f.editor.editingId='42';f.editor.editingText='Changed';
  f.refreshWith({...f.task,fileVersion:'v2',editContent:{blocks:[],checklist:[{id:'84',text:'Changed'},{id:'85',text:'Second'}]}});
  await f.editor.changeCheck({type:'setChecked',id:'43',checked:true});
  assert.equal(f.writes.length,2);
  assert.deepEqual(f.writes[1].changes,[{field:'CHECKLIST',value:{type:'setChecked',id:'85',checked:true}}]);
});

test('保存其他区块导致版本变化时，不在新的区块位置打开旧点击对应的输入', async () => {
  const f = blockFixture();f.editor.revision='v1';
  f.editor.editor.finish = async () => { f.editor.revision='v2';return true; };
  f.editor.begin = async () => { assert.fail('版本变化后必须重新点选'); };
  await f.editor.edit();assert.equal(f.editor.editing,false);assert.deepEqual(f.writes,[]);
});
test('项目保存正文改变结构后，不用原清单 ID 继续执行已过期的勾选事件', async () => {
  const f = projectFixture();await f.editor.session();
  f.editor.blockEditor.finish = async () => { f.editor.current={...f.task,fileVersion:'v2'};return true; };
  await f.editor.changeCheck({type:'setChecked',id:'42',checked:true});
  assert.deepEqual(f.writes,[]);
});

function compiledBuilders(name, methods, directory = 'components/editors') {
  const filename = `entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/${directory}/${name}.ts`;
  const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true);
  const bodies = [];
  function visit(node) {
    if (ts.isMethodDeclaration(node) && methods.includes(node.name?.getText(source))) bodies.push(node.getText(source));
    ts.forEachChild(node, visit);
  }
  visit(source);assert.equal(bodies.length, methods.length);
  const children = [];
  function component(name) { return class {
    constructor(owner, params) { this.kind = name; this.owner = owner;Object.assign(this, params);children.push(this); }
  }; }
  const noop = new Proxy({}, {get:()=>()=>{}});
  const areaChanges=[], overlays=[], guideHeights=[];
  const common = new Proxy({}, {get:(_,key)=>key==='onAreaChange'?callback=>areaChanges.push(callback):
    key==='overlay'?value=>overlays.push(value.builder):()=>{}});
  const rect = new Proxy({}, {get:(_,key)=>key==='height'?value=>guideHeights.push(value):()=>{}});
  const module = {exports:{}};
  const globals = {module,TaskContentEditor:component('blocks'),TaskChecklistBlock:component('checklist'),
    TaskEditor:component('task'),
    TaskBlockView:component('block'),TaskDocumentContent:component('document'),ForEach:noop,Rect:rect,
    Alignment:{TopStart:'top'},HitTestMode:{None:'none'},projectContentGap:()=>0,
    Gesture:noop,GesturePriority:{High:'high'},PanGesture:noop,PanDirection:{All:'all'},
    Row:noop,Color:{Transparent:'transparent'},
    ViewPU:{create(){}},__Common__:common,Column:common,Stack:noop,If:noop,TaskStateCategory:{Doing:'Doing'},UiColor:{taskCard:'card'},UiSize:{contentLiftRadius:8,contentLiftShadowRadius:12,contentLiftShadowOffset:6}};
  const code = ts.transpileModule('class Host {' + bodies.join('\n') + '}\nmodule.exports=Host;', {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code, globals);
  const host = new module.exports();
  Object.assign(host,{observeComponentCreation2(callback){callback(1,true);},ifElseBranchUpdateFunction(_,callback){callback();},
    forEachUpdateFunction(_,items,render){items.forEach(render);}});
  return {host,children,areaChanges,overlays,guideHeights};
}

test('编译后的清单区块在菜单外壳中仍调用原宿主的阅读槽', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskContentEditor',['initialRender','blockFor','indexFor','validMoveGap','canDragBlock','selectedForMove']);
  const block={id:'20',kind:'checklist',items:[{id:'42',text:'项目清单'}]};
  const rendered=[];
  Object.assign(f.host,{blocks:[block],slots:[{key:'one',block}],checklist(index){assert.equal(this,f.host);rendered.push(this.blocks[index()]);}});
  f.host.initialRender();
  const shell=f.children.find(child=>child.kind==='block');
  assert.equal(shell.nativeChecklist,true);
  shell.readContent.call(shell);
  assert.deepEqual(rendered,[block]);
});

test('编译后的项目竖线仅在二级及更深正文按实测高度收尾，一级与前言不画线', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('OrgFileSectionBody',['initialRender','bodyGuide'],'components');
  Object.assign(f.host,{task:{state:null,level:2},blocks:[],bodyHeight:0});
  f.host.initialRender();assert.equal(f.children[0].projectReading,true);
  for(const height of [52,26,130]){
    f.areaChanges[0]({}, {height});f.host.bodyGuide();
    assert.equal(f.guideHeights.at(-1),height-6);
  }
  f.host.task={state:null,level:1};f.areaChanges[0]({}, {height:100});f.host.bodyGuide();
  f.host.task={state:{name:'TODO'},level:1};f.host.bodyGuide();
  f.host.task=null;f.host.bodyGuide();
  assert.deepEqual(f.overlays,[], '装饰线不能使用会拦截整块正文触摸的 overlay');
  assert.deepEqual(f.guideHeights,[46,20,124]);
  f.host.task={state:{name:'TODO'},level:2};f.host.taskId='project-parent';f.host.dataSet={};
  f.host.initialRender();
  const body=f.children.at(-1);
  assert.equal(body.kind,'task');
  assert.equal(body.bodyOnly,true);
  assert.equal(body.taskId,'project-parent');
});

test('编译后的任务区块回调在子组件中执行时仍使用任务宿主，清单与拖动手柄均能创建', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskEditor',['bodyBlocks','checklistBlock','checkBlock','tree','contentLinks']);
  const item={id:'42',text:'日志回归验证 20261112',checked:false,depth:0};
  const block={id:'20',kind:'checklist',items:[item]};
  const calls=[];
  Object.assign(f.host,{readOnly:false,addingCheck:false,value:()=>({fileVersion:'v1',state:null,editContent:{blocks:[block],checklist:[item]}}),
    blockItems(value){assert.equal(this,f.host);assert.equal(value,block);return value.items;},lastChecklist(){assert.equal(this,f.host);return true;},
    checklistGrip(value,floating){assert.equal(this,f.host);calls.push([value,floating]);}});
  f.host.bodyBlocks();
  const blocks=f.children.find(child=>child.kind==='blocks');assert.ok(blocks);
  blocks.checklist.call(blocks,()=>0);
  const checklist=f.children.find(child=>child.kind==='checklist');assert.ok(checklist);assert.equal(checklist.items[0],item);
  checklist.grip.call(checklist,item,false);
  assert.deepEqual(calls,[[item,false]]);
});

test('编译后的项目正文清单回调保持文档宿主，避免借用区块组件的 this', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskDocumentContent',['initialRender','checklist','tree']);
  const block={id:'20',kind:'checklist',items:[{id:'42',text:'项目清单'}]};
  Object.assign(f.host,{content:()=>[block],isReadonly(){assert.equal(this,f.host);return false;},lastChecklist(){assert.equal(this,f.host);return true;},message:''});
  f.host.initialRender();
  const blocks=f.children.find(child=>child.kind==='blocks');assert.ok(blocks);
  blocks.checklist.call(blocks,()=>0);
  const checklist=f.children.find(child=>child.kind==='checklist');assert.ok(checklist);assert.equal(checklist.items,block.items);
});

test('编译后的项目清单在连续新增、勾选、删除和位置 ID 改变后读取当前快照', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskDocumentContent',['initialRender','checklist','lastChecklist','tree']);
  let blocks=[{id:'20',kind:'checklist',items:[{id:'42',text:'原条目',checked:false}]}];
  Object.assign(f.host,{content:()=>blocks,isReadonly:()=>false,adding:true,message:''});
  f.host.initialRender();f.children.find(child=>child.kind==='blocks').checklist(()=>0);
  const checklist=f.children.find(child=>child.kind==='checklist');
  for (const items of [
    [...blocks[0].items,{id:'60',text:'新增一',checked:false}],
    [{id:'43',text:'原条目',checked:true},{id:'61',text:'新增一',checked:false},{id:'80',text:'新增二',checked:false}],
    [{id:'43',text:'原条目',checked:true},{id:'61',text:'新增一',checked:false}]
  ]) {
    blocks=[{id:String(Number(blocks[0].id)+1),kind:'checklist',items}];
    const current=checklist.paramsGenerator_();
    assert.equal(current.items,items);assert.equal(current.blockId,blocks[0].id);
    assert.equal(current.showAdd,true);assert.equal(current.adding,true);
  }
});

test('编译后的任务编辑清单在新快照条目 ID 全部移动后仍显示完整清单', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskEditor',['checklistBlock','checkBlock','blockItems','lastChecklist','tree','contentLinks']);
  let blocks=[{id:'20',kind:'checklist',items:[{id:'42',text:'原条目'}]}];
  Object.assign(f.host,{value:()=>({editContent:{blocks}}),checkItems:()=>blocks[0].items,addingCheck:true});
  f.host.checklistBlock(()=>0);
  const checklist=f.children.find(child=>child.kind==='checklist');
  blocks=[{id:'21',kind:'checklist',items:[{id:'43',text:'原条目'},{id:'61',text:'新增条目'}]}];
  const current=checklist.paramsGenerator_();
  assert.deepEqual(current.items,blocks[0].items);assert.equal(current.blockId,'21');assert.equal(current.showAdd,true);
});

test('项目正文会话从来源取得最新版本，草稿开始后冻结版本且失败保留输入',async()=>{
 const f=projectFixture();let latest={...f.task,fileVersion:'live-v2'};f.editor.readTask=()=>latest;
 await f.editor.session();assert.equal(f.editor.current,latest);
 const frozen=f.editor.current;latest={...latest,fileVersion:'live-v3'};
 f.fail(new Error('文件版本冲突'));f.editor.editingId='42';f.editor.editingText='保留草稿';
 assert.equal(await f.editor.saveCheck(false),false);
 assert.equal(f.writes[0].snapshot,frozen);assert.equal(f.writes[0].snapshot.fileVersion,'live-v2');
 assert.equal(f.editor.editingText,'保留草稿');assert.equal(f.editor.current,frozen);
});


test('隐藏日志首次不创建阅读器，首次打开后收起保留内容，默认展开立即创建',()=>{
 const {TaskLogView:Logs}=load('components/editors/TaskLogView',{},prefix('TaskLogView'));
 const hidden=Object.assign(new Logs(),{expanded:false,contentCreated:false});hidden.aboutToAppear();
 assert.equal(hidden.contentCreated,false);hidden.expanded=true;hidden.expansionChanged();assert.equal(hidden.contentCreated,true);
 hidden.expanded=false;hidden.expansionChanged();assert.equal(hidden.contentCreated,true);
 const visible=Object.assign(new Logs(),{expanded:true,contentCreated:false});visible.aboutToAppear();assert.equal(visible.contentCreated,true);
});
