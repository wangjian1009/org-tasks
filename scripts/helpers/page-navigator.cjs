const { transpileFixture } = require('./localized-resources.cjs');
// 页面行为测试沿用原 Router 替身；路径与返回规则由 PageNavigator 专项测试覆盖。
exports.pageNavigatorMock = {
  primaryPage: view => view === 'inbox' ? { url: 'pages/Inbox' } : { url: 'pages/' + view[0].toUpperCase() + view.slice(1) },
  PageNavigator: { shared: {
    path: { depth: 2 }, start() {}, reset() {}, restore() {}, async close() {}, watchExternalLeaveGuard() { return () => {}; },
    async pushPage(context, page) { await context.getRouter().pushUrl(page); return true; },
    async replacePage(context, page) { await context.getRouter().replaceUrl(page); return true; },
    async openPrimary(context, page) { await context.getRouter().replaceUrl(page); return true; },
    async back(context) { await context.getRouter().back(); return true; }
  } }
};


// 冷启动入口行为使用真实路径转换实现，避免替身复制卡片协议。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function loadNavigationModule(name, dependencies = {}) {
  const file = path.resolve(__dirname, '../../entry/src/main/ets/services', name + '.ets');
  const module = { exports: {} };
  const code = transpileFixture(ts, fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  vm.runInThisContext('(function(require,module,exports){' + code + '\n})', { filename: file })(key => {
    if (!(key in dependencies)) throw new Error('缺少导航依赖 ' + key);
    return dependencies[key];
  }, module, module.exports);
  return module.exports;
}
exports.pagePathModule = loadNavigationModule('PagePath');
exports.entryNavigationModule = loadNavigationModule('EntryNavigation', { './PagePath': exports.pagePathModule });
