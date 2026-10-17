import { router } from '@kit.ArkUI'

// 旧入口转到统一的存储库管理页，避免保留第二套导航。
@Entry
@Component
struct Workspace {
  aboutToAppear() { router.replaceUrl({ url: 'pages/Repositories' }) }
  build() { Column() {}.width('100%').height('100%') }
}
