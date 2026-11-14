// 验证公共链接控件的系统跳转、地图选择、失败与生命周期隔离。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-links.cjs\n验证链接控件的网页、邮件、电话、地图跳转和失败反馈，内部链接、协议切换、长按拷贝与编辑，以及异步生命周期隔离。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function presentation() {
  const module = { exports: {} };
  const input = fs.readFileSync('entry/src/main/ets/ui/LinkPresentation.ets','utf8');
  const code = ts.transpileModule(input,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInThisContext('(function(module,exports,$r){'+code+'})')(module,module.exports,name=>({name}));
  return module.exports;
}
const linkPresentation = presentation();
const filename = 'entry/src/main/ets/components/LinkView.ets';
const source = fs.readFileSync(filename, 'utf8');
const behavior = source.slice(0, source.indexOf('  build() {')).replace(/  @Builder\n[\s\S]*?\n  \}\n/g, '')
  + '}\n' + source.slice(source.indexOf('interface GeoCoordinates'));
const code = ts.transpileModule(behavior.replace(/@Component\n|@State |@Prop |@BuilderParam /g, '')
  .replace('export struct LinkView', 'export class LinkView'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture() {
  const calls = [], messages = [];
  let open = async () => {}, start = async () => {}, search = async () => {};
  const module = { exports: {} };
  const context = {
    async openLink(...args) { calls.push(['web', ...args]); await open(...args); },
    async startAbility(...args) { calls.push(['ability', ...args]); await start(...args); }
  };
  const mocks = {
    '@kit.BasicServicesKit': { pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (type,value) => ({type,value}),
      getSystemPasteboard: () => ({ async setData(value) { calls.push(['copy',value]); } })
    } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({width:390}) } },
    '../ui/LinkPresentation': linkPresentation,
    '@kit.MapKit': { petalMaps: { async openMapTextSearch(...args) { calls.push(['search', ...args]); await search(...args); } } },
    '../ui/Theme': { UiSize: { taskFont: 16 }, UiColor: { surface: '#2D2C2B', text: '#D8D8D8',
      primary: '#64C4BA', secondary: '#AEACA9', field: '#3A3E3F', error: '#FF7592' } }
  };
  vm.runInThisContext('(function(require,module,exports,FontWeight,$r,TextController){' + code + '\n})', { filename })(
    name => { assert.ok(name in mocks, name); return mocks[name]; }, module, module.exports,
    { Normal: 400 }, name => ({ name }), class {});
  const view = new module.exports.LinkView();
  view.getUIContext = () => ({ getHostContext: () => context, px2vp: value => value,
    getFocusController: () => ({requestFocus() {}}),
    getPromptAction: () => ({ showToast: ({message}) => messages.push(message) }) });
  view.getUniqueId = () => 1;
  view.aboutToAppear();
  return { view, calls, messages, context, documentScript: module.exports.linkDocumentScript,
    open: value => { open = value; }, start: value => { start = value; }, search: value => { search = value; } };
}

test('标题和 Web 适配共用同一跳转控制器，网页交给系统，内嵌资源不触发跳转', async () => {
  const f = fixture();
  assert.equal(f.view.links.navigate('about:blank', true), false);
  assert.equal(f.view.links.navigate('data:text/html,hello', true), false);
  assert.equal(f.view.links.navigate('#chapter', true), false);
  assert.equal(f.view.links.navigate('https://example.com/frame', false), true);
  assert.deepEqual(f.calls, []);
  assert.equal(f.view.links.navigate('https://example.com/path?x=1', true), true);
  await Promise.resolve();
  assert.deepEqual(f.calls, [['web', 'https://example.com/path?x=1', { appLinkingOnly: false }]]);
});

test('邮件和电话使用 viewData，链接行为不调用标题区域激活操作', async () => {
  const f = fixture();
  f.view.activate = () => { assert.fail('链接点击不应激活标题区域'); };
  for (const href of ['mailto:team@example.com', 'tel:12345']) await f.view.links.open(href);
  assert.deepEqual(f.calls, ['mailto:team@example.com', 'tel:12345'].map(uri =>
    ['ability', { action: 'ohos.want.action.viewData', uri }]));
});

