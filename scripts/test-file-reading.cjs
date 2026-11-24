// 验证文件阅读目录在刷新、原文模式和导航失败时不会作用于错误快照。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-file-reading.cjs\n验证文件目录生命周期、折叠导航失败保护与只读页面包装。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(filename, mocks = {}, transform = source => source) {
  const source = ts.transpileModule(transform(fs.readFileSync(filename, 'utf8')), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports,Scroller){' + source + '\n})', { filename })(name => {
    if (name.endsWith('/PageDataEquality')) return { samePageValue: (a,b) => JSON.stringify(a) === JSON.stringify(b) };
    if (name.endsWith('/PageNavigator')) return require('./helpers/page-navigator.cjs').pageNavigatorMock;
    if (name.endsWith('/CenteredPanel')) return {};
    if (name.endsWith('/DangerousConfirmation')) return require('./helpers/dangerous-confirmation.cjs');
    if (name.endsWith('/SystemRepository')) return { isSystemRepository: repo => repo.id === 'org-tasks-system' };
    assert.ok(name in mocks, `缺少替身：${name}`);
    return mocks[name];
  }, module, module.exports, class { scrollTo(value) { this.lastScroll = value; } currentOffset() { return { xOffset: 0, yOffset: this.lastScroll?.yOffset ?? 0 }; } });
  return module.exports;
}
const base = 'entry/src/main/ets/';
const navigation = load(base + 'ui/OrgDocumentNavigation.ets');
const projectHeader = load(base + 'ui/OrgFileHeaderPresentation.ets');
const tagFilter = load(base + 'ui/TaskTagFilterPresentation.ets', {
  './TaskStatePresentation': load(base + 'ui/TaskStatePresentation.ets')
});
const projectReading = load(base + 'ui/OrgFileReadingPresentation.ets');
const projectStructure = load(base + 'ui/OrgFileStructurePresentation.ets');
const swipeMenus = load(base + 'components/controls/RightSwipe.ets', {}, source => source.split('@Component')[0]);
const taskActions = load(base + 'ui/TaskActionPresentation.ets');
const internalLinkProcessors = load(base + 'ui/InternalLinkProcessor.ets');
const theme = load(base + 'ui/Theme.ets');
const presentation = load(base + 'ui/OrgDocumentPresentation.ets', { './Theme': theme });

test('项目普通段落区分单空行与多空行，首段和结构区块保持各自间距', () => {
  const blocks = [
    { paragraph: true, blankLinesBefore: 3 },
    { paragraph: true, blankLinesBefore: 0 },
    { paragraph: true, blankLinesBefore: 1 },
    { paragraph: true, blankLinesBefore: 2 },
    { paragraph: true, blankLinesBefore: 5 },
    { paragraph: false, blankLinesBefore: 1 },
    { paragraph: true, blankLinesBefore: 1 }
  ];
  assert.deepEqual(blocks.map((_, index) => projectReading.projectContentGap(blocks, index)), [0, 0, 0, 12, 12, 12, 12]);
});
test('项目归档只隐藏后代，保留同级标题；叶任务和父任务正确区分', () => {
  const section = (id, level, archived = false) => ({ key: id, node: {
    id, level, property: () => null, editContent: { ownTags: archived ? ['ARCHIVE'] : [] }
  } });
  const source = [section('archive', 1, true), section('hidden', 3), section('sibling', 1), section('leaf', 2)];
  assert.deepEqual(projectReading.projectReadingItems(source).filter(item => item.visible).map(item => [item.section.key, item.hasChildren]),
    [['archive', true], ['sibling', true], ['leaf', false]]);
  source[0].node.editContent.ownTags = [];
  assert.equal(projectReading.projectReadingItems(source).length, 4);
});

test('项目折叠直接读取 Task 通用属性，隐藏直属后代并保留下一同级', () => {
  const section = (id, level, visibility = null) => ({ key: id, node: {
    id, level, property: name => name === 'VISIBILITY' ? visibility : null, editContent: { ownTags: [] }
  } });
  const sections = [section('folded', 1, 'folded'), section('child', 2), section('deep', 4), section('sibling', 1)];
  assert.deepEqual(projectReading.projectReadingItems(sections).filter(item => item.visible).map(item => item.section.key), ['folded', 'sibling']);
  for (const visibility of [null, 'all']) {
    sections[0] = section('folded', 1, visibility);
    assert.deepEqual(projectReading.projectReadingItems(sections).filter(item => item.visible).map(item => item.section.key),
      ['folded', 'child', 'deep', 'sibling']);
  }
});

test('项目标题收起时写入 VISIBILITY，展开时删除该属性', async () => {
  const { OrgHeadingView } = load(base + 'components/OrgHeadingView.ets', {
    '../services/TaskInlineService': { TaskInlineSession: { end: async () => true } }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop /g, '')
    .replace('export struct OrgHeadingView', 'export class OrgHeadingView') + '}');
  const heading = new OrgHeadingView();
  let visibility = null;
  const submitted = [];
  heading.node = { editContent: { ownTags: [] }, property: name => name === 'VISIBILITY' ? visibility : null };
  heading.modify = async changes => {
    submitted.push(changes);
    visibility = changes[0].value.value;
  };
  await heading.toggleSubtree();
  await heading.toggleSubtree();
  assert.deepEqual(submitted, [
    [{ field: 'PROPERTY', value: { name: 'VISIBILITY', value: 'folded' } }],
    [{ field: 'PROPERTY', value: { name: 'VISIBILITY', value: null } }]
  ]);
});

test('项目标签只过滤任务，普通章节及正文完整保留，命中任务的全部祖先保持源顺序', () => {
  const section = (id, level, task = false) => ({ key: id, node: { id, level, state: task ? {name:'TODO'} : null,
    property: () => null, editContent: { ownTags: [] } }, blocks: [{source:'正文 '+id}] });
  const source = [{ key: 'preamble', node: null }, section('root', 1), section('other', 2),
    section('parentTask', 2, true), section('middle', 3), section('deepTask', 4, true),
    section('filteredTask', 2, true), section('end', 1)];
  const snapshot = JSON.stringify(source);
  const all = projectReading.projectReadingItems(source, ['deepTask']);
  assert.equal(all.length, source.length);
  assert.ok(all.every((item,index) => item.section === source[index]));
  assert.equal(all.find(item=>item.section.key==='filteredTask').visible,false);
  const items = all.filter(item=>item.visible);
  assert.deepEqual(items.map(item => item.section.key), ['preamble', 'root', 'other', 'parentTask', 'middle', 'deepTask', 'end']);
  assert.deepEqual(items.map(item => item.contextOnly), [false, false, false, true, false, false, false]);
  assert.equal(items[2].section.blocks[0].source, '正文 other');
  assert.equal(JSON.stringify(source), snapshot);
  assert.deepEqual(projectReading.projectReadingItems(source, []).filter(item => item.visible).map(item => item.section.key),
    ['preamble', 'root', 'other', 'parentTask', 'middle', 'end']);
  assert.equal(projectReading.projectReadingItems(source).length, source.length);
});

test('未命中父任务保留其普通子章节路径，已归档与已收起子树继续隐藏', () => {
  const section = (id, level, state = null, tags = [], folded = false) => ({key:id,node:{id,level,state,
    editContent:{ownTags:tags},property:()=>folded?'folded':null}});
  const source = [section('parent',1,{name:'TODO'}),section('chapter',2),
    section('archived',1,null,['ARCHIVE']),section('archivedTask',2,{name:'TODO'}),
    section('folded',1,null,[],true),section('foldedTask',2,{name:'TODO'}),section('tail',1)];
  const items = projectReading.projectReadingItems(source, ['archivedTask','foldedTask']).filter(item=>item.visible);
  assert.deepEqual(items.map(item=>item.section.key),['parent','chapter','archived','folded','tail']);
  assert.equal(items[0].contextOnly,true);
});

function fixture() {
  const calls = [], toasts = [];
  let evaluate = async () => JSON.stringify({ chapters: [{ index: 0, level: 1, title: '章节' }], activeIndex: 0 });
  const { ConflictView } = load(base + 'components/OrgFileConflictView.ets', {
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: value => Buffer.from(value).toString('utf8') }) } } },
    '@kit.ArkWeb': { webview: { WebviewController: class { async runJavaScript(script) { calls.push(script); return evaluate(script); } } } },
    '../services/AppConfigService': {},
    '../services/NotebookService': {},
    '../services/NativeCoreService': { coreErrorMessage: error => error.message },
    '../ui/SyncLogPresentation': {},
    '../ui/Theme': theme,
    '../ui/OrgDocumentNavigation': navigation
  }, source => source.split('  @Builder\n')[0].replace(/@Entry\n|@Component\n|@State |@BuilderParam |@Prop(?: @Watch\('[^']+'\))? /g, '')
    .replace('export struct OrgFileConflictView', 'class ConflictView') + '}\nmodule.exports = { ConflictView };');
  const page = new ConflictView();
  page.aboutToAppear();
  page.loading = false;
  page.renderReady = true;
  page.getUIContext = () => ({ getPromptAction: () => ({ showToast: toast => toasts.push(toast.message) }) });
  return { page, calls, toasts, evaluate: value => { evaluate = value; } };
}

