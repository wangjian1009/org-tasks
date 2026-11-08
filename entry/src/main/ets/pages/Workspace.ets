
// 旧入口转到统一的存储库管理页，避免保留第二套导航。
@Entry
@Component
struct Workspace {
  async aboutToAppear() {
    try { await this.getUIContext().getRouter().replaceUrl({ url: 'pages/Files' }) }
    catch (error) { console.error('打开存储库页面失败') }
  }
  build() { Column() {}.width('100%').height('100%') }
}
