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
    assert.ok(name in mocks, `缺少替身：${name}`);
    return mocks[name];
  }, module, module.exports, class { scrollTo(value) { this.lastScroll = value; } currentOffset() { return { xOffset: 0, yOffset: this.lastScroll?.yOffset ?? 0 }; } });
  return module.exports;
}
const base = 'entry/src/main/ets/';
const navigation = load(base + 'ui/OrgDocumentNavigation.ets');
const projectPresentation = load(base + 'ui/ProjectDocumentPresentation.ets');
const projectReading = load(base + 'ui/ProjectReadingPresentation.ets');
const theme = load(base + 'ui/Theme.ets');
const presentation = load(base + 'ui/OrgDocumentPresentation.ets', { './Theme': theme });
function fixture() {
  const calls = [], toasts = [];
  let evaluate = async () => JSON.stringify({ chapters: [{ index: 0, level: 1, title: '章节' }], activeIndex: 0 });
  const { FileDetail } = load(base + 'components/OrgFilePreviewView.ets', {
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: value => Buffer.from(value).toString('utf8') }) } } },
    '@kit.ArkWeb': { webview: { WebviewController: class { async runJavaScript(script) { calls.push(script); return evaluate(script); } } } },
    '../services/AppConfigService': {},
    '../services/NotebookService': {},
    '../services/NativeCoreService': { coreErrorMessage: error => error.message },
    '../ui/SyncLogPresentation': {},
    '../ui/Theme': theme,
    '../ui/OrgDocumentNavigation': navigation,
    '../ui/ProjectDocumentPresentation': projectPresentation
  }, source => source.split('  @Builder\n')[0].replace(/@Entry\n|@Component\n|@State |@BuilderParam |@Prop(?: @Watch\('[^']+'\))? /g, '')
    .replace('export struct OrgFilePreviewView', 'class FileDetail') + '}\nmodule.exports = { FileDetail };');
  const page = new FileDetail();
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
  assert.equal(f.page.content, '');
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

test('原文和尚未加载的页面不执行阅读 DOM 操作', async () => {
  const f = fixture();
  f.page.displayMode = 'source';
  await f.page.openOutline();
  await f.page.expandAll(false);
  f.page.displayMode = 'rendered';
  f.page.renderReady = false;
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
  assert.equal(f.page.content, '');
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

test('正文包装保留安全边界，路径按文本转义，新版式只在文件阅读启用', () => {
  const fragment = '<p>原正文</p>';
  const context = '<script>alert(1)</script> & 仓库';
  const document = presentation.orgDocumentPage(fragment, false, false, theme.UiColor.surface, 16, true, context);
  assert.ok(document.includes('script-src \'none\''));
  assert.ok(document.includes('<body class="file-reading">'));
  assert.ok(document.includes('&lt;script&gt;alert(1)&lt;/script&gt; &amp; 仓库'));
  assert.ok(document.includes(fragment));
  const embedded = presentation.orgDocumentPage(fragment, false, true, theme.UiColor.surface, 16, true, context);
  assert.ok(embedded.includes('<body class="embedded">'));
  assert.ok(!embedded.includes('<div class="file-context">'));
  assert.ok(presentation.orgDocumentPage(fragment, false).includes('<body class="">'));
  assert.ok(presentation.orgDocumentPage('', true, false, theme.UiColor.surface, 16, true).includes('空白 Org 文件'));
  for (const invalid of [-1, 1.5, NaN, Infinity]) assert.equal(navigation.documentChapterScript(invalid), 'false');
});

test('项目目录只定位标题，不改变当前任务或祖先的展开状态', () => {
  const ancestor = { open: false, matches: () => true, parentElement: null };
  let position;
  const target = { open: false, parentElement: ancestor, matches: () => true,
    scrollIntoView: options => { position = options; } };
  const document = { querySelectorAll: () => [target] };
  assert.equal(vm.runInNewContext(navigation.documentChapterScript(0, true), { document }), true);
  assert.equal(target.open, false);
  assert.equal(ancestor.open, false);
  assert.equal(position.block, 'start');
  assert.equal(vm.runInNewContext(navigation.documentChapterScript(0), { document }), true);
  assert.equal(target.open, true);
  assert.equal(ancestor.open, true);
});

test('原文变化定位使用当前快照坐标，切换快照清除旧坐标', async () => {
  const f = fixture();f.page.displayMode = 'source';
  f.page.sourceOffsets.set(1, 284);
  await f.page.focusChange(1);
  assert.deepEqual(f.page.sourceScroller.lastScroll, { xOffset: 0, yOffset: 284, animation: false });
  assert.deepEqual(f.calls, []);
  f.page.snapshotChanged();
  assert.equal(f.page.sourceOffsets.size, 0);
});

test('文档载入中切换相同正文的版本，完成回调仍只发布最新快照', () => {
  const loads = [], ready = [];
  const { Content } = load(base + 'components/OrgContentView.ets', {
    '@kit.ArkWeb': { webview: { WebviewController: class { loadData(data) { loads.push(decodeURIComponent(data)); } } } },
    '../ui/OrgDocumentPresentation': presentation,
    '../ui/Theme': theme,
    '../services/NativeCoreService': { coreErrorMessage: e => e.message },
    './LinkView': { LinkEditController: class {async finish(){return true}} }
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g, '')
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

test('正文带详情卡时在原生滚动容器中定位，离开后的旧定位不会滚动新快照', async () => {
  const f=fixture();f.page.flowContent=true;f.page.contentWidth=390;f.page.viewportHeight=600;
  f.page.footerOffset=900;f.evaluate(async()=> '2');
  await f.page.focusChange(0);
  assert.deepEqual(f.page.sourceScroller.lastScroll,{xOffset:0,yOffset:660,animation:false});
  assert.ok(!f.calls.at(-1).includes('scrollIntoView'));
  let release;f.evaluate(()=>new Promise(resolve=>release=resolve));const pending=f.page.focusChange(0);
  f.page.snapshotChanged();release('9');await pending;
  assert.equal(f.page.sourceScroller.lastScroll.yOffset,660);
  f.page.focusFooter();assert.equal(f.page.sourceScroller.lastScroll.yOffset,690);
  assert.equal(await f.page.navigation.capturePosition(),690);
});

test('原文与详情卡共用滚动位置；缺少变化锚点时定位详情卡', async () => {
  const f=fixture();f.page.flowContent=true;f.page.displayMode='source';f.page.viewportHeight=600;f.page.footerOffset=900;
  f.page.changes={changes:[{after:{start:{line:4}}}]};f.page.lineOffsets.set(3,128);
  await f.page.focusChange(0);assert.equal(f.page.sourceScroller.lastScroll.yOffset,128);
  f.page.snapshotChanged();assert.equal(f.page.lineOffsets.size,0);
  await f.page.focusChange(0);assert.equal(f.page.sourceScroller.lastScroll.yOffset,690);
  assert.deepEqual(f.calls,[]);
});

test('正文随外层滚动时仍保持整篇阅读版式和安全边界', () => {
  const doc=presentation.orgDocumentPage('<p>正文</p>',false,true,theme.UiColor.surface,16,true,'',true);
  assert.ok(doc.includes('<body class="file-reading">'));
  assert.ok(doc.includes("script-src 'none'"));
  const task=presentation.orgDocumentPage('<p>任务</p>',false,true,theme.UiColor.surface,16,true);
  assert.ok(task.includes('<body class="embedded">'));
});

test('嵌入正文点击链接或折叠标题时不进入编辑，正文区域可以选中节点', async () => {
  let hit='true';const selected=[];
  const { Content }=load(base+'components/OrgContentView.ets',{
    '@kit.ArkWeb':{webview:{WebviewController:class {async runJavaScript(script){return script.includes('const action =')?hit:'0';}}}},
    '../ui/OrgDocumentPresentation':presentation,'../ui/Theme':theme,
    '../services/NativeCoreService':{coreErrorMessage:e=>e.message},'./LinkView':{LinkEditController:class {async finish(){return true}}}
  },source=>source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g,'')
    .replace('export struct OrgContentView','class Content')+'}\nmodule.exports={Content};');
  const view=new Content();view.loaded=true;view.widthVp=390;view.nodeActivated=index=>selected.push(index);
  await view.activateAt(20,20);assert.deepEqual(selected,[]);
  hit='false';await view.activateAt(20,20);assert.deepEqual(selected,[0]);
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
  }, source => source.split('  @Builder\n')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g, '')
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
  assert.equal(f.page.sourceScroller.lastScroll,undefined);
  assert.equal(f.page.contentMeasureRevision,0);
  assert.equal(await f.page.navigation.capturePosition(),240000);
  await f.page.navigation.restorePosition(123000);
  assert.equal(browser.scrollY,123000);
  await f.page.focusConflictCard('missing-card');
  assert.equal(browser.scrollY,123000);
  assert.deepEqual(f.toasts,[]);
});

function projectPageFixture() {
  let open = async () => file();
  let end = async () => true;
  let capture = '{"open":["org-node-12"],"anchor":"org-node-12","offset":0,"scroll":80}';
  const file = (version = 'v1') => ({ fileVersion: version, hasConflict: false,
    nodes: () => [], project: () => '项目', category: () => '工作', fileTags: () => ['project', 'work'], specialTags: () => ['project', 'REFILE', 'ARCHIVE', 'CONFLICT'], documentSections: () => [{ path: null, html: '<p>完整文档</p>' }], sourceBytes: () => Buffer.from('项目原文'), renderDocumentHtml: () => '<p>完整文档</p>' });
  const { ProjectDetail } = load(base + 'pages/ProjectDetail.ets', {
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: value => Buffer.from(value).toString('utf8') }) } } },
    '../components/AppShell': {}, '../components/Controls': {},
    '../components/OrgFilePreviewView': { OrgFilePreviewNavigation: class {
      async captureReadingState() { return capture; } closePanel() { return false; }
    } },
    '../services/AppConfigService': { AppConfigService: { async load() { return { repos: [{ id: 'config', rootDirectory: '/repo', name: '仓库' }] }; } } },
    '../services/NotebookService': { NotebookService: { open: (...args) => open(...args) } },
    '../services/NativeCoreService': { coreErrorMessage: error => error.message,
      NativeCoreService: { async workspaceFor() { return { async repos() { return [{ id: 'core', rootDirectory: '/repo' }]; } }; } } },
    '../ui/Theme': theme, '../ui/ProjectReadingPresentation': projectReading,
    '../services/TaskInlineService': { TaskInlineSession: { end: (...args) => end(...args) } }
  }, source => source.split('  build()')[0].replace(/@Entry\n|@Component\n|@State /g, '')
    .replace('struct ProjectDetail', 'class ProjectDetail') + '}\nmodule.exports = { ProjectDetail };');
  const page = new ProjectDetail(), routes = [];
  page.getUIContext = () => ({ getHostContext: () => ({}), getRouter: () => ({
    getParams: () => ({ repoId: 'core', path: 'project.org' }), replaceUrl: async route => routes.push(route), back: () => routes.push('back')
  }) });
  return { page, file, routes, setOpen: fn => { open = fn; }, setEnd: fn => { end = fn; } };
}