test('文字地址先展示地图选择，不支持项保留面板，花瓣使用文字搜索接口', async () => {
  const f = fixture();
  await f.view.links.open('addr:%E5%8C%97%E4%BA%AC');
  assert.equal(f.view.chooserVisible, true);
  assert.equal(f.view.mapChoices[0].contextLabel, '搜索：北京');
  assert.equal(f.view.mapChoices[0].supported, false);
  await f.view.selectMapApp(f.view.mapChoices[0]);
  assert.equal(f.view.chooserVisible, true);
  assert.match(f.messages.at(-1), /高德地图暂不支持地址搜索/);
  assert.deepEqual(f.calls, []);
  await f.view.selectMapApp(f.view.mapChoices[1]);
  assert.equal(f.view.chooserVisible, false);
  assert.deepEqual(f.calls, [['search', f.context, { destinationName: '北京' }]]);
});

test('坐标地址可选择高德或花瓣，地图 URI 与应用身份正确', async () => {
  const f = fixture();
  for (let index=0; index<2; index++) {
    await f.view.links.open('geo:39.9042,116.4074');
    assert.ok(f.view.mapChoices.every(choice => choice.supported));
    await f.view.selectMapApp(f.view.mapChoices[index]);
  }
  assert.equal(f.calls[0][1].bundleName, 'com.amap.hmapp');
  assert.match(f.calls[0][1].uri, /dlat=39.9042&dlon=116.4074/);
  assert.equal(f.calls[1][1].bundleName, 'com.huawei.hmos.maps.app');
  assert.equal(f.calls[1][1].uri, 'geo:39.9042,116.4074');
});

test('系统打开失败显示反馈，地图选择失败保留面板以便重试', async () => {
  const f = fixture();
  f.open(async () => { throw new Error('系统打开失败'); });
  await f.view.links.open('https://example.com/');
  assert.match(f.messages.at(-1), /无法打开链接/);
  await f.view.links.open('geo:0,0?q=Beijing');
  f.search(async () => { throw new Error('地图未安装'); });
  await f.view.selectMapApp(f.view.mapChoices[1]);
  assert.equal(f.view.chooserVisible, true);
  assert.equal(f.view.launching, false);
  assert.match(f.messages.at(-1), /无法打开地图/);
});

test('无效地址与不支持的协议只提示，不启动应用', async () => {
  const f = fixture();
  for (const href of ['geo:0,0', 'addr:%invalid', 'javascript:alert(1)', 'file:/secret']) await f.view.links.open(href);
  assert.equal(f.messages.length, 4);
  assert.deepEqual(f.calls, []);
});

test('禁用链接与重复点击不启动额外操作，离开后的失败不回写新生命周期', async () => {
  const f = fixture();
  f.view.openLinks = false;
  await f.view.links.open('https://example.com/');assert.deepEqual(f.calls, []);
  f.view.openLinks = true;
  let reject;
  f.open(() => new Promise((_resolve, fail) => { reject = fail; }));
  const pending = f.view.links.open('https://example.com/');
  await f.view.links.open('https://example.com/second');
  assert.equal(f.calls.length, 1);
  f.view.aboutToDisappear();f.view.aboutToAppear();
  reject(new Error('旧页面请求失败'));await pending;
  assert.deepEqual(f.messages, []);assert.equal(f.view.launching, false);
});

function linkHit() {
  return { link: { start: 3, end: 30, source: '[[https://example.com][资料]]', title: '资料', url: 'https://example.com' },
    href: 'https://example.com/', label: '资料', x: 120, y: 28, width: 390 };
}

test('可编辑链接单击跳转，长按菜单选择编辑后才展开表单，成功保存后退出编辑', async () => {
  const f = fixture(), changes = [], states = [];
  f.view.editable = true;f.view.revision = 'v1';
  f.view.change = async (...args) => changes.push(args);
  f.view.editingChanged = value => states.push(value);
  const hit = linkHit();await f.view.select(hit);
  assert.equal(f.view.menuVisible, false);assert.equal(f.view.editing, false);
  assert.deepEqual(f.calls, [['web', hit.href, { appLinkingOnly: false }]]);
  await f.view.select({...hit, menu:true});
  assert.equal(f.view.editing, false);
  f.view.menuItems().find(item=>item.title==='编辑').action();
  await Promise.resolve();
  assert.equal(f.view.editing, true);assert.equal(f.view.menuVisible, false);
  assert.equal(f.view.titleDraft, '资料');assert.equal(f.view.urlDraft, 'https://example.com');
  f.view.titleDraft = '新标题';f.view.urlDraft = 'https://example.org/';
  assert.equal(await f.view.saveEdit(), true);
  assert.deepEqual(changes, [[hit.link, { title: '新标题', url: 'https://example.org/' }]]);
  assert.equal(f.view.editing, false);assert.deepEqual(states, [true, false]);
});