test('目录读取当前快照，跳转成功后关闭面板', async () => {
  const f = fixture();
  await f.page.openOutline();
  assert.equal(f.page.outlineVisible, true);
  assert.equal(f.page.activeChapter, 0);
  f.evaluate(async () => 'true');
  await f.page.openChapter(f.page.chapters[0]);
  assert.equal(f.page.outlineVisible, false);
  assert.equal(f.page.renderedHtml, '');
});

test('兼容 Web 引擎对目录字符串进行 JSON 二次编码', async () => {
  const f = fixture();
  f.evaluate(async () => JSON.stringify(JSON.stringify({ chapters: [], activeIndex: -1 })));
  await f.page.openOutline();
  assert.equal(f.page.outlineVisible, true);
  assert.deepEqual(f.page.chapters, []);
});

test('离开页面后迟到的目录读取不会重新打开面板', async () => {
  const f = fixture();
  let complete;
  f.evaluate(() => new Promise(resolve => { complete = resolve; }));
  const pending = f.page.openOutline();
  f.page.aboutToDisappear();
  complete(JSON.stringify({ chapters: [{ index: 4, level: 2, title: '旧文件' }], activeIndex: 4 }));
  await pending;
  assert.equal(f.page.outlineVisible, false);
  assert.deepEqual(f.page.chapters, []);
  assert.equal(f.page.renderReady, false);
});

test('冲突正文尚未加载时不执行阅读 DOM 操作', async () => {
  const f = fixture();
  f.page.renderReady = false;
  await f.page.expandAll(false);
  await f.page.openOutline();
  await f.page.openChapter({ index: 0, title: '章节', level: 1 });
  assert.deepEqual(f.calls, []);
});

test('定位失败保留正文和目录供重试，返回键只关闭面板', async () => {
  const f = fixture();
  await f.page.openOutline();
  f.evaluate(async () => 'false');
  await f.page.openChapter(f.page.chapters[0]);
  assert.equal(f.page.outlineVisible, true);
  assert.equal(f.page.renderedHtml, '');
  assert.match(f.toasts[0], /目录已失效/);
  assert.equal(f.page.navigation.closePanel(), true);
  assert.equal(f.page.outlineVisible, false);
  assert.equal(f.page.navigation.closePanel(), false);
});

test('最新目录请求优先；旧章节跳转不修改新文件状态', async () => {
  const f = fixture();
  const pending = [];
  f.evaluate(() => new Promise(resolve => pending.push(resolve)));
  const first = f.page.openOutline(), second = f.page.openOutline();
  pending[1](JSON.stringify({ chapters: [], activeIndex: -1 }));
  await second;
  pending[0](JSON.stringify({ chapters: [{ index: 0, level: 1, title: '旧章节' }], activeIndex: 0 }));
  await first;
  assert.deepEqual(f.page.chapters, []);
  const jump = f.page.openChapter({ index: 0, level: 1, title: '旧章节' });
  f.page.aboutToDisappear();
  pending[2]('true');
  await jump;
  assert.equal(f.page.activeChapter, -1);
});

test('冲突和嵌入正文采用各自的版式并保留安全边界', () => {
  const fragment = '<p>原正文</p>';
  const document = presentation.orgDocumentPage(fragment, false, false, theme.UiColor.surface, 16, true);
  assert.ok(document.includes('script-src \'none\''));
  assert.ok(document.includes('<body class="file-reading">'));
  assert.ok(document.includes(fragment));
  const embedded = presentation.orgDocumentPage(fragment, false, true, theme.UiColor.surface, 16);
  assert.ok(embedded.includes('<body class="embedded">'));
  assert.ok(presentation.orgDocumentPage(fragment, false).includes('<body class="">'));
  assert.ok(presentation.orgDocumentPage('', true, false, theme.UiColor.surface, 16, true).includes('空白 Org 文件'));
  for (const invalid of [-1, 1.5, NaN, Infinity]) assert.equal(navigation.documentChapterScript(invalid), 'false');
});

test('冲突文件目录展开目标及其祖先并定位', () => {
  const ancestor = { open: false, matches: () => true, parentElement: null };
  let position;
  const target = { open: false, parentElement: ancestor, matches: () => true,
    scrollIntoView: options => { position = options; } };
  const document = { querySelectorAll: () => [target] };
  assert.equal(vm.runInNewContext(navigation.documentChapterScript(0), { document }), true);
  assert.equal(target.open, true);
  assert.equal(ancestor.open, true);
  assert.equal(position.block, 'start');
});

test('文档载入中切换相同正文的版本，完成回调仍只发布最新快照', () => {
  const loads = [], ready = [];
  const { Content } = load(base + 'components/OrgContentView.ets', {
    '@kit.ArkWeb': { webview: { WebviewController: class { loadData(data) { loads.push(decodeURIComponent(data)); } } } },
    '../ui/OrgDocumentPresentation': presentation,
    '../ui/Theme': theme,
    '../services/NativeCoreService': { coreErrorMessage: e => e.message },
    './LinkView': { LinkEditController: class {async finish(){return true}} }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? |@StorageLink\('[^']+'\) @Watch\('[^']+'\) /g, '')
    .replace('export struct OrgContentView', 'class Content') + '}\nmodule.exports = { Content };');
  const view = new Content();view.ready = () => ready.push(view.fragment);
  view.fragment = '<p>旧内容</p>';view.pageEnded();
  view.fragment = '<p>新内容</p>';view.documentChanged();
  view.pageEnded();assert.equal(ready.length, 0);assert.match(loads.at(-1), /新内容/);
  view.pageEnded();assert.deepEqual(ready, ['<p>新内容</p>']);
  view.revision = '2';view.documentChanged();view.pageEnded();
  assert.equal(ready.length, 2);
  view.aboutToDisappear();view.pageEnded();assert.equal(ready.length, 2);
});

test('任务区块仅版本变化不重载相同正文，正文改变仍加载，文档默认按版本刷新', () => {
  const loads = [];
  const { Content } = load(base + 'components/OrgContentView.ets', {
    '@kit.ArkWeb': { webview: { WebviewController: class { loadData(data) { loads.push(decodeURIComponent(data)); } } } },
    '../ui/OrgDocumentPresentation': presentation, '../ui/Theme': theme,
    '../services/NativeCoreService': { coreErrorMessage: e => e.message },
    './LinkView': { LinkEditController: class {} }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? |@StorageLink\('[^']+'\) @Watch\('[^']+'\) /g, '')
    .replace('export struct OrgContentView', 'class Content') + '}\nmodule.exports = { Content };');
  const view = new Content(); view.fragment = '<p>正文</p>'; view.pageEnded(); view.pageEnded();
  const initial = loads.length;
  view.reloadOnRevision = false; view.revision = '状态切换后的版本'; view.revisionChanged();
  assert.equal(loads.length, initial); assert.equal(view.loaded, true);
  view.fragment = '<p>真正修改正文</p>'; view.documentChanged();
  assert.equal(loads.length, initial + 1); assert.match(loads.at(-1), /真正修改正文/);
  view.pageEnded(); view.reloadOnRevision = true; view.revisionChanged();
  assert.equal(loads.length, initial + 2);
});

test('嵌入正文只在点击可编辑正文时进入编辑', async () => {
  let hit='true', opened=0;
  const { Content }=load(base+'components/OrgContentView.ets',{
    '@kit.ArkWeb':{webview:{WebviewController:class {async runJavaScript(){return hit;}}}},
    '../ui/OrgDocumentPresentation':presentation,'../ui/Theme':theme,
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message},'./LinkView':{LinkEditController:class {async finish(){return true}}}
  },source=>source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g,'')
    .replace('export struct OrgContentView','class Content')+'}\nmodule.exports={Content};');
  const view=new Content();view.loaded=true;view.widthVp=390;view.activate=()=>{opened++;};
  await view.activateAt(20,20);assert.equal(opened,0);
  hit='false';await view.activateAt(20,20);assert.equal(opened,1);
});

