import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { ExternalLinkService, MapAppChoice } from '../services/ExternalLinkService'
import { MapAppSheet } from './MapAppSheet'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { orgDocumentPage } from '../ui/OrgDocumentPresentation'

// 复用只读文档的加载顺序；嵌入编辑内容时按实际内容高度参与页面滚动。
@Component
export struct OrgContentView {
  @Prop fragment: string = ''
  @Prop empty: boolean = false
  @Prop embedded: boolean = false
  @Prop contentBackground: string = UiColor.surface
  @Prop embeddedPadding: number = 16
  controller: webview.WebviewController = new webview.WebviewController()
  ready: () => void = () => {}
  failed: (message: string) => void = () => {}
  @State contentHeight: number = 100
  @State error: string = ''
  @State chooserVisible: boolean = false
  @State mapChoices: MapAppChoice[] = []
  private loadRequested: boolean = false
  private loaded: boolean = false
  private active: boolean = true
  private widthVp: number = 0

  async openLink(href: string) {
    try {
      await ExternalLinkService.open(getContext(this) as common.UIAbilityContext, href,
        (choices: MapAppChoice[]): void => { this.chooseMapApp(choices) })
    } catch (error) {
      if (this.active) this.getUIContext().getPromptAction().showToast({ message: (error as Error).message || '无法打开链接，请确认已安装对应应用。' })
    }
  }

  chooseMapApp(choices: MapAppChoice[]): void {
    this.mapChoices = choices
    this.chooserVisible = true
  }

  aboutToDisappear() { this.active = false }

  async measure() {
    if (!this.active || !this.embedded || !this.loaded || this.widthVp <= 0) return
    try {
      const result = await this.controller.runJavaScript('document.body.getBoundingClientRect().height / window.innerWidth')
      const ratio = Number(result)
      if (this.active && Number.isFinite(ratio) && ratio > 0) this.contentHeight = Math.max(40, Math.ceil(ratio * this.widthVp))
    } catch (e) {
      // 页面已离开时不再更新嵌入内容的尺寸。
      if (this.active) this.reportError(e as CoreBridgeError)
    }
  }

  reportError(error: CoreBridgeError) {
    this.error = `阅读视图加载失败：${coreErrorMessage(error)}`
    this.failed(this.error)
  }

  pageEnded() {
    if (this.loadRequested) {
      this.loaded = true
      this.ready()
      this.measure()
      return
    }
    this.loadRequested = true
    try {
      // 初始空白页结束后加载文档；URL 编码保留 CSS 中的 # 等字符。
      this.controller.loadData(encodeURIComponent(orgDocumentPage(this.fragment, this.empty, this.embedded, this.contentBackground, this.embeddedPadding)), 'text/html', 'UTF-8')
    } catch (e) { this.reportError(e as CoreBridgeError) }
  }

  build() {
    if (this.error) {
      Text(this.error).width('100%').padding(16).fontSize(14).fontColor(UiColor.error)
    } else {
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%').height(this.embedded ? this.contentHeight : '100%').backgroundColor(this.contentBackground)
        .javaScriptAccess(true).fileAccess(false).blockNetwork(true).domStorageAccess(false).databaseAccess(false)
        .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
          const href = request.getRequestUrl()
          if (href === 'about:blank' || href.startsWith('data:')) return false
          if (this.active && request.isMainFrame()) this.openLink(href)
          return true
        })
        .onControllerAttached(() => { this.active = true; this.loadRequested = false; this.loaded = false })
        .onPageEnd(() => { this.pageEnded() })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const width = parseFloat(newArea.width.toString())
          if (width !== this.widthVp) { this.widthVp = width; this.measure() }
        })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Up && this.embedded) setTimeout(() => { this.measure() }, 100)
        })
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Up && this.embedded) setTimeout(() => { this.measure() }, 100)
          return false
        })
        .bindSheet($$this.chooserVisible, MapAppSheet(this.mapChoices, (): void => { this.chooserVisible = false }), {
          height: 220,
          detents: [220],
          preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface,
          maskColor: Color.Transparent,
          showClose: false
        })
    }
  }
}
