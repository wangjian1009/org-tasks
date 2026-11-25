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
  @Prop @Watch('revisionChanged') revision: string = ''
  @Prop reloadOnRevision: boolean = true
  @Prop empty: boolean = false
  @Prop embedded: boolean = false
  @Prop horizontalParentFirst: boolean = false
  @Prop @Watch('backgroundChanged') contentBackground: string = UiColor.surface
  @Prop embeddedPadding: number = 16
  @Prop compactLogs: boolean = false
  @Prop fileReading: boolean = false
  @Prop bodyBlock: boolean = false
  @Prop editable: boolean = false
  changeLink: ((link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  linkEditingChanged: (editing: boolean) => void = () => {}
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  linkEditor: LinkEditController = new LinkEditController()
  controller: webview.WebviewController = new webview.WebviewController()
  conflictCardActivated: ((id: string, action: string) => void) | undefined = undefined
  activate: (() => void) | undefined = undefined
  contextMenu: ((x: number, y: number) => void) | undefined = undefined
  private tapX: number = 0
  private tapY: number = 0
  private tapTime: number = 0
  private tapMoved: boolean = false
  private pressTimer: number = -1
  ready: () => void = () => {}
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
    if ((!this.activate && !this.conflictCardActivated) || !this.loaded || !this.active || this.widthVp <= 0) return
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
    } catch (e) { /* 点击命中检查失败时保留阅读视图。 */ }
  }

  async contextMenuAt(x: number, y: number) {
    if (!this.contextMenu || !this.loaded || !this.active || this.widthVp <= 0) return
    const generation = this.documentGeneration
    try {
      const result = await this.controller.runJavaScript(`(() => {
        if (document.querySelector('.org-link-editor')) return true;
        const node = document.elementFromPoint(${x} * window.innerWidth / ${this.widthVp}, ${y} * window.innerWidth / ${this.widthVp});
        return !node || Boolean(node.closest('a, .link, input, textarea, select, button'));
      })()`)
      if (result === 'false' && this.active && generation === this.documentGeneration) this.contextMenu(x, y)
    } catch (_) { /* 命中检查失败时不把链接或输入误认为正文区块。 */ }
  }

  cancelPress() {
    if (this.pressTimer !== -1) clearTimeout(this.pressTimer)
    this.pressTimer = -1
  }

  aboutToDisappear() { this.cancelPress(); this.documentGeneration++; this.active = false }

  async measure() {
    if (!this.active || !this.embedded || !this.loaded || this.widthVp <= 0) return
    const generation = this.documentGeneration
    try {
      const result = await this.controller.runJavaScript('document.body.getBoundingClientRect().height / window.innerWidth')
      if (generation !== this.documentGeneration || !this.active || !this.loaded) return
      const ratio = Number(result)
      const height = Number.isFinite(ratio) && ratio > 0 ? Math.max(this.compactLogs || this.bodyBlock ? 1 : 40, Math.ceil(ratio * this.widthVp)) : this.contentHeight
      if (height !== this.contentHeight) this.contentHeight = height
    } catch (e) {
      // 页面已离开时不再更新嵌入内容的尺寸。
      if (this.active) this.reportError(e as CoreBridgeError)
    }
  }

  reportError(error: CoreBridgeError) {
    this.error = `阅读视图加载失败：${coreErrorMessage(error)}`
    this.failed(this.error)
  }

  revisionChanged() {
    // 内容区块仍向链接控件传递真实版本；状态等外部字段变化无需重载相同正文。
    if (this.reloadOnRevision) this.documentChanged()
  }

  documentChanged() {
    this.cancelPress()
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
        this.contentBackground, this.embeddedPadding, this.fileReading, this.compactLogs, this.bodyBlock)), 'text/html', 'UTF-8')
    } catch (e) { this.reportError(e as CoreBridgeError) }
  }

  async pageEnded() {
    if (!this.active) return
    if (this.loadRequested) {
      // 载入中更换了冲突或版本，旧页面结束后必须加载最新快照。
      if (this.requestedGeneration !== this.documentGeneration) { this.loadDocument(); return }
      const generation = this.documentGeneration
      this.loaded = true
      // 区块拥有长按菜单，关闭 Web 默认选词；链接表单仍保留文本选择。
      if (this.contextMenu) {
        try { await this.controller.runJavaScript(`(() => {
          const style = document.createElement('style');
          style.textContent = 'body { -webkit-user-select: none; user-select: none; } .org-link-editor, .org-link-editor * { -webkit-user-select: text; user-select: text; }';
          document.head.append(style);
        })()`) } catch (_) { /* 不影响正文加载。 */ }
      }
      if (!this.active || generation !== this.documentGeneration) return
      this.ready()
      this.measure()
      return
    }
    // 初始空白页结束后加载文档；URL 编码保留 CSS 中的 # 等字符。
    this.loadDocument()
  }

  touch(event: TouchEvent) {
    const point = event.changedTouches[0]
    if (point && event.type === TouchType.Down) {
      LinkEditController.protectInteraction()
      this.cancelPress()
      if (this.contextMenu) this.pressTimer = setTimeout((): void => {
        this.pressTimer = -1
        this.contextMenuAt(point.x, point.y)
      }, 500)
      this.tapX = point.x; this.tapY = point.y; this.tapTime = Date.now(); this.tapMoved = false
    }
    if (point && event.type === TouchType.Move && Math.abs(point.x - this.tapX) + Math.abs(point.y - this.tapY) > 10) { this.tapMoved = true; this.cancelPress() }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.cancelPress()
    if (event.type === TouchType.Up) LinkEditController.protectInteraction()
    if (event.type === TouchType.Up && (this.embedded || this.conflictCardActivated)) {
      setTimeout(() => { this.measure() }, 100)
      if (point && !this.tapMoved && Date.now() - this.tapTime < 500) this.activateAt(point.x, point.y)
    }
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
        .javaScriptProxy({ object: links, name: 'OrgTaskLinks', methodList: ['hit', 'protocol', 'draft', 'save', 'cancel'], controller: this.controller })
        .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
          return links.navigate(request.getRequestUrl(), this.active && request.isMainFrame())
        })
        .onContextMenuShow((event: OnContextMenuShowEvent): boolean => {
          if (!this.contextMenu || event.param.isEditable()) return false
          if (!event.param.getLinkUrl()) this.contextMenuAt(event.param.x(), event.param.y())
          return true
        })
        .onControllerAttached(() => { this.active = true; this.loadRequested = false; this.loaded = false })
        .onPageEnd(() => { this.pageEnded(); links.ready() })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const width = parseFloat(newArea.width.toString())
          if (width !== this.widthVp) { this.widthVp = width; this.measure() }
        })
        .onTouch((event: TouchEvent): void => { this.touch(event) })
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