test('区块长按跳过链接与输入表单；切换快照或离开后忽略迟到命中', async () => {
  let field=false, linked=false, evaluate;
  const hits=[];
  const { Content }=load(base+'components/OrgContentView.ets',{
    '@kit.ArkWeb':{webview:{WebviewController:class {async runJavaScript(script){
      if(evaluate)return evaluate(script);
      return String(vm.runInNewContext(script,{window:{innerWidth:390},document:{
        querySelector:()=>field?{}:null,elementFromPoint:()=>({closest:()=>linked?{}:null})
      }}));
    }}}},
    '../ui/OrgDocumentPresentation':presentation,'../ui/Theme':theme,
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message},'./LinkView':{LinkEditController:class {static protectInteraction(){}}}
  },source=>source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g,'')
    .replace('export struct OrgContentView','class Content')+'}\nmodule.exports={Content};');
  const view=new Content();view.loaded=true;view.widthVp=390;view.contextMenu=(x,y)=>hits.push([x,y]);
  await view.contextMenuAt(10,20);assert.deepEqual(hits,[[10,20]]);
  linked=true;await view.contextMenuAt(11,21);linked=false;
  field=true;await view.contextMenuAt(12,22);field=false;
  assert.equal(hits.length,1);
  let finish;evaluate=()=>new Promise(resolve=>{finish=resolve;});
  const pending=view.contextMenuAt(13,23);view.documentGeneration++;finish('false');await pending;
  assert.equal(hits.length,1);
  const leaving=view.contextMenuAt(14,24);view.aboutToDisappear();finish('false');await leaving;
  assert.equal(hits.length,1);
});

test('正文长按触发区块菜单，抬手、滚动、取消与换快照均撤销待触发长按', async () => {
  const { Content }=load(base+'components/OrgContentView.ets',{
    '@kit.ArkWeb':{webview:{WebviewController:class {}}},
    '../ui/OrgDocumentPresentation':presentation,'../ui/Theme':theme,
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message},'./LinkView':{LinkEditController:class {static protectInteraction(){}}}
  },source=>source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g,'')
    .replace('export struct OrgContentView','class Content')+'}\nmodule.exports={Content};');
  const previous=global.TouchType;
  global.TouchType={Down:0,Up:1,Move:2,Cancel:3};
  try {
    const view=new Content(), hits=[];
    view.contextMenu=()=>{};view.contextMenuAt=(x,y)=>hits.push([x,y]);
    const event=(type,x=10,y=20)=>({type,changedTouches:[{x,y}]});
    view.touch(event(0));await new Promise(resolve=>setTimeout(resolve,520));
    assert.deepEqual(hits,[[10,20]]);
    view.touch(event(1));
    for(const cancel of [()=>view.touch(event(1)),()=>view.touch(event(2,30)),
      ()=>view.touch(event(3)),()=>view.documentChanged(),()=>view.aboutToDisappear()]){
      view.touch(event(0));assert.notEqual(view.pressTimer,-1);cancel();assert.equal(view.pressTimer,-1);
    }
    await new Promise(resolve=>setTimeout(resolve,520));assert.equal(hits.length,1);
  } finally { global.TouchType=previous; }
});

test('链接字段切换引起 Web 滚动后，不按旧坐标结束链接草稿或进入整段备注输入', async () => {
  let editing = true;
  let finished = 0, activated = 0, hitTests = 0;
  const { Content } = load(base + 'components/OrgContentView.ets', {
    '@kit.ArkWeb': { webview: { WebviewController: class {
      async runJavaScript(script) {
        return vm.runInNewContext(script, { document: {
          querySelector: () => editing ? {} : null,
          elementFromPoint() { hitTests++;return { closest: () => null }; }
        }, window: { innerWidth: 390 } });
      }
    } } },
    '../ui/OrgDocumentPresentation': presentation, '../ui/Theme': theme,
    '../services/NativeCoreService': { coreErrorMessage: e => e.message },
    './LinkView': { LinkEditController: class { async finish() { finished++;return true; } } }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? |@StorageLink\('[^']+'\) @Watch\('[^']+'\) /g, '')
    .replace('export struct OrgContentView', 'class Content') + '}\nmodule.exports = { Content };');
  const view = new Content();view.loaded = true;view.widthVp = 390;
  view.activate = () => { activated++; };
  await view.activateAt(20, 300);
  assert.equal(hitTests, 0);assert.equal(finished, 0);assert.equal(activated, 0);
  editing = false;
  await view.activateAt(20, 300);
  assert.equal(hitTests, 1);assert.equal(finished, 1);assert.equal(activated, 1);
});

test('长文档冲突卡片使用 Web 视口定位，保留浏览器滚动位置并展开父章节', async () => {
  const f=fixture();
  const browser={scrollY:0,scrollTo(x,y){this.scrollY=y;}};
  const parent={tagName:'DETAILS',open:false,parentElement:null};
  const card={dataset:{conflictCard:'far-card'},parentElement:parent,
    scrollIntoView(options){assert.equal(options.block,'start');browser.scrollY=240000;}};
  const document={querySelectorAll:()=>[card]};
  f.evaluate(async script=>String(vm.runInNewContext(script,{document,window:browser})));
  await f.page.focusConflictCard('far-card');
  assert.equal(browser.scrollY,240000);
  assert.equal(parent.open,true);
  assert.equal(await f.page.navigation.capturePosition(),240000);
  await f.page.navigation.restorePosition(123000);
  assert.equal(browser.scrollY,123000);
  await f.page.focusConflictCard('missing-card');
  assert.equal(browser.scrollY,123000);
  assert.deepEqual(f.toasts,[]);
});

function projectPageFixture() {
  let inlineActive = false;
  let open = async () => file();
  let end = async () => true;
  let capture = '{"open":["org-node-12"],"anchor":"org-node-12","offset":0,"scroll":80}';
  const file = (version = 'v1') => ({ fileVersion: version, hasConflict: false,
    nodes: () => [], title: () => '普通文档', titleParts: () => [], project: () => '项目', category: () => '工作', fileTags: () => ['project', 'todo', 'work'], headerEntries: () => [], specialTags: () => ['project', 'REFILE', 'ARCHIVE', 'CONFLICT', 'ATTACH'], documentSections: () => [{ path: null, html: '<p>完整文档</p>' }], sourceBytes: () => Buffer.from('项目原文'), renderDocumentHtml: () => '<p>完整文档</p>' });
  const { OrgFileDetail } = load(base + 'pages/OrgFileDetail.ets', {
    '../services/ReadingDataManager': {},
    '../ui/SyncLogPresentation': {},
    '../services/AppDataManager': { AppDataManager: { shared: () => ({ manager: {} }) } },
    '../services/DataManager': { DataManager: class {
      static create(context,page,definitions,options){assert.equal(definitions.length,3);assert.ok(options.parent);assert.ok(definitions.every(item=>item.query.query.includeFiles?.[0]?.path==='project.org'));assert.equal(options.cache,false);assert.equal(definitions[0].query.type,'task');assert.deepEqual(definitions[0].query.query.fullFiles,[{repoId:'core',path:'project.org'}]);return new this();}
      dataSet(){return this;}
      subscribeFiles(fn){this.fileListener=fn;return()=>this.fileListener=undefined;}
      async refreshFiles(){await this.refresh();await this.fileListener?.({name:'tasks',fullFiles:[this.file]});}
      get document(){return this.file?{file:this.file,tasks:this.file.nodes()}:undefined;}
      get data(){return this.getConfirmed().data;}
      get error(){return this.failure??'';}
      constructor(){this.listeners=new Set();this.identity=String(Math.random());}
      hasValidScope(){return true;}
      subscribe(fn){this.listeners.add(fn);return()=>this.listeners.delete(fn);}
      getFile(){return this.file;}
      snapshot(){return {optimistic:false};}
      getConfirmed(){return{data:{type:'task',result:{tasks:this.file?.nodes()??[]}}};}
      taskKey(id){return id;}
      async start(){await this.refresh();if(this.failure)throw new Error(this.failure);return[{name:'tasks',fullFiles:[this.file]}];}
      async refresh(){try{this.file=await open();this.failure='';for(const fn of this.listeners)fn({name:'tasks',type:'document'});}catch(error){this.failure=error.message;for(const fn of this.listeners)fn({name:'tasks',type:'error',message:error.message});}}
      async close(){}
    } },
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: value => Buffer.from(value).toString('utf8') }) } } },
    '../components/OrgFileHeader': {}, '../ui/OrgFileHeaderPresentation': projectHeader,
    '../ui/TaskTagFilterPresentation': tagFilter,
    '../services/FileTargetService': { configuredSpecialFileExclusions: () => ({ files: [], repositoryBindings: [] }) },
    '../components/AppShell': {}, '../components/controls/EmptyState': {},
    '../components/OrgFileDocumentView': { OrgFileDocumentNavigation: class {
      async captureReadingState() { return capture; } closePanel() { return false; }
    } },
    '../components/editors/OrgFileStructureSheet': { OrgFileStructureSheetController: class {} },
    '../ui/OrgFileStructurePresentation': projectStructure,
    '../ui/InternalLinkProcessor': internalLinkProcessors,
    '../services/AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'config', rootDirectory: '/repo', name: '仓库' }] }; } } },
    '../services/NotebookService': { NotebookService: { open: (...args) => open(...args) } },
    '../services/NativeCoreService': { coreErrorMessage: error => error.message,
      NativeCoreService: { async workspaceFor() { return { async repos() { return [{ id: 'core', rootDirectory: '/repo' }]; } }; } } },
    '../ui/Theme': theme, '../ui/OrgFileReadingPresentation': projectReading,
    '../services/TaskInlineService': { TaskInlineSession: { active:()=>inlineActive,end: (...args) => end(...args) } }
  }, source => source.split('  build()')[0].replace(/@Entry\n|@Component\n|@Builder\n|@State |@StorageLink\('[^']+'\) |@Watch\('[^']+'\) /g, '')
    .replace('struct OrgFileDetail', 'class OrgFileDetail') + '}\nmodule.exports = { OrgFileDetail };');
  const page = new OrgFileDetail(), routes = [];
  page.getUIContext = () => ({ getHostContext: () => ({}), getRouter: () => ({
    getParams: () => ({ repoId: 'core', path: 'project.org' }), replaceUrl: async route => routes.push(route), back: () => routes.push('back')
  }) });
  return { page, file, routes, setActive: value => { inlineActive = value; }, setOpen: fn => { open = fn; }, setEnd: fn => { end = fn; } };
}