test('项目刷新保持同版本阅读状态，新版本清除旧展开锚点', async () => {
  const f = projectPageFixture(); await f.page.loadFile();
  assert.equal(f.page.content, '项目原文');
  const revision = f.page.renderRevision;
  await f.page.loadFile();
  assert.match(f.page.readingState, /org-node-12/);
  assert.equal(f.page.renderRevision, revision);
  f.setOpen(async () => f.file('v2'));
  await f.page.loadFile();
  assert.equal(f.page.readingState, '');
  assert.ok(f.page.renderRevision > revision);
});

test('项目原文切换保留文档状态，刷新失败保留上次全文与错误', async () => {
  const f = projectPageFixture(); await f.page.loadFile();
  await f.page.toggleSource(); assert.equal(f.page.sourceMode, true);
  const reading = f.page.readingState;
  await f.page.toggleSource(); assert.equal(f.page.sourceMode, false);
  assert.equal(f.page.readingState, reading);
  f.setOpen(async () => { throw new Error('离线'); });
  await f.page.loadFile();
  assert.equal(f.page.content, '项目原文');
  assert.equal(f.page.sections[0].html, '<p>完整文档</p>');
  assert.match(f.page.refreshMessage, /离线/);
  assert.equal(f.page.message, '');
});

test('项目读取迟到或页面退出，不覆盖最新文档', async () => {
  const f = projectPageFixture(), pending = [];
  f.setOpen(() => new Promise(resolve => pending.push(resolve)));
  const first = f.page.loadFile(), second = f.page.loadFile();
  await new Promise(resolve => setImmediate(resolve));
  pending[1](f.file('new')); await second;
  const revision = f.page.renderRevision;
  pending[0](f.file('old')); await first;
  assert.equal(f.page.fileVersion, 'new');
  assert.equal(f.page.renderRevision, revision);
  const third = f.page.loadFile();
  await new Promise(resolve => setImmediate(resolve));
  f.page.onPageHide(); pending[2](f.file('late')); await third;
  assert.equal(f.page.fileVersion, 'new');
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

test('项目文件改为普通文件时跳转，含冲突的项目仍展示文档快照', async () => {
  const f = projectPageFixture();
  f.setOpen(async () => ({ ...f.file(), project: () => null }));
  await f.page.loadFile(); assert.equal(f.routes[0].url, 'pages/FileDetail');
  f.setOpen(async () => ({ ...f.file(), hasConflict: true }));
  await f.page.loadFile(); assert.equal(f.routes.length, 1);
  assert.equal(f.page.content, '项目原文');
  assert.equal(f.page.sections[0].html, '<p>完整文档</p>');
});

test('项目跳转等待草稿保存成功，失败保留页面，成功使用真实文件身份', async () => {
  const routes = [];
  let saved = false;
  const { ProjectNavigation } = load(base + 'services/ProjectNavigation.ets', {
    './TaskInlineService': { TaskInlineSession: { async end(collapse) { assert.equal(collapse, true); return saved; } } }
  });
  const context = { getRouter: () => ({ async pushUrl(route) { routes.push(route); } }), getPromptAction: () => ({ showToast() {} }) };
  assert.equal(await ProjectNavigation.open(context, 'core', 'folder/project.org'), false);
  assert.deepEqual(routes, []);
  saved = true;
  assert.equal(await ProjectNavigation.open(context, 'core', 'folder/project.org'), true);
  assert.deepEqual(routes, [{ url: 'pages/ProjectDetail', params: { repoId: 'core', path: 'folder/project.org' } }]);
});

test('项目分段一次批量关联全部节点，保留重名标题与无状态章节', () => {
  const first = { fullPath: { repoId: 'r', file: 'p.org', titles: ['重名'], occurrence: 1 }, state: null };
  const second = { fullPath: { ...first.fullPath, occurrence: 2 }, state: { name: 'NEXT' } };
  let reads = 0;
  const file = { nodes() { reads++; return [first, second]; }, documentSections() { return [
    { path: null, html: '<p>前言</p>' }, { path: first.fullPath, html: '<table>章节</table>' },
    { path: second.fullPath, html: '<p>任务正文</p>' }
  ]; } };
  const sections = projectReading.projectReadingSections(file);
  assert.equal(reads, 1);
  assert.equal(sections[0].node, null);
  assert.equal(sections[1].node, first);
  assert.equal(sections[2].node, second);
  assert.notEqual(sections[1].key, sections[2].key);
  assert.equal(sections[2].html, '<p>任务正文</p>');
  assert.throws(() => projectReading.projectReadingSections({ ...file, nodes: () => [first] }), /版本不一致/);
  const tags = ['project', 'work', 'REFILE', 'ARCHIVE', 'CONFLICT', 'Project'];
  assert.deepEqual(projectReading.visibleProjectTags(tags, ['project', 'REFILE', 'ARCHIVE', 'CONFLICT']), ['work', 'Project']);
  assert.equal(tags.length, 6);
});

test('主动刷新等待任务草稿保存，失败保留当前快照且不读取文件', async () => {
  const f = projectPageFixture(); await f.page.loadFile();
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

function nativeProjectFixture() {
  let save = async () => true;
  const { View } = load(base + 'components/ProjectDocumentView.ets', {
    './OrgFilePreviewView': { OrgFilePreviewNavigation: class {} },
    '../services/TaskInlineService': { TaskInlineSession: { end: (...args) => save(...args) } }
  }, source => source.split('  @Builder\n')[0]
    .replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g, '')
    .replace('export struct ProjectDocumentView', 'class View') + '}\nmodule.exports = { View };');
  const view = new View(); view.aboutToAppear();
  return { view, save: fn => { save = fn; } };
}

test('原生项目目录保存草稿后按完整路径定位，不改变任务卡片展开状态', async () => {
  const f = nativeProjectFixture(); f.view.outlineVisible = true;
  f.view.offsets.set('second-occurrence', 300);
  f.save(async collapse => { assert.equal(collapse, false); return true; });
  await f.view.openChapter({ key: 'second-occurrence' });
  assert.equal(f.view.scroller.lastScroll.yOffset, 288);
  assert.equal(f.view.outlineVisible, false);
  f.view.outlineVisible = true; f.save(async () => false);
  await f.view.openChapter({ key: 'second-occurrence' });
  assert.equal(f.view.outlineVisible, true);
});

test('原生项目离开或切换版本后，迟到目录定位失效；切回正文恢复原位置', async () => {
  const f = nativeProjectFixture(); let finish;
  f.view.offsets.set('old', 999); f.save(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.view.openChapter({ key: 'old' });
  f.view.revision = 'new'; f.view.snapshotChanged(); finish(true); await pending;
  assert.equal(f.view.scroller.lastScroll.yOffset, 0);
  assert.equal(f.view.offsets.size, 0);
  f.view.readingState = '{"scroll":345}'; f.view.showing = false; f.view.visibilityChanged();
  assert.equal(f.view.pendingOffset, 0);
  f.view.showing = true; f.view.visibilityChanged(); assert.equal(f.view.pendingOffset, 345);
  f.view.aboutToDisappear();
  assert.equal(f.view.active, false);
});

test('标签窗口隐藏内部标签，修改普通互斥组仍保留原有项目和系统标记', async () => {
  const tagPresentation = load(base + 'ui/TaskTagsPresentation.ets');
  const { Dialog } = load(base + 'components/TaskTagsDialog.ets', {
    '../ui/TaskTagsPresentation': tagPresentation
  }, source => source.split('  @Builder\n')[0].replace(/@CustomDialog\n|@State /g, '')
    .replace('export struct TaskTagsDialog', 'class Dialog') + '}\nmodule.exports = { Dialog };');
  const dialog = new Dialog();
  dialog.ownTags = ['project', 'REFILE', 'home']; dialog.inheritedTags = ['ARCHIVE'];
  dialog.visibleTags = [...dialog.ownTags]; dialog.hiddenTags = ['project', 'REFILE', 'ARCHIVE', 'CONFLICT'];
  dialog.supportTags = { tags: ['work', 'home', 'project'], groups: [['work', 'home', 'project']] };
  let written; dialog.change = async tags => { written = tags; return true; };
  dialog.aboutToAppear();
  assert.deepEqual(dialog.names, ['work', 'home']); assert.deepEqual(dialog.selectedNames(), ['home']);
  await dialog.toggle('work');
  assert.ok(written.includes('project') && written.includes('REFILE') && written.includes('work'));
  assert.ok(!written.includes('home'));
  dialog.creating = true; dialog.name = 'CONFLICT'; await dialog.create();
  assert.match(dialog.message, /系统管理/); assert.ok(!written.includes('CONFLICT'));
});


test('项目返回先保存原位编辑，保存失败不离开页面', async () => {
  const f = projectPageFixture();
  f.setEnd(async collapse => { assert.equal(collapse, true); return false; });
  await f.page.leaveProject(); assert.deepEqual(f.routes, []);
  f.setEnd(async () => true); await f.page.leaveProject(); assert.deepEqual(f.routes, ['back']);
});

test('项目任务展开后可从更多菜单查看和收起日志，没有日志时隐藏入口', () => {
  const filename = base + 'components/TaskListItem.ets';
  const { Card } = load(filename, {}, source => {
    const start = source.indexOf('  moreItems():');
    const end = source.indexOf('  @Builder\n  attributes()', start);
    return 'function $r(name: string): string { return name }\nexport class Card {\n' + source.slice(start, end) + '\n}';
  });
  const card = new Card();
  let logs = [{ type: 'taskNote', timestamp: '2026-11-14 09:00', noteHtml: '<p>任务日志</p>' }];
  card.documentMode = true; card.readOnly = false; card.logbookExpanded = false;
  card.value = () => ({ logs });
  const show = card.moreItems().find(item => item.title === '日志');
  assert.ok(show);
  show.action(); assert.equal(card.logbookExpanded, true);
  const hide = card.moreItems().find(item => item.title === '日志');
  assert.notEqual(hide.icon, show.icon);
  hide.action(); assert.equal(card.logbookExpanded, false);
  logs = []; assert.ok(!card.moreItems().some(item => item.title === '日志'));
});

function projectDataObserver(page) {
  const filename = base + 'components/AppShell.ets';
  const source = fs.readFileSync(filename, 'utf8');
  const names = ['dataChanged', 'repositoryDataInvalidated', 'inlineSessionChanged'];
  const methods = names.map(name => source.match(new RegExp('  ' + name + '\\(\\) \\{[\\s\\S]*?\\n  \\}'))[0]).join('\n');
  let active = false;
  const module = { exports: {} };
  const code = ts.transpileModule('export class Observer {' + methods + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInThisContext('(function(module,exports,TaskInlineSession){' + code + '\n})', { filename })(module, module.exports,
    { active: () => active });
  const observer = Object.assign(new module.exports.Observer(), { pageVisible: true, dataRevision: 0,
    dataChangeState: { revision: 0 }, drawerOpen: false, deferredRefresh: false, inlineActive: '',
    synchronized: () => page.loadFile() });
  return { observer, setActive(value) { active = value; observer.inlineActive = value ? 'project:task' : ''; } };
}

test('项目订阅数据版本变化后刷新完整文档和原文，重复版本不重读', async () => {
  const f = projectPageFixture(); await f.page.loadFile();
  const { observer } = projectDataObserver(f.page);
  f.page.sourceMode = true;
  let reads = 0;
  f.setOpen(async () => { reads++; return { ...f.file('done'), sourceBytes: () => Buffer.from('* DONE 已完成'),
    documentSections: () => [{ path: null, html: '<p>完成后的正文与进度</p>' }] }; });
  observer.dataChangeState = { revision: 1 }; observer.dataChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.page.content, '* DONE 已完成');
  assert.equal(f.page.sections[0].html, '<p>完成后的正文与进度</p>');
  assert.equal(f.page.fileVersion, 'done');
  observer.dataChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 1);
});

test('项目编辑期间合并多个事件，结束会话后只读取最新版本；退出后延迟刷新不再打开文件', async () => {
  const f = projectPageFixture(); await f.page.loadFile();
  const data = projectDataObserver(f.page);
  let reads = 0;
  f.setOpen(async () => { reads++; return f.file('latest'); });
  data.setActive(true);
  data.observer.dataChangeState = { revision: 1 }; data.observer.dataChanged();
  data.observer.dataChangeState = { revision: 2 }; data.observer.dataChanged();
  assert.equal(reads, 0);
  data.setActive(false); data.observer.inlineSessionChanged();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(reads, 1);
  assert.equal(f.page.fileVersion, 'latest');
  data.setActive(true);
  data.observer.dataChangeState = { revision: 3 }; data.observer.dataChanged();
  data.setActive(false); data.observer.inlineSessionChanged();
  f.page.onPageHide();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(reads, 1);
  f.page.onPageShow();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 2);
});
