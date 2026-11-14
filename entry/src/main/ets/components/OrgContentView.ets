import { InternalLinkProcessor, DocumentInternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { webview } from '@kit.ArkWeb'
import { LinkView, LinkController, LinkEditController } from './LinkView'
import { CoreBridgeError, coreErrorMessage, CoreTextLink, CoreLinkValue } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { orgDocumentPage } from '../ui/OrgDocumentPresentation'

interface ConflictCardHit { id: string; action: string }

// 复用只读文档的加载顺序；嵌入编辑内容时按实际内容高度参与页面滚动。
@Component
export struct OrgContentView {
  @Prop @Watch('documentChanged') fragment: string = ''
  @Prop @Watch('documentChanged') revision: string = ''
  @Prop empty: boolean = false
  @Prop embedded: boolean = false
  @Prop horizontalParentFirst: boolean = false
  @Prop @Watch('backgroundChanged') contentBackground: string = UiColor.surface
  @Prop embeddedPadding: number = 16
  @Prop compactLogs: boolean = false
  @Prop fileReading: boolean = false
  @Prop flowReading: boolean = false
  @Prop projectReading: boolean = false
  @Prop editable: boolean = false
  changeLink: ((link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  linkEditingChanged: (editing: boolean) => void = () => {}
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  linkEditor: LinkEditController = new LinkEditController()
  scrolled: (offset: number) => void = () => {}
  @Prop @Watch('measure') layoutRevision: number = 0
  @Prop fileContext: string = ''
  controller: webview.WebviewController = new webview.WebviewController()
  nodeActivated: ((index: number) => void) | undefined = undefined
  conflictCardActivated: ((id: string, action: string) => void) | undefined = undefined
  activate: (() => void) | undefined = undefined
  horizontalSwipe: (left: boolean) => void = () => {}
  private tapX: number = 0
  private tapY: number = 0
  private tapTime: number = 0
  private tapMoved: boolean = false
  ready: () => void = () => {}
  measured: () => void = () => {}
  failed: (message: string) => void = () => {}
  @State contentHeight: number = 100
  @State error: string = ''
  private documentGeneration: number = 0
  private requestedGeneration: number = -1
  private loadRequested: boolean = false
  private loaded: boolean = false
  private active: boolean = true
  private widthVp: number = 0

  async backgroundChanged() {
    if (!this.active || !this.loaded) return
    try { await this.controller.runJavaScript(`document.body.style.backgroundColor = ${JSON.stringify(this.contentBackground)}`) }
    catch (e) { /* 颜色变化不影响正文读取。 */ }
  }

  async activateAt(x: number, y: number) {
    if ((!this.activate && !this.nodeActivated && !this.conflictCardActivated) || !this.loaded || !this.active || this.widthVp <= 0) return
    const generation = this.documentGeneration
    try {
      const result = await this.controller.runJavaScript(`(() => {
        // 键盘与 Web 自动滚动可能改变点击坐标；链接表单打开时不切换整段备注编辑。
        if (document.querySelector('.org-link-editor')) return 'true';
        const node = document.elementFromPoint(${x} * window.innerWidth / ${this.widthVp}, ${y} * window.innerWidth / ${this.widthVp});
        const action = node?.closest('[data-conflict-action]');
        if (action) return JSON.stringify({ id: action.getAttribute('data-conflict-id') || '', action: action.getAttribute('data-conflict-action') || '' });
        const card = node?.closest('[data-conflict-card]');
        if (card) return JSON.stringify({ id: card.getAttribute('data-conflict-card') || '', action: 'focus' });
        return Boolean(node?.closest('a, summary, [data-org-link], .org-link-editor')) ? 'true' : 'false';
      })()`)
      if (generation !== this.documentGeneration) return
      if (result !== 'false' && result !== 'true') {
        try {
          const payload = result.startsWith('\"') ? JSON.parse(result) as string : result
          const card = JSON.parse(payload) as ConflictCardHit
          if (this.active && card.id.length > 0) this.conflictCardActivated?.(card.id, card.action)
        } catch (_) { /* 卡片命中信息异常时忽略本次点击。 */ }
        return
      }
      if (this.active && result === 'false' && this.activate) {
        if (!await this.linkEditor.finish() || !this.active || generation !== this.documentGeneration) return
        this.activate()
      }
      if (this.active && this.nodeActivated && result === 'false') {
        const selected = await this.controller.runJavaScript(`(() => {
          const node = document.elementFromPoint(${x} * window.innerWidth / ${this.widthVp}, ${y} * window.innerWidth / ${this.widthVp});
          if (!node || node.closest('a')) return -1;
          return [...document.querySelectorAll('details.heading')].indexOf(node.closest('details.heading'));
        })()`)
        const index = Number(selected)
        if (generation === this.documentGeneration && this.active && Number.isInteger(index) && index >= 0) this.nodeActivated?.(index)
      }
    } catch (e) { /* 点击命中检查失败时保留阅读视图。 */ }
  }

  aboutToDisappear() { this.documentGeneration++; this.active = false }

  async measure() {
    if (!this.active || !this.embedded || !this.loaded || this.widthVp <= 0) return
    const generation = this.documentGeneration
    try {
      const result = await this.controller.runJavaScript('document.body.getBoundingClientRect().height / window.innerWidth')
      if (generation !== this.documentGeneration || !this.active || !this.loaded) return
      const ratio = Number(result)
      const height = Number.isFinite(ratio) && ratio > 0 ? Math.max(this.compactLogs || this.projectReading ? 1 : 40, Math.ceil(ratio * this.widthVp)) : this.contentHeight
      if (height !== this.contentHeight) this.contentHeight = height
      else if (this.active) this.measured()
    } catch (e) {
      // 页面已离开时不再更新嵌入内容的尺寸。
      if (this.active) this.reportError(e as CoreBridgeError)
    }
  }

  reportError(error: CoreBridgeError) {
    this.error = `阅读视图加载失败：${coreErrorMessage(error)}`
    this.failed(this.error)
  }

  documentChanged() {
    this.documentGeneration++
    if (!this.active || !this.loaded) return
    this.loadDocument()
  }

  loadDocument() {
    this.loaded = false
    this.loadRequested = true
    this.requestedGeneration = this.documentGeneration
    try {
      this.controller.loadData(encodeURIComponent(orgDocumentPage(this.fragment, this.empty, this.embedded,
        this.contentBackground, this.embeddedPadding, this.fileReading, this.fileContext, this.flowReading, this.compactLogs, this.projectReading)), 'text/html', 'UTF-8')
    } catch (e) { this.reportError(e as CoreBridgeError) }
  }

  async pageEnded() {
    if (!this.active) return
    if (this.loadRequested) {
      // 载入中更换了冲突或版本，旧页面结束后必须加载最新快照。
      if (this.requestedGeneration !== this.documentGeneration) { this.loadDocument(); return }
      this.loaded = true
      this.ready()
      this.measure()
      return
    }
    // 初始空白页结束后加载文档；URL 编码保留 CSS 中的 # 等字符。
    this.loadDocument()
  }

  @Builder
  documentContent(links: LinkController) {
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%').height(this.embedded ? this.contentHeight : '100%').backgroundColor(this.contentBackground)
        .nestedScroll({ scrollUp: this.embedded ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_ONLY,
          scrollDown: this.embedded ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_ONLY,
          scrollLeft: this.horizontalParentFirst ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_FIRST,
          scrollRight: this.horizontalParentFirst ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_FIRST })
        .javaScriptAccess(true).fileAccess(false).blockNetwork(true).domStorageAccess(false).databaseAccess(false)
        .javaScriptProxy({ object: links, name: 'OrgTaskLinks', methodList: ['hit', 'draft', 'save', 'cancel'], controller: this.controller })
        .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
          return links.navigate(request.getRequestUrl(), this.active && request.isMainFrame())
        })
        .onScroll((event: OnScrollEvent): void => { this.scrolled(event.yOffset) })
        .onControllerAttached(() => { this.active = true; this.loadRequested = false; this.loaded = false })
        .onPageEnd(() => { this.pageEnded(); links.ready() })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const width = parseFloat(newArea.width.toString())
          if (width !== this.widthVp) { this.widthVp = width; this.measure() }
          else if (this.embedded && this.loaded && Math.abs(Number(newArea.height) - this.contentHeight) < 1) this.measured()
        })
        .onTouch((event: TouchEvent) => {
          const point = event.changedTouches[0]
          if (point && event.type === TouchType.Down) {
            this.tapX = point.x; this.tapY = point.y; this.tapTime = Date.now(); this.tapMoved = false
          }
          if (point && event.type === TouchType.Move && Math.abs(point.x - this.tapX) + Math.abs(point.y - this.tapY) > 10) this.tapMoved = true
          if (event.type === TouchType.Up && point && this.horizontalParentFirst
            && Math.abs(point.x - this.tapX) > 40
            && Math.abs(point.x - this.tapX) > Math.abs(point.y - this.tapY) * 1.5) {
            // Web 会消费横向手势；转交条目原生侧滑菜单，不把拖动当成链接点击。
            this.horizontalSwipe(point.x < this.tapX)
          }
          if (event.type === TouchType.Up && (this.embedded || this.nodeActivated || this.conflictCardActivated)) {
            setTimeout(() => { this.measure() }, 100)
            if (point && !this.tapMoved && Date.now() - this.tapTime < 500) this.activateAt(point.x, point.y)
          }
        })
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Up && this.embedded) setTimeout(() => { this.measure() }, 100)
          return false
        })
  }

  build() {
    if (this.error) {
      Text(this.error).width('100%').padding(16).fontSize(14).fontColor(UiColor.error)
    } else {
      LinkView({ document: true, contentHeight: this.embedded ? this.contentHeight : '100%',
        internalLinkProcessor: this.internalLinkProcessor ?? new DocumentInternalLinkProcessor(this.controller),
        editable: this.editable, revision: this.revision, webController: this.controller,
        change: this.changeLink, editingChanged: this.linkEditingChanged, editor: this.linkEditor,
        remeasure: (): void => { this.measure() },
        content: (links: LinkController): void => { this.documentContent(links) } }).width('100%')
    }
  }
}