test('项目标签切换先保存并收起任务，失败不切换，快速切换只采用最后请求', async () => {
  const f = projectPageFixture(), pending = [];
  f.page.refreshDocument = () => {};
  const matches = { error: '', setQuery: query => new Promise(resolve => pending.push({ query, resolve })) };
  f.page.dataManager = { dataSet: name => { assert.equal(name, 'matches'); return matches; } };
  f.setEnd(async collapse => { assert.equal(collapse, true); return false; });
  await f.page.selectTag('design');
  assert.deepEqual(f.page.selectedTags, []); assert.equal(pending.length, 0);
  f.setEnd(async collapse => { assert.equal(collapse, true); return true; });
  const first = f.page.selectTag('design'); await new Promise(resolve => setImmediate(resolve));
  const last = f.page.selectTag('unused'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(pending[0].query.query.expression, 't."design"');
  pending[0].resolve(); await first;
  assert.equal(f.page.filtering, true); assert.deepEqual(f.page.selectedTags, ['design', 'unused']);
  matches.error = '查询失败'; pending[1].resolve(); await last;
  assert.equal(f.page.filtering, false); assert.equal(f.page.filterMessage, '查询失败');
});

test('项目刷新保留同文件阅读位置，新文件版本更新文档与定位坐标', async () => {
  const f = projectPageFixture(); await f.page.refreshFile(); await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.page.content, '项目原文');
  const revision = f.page.renderRevision;
  await f.page.refreshFile(); await new Promise(resolve=>setImmediate(resolve));
  assert.match(f.page.readingState, /org-node-12/);
  assert.ok(f.page.renderRevision > revision);
  f.setOpen(async () => f.file('v2'));
  await f.page.refreshFile(); await new Promise(resolve=>setImmediate(resolve));
  assert.equal(JSON.parse(f.page.readingState).scroll,80);
  assert.ok(f.page.renderRevision > revision);
});

test('项目原文切换保留文档状态，刷新失败保留上次全文与错误', async () => {
  const f = projectPageFixture(); await f.page.loadFile(); await new Promise(resolve=>setImmediate(resolve));
  await f.page.toggleSource(); assert.equal(f.page.sourceMode, true);
  const reading = f.page.readingState;
  await f.page.toggleSource(); assert.equal(f.page.sourceMode, false);
  assert.equal(f.page.readingState, reading);
  f.setOpen(async () => { throw new Error('离线'); });
  await f.page.refreshFile(); await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.page.content, '项目原文');
  assert.equal(f.page.sections[0].html, '<p>完整文档</p>');
  assert.match(f.page.refreshMessage, /离线/);
  assert.equal(f.page.message, '');
});

test('项目重复出现复用管理对象，隐藏后迟到文件快照不更新文档',async()=>{
  const f=projectPageFixture();let resolve,reads=0;
  f.setOpen(()=>{reads++;return new Promise(done=>resolve=done)});
  const first=f.page.loadFile();await f.page.loadFile();assert.equal(reads,1);
  resolve(f.file('new'));await first;await new Promise(done=>setImmediate(done));
  assert.equal(f.page.fileVersion,'new');
  f.page.onPageHide();await f.page.applyFileState({snapshot:{file:f.file('late'),tasks:[]},message:''});
  assert.equal(f.page.fileVersion,'new');
});

test('项目页面离开时不再向可能销毁的 Web 发送阅读状态脚本', () => {
  const f = projectPageFixture();
  let captures = 0;
  f.page.navigation.captureReadingState = async () => { captures++; return ''; };
  const revision = f.page.loadRevision;
  f.page.onPageHide();
  assert.equal(captures, 0);
  assert.equal(f.page.loadRevision, revision + 1);
});

test('项目文件改为普通文件后沿用同一阅读页面，含冲突的项目仍展示快照', async () => {
  const f = projectPageFixture();
  f.setOpen(async () => ({ ...f.file(), project: () => null }));
  await f.page.loadFile(); await new Promise(resolve=>setImmediate(resolve)); assert.deepEqual(f.routes, []); assert.equal(f.page.title, '普通文档');
  f.setOpen(async () => ({ ...f.file(), hasConflict: true }));
  await f.page.refreshFile(); await new Promise(resolve=>setImmediate(resolve)); assert.equal(f.routes.length, 0);
  assert.equal(f.page.content, '项目原文');
  assert.equal(f.page.sections[0].html, '<p>完整文档</p>');
});

test('项目跳转等待草稿保存成功，失败保留页面，成功使用真实文件身份', async () => {
  const routes = [];
  let saved = false;
  const { OrgFileNavigation } = load(base + 'services/OrgFileNavigation.ets', {
    './TaskInlineService': { TaskInlineSession: { async end(collapse) { assert.equal(collapse, true); return saved; } } }
  });
  const context = { getRouter: () => ({ async pushUrl(route) { routes.push(route); } }), getPromptAction: () => ({ showToast() {} }) };
  assert.equal(await OrgFileNavigation.open(context, 'core', 'folder/project.org'), false);
  assert.deepEqual(routes, []);
  saved = true;
  assert.equal(await OrgFileNavigation.open(context, 'core', 'folder/project.org'), true);
  assert.deepEqual(routes, [{ url: 'pages/OrgFileDetail', params: { repoId: 'core', path: 'folder/project.org' } }]);
});

test('项目分段一次批量关联全部节点，保留重名标题与无状态章节', () => {
  const first = { fullPath: { repoId: 'r', file: 'p.org', titles: ['重名'], occurrence: 1 }, state: null };
  const second = { fullPath: { ...first.fullPath, occurrence: 2 }, state: { name: 'NEXT' } };
  let reads = 0;
  const file = { nodes() { reads++; return [first, second]; }, documentSections() { return [
    { path: null, html: '<p>前言</p>', blocks: [] }, { path: first.fullPath, html: '<table>章节</table>', blocks: [{ id: '1', kind: 'table', source: '| 章节 |', html: '<table>章节</table>', items: [] }] },
    { path: second.fullPath, html: '<p>任务正文</p>', blocks: [] }
  ]; } };
  const sections = projectReading.projectReadingSections(file);
  assert.equal(reads, 1);
  assert.equal(sections[0].node, null);
  assert.equal(sections[1].node, first);
  assert.equal(sections[2].node, second);
  assert.notEqual(sections[1].key, sections[2].key);
  assert.equal(sections[2].html, '<p>任务正文</p>');
  assert.equal(sections[1].blocks[0].kind, 'table');
  assert.equal(sections[1].blocks[0].source, '| 章节 |');
  assert.throws(() => projectReading.projectReadingSections({ ...file, nodes: () => [first] }), /版本不一致/);
  const tags = ['project', 'work', 'REFILE', 'ARCHIVE', 'CONFLICT', 'ATTACH', 'Project'];
  assert.deepEqual(projectReading.visibleProjectTags(tags, ['project', 'REFILE', 'ARCHIVE', 'CONFLICT', 'ATTACH']), ['work', 'Project']);
  assert.equal(tags.length, 7);
});

