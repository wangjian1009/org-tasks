// 页面行为测试沿用原 Router 替身；路径与返回规则由 PageNavigator 专项测试覆盖。
exports.pageNavigatorMock = {
  primaryPage: view => view === 'inbox' ? { url: 'pages/Inbox' } : { url: 'pages/TaskOverview', params: { view } },
  PageNavigator: { shared: {
    path: { depth: 2 }, start() {}, reset() {}, async close() {},
    async pushPage(context, page) { await context.getRouter().pushUrl(page); return true; },
    async replacePage(context, page) { await context.getRouter().replaceUrl(page); return true; },
    async openPrimary(context, page) { await context.getRouter().replaceUrl(page); return true; },
    async back(context) { await context.getRouter().back(); return true; }
  } }
};