test('可编辑链接无法打开时提示并保持阅读态，Web 导航无需快照位置也尝试跳转', async () => {
  const f=fixture();f.view.editable=true;
  await f.view.select({...linkHit(),href:''});
  assert.match(f.messages.at(-1),/暂不支持打开/);assert.equal(f.view.editing,false);
  f.open(async()=>{throw new Error('打开失败');});
  await f.view.select(linkHit());
  assert.match(f.messages.at(-1),/无法打开链接/);assert.equal(f.view.editing,false);
  f.open(async()=>{});await f.view.navigate('https://example.org/no-position');
  assert.equal(f.calls.at(-1)[1],'https://example.org/no-position');assert.equal(f.view.editing,false);
});

test('取消不提交，删除传递具体链接和空值，重复网址不会依赖 href 定位', async () => {
  const f = fixture(), changes = [];
  f.view.editable = true;f.view.change = async (...args) => changes.push(args);
  await f.view.select(linkHit());await f.view.beginEdit();
  f.view.titleDraft = '放弃的草稿';f.view.cancelEdit();assert.deepEqual(changes, []);
  const second = linkHit();second.link.start = 60;second.link.end = 87;
  await f.view.select({...second,menu:true});assert.equal(await f.view.commit(null), true);
  assert.deepEqual(changes, [[second.link, null]]);
});

test('保存失败、空地址及版本变化保留草稿，结束输入同样等待保存成功', async () => {
  const f = fixture();let failed = true;
  f.view.editable = true;f.view.revision = 'v1';
  f.view.change = async () => { if (failed) throw new Error('版本冲突'); };
  await f.view.select(linkHit());await f.view.beginEdit();f.view.titleDraft = '保留的草稿';
  assert.equal(await f.view.editor.finish(), false);assert.equal(f.view.editing, true);
  assert.equal(f.view.titleDraft, '保留的草稿');assert.match(f.view.editError, /版本冲突/);
  failed = false;f.view.urlDraft = '';assert.equal(await f.view.saveEdit(), false);
  f.view.urlDraft = 'https://example.org/';f.view.revision = 'v2';
  assert.equal(await f.view.saveEdit(), false);assert.match(f.view.editError, /内容已变化/);
  f.view.revision = 'v1';assert.equal(await f.view.editor.finish(), true);
});

test('共享编辑控制器阻止同时编辑两个链接，旧草稿保存失败时不切换', async () => {
  const first = fixture(), second = fixture();let saved = false;
  first.view.editable = true;first.view.change = async () => { if (!saved) throw new Error('保存失败'); };
  await first.view.select(linkHit());await first.view.beginEdit();first.view.titleDraft = '未保存的标题';
  second.view.editor.release(1);second.view.editor = first.view.editor;
  second.view.getUniqueId = () => 2;second.view.aboutToAppear();
  second.view.editable = true;second.view.change = async () => {};
  await second.view.select(linkHit());await second.view.beginEdit();assert.equal(second.view.editing, false);
  saved = true;await second.view.beginEdit();
  assert.equal(first.view.editing, false);assert.equal(second.view.editing, true);
});