test('主动刷新等待任务草稿保存，失败保留当前快照且不读取文件', async () => {
  const f = projectPageFixture(); await f.page.loadFile(); await new Promise(resolve=>setImmediate(resolve));
  const snapshot = f.page.sections;
  let reads = 0, finish;
  f.setOpen(async () => { reads++; return f.file('v2'); });
  f.setEnd(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.page.refreshFile();
  assert.equal(reads, 0);
  finish(false); await pending;
  assert.equal(reads, 0); assert.equal(f.page.sections, snapshot);
  f.setEnd(async collapse => { assert.equal(collapse, true); return true; });
  await f.page.refreshFile();
  assert.equal(reads, 1); assert.equal(f.page.fileVersion, 'v2');
});

test('项目目录仅列普通章节，保留任务下的章节与重名路径，完整正文不变', () => {
  const section = (key, heading, state = null) => ({ key, html: `<p>${key} 正文</p>`, node: {
    heading, state, fullPath: { repoId: 'r', file: 'p.org', titles: key.split('/'), occurrence: 1 }
  } });
  const sections = [
    { key: 'preamble', node: null, html: '<p>前言</p>' },
    section('chapter', '实施'), section('task', '任务', { name: 'NEXT', category: 'Todo' }),
    section('task/chapter', '实施'), section('done', '完成', { name: 'FINISHED', category: 'Done' }),
    section('cancel', '取消', { name: 'CANCELLED', category: 'Cancel' }), section('literal', 'TODO 文字章节')
  ];
  const snapshot = JSON.stringify(sections);
  const outline = projectReading.projectOutlineSections(sections);
  assert.deepEqual(outline.map(item => item.key), ['chapter', 'task/chapter', 'literal']);
  assert.equal(outline[1], sections[3]);
  assert.equal(JSON.stringify(sections), snapshot);
  assert.deepEqual(projectReading.projectOutlineSections(sections.filter(item => item.node?.state)), []);
  assert.deepEqual(projectReading.projectOutlineSections([]), []);
});

function nativeProjectFixture() {
  let save = async () => true;
  const { View } = load(base + 'components/OrgFileDocumentView.ets', {
    '../services/PageDataSnapshot': load(base + 'services/PageDataSnapshot.ets'),
    '../ui/OrgFileReadingPresentation': projectReading,
    '../ui/OrgFileStructurePresentation': projectStructure,
    './OrgFileHeader': { OrgFileHeaderNavigation: class { close() { return false; } } },
    './controls/RightSwipe': swipeMenus,
    '../services/TaskInlineService': { TaskInlineSession: { end: (...args) => save(...args), active: () => false } }
  }, source => source.split('  @Builder\n')[0]
    .replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? |@StorageLink\('[^']+'\) @Watch\('[^']+'\) /g, '')
    .replace('export struct OrgFileDocumentView', 'class View') + '}\nmodule.exports = { View };');
  const view = new View(); view.aboutToAppear();
  function section(key, title, offset, linkTargets = [], occurrence = 1) {
    const fullPath = { repoId: 'r', file: 'p.org', titles: ['上级', title], occurrence };
    view.sections.push({ key, node: { fullPath, level: 2, property: () => null, editContent: { ownTags: [] } }, linkTargets });
    view.updateDocument();
    view.offsets.set(key, offset);
    return fullPath;
  }
  return { view, section, save: fn => { save = fn; } };
}

test('原生项目目录保存草稿后按完整路径定位，不改变任务卡片展开状态', async () => {
  const f = nativeProjectFixture(); f.view.outlineVisible = true;
  f.section('first-occurrence', '重名', 100);
  const path = f.section('second-occurrence', '重名', 300, [], 2);
  f.save(async collapse => { assert.equal(collapse, false); return true; });
  assert.equal(await f.view.navigation.locateSection({ ...path, file: 'other.org' }), false);
  assert.equal(await f.view.navigation.locateSection({ ...path, titles: ['其他上级', '重名'] }), false);
  assert.equal(await f.view.navigation.locateSection(path), true);
  assert.equal(f.view.scroller.lastScroll.yOffset, 288);
  assert.equal(f.view.outlineVisible, false);
  f.view.outlineVisible = true; f.save(async () => false);
  assert.equal(await f.view.navigation.locateSection(path), false);
  assert.equal(f.view.outlineVisible, true);
});

test('任务来源定位展开折叠父项并只提醒指定的同名任务', async () => {
  const { view, section } = nativeProjectFixture();
  section('parent', '章节', 90);
  const parent = view.sections[0].node;
  parent.level = 1;
  parent.property = name => name === 'VISIBILITY' ? 'folded' : null;
  section('first', '重名任务', 150);
  const target = section('second', '重名任务', 900, [], 2);
  for (const item of view.sections.slice(1)) item.node.state = { name: 'TODO' };
  view.updateDocument();
  assert.deepEqual(view.visibleKeys, ['parent']);
  view.focusTask = target;
  view.updateDocument();
  view.focusWhenLaidOut();
  assert.equal(view.attentionRow, '');
  view.viewportHeight = 300;
  view.contentHeight = 1200;
  view.focusWhenLaidOut();
  assert.equal(view.scroller.lastScroll.yOffset, 888);
  assert.equal(view.attentionRow, 'second');
  assert.deepEqual(view.visibleKeys, ['parent', 'first', 'second']);
  view.showing = false;
  view.visibilityChanged();
  assert.equal(view.attentionRow, '');
});

