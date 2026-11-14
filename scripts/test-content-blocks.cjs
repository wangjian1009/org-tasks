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
function blockFixture() {
  const { TaskBlockView } = load('components/editors/TaskBlockView', {
    '../../ui/TaskBlockController': controller, '../LinkView': { LinkEditController: class { async finish() { return true; } } },
    '../../ui/Theme': { UiColor: { taskCard: 'card' } }
  }, prefix('TaskBlockView'));
  const editor = new TaskBlockView();
  const writes = [], events = [];
  editor.inputKey = 'block'; editor.block = { id: '1', kind: 'text', source: 'Original', html: '<p>Original</p>', items: [] };
  editor.readonly = false;editor.disabled = false;
  editor.begin = async () => true;
  editor.save = async (block, source) => { writes.push({ block, source });return true; };
  editor.editingChanged = value => events.push(value);
  return { editor, writes, events };
}
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
  const service = { async modify(context, snapshot, changes, documentMode) {
    writes.push({ snapshot, changes, documentMode });if (fail) throw fail;
  }, async reload() { if (reloadFail) throw reloadFail;return refreshed; } };
  const { TaskDocumentContent } = load('components/editors/TaskDocumentContent', {
    '../../services/NativeCoreService': { coreErrorMessage: e => e.message },
    '../../services/TaskInlineService': { TaskInlineService: service, TaskInlineSession: { async begin() { return true; }, release() { releases++; } } },
    '../../ui/TaskBlockController': controller, '../LinkView': { LinkEditController: class { async finish() { return true; } } },
    '../../ui/Theme': { UiColor: { surface: 'surface' } }, '@kit.ArkUI': { KeyboardAvoidMode: { RESIZE: 1 } }
  }, source => prefix('TaskDocumentContent')(source.split('  @Builder\n')[0]));
  const editor = new TaskDocumentContent();editor.active = true;editor.task = task;editor.getUIContext = () => ({ getHostContext: () => ({}), setKeyboardAvoidMode() {} });
  return { editor, task, writes, releases: () => releases, refreshWith: value => { refreshed = value; }, fail: value => { fail = value; }, reloadFail: value => { reloadFail = value; } };
}
test('项目区块保留原版本提交，成功重读；只读前言不提交', async () => {
  const f = projectFixture();assert.equal(await f.editor.session(), true);
  await f.editor.saveBlock({ id: '42' }, 'Changed');assert.equal(f.writes[0].snapshot, f.task);
  assert.equal(f.writes[0].documentMode, true);assert.deepEqual(f.writes[0].changes, [{field:'CONTENT_BLOCK',value:{type:'replace',id:'42',source:'Changed'}}]);
  assert.equal(f.editor.current.fileVersion, 'v2');
  f.editor.readonly = true;assert.equal(await f.editor.saveBlock({id:'42'}, 'Blocked'), false);assert.equal(f.writes.length, 1);
});
test('项目写入失败可重试，提交成功而重读失败时阻止再次写入', async () => {
  const f = projectFixture();await f.editor.session();f.fail(new Error('版本变化'));
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
      TextDecorationType:{LineThrough:'strike',None:'none'},
      checklistSiblings:items=>items };
    vm.runInNewContext(code, globals);
    const item = {id:'first',text:'这是应当完整换行的很长清单文字，不能在只读状态切换成单行省略',checked,partial,depth:2};
    const component = Object.assign(new globals.module.exports(), {readonly,disabled:false,dragging:false,editingId:'',sorting:true,items:[item,{...item,id:'second'}],
      observeComponentCreation2(callback){callback(0,true);},ifElseBranchUpdateFunction(_,callback){callback();},
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

function compiledBuilders(name, methods) {
  const filename = `entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/editors/${name}.ts`;
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
  const module = {exports:{}};
  const globals = {module,TaskContentBlocks:component('blocks'),TaskChecklistBlock:component('checklist'),
    ViewPU:{create(){}},__Common__:noop,Column:noop,If:noop,TaskStateCategory:{Doing:'Doing'},UiColor:{taskCard:'card'}};
  const code = ts.transpileModule('class Host {' + bodies.join('\n') + '}\nmodule.exports=Host;', {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code, globals);
  const host = new module.exports();
  Object.assign(host,{observeComponentCreation2(callback){callback(1,true);},ifElseBranchUpdateFunction(_,callback){callback();}});
  return {host,children};
}

test('编译后的任务区块回调在子组件中执行时仍使用任务宿主，清单与拖动手柄均能创建', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskEditor',['bodyBlocks','checklistBlock']);
  const item={id:'42',text:'日志回归验证 20261112',checked:false,depth:0};
  const block={id:'20',kind:'checklist',items:[item]};
  const calls=[];
  Object.assign(f.host,{readOnly:false,addingCheck:false,value:()=>({fileVersion:'v1',state:null,editContent:{blocks:[block],checklist:[item]}}),
    blockItems(value){assert.equal(this,f.host);assert.equal(value,block);return value.items;},lastChecklist(){assert.equal(this,f.host);return true;},
    checklistGrip(value,floating){assert.equal(this,f.host);calls.push([value,floating]);}});
  f.host.bodyBlocks();
  const blocks=f.children.find(child=>child.kind==='blocks');assert.ok(blocks);
  blocks.checklist.call(blocks,block);
  const checklist=f.children.find(child=>child.kind==='checklist');assert.ok(checklist);assert.equal(checklist.items[0],item);
  checklist.grip.call(checklist,item,false);
  assert.deepEqual(calls,[[item,false]]);
});

test('编译后的项目正文清单回调保持文档宿主，避免借用区块组件的 this', {skip:!fs.existsSync(emittedChecklist)}, () => {
  const f=compiledBuilders('TaskDocumentContent',['initialRender','checklist']);
  const block={id:'20',kind:'checklist',items:[{id:'42',text:'项目清单'}]};
  Object.assign(f.host,{content:()=>[block],isReadonly(){assert.equal(this,f.host);return false;},lastChecklist(){assert.equal(this,f.host);return true;},message:''});
  f.host.initialRender();
  const blocks=f.children.find(child=>child.kind==='blocks');assert.ok(blocks);
  blocks.checklist.call(blocks,block);
  const checklist=f.children.find(child=>child.kind==='checklist');assert.ok(checklist);assert.equal(checklist.items,block.items);
});
