import { router } from '@kit.ArkUI'
import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { orgDocumentPage } from '../ui/OrgDocumentPresentation'

interface NotebookParams { repoId?: string; path?: string }

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State title: string = ''
  @State content: string = ''
  @State renderedHtml: string = ''
  @State tab: string = '阅读'
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  @State allCollapsed: boolean = false
  private controller: webview.WebviewController = new webview.WebviewController()
  private loadRevision: number = 0
  private readingLoadRequested: boolean = false

  onPageShow() { this.loadFile() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadFile() {
    const revision = ++this.loadRevision
    this.loading = true
    this.renderReady = false
    this.allCollapsed = false
    try {
      const params = router.getParams() as NotebookParams
      this.path = params.path || ''
      const config = await AppConfigService.load(getContext(this))
      const file = await NotebookService.open(config.repos, params.repoId || '', this.path, config.todoDefaults)
      if (revision !== this.loadRevision) return
      if (!file) { this.message = '该文件已不存在，请返回存储库列表。'; return }
      this.title = file.title() || this.path
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      this.renderedHtml = file.renderHtml()
      this.message = ''
    } catch (e) {
      if (revision === this.loadRevision) this.message = `读取文件失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      if (revision === this.loadRevision) this.loading = false
    }
  }

  async toggleAll() {
    if (!this.renderReady || this.tab !== '阅读' || this.loading) return
    // 仅改变阅读 DOM 的折叠状态，不向文档注入脚本或绑定写入接口。
    try {
      const result = await this.controller.runJavaScript("(function() { var collapse = !!document.querySelector('details.heading[open]'); document.querySelectorAll('details.heading').forEach(function(node) { node.open = !collapse; }); return collapse; })()")
      this.allCollapsed = result === 'true'
    } catch (e) {
      this.message = `阅读视图加载失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  readingPageEnded() {
    if (this.readingLoadRequested) {
      this.renderReady = true
      return
    }
    this.readingLoadRequested = true
    try {
      // 等初始空白页加载结束再注入文档，并编码 CSS 色值中的 # 等 URL 字符。
      this.controller.loadData(encodeURIComponent(orgDocumentPage(this.renderedHtml, this.content.trim().length === 0)), 'text/html', 'UTF-8')
    } catch (e) {
      this.message = `阅读视图加载失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || '文件', titleIcon: $r('app.media.ui_folder'), synchronized: (): void => { this.loadFile() }, back: true, drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_expand'), actionLabel: this.tab === '阅读' && this.renderReady ? (this.allCollapsed ? '展开全部' : '收起全部') : '',
        action: (): void => { this.toggleAll() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开文件', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            Row({ space: 8 }) {
              ForEach(['阅读', '原文'], (tab: string) => {
                Button(tab).height(34).fontSize(13).fontColor(this.tab === tab ? UiColor.onSelected : UiColor.secondary)
                  .backgroundColor(this.tab === tab ? UiColor.selected : Color.Transparent)
                  .onClick(() => {
                    if (this.tab !== tab) { this.renderReady = false; this.allCollapsed = false; this.tab = tab }
                  })
              })
              Blank()
              Text('只读').fontSize(12).fontColor(UiColor.secondary)
            }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 8 })
            if (this.tab === '原文') {
              Scroll() {
                Text(this.content || '空白 Org 文件').width('100%').fontSize(14).fontFamily('monospace')
                  .fontColor(UiColor.text).copyOption(CopyOptions.LocalDevice).padding(20)
              }.width('100%').layoutWeight(1).align(Alignment.TopStart)
            } else {
              Web({ src: 'about:blank', controller: this.controller })
                .width('100%').layoutWeight(1).backgroundColor(UiColor.surface)
                .javaScriptAccess(true).fileAccess(false).blockNetwork(true).domStorageAccess(false).databaseAccess(false)
                .onControllerAttached(() => {
                  this.readingLoadRequested = false
                })
                .onPageEnd(() => { this.readingPageEnded() })
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