test('原生项目离开或切换版本后，迟到目录定位失效；切回正文恢复原位置', async () => {
  const f = nativeProjectFixture(); let finish;
  const path = f.section('old', '旧章节', 999);
  f.save(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.view.navigation.locateSection(path);
  f.view.revision = 'new'; f.view.snapshotChanged(); finish(true); assert.equal(await pending, false);
  assert.equal(f.view.scroller.lastScroll.yOffset, 0);
  assert.equal(f.view.offsets.size, 0);
  f.view.readingState = '{"scroll":345}'; f.view.showing = false; f.view.visibilityChanged();
  assert.equal(f.view.pendingOffset, 0);
  f.view.showing = true; f.view.visibilityChanged(); assert.equal(f.view.pendingOffset, 345);
  f.view.aboutToDisappear();
  assert.equal(f.view.active, false);
});

test('项目首次阅读等待布局完成后跳过文件头，后续高度变化不重设位置', () => {
  const f = nativeProjectFixture();
  f.view.headerHeight = 240; f.view.viewportHeight = 600;
  f.view.scheduleInitialOffset(); assert.equal(f.view.scroller.lastScroll, undefined);
  f.view.contentHeight = 1500; f.view.scheduleInitialOffset();
  assert.equal(f.view.scroller.lastScroll.yOffset, 240); assert.equal(f.view.initialOffsetApplied, true);
  f.view.headerHeight = 320; f.view.scheduleInitialOffset();
  assert.equal(f.view.scroller.lastScroll.yOffset, 240);
});

test('项目已有阅读位置包含页首零位置时，默认跳过文件头不覆盖用户位置', () => {
  for (const offset of [0, 345]) {
    const f = nativeProjectFixture(); f.view.readingState = JSON.stringify({ scroll: offset });
    f.view.snapshotChanged(); f.view.headerHeight = 240; f.view.viewportHeight = 600; f.view.contentHeight = 1500;
    f.view.scheduleInitialOffset(); assert.equal(f.view.scroller.lastScroll.yOffset, offset);
  }
});

test('项目正文不足一屏时，默认阅读偏移限制在可滚动范围', () => {
  for (const [height, expected] of [[750, 150], [500, 0]]) {
    const f = nativeProjectFixture(); f.view.headerHeight = 240; f.view.viewportHeight = 600; f.view.contentHeight = height;
    f.view.scheduleInitialOffset();
    assert.equal(f.view.scroller.lastScroll?.yOffset ?? 0, expected); assert.equal(f.view.initialOffsetApplied, true);
  }
});

test('标签窗口隐藏内部标签，修改普通互斥组仍保留原有项目和系统标记', async () => {
  const tagPresentation = load(base + 'ui/TaskTagsPresentation.ets');
  const { Dialog } = load(base + 'components/editors/TaskTagsDialog.ets', {
    '../../ui/TaskTagsPresentation': tagPresentation
  }, source => source.split('  @Builder\n')[0].replace(/@CustomDialog\n|@State /g, '')
    .replace('export struct TaskTagsDialog', 'class Dialog') + '}\nmodule.exports = { Dialog };');
  const dialog = new Dialog();
  dialog.ownTags = ['project', 'REFILE', 'ATTACH', 'home']; dialog.inheritedTags = ['ARCHIVE'];
  dialog.visibleTags = [...dialog.ownTags]; dialog.hiddenTags = ['project', 'REFILE', 'ARCHIVE', 'CONFLICT', 'ATTACH'];
  dialog.supportTags = { tags: ['work', 'home', 'project'], groups: [['work', 'home', 'project']] };
  let written; dialog.changed = modification => { assert.equal(modification.field, 'TAGS'); written = modification.value; };
  dialog.aboutToAppear();
  assert.deepEqual(dialog.names, ['work', 'home']); assert.deepEqual(dialog.selectedNames(), ['home']);
  await dialog.toggle('work');
  assert.ok(written.includes('project') && written.includes('REFILE') && written.includes('ATTACH') && written.includes('work'));
  assert.ok(!written.includes('home'));
  dialog.creating = true; dialog.name = 'CONFLICT'; await dialog.create();
  assert.match(dialog.message, /系统管理/); assert.ok(!written.includes('CONFLICT'));
});


test('项目返回先保存原位编辑，保存失败不离开页面', async () => {
  const f = projectPageFixture();
  f.setEnd(async collapse => { assert.equal(collapse, true); return false; });
  await f.page.leaveFile(); assert.deepEqual(f.routes, []);
  f.setEnd(async () => true); await f.page.leaveFile(); assert.deepEqual(f.routes, ['back']);
});

test('项目任务展开后可从更多菜单查看和收起日志，没有日志时隐藏入口', () => {
  const filename = base + 'components/editors/TaskEditor.ets';
  const logsPresentation = load(base + 'ui/TaskLogPresentation.ets');
  const { Card } = load(filename, { './TaskLogPresentation': logsPresentation }, source => {
    const start = source.indexOf('  moreItems():');
    const end = source.indexOf('  @Builder\n', start);
    return 'import { taskEventLogs } from "./TaskLogPresentation";\nconst LogShowPolicy = {LogShowBySwitch: \'LogShowBySwitch\', LogShowAlways: \'LogShowAlways\'};\nfunction $r(name: string): string { return name }\nexport class Card {\n' + source.slice(start, end) + '\n}';
  });
  const card = new Card();
  card.logShowPolicy = 'LogShowBySwitch';
  let logs = [{ type: 'taskStateChange', timestamp: '2026-11-14 09:00', from: 'TODO', to: 'DONE', noteHtml: '' }];
  card.readOnly = false; card.logbookExpanded = false;
  card.value = () => ({ logs });
  const show = card.moreItems().find(item => item.title === '日志');
  assert.ok(show);
  show.action(); assert.equal(card.logbookExpanded, true);
  const hide = card.moreItems().find(item => item.title === '日志');
  assert.notEqual(hide.icon, show.icon);
  hide.action(); assert.equal(card.logbookExpanded, false);
  logs = [{ type: 'taskNote', timestamp: '2026-11-14 09:00', noteHtml: '<p>任务备注</p>' }];
  assert.ok(!card.moreItems().some(item => item.title === '日志'));
  logs = [{ type: 'taskClosingNote', timestamp: '2026-11-14 09:00', noteHtml: '<p>完成说明</p>' }];
  assert.ok(!card.moreItems().some(item => item.title === '日志'));
  logs = [{ type: 'taskStateChange', timestamp: '2026-11-14 09:00', from: 'TODO', to: 'DONE', noteHtml: '' }];
  card.logShowPolicy = 'LogShowAlways'; assert.ok(!card.moreItems().some(item => item.title === '日志'));
  logs = []; assert.ok(!card.moreItems().some(item => item.title === '日志'));
});

test('项目完整文档通过管理对象快照更新，源码与章节使用同一版本',async()=>{
  const f=projectPageFixture();await f.page.loadFile();await new Promise(resolve=>setImmediate(resolve));
  f.page.sourceMode=true;
  f.setOpen(async()=>({...f.file('changed'),sourceBytes:()=>Buffer.from('* DONE 已完成'),documentSections:()=>[{path:null,html:'<p>完成后的正文与进度</p>'}]}));
  await f.page.refreshFile();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.page.content,'* DONE 已完成');assert.equal(f.page.sections[0].html,'<p>完成后的正文与进度</p>');
  assert.equal(f.page.fileVersion,'changed');
});

test('原生项目内部链接共用 Core 目标索引，优先定位专用目标并在保存失败时保持原位置', async () => {
  const f=nativeProjectFixture(), page=projectPageFixture().page;
  page.navigation=f.view.navigation;
  f.view.internalLinkProcessor=page.internalLinks;
  f.section('heading', '目标', 100, [{target:'目标',priority:2}]);
  f.section('named', '命名项', 200, [{target:'目标',priority:1}]);
  f.section('dedicated', '专用项', 400, [{target:'目标',priority:0}]);
  assert.equal(await page.internalLinks.isValid('目标'),true);
  assert.equal(await page.internalLinks.isValid('不存在'),false);
  await page.internalLinks.process('目标');assert.equal(f.view.scroller.lastScroll.yOffset,388);
  f.save(async()=>false);f.view.offsets.set('dedicated',600);
  await assert.rejects(page.internalLinks.process('目标'),/无法定位/);
  assert.equal(f.view.scroller.lastScroll.yOffset,388);
  f.view.aboutToDisappear();assert.equal(await page.internalLinks.isValid('目标'),false);
});

test('项目页面隐藏、原文模式及刷新期间禁用内部跳转，保存期间隐藏文档也不滚动', async () => {
  const f=nativeProjectFixture(), page=projectPageFixture().page;
  page.navigation=f.view.navigation;
  f.section('chapter', '章节', 400, [{target:'*章节',priority:2}]);
  for (const state of ['pageVisible','sourceMode','refreshing']) {
    const previous=page[state];
    page[state]=state!=='pageVisible';
    assert.equal(await page.internalLinks.isValid('*章节'),false);
    await assert.rejects(page.internalLinks.process('*章节'),/当前页面/);
    assert.equal(f.view.scroller.lastScroll,undefined);
    page[state]=previous;
  }
  let finish;
  f.save(()=>new Promise(resolve=>{finish=resolve;}));
  const pending=page.internalLinks.process('*章节');
  await new Promise(resolve=>setImmediate(resolve));f.view.showing=false;finish(true);
  await assert.rejects(pending,/无法定位/);
  assert.equal(f.view.scroller.lastScroll,undefined);
  assert.equal(await page.internalLinks.isValid('*章节'),false);
});


test('项目属性变化保留文档结构，新增删除与移动仅更新成员顺序', () => {
 const task=(id,title=id)=>({id,heading:title,fullPath:{repoId:'r',file:'p.org',titles:[title]},editContent:{blocks:[]}});
 const a=task('a'),b=task('b');const preamble={key:'preamble',node:null,blocks:[],linkTargets:[]};
 const sections=[preamble,{key:'a',node:a,blocks:[],linkTargets:[]},{key:'b',node:b,blocks:[],linkTargets:[]}];
 assert.equal(projectReading.reconcileProjectSections(sections,[{...a,heading:'修改属性',modifiedAt:123},b],t=>t.id),sections);
 const moved=projectReading.reconcileProjectSections(sections,[b,a],t=>t.id);assert.equal(moved[0],preamble);assert.equal(moved[1],sections[2]);assert.equal(moved[2],sections[1]);
 const replaced=projectReading.reconcileProjectSections(sections,[a,task('c')],t=>t.id);assert.equal(replaced[1],sections[1]);assert.equal(replaced[2].key,'c');
});

test('项目章节按稳定任务身份订阅，属性修改保留正文修订，正文变化仅更新当前章节', () => {
 const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);let active=false,listener,stopped=false;
 const {Section}=load(base+'components/OrgFileTaskSection.ets',{
  './TitleText': {},
  './controls/PopupMenuButton': {},
  './TaskSelectionRow': {},
  '../services/PageDataEquality':{samePageValue:equal},'../services/TaskInlineService':{TaskInlineSession:{active:()=>active}},
  '../ui/TaskActionPresentation':taskActions,
  '../ui/Theme':theme
 },source=>source.split('  build()')[0].replace(/@Component\n|@Builder\n|@State |@Prop |@StorageLink\('[^']+'\) |@Watch\('[^']+'\) /g,'').replace('export struct OrgFileTaskSection','class Section')+'}\nmodule.exports={Section};');
 const value=(body='正文',extra={})=>({id:'a',heading:'标题',modifiedAt:null,fileVersion:'v1',editContent:{blocks:[{id:'10',kind:'text',source:body,html:'<p>'+body+'</p>',paragraph:true,blankLinesBefore:0,items:[]}]},...extra});
 const source={task:value(),monitor(fn){listener=change=>{source.task=change.task;fn(change)};fn({task:source.task});return()=>stopped=true}};
 const section=new Section();section.taskId='stable-a';section.dataSet={taskSource(id){assert.equal(id,'stable-a');return source}};
 section.aboutToAppear();const revision=section.bodyRevision;
 listener({task:value('正文',{fileVersion:'v2',priority:{name:'A'}})});assert.equal(section.bodyRevision,revision);assert.equal(section.node.fileVersion,'v2');
 listener({task:value('新正文',{fileVersion:'v3'})});assert.equal(section.bodyRevision,revision+1);
 active=true;listener({task:value('编辑中外部修改',{fileVersion:'v4'})});assert.equal(section.node.fileVersion,'v3');active=false;section.inlineChanged();assert.equal(section.node.fileVersion,'v4');
 section.aboutToDisappear();assert.equal(stopped,true);
});