test('正文链接编辑以 Enter 切换到地址并提交最新草稿，输入法组词期间不切换', () => {
  const f = fixture(), saved = [], drafts = [];
  let focused, form;
  const link = linkHit().link;
  function element(tag) {
    return { tag, style: {}, children: [], listeners: {}, value: '',
      setAttribute(name,value) { this[name] = value; },
      before(node) { const index=this.parent.children.indexOf(this);this.parent.children.splice(index,0,node);node.parent=this.parent; },
      append(...nodes) { for(const node of nodes){ if(node.parent)node.parent.children.splice(node.parent.children.indexOf(node),1);node.parent=this;this.children.push(node); } },
      replaceChildren(...nodes) { this.children=[];this.append(...nodes); },
      addEventListener(name, callback) { this.listeners[name] = callback; },
      focus() { focused = this; }
    };
  }
  const anchor = { dataset: { orgLink: JSON.stringify(link) }, after(node) { form = node; },
    querySelector() { return true; }, getAttribute(name) { return name==='data-org-url'?'https://example.com/':''; } };
  const window = { OrgTaskLinks: {
    draft: (...values) => drafts.push(values), save: (...values) => saved.push(values)
  } };
  vm.runInNewContext(f.documentScript(), { window, document: {
    querySelectorAll: () => [anchor], querySelector: () => null,
    createElement: element, createElementNS: (_ns,tag)=>element(tag), createTextNode: text=>({textContent:text}), addEventListener() {}, removeEventListener() {}
  } });
  assert.equal(window.orgLinkEdit(link, '原标题', 'https://example.com/'), true);
  const title = form.children.find(node => node.tag === 'input');
  const urlRow = form.children.find(node => node.children?.some(child=>child.tag==='input'));
  const url = urlRow.children.find(node=>node.tag==='input');
  const button = urlRow.children[0], choices = urlRow.children[2];
  assert.equal(button.tag,'button');assert.equal(button['aria-label'],'选择链接协议，当前为HTTPS 网页');
  assert.equal(choices.hidden,true);
  button.listeners.click();assert.equal(choices.hidden,false);
  title.value='修改标题';
  choices.children[2].listeners.click();
  assert.equal(url.value,'mailto:example.com/');assert.equal(choices.hidden,true);
  assert.equal(button['aria-label'],'选择链接协议，当前为邮件');
  url.value='custom:keep';url.listeners.input();
  assert.equal(button['aria-label'],'选择链接协议，当前为其他协议');
  title.focus();drafts.length=0;
  assert.equal(focused, title);
  let prevented = 0;
  const enter = { key: 'Enter', isComposing: true, preventDefault() { prevented++; }, stopPropagation() {} };
  title.listeners.keydown(enter);
  assert.equal(focused, title);assert.equal(prevented, 0);
  enter.isComposing = false;
  title.value = '修改标题';title.listeners.keydown(enter);
  assert.equal(focused, url);assert.equal(prevented, 1);assert.equal(saved.length, 0);
  url.value = 'https://example.com/updated';url.listeners.keydown(enter);
  assert.equal(prevented, 2);
  assert.deepEqual(saved, [['修改标题', 'https://example.com/updated']]);
  assert.deepEqual(drafts, saved);
});

test('协议选择替换前缀并保留内容，同类选择不改写原地址，图标区分跳转类型', () => {
  const {linkProtocol, switchLinkProtocol, internalLinkTarget, LINK_PROTOCOLS} = linkPresentation;
  assert.equal(switchLinkProtocol('https://example.com/a?b=1','http'),'http://example.com/a?b=1');
  assert.equal(switchLinkProtocol('mailto:team@example.com','https'),'https://team@example.com');
  assert.equal(switchLinkProtocol('tel:12345','internal'),'12345');
  assert.equal(switchLinkProtocol('*章节','https'),'https://*章节');
  assert.equal(switchLinkProtocol('HTTPS://EXAMPLE.com/a','https'),'HTTPS://EXAMPLE.com/a');
  assert.equal(internalLinkTarget('org-internal:%23%E7%AB%A0%E8%8A%82'),'#章节');
  assert.equal(internalLinkTarget('org-internal:%invalid'),undefined);
  assert.equal(linkProtocol('javascript:alert(1)').kind,'other');
  assert.equal(new Set(['https:','mailto:','tel:','geo:','addr:','*章节'].map(value=>linkProtocol(value).icon.name)).size,6);
  assert.equal(LINK_PROTOCOLS.length,7);
});

test('长按菜单始终支持拷贝，只有可编辑且有快照位置的链接提供编辑和删除', async () => {
  const f = fixture(), hit = linkHit();
  await f.view.select({...hit,menu:true});
  assert.equal(f.view.menuVisible,true);assert.deepEqual(f.calls,[]);
  assert.deepEqual(f.view.menuItems().map(item=>item.title),['拷贝链接','拷贝标题']);
  await f.view.copySelected(false);await f.view.copySelected(true);
  assert.deepEqual(f.calls,[['copy',{type:'text/plain',value:hit.link.url}],['copy',{type:'text/plain',value:'资料'}]]);
  f.view.editable=true;f.view.change=async()=>{};
  await f.view.select({...hit,menu:true});
  assert.deepEqual(f.view.menuItems().map(item=>item.title),['拷贝链接','拷贝标题','编辑','删除']);
  assert.equal(f.view.editing,false);
  await f.view.select({link:null,href:'',url:'custom:original',label:'未知协议',x:0,y:0,width:390,menu:true});
  await f.view.copySelected(false);
  assert.equal(f.calls.at(-1)[1].value,'custom:original');
  assert.deepEqual(f.view.menuItems().map(item=>item.title),['拷贝链接','拷贝标题']);
});

