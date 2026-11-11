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
    '../ui/OrgDocumentNavigation': navigation
  }, source => source.split('  @Builder\n')[0].replace(/@Entry\n|@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g, '')
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
    '../services/ExternalLinkService': {}
  }, source => source.split('  build()')[0].replace(/@Component\n|@State |@Prop(?: @Watch\('[^']+'\))? /g, '')
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