test('项目首次读取期间隐藏后再次显示会重新加载，不复用已丢弃的一次性文件', async () => {
 const f=projectPageFixture();let resolve,reads=0;
 f.setOpen(()=>{reads++;return reads===1?new Promise(done=>resolve=done):Promise.resolve(f.file('visible'));});
 const first=f.page.loadFile();f.page.onPageHide();resolve(f.file('hidden'));await first;assert.equal(f.page.fileVersion,'');
 f.page.onPageShow();await new Promise(done=>setImmediate(done));assert.equal(reads,2);assert.equal(f.page.fileVersion,'visible');assert.equal(f.page.refreshing,false);
});


test('文件头标签保留声明行、组边界与普通标签，隐藏候选不留下空行', () => {
  assert.deepEqual(projectHeader.projectHeaderRows([
    ['before', 'iOS', 'Android', 'after'], ['hidden'], ['BUG', 'FEAT']
  ], ['before', 'iOS', 'Android', 'after', 'BUG', 'FEAT'], [['iOS', 'Android'], ['BUG', 'FEAT']]), [
    [{ tags: ['before'], grouped: false }, { tags: ['iOS', 'Android'], grouped: true }, { tags: ['after'], grouped: false }],
    [{ tags: ['BUG', 'FEAT'], grouped: true }]
  ]);
  assert.equal(projectHeader.projectHeaderTitle('研发', '手机应用'), '研发 . 手机应用');
  assert.equal(projectHeader.projectHeaderTitle('', ''), '未命名项目');
});

test('项目分组标签切换与取消，所选标签整体取并集并交给 Core 求值', async () => {
  const f = projectPageFixture(), expressions = [];
  f.page.refreshDocument = () => {};
  f.page.tagGroups = [['iOS', 'Android'], ['BUG', 'FEAT']];
  f.page.dataManager = { dataSet: () => ({ error: '', async setQuery(query) { expressions.push(query.query.expression); } }) };
  for (const tag of ['iOS', 'Android', 'BUG', 'work', 'home', 'Android', 'BUG', 'work', 'home']) await f.page.selectTag(tag);
  assert.deepEqual(expressions, [
    't."iOS"', 't."Android"', 't."Android" or t."BUG"',
    't."Android" or t."BUG" or t."work"',
    't."Android" or t."BUG" or t."work" or t."home"',
    't."BUG" or t."work" or t."home"', 't."work" or t."home"', 't."home"', ''
  ]);
  await f.page.selectTag('iOS'); await f.page.selectTag('');
  assert.deepEqual(f.page.selectedTags, []);
  assert.equal(expressions.at(-1), '');
});

test('项目文件配置更新移除失效选择、采用新分组并刷新匹配，标题随分类更新', () => {
  const f = projectPageFixture(), expressions = [];
  f.page.fileVersion = 'v1'; f.page.selectedTags = ['removed', 'design', 'product'];
  const metadata = { category: '研发', projectName: '新项目', tagOptions: ['product', 'design'],
    tagGroups: [['product', 'design']], tagRows: [['product'], ['design']] };
  f.page.dataManager = { dataSet: () => ({ data: { type: 'file', result: [metadata] } }) };
  f.page.updateTagQuery = () => expressions.push(f.page.tagExpression());
  f.page.refreshDocument();
  assert.equal(f.page.title, '研发 . 新项目');
  assert.deepEqual(f.page.selectedTags, ['product']);
  assert.deepEqual(f.page.tagRows, [['product'], ['design']]);
  assert.deepEqual(expressions, ['t."product"']);
});

test('文件配置分行穿过元信息缓存，旧缓存恢复为单行', () => {
  const snapshots = load(base + 'services/PageDataSnapshot.ets', { './NativeCoreService': {} });
  const metadata = { tagOptions: ['a', 'b', 'c'], tagGroups: [['a', 'b']], tagRows: [['a', 'b'], ['c']],
    taskStateOf: () => null, taskPriorityOf: () => null };
  const record = JSON.parse(JSON.stringify(snapshots.metadataRecord(metadata)));
  assert.deepEqual(new snapshots.PageMetadataSnapshot(record).tagRows, [['a', 'b'], ['c']]);
  delete record.value.tagRows;
  assert.deepEqual(new snapshots.PageMetadataSnapshot(record).tagRows, [['a', 'b', 'c']]);
});

function headerEditorFixture() {
  class WriteError extends Error { constructor(message, committed) { super(message); this.committed = committed; } }
  const { Header } = load(base + 'components/OrgFileHeader.ets', {
    '@kit.ArkUI': {}, '@kit.BasicServicesKit': {}, '../services/NativeCoreService': {},
    '../ui/Theme': theme, '../services/DataSet': { DataSetWriteError: WriteError },
    '../services/TaskInlineService': { TaskInlineSession: { begin: async () => true, release() {} } }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop /g, '')
    .replace('export struct OrgFileHeader', 'class Header') + '}\nmodule.exports = { Header };');
  const header = new Header(), calls = [], dialogs = [];
  header.alive = true;
  header.getUIContext = () => ({ showAlertDialog: value => dialogs.push(value), getPromptAction: () => ({ showToast() {} }) });
  header.fileVersion = 'v1';
  header.headerEntries = [{ id: 'entry-v1', name: 'TITLE', keyword: true, value: '原值', tags: [], edit: { kind: 'text', protectedTags: [] } }];
  header.save = async (...args) => { calls.push(args); };
  return { header, calls, dialogs, WriteError };
}

test('属性编辑捕获原版本；外部更新保留草稿并拒绝旧版本保存，不自动改用新 ID', async () => {
  const { header, calls, dialogs } = headerEditorFixture();
  await header.openEditor();
  header.setText('entry-v1', '未保存草稿'); header.fileVersion = 'v2';
  header.headerEntries = [{ ...header.headerEntries[0], id: 'entry-v2', value: '外部更新' }];
  await header.submitEditor();
  assert.equal(header.draft('entry-v1').text, '未保存草稿'); assert.equal(header.editing, true);
  assert.equal(calls.length, 0); assert.match(header.message, /文件已更新/);
  header.closeEditor(); assert.equal(header.editing, true);
  dialogs[0].secondaryButton.action(); assert.equal(header.editing, false);
  await header.openEditor();
  header.setText('entry-v2', '本次修改'); await header.submitEditor();
  assert.deepEqual(calls, [[[{entryId:'entry-v2',value:{type:'text',value:'本次修改'}}], 'v2']]);
});

test('文件属性已提交后的确认错误不能导致再次提交；未修改关闭不产生写入', async () => {
  const { header, calls, WriteError } = headerEditorFixture();
  await header.openEditor(); await header.submitEditor(); assert.equal(calls.length, 0);
  await header.openEditor(); header.setText('entry-v1', '新值');
  header.save = async (...args) => { calls.push(args); throw new WriteError('确认失败', true); };
  await header.submitEditor(); assert.equal(header.saved, true); assert.match(header.message, /已保存/);
  await header.submitEditor(); assert.equal(calls.length, 1); assert.equal(header.editing, false);
});

test('整个属性区进入编辑，所有可编辑字段批量保存；未知字段保持只读', async () => {
  const { header, calls } = headerEditorFixture();
  header.headerEntries.push({id:'readonly',name:'UNKNOWN',value:'原样',edit:null});
  header.headerEntries.push({id:'category',name:'CATEGORY',value:'工作',tags:[],edit:{kind:'category',protectedTags:[]}});
  await header.openEditor();
  assert.equal(header.allowFilterClick(),false);
  assert.equal(header.entries().length,3);assert.equal(header.drafts.length,2);
  header.setText('entry-v1','新标题');header.setText('category','研发');
  await header.submitEditor();
  assert.deepEqual(calls,[[[{entryId:'entry-v1',value:{type:'text',value:'新标题'}},{entryId:'category',value:{type:'text',value:'研发'}}],'v1']]);
  assert.equal(header.editing,false);
});