test('内部处理对象验证目标再执行；目标失效不跳转，异步验证不能跨页面生命周期执行', async () => {
  const f = fixture(), internal = [];
  let valid=true, release;
  f.view.internalLinkProcessor={async isValid(target){internal.push(['valid',target]);return valid;},async process(target){internal.push(['process',target]);}};
  await f.view.links.open('org-internal:%23chapter');
  assert.deepEqual(internal,[['valid','#chapter'],['process','#chapter']]);assert.deepEqual(f.calls,[]);
  valid=false;await f.view.links.open('org-internal:%23missing');
  assert.deepEqual(internal.at(-1),['valid','#missing']);assert.match(f.messages.at(-1),/目标不存在/);
  f.view.internalLinkProcessor.isValid=()=>new Promise(resolve=>{release=resolve;});
  const pending=f.view.links.open('org-internal:%23chapter');
  f.view.aboutToDisappear();f.view.aboutToAppear();release(true);await pending;
  assert.equal(internal.filter(row=>row[0]==='process').length,1);assert.equal(f.view.launching,false);
});

function internalScript() {
  const input=fs.readFileSync('entry/src/main/ets/ui/InternalLinkProcessor.ets','utf8');
  const output=ts.transpileModule(input,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};
  vm.runInThisContext('(function(module,exports){'+output+'})')(module,module.exports);
  return module.exports.documentInternalLinkScript;
}
test('文档跳转按 Core 提供的优先级选择目的地，验证不滚动，执行展开折叠祖先', () => {
  const script=internalScript(), scrolled=[];
  const parent={open:false,parentElement:null,matches:selector=>selector==='details'};
  function target(priority,name){return {parentElement:parent,matches:()=>false,
    getAttribute:key=>key==='data-org-link-targets'?JSON.stringify(['目标']):String(priority),scrollIntoView:()=>scrolled.push(name)};}
  const nodes=[target(2,'标题'),target(1,'NAME'),target(0,'专用目标')];
  const document={querySelectorAll:()=>nodes};
  assert.equal(vm.runInNewContext(script('目标',false),{document}),true);assert.deepEqual(scrolled,[]);assert.equal(parent.open,false);
  assert.equal(vm.runInNewContext(script('目标',true),{document}),true);assert.deepEqual(scrolled,['专用目标']);assert.equal(parent.open,true);
  assert.equal(vm.runInNewContext(script('失效目标',true),{document}),false);assert.deepEqual(scrolled,['专用目标']);
});

test('Web 单击与长按分离，滚动取消长按，字段点击不触发链接或宿主动作', () => {
  const f=fixture(), hits=[], handlers={}, timers=new Map();let sequence=0;
  const hit=linkHit();
  const anchor={dataset:{orgLink:JSON.stringify(hit.link)},querySelector:()=>true,
    getAttribute:key=>({href:hit.href,'data-org-url':hit.link.url}[key]||''),textContent:'资料',
    getBoundingClientRect:()=>({left:20,top:40,width:50})};
  const window={innerWidth:390,OrgTaskLinks:{hit:payload=>hits.push(JSON.parse(payload))}};
  vm.runInNewContext(f.documentScript(),{window,document:{querySelectorAll:()=>[anchor],
    addEventListener:(key,callback)=>handlers[key]=callback,removeEventListener(){}},
    setTimeout:callback=>{timers.set(++sequence,callback);return sequence;},clearTimeout:id=>timers.delete(id)});
  function event(form=false){return {button:0,clientX:20,clientY:40,
    target:{closest:selector=>selector==='.org-link-editor'?(form?{}:null):anchor},preventDefault(){},stopPropagation(){}};}
  handlers.click(event());assert.equal(hits.length,1);assert.equal(hits[0].menu,false);
  handlers.pointerdown(event());const callback=[...timers.values()][0];callback();
  assert.equal(hits.length,2);assert.equal(hits[1].menu,true);
  handlers.click(event());assert.equal(hits.length,2);
  handlers.pointerdown(event());handlers.pointermove({...event(),clientX:100});assert.equal(timers.size,0);
  handlers.click(event(true));assert.equal(hits.length,2);
});