test('TAGS 与 FILETAGS 原位增删，保护标签不可删除，正在输入的标签随保存提交', async () => {
  const { header,calls }=headerEditorFixture();
  header.headerEntries=[{id:'filetags',name:'FILETAGS',value:':project:todo:work:',tags:['project','todo','work'],edit:{kind:'fileTags',protectedTags:['project','todo']}},
    {id:'tags',name:'TAGS',value:'{ A(a) B(b) }',tags:['A','B'],edit:{kind:'tagConfig',protectedTags:[]}}];
  await header.openEditor();header.suppressClickUntil=0;
  header.removeTag('filetags','project');header.removeTag('filetags','todo');header.removeTag('filetags','work');
  assert.deepEqual(header.draft('filetags').tags,['project','todo']);
  header.setNewTag('filetags','home');header.addTag('filetags');header.setNewTag('filetags','home');header.addTag('filetags');
  header.removeTag('tags','B');header.setNewTag('tags','C');
  await header.submitEditor();
  assert.deepEqual(calls,[[[{entryId:'filetags',value:{type:'tags',value:['project','todo','home']}},{entryId:'tags',value:{type:'tags',value:['A','C']}}],'v1']]);
});

test('取消整个属性区编辑丢弃标签和文本草稿，不触发写入', async () => {
  const {header,calls,dialogs}=headerEditorFixture();await header.openEditor();
  header.setText('entry-v1','取消的草稿');header.closeEditor();dialogs[0].secondaryButton.action();
  assert.equal(header.editing,false);assert.equal(calls.length,0);
  await header.openEditor();assert.equal(header.draft('entry-v1').text,'原值');
});

test('属性编辑期间元信息版本持续更新，文档结构推迟到编辑结束刷新', () => {
 const f=projectPageFixture();f.page.fileVersion='v1';f.setActive(true);
 const metadata={headerEntries:[{id:'external',name:'TITLE',value:'外部标题'}],fileVersion:'v2',category:'新分类',projectName:'新项目',tagOptions:[],tagGroups:[],tagRows:[]};
 const oldSections=f.page.sections;
 f.page.dataManager={dataSet:()=>({data:{type:'file',result:[metadata]}})};
 f.page.refreshDocument();assert.equal(f.page.headerVersion,'v2');assert.equal(f.page.headerEntries,metadata.headerEntries);
 assert.equal(f.page.sections,oldSections);assert.equal(f.page.title,'');
 f.setActive(false);f.page.refreshDocument();assert.equal(f.page.title,'新分类 . 新项目');
});

test('返回优先交给属性原位编辑器，其次关闭目录', () => {
 const f=nativeProjectFixture();let calls=0;
 f.view.outlineVisible=true;f.view.headerNavigation.close=()=>{calls++;return true;};
 assert.equal(f.view.navigation.closePanel(),true);assert.equal(f.view.outlineVisible,true);assert.equal(calls,1);
 f.view.headerNavigation.close=()=>false;
 assert.equal(f.view.navigation.closePanel(),true);assert.equal(f.view.outlineVisible,false);
});

test('加号只建立原位输入草稿，切换声明先收起前一标签，空值和重复值不新增', async () => {
 const {header,calls}=headerEditorFixture();
 header.headerEntries=[{id:'a',name:'TAGS',value:'A',tags:['A'],edit:{kind:'tagConfig',protectedTags:[]}},
   {id:'b',name:'FILETAGS',value:':project:',tags:['project'],edit:{kind:'fileTags',protectedTags:['project']}}];
 await header.openEditor();header.startTag('a');
 assert.equal(header.creatingTagId,'a');assert.equal(header.dirty(),false);assert.equal(calls.length,0);
 header.setNewTag('a','B');header.startTag('b');
 assert.equal(header.creatingTagId,'b');assert.deepEqual(header.draft('a').tags,['A','B']);
 header.addTag('b');assert.equal(header.creatingTagId,'');assert.deepEqual(header.draft('b').tags,['project']);
 header.startTag('a');header.setNewTag('a','B');header.addTag('a');assert.deepEqual(header.draft('a').tags,['A','B']);
 header.startTag('b');header.setNewTag('b','new');await header.submitEditor();
 assert.deepEqual(calls,[[[{entryId:'a',value:{type:'tags',value:['A','B']}},{entryId:'b',value:{type:'tags',value:['project','new']}}],'v1']]);
 assert.equal(header.creatingTagId,'');
});


test('项目属性编辑期间父级分类候选继续更新，不覆盖本地编辑状态或触发查询',()=>{
 const f=projectPageFixture();f.page.fileVersion='v1';f.page.repoId='core';f.setActive(true);
 f.page.dataManager={dataSet:name=>({data:name==='categories'?{type:'file',result:[
  {repoId:'core',category:'新增分类'},{repoId:'core',category:'新增分类'},{repoId:'other',category:'其他仓库'}
 ]}:{type:'file',result:[]}})};
 const sections=f.page.sections;f.page.refreshDocument();assert.deepEqual(f.page.categoryOptions,['新增分类']);
 assert.equal(f.page.sections,sections);assert.equal(f.page.title,'');
});

test('项目单章节保存直接读取来源最新版本，删除通知清除节点且退出取消 Monitor', async()=>{
 let callback,cancelled=false;const source={task:{fileVersion:'v1',editContent:{blocks:[]}},monitor(fn){callback=fn;fn({task:this.task});return()=>cancelled=true}};
 const {Section}=load(base+'components/OrgFileTaskSection.ets',{
  './TitleText': {},
  './controls/PopupMenuButton': {}, './TaskSelectionRow': {},
  '../ui/TaskActionPresentation':taskActions,
  '../services/TaskInlineService':{TaskInlineSession:{active:()=>false}},'../ui/Theme':theme
 },text=>text.split('  build()')[0].replace(/@Component\n|@Builder\n|@State |@Prop |@StorageLink\('[^']+'\) |@Watch\('[^']+'\) /g,'').replace('export struct OrgFileTaskSection','class Section')+'}\nmodule.exports={Section};');
 const section=new Section(),writes=[];section.taskId='row';section.dataSet={taskSource:()=>source,async updateTask(...args){writes.push(args);return source.task}};
 section.aboutToAppear();source.task={...source.task,fileVersion:'v2'};
 assert.equal(section.node.fileVersion,'v1');await section.modify([{field:'PRIORITY',value:'A'}]);assert.equal(writes[0][2],'v2');
 source.task=undefined;callback({removed:true});assert.equal(section.node,undefined);await assert.rejects(section.modify([]),/已移除/);
 section.aboutToDisappear();assert.equal(cancelled,true);
});

test('项目普通任务事件不重算章节与全文，结构事件才归并成员', async()=>{
 const f=projectPageFixture();await f.page.loadFile();const manager=f.page.dataManager;
 const sections=f.page.sections;f.page.matchedIds=[];
 for(const fn of manager.listeners)fn({type:'update',added:[],removed:[],updated:['a'],structureChanged:false});
 assert.equal(f.page.sections,sections);assert.equal(f.page.structurePending,false);assert.equal(f.page.linkSnapshotDirty,true);
 for(const fn of manager.listeners)fn({type:'refresh',added:['a'],removed:[],updated:[],structureChanged:true});
 assert.equal(f.page.structurePending,false);assert.equal(f.page.fileVersion,'v1');
});

test('项目链接索引按需确认不重建阅读会话，普通任务事件只标记待确认',async()=>{
 const f=projectPageFixture();await f.page.loadFile();const revision=f.page.renderRevision,session=f.page.documentSession;
 for(const fn of f.page.dataManager.listeners)fn({type:'update',added:[],removed:[],updated:['a'],structureChanged:false});
 f.setOpen(async()=>({...f.file('v2'),documentSections:()=>[{path:null,html:'最新链接索引',blocks:[],linkTargets:[{target:'新目标',priority:0}]}]}));
 assert.equal(await f.page.ensureLinkSnapshot(),true);assert.equal(f.page.sections[0].linkTargets[0].target,'新目标');
 assert.equal(f.page.renderRevision,revision);assert.equal(f.page.documentSession,session);assert.equal(f.page.content,'项目原文');
 assert.equal(f.page.linkSnapshotDirty,false);
});

test('项目完整恢复等待排队修改确认，旧版本完整文件不能覆盖新任务',async()=>{
 const f=projectPageFixture();await f.page.loadFile();const manager=f.page.dataManager;
 f.page.pendingFile={file:f.file('v2'),tasks:[]};manager.snapshot=()=>({optimistic:true});
 await f.page.applyPendingFile();assert.ok(f.page.pendingFile);assert.equal(f.page.fileVersion,'v1');
 manager.snapshot=()=>({optimistic:false});await f.page.applyPendingFile();assert.equal(f.page.fileVersion,'v2');
 let refreshes=0;manager.refreshFiles=async()=>{refreshes++};
 manager.file={...f.file('v3'),nodes:()=>[{fileVersion:'v3'}]};f.page.pendingFile={file:f.file('v2'),tasks:[]};
 await f.page.applyPendingFile();assert.equal(refreshes,1);assert.equal(f.page.fileVersion,'v2');assert.equal(f.page.pendingFile,undefined);
});
