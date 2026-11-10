import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgContentView } from '../components/OrgContentView'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFile, CoreTitlePart, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { syncLogTimeLabel } from '../ui/SyncLogPresentation'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { OrgDocumentChapter, OrgDocumentOutline, documentOutlineScript, documentChapterScript, documentExpandScript } from '../ui/OrgDocumentNavigation'

interface NotebookParams { repoId?: string; path?: string; syncId?: string; repositoryName?: string; backupTime?: number; backupPath?: string }

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State historyLabel: string = ''
  @State fileContext: string = ''
  @State title: string = ''
  @State titleParts: CoreTitlePart[] = []
  @State content: string = ''
  @State renderedHtml: string = ''
  @State displayMode: 'rendered' | 'source' = 'rendered'
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  @State outlineVisible: boolean = false
  @State chapters: OrgDocumentChapter[] = []
  @State activeChapter: number = -1
  private controller: webview.WebviewController = new webview.WebviewController()
  private loadRevision: number = 0
  private outlineRequest: number = 0

  onPageShow() { this.loadFile() }
  onPageHide() {
    this.loadRevision++
    this.outlineRequest++
    this.outlineVisible = false
    this.renderReady = false
  }
  onBackPress(): boolean {
    if (this.outlineVisible) { this.outlineVisible = false; this.outlineRequest++; return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadFile() {
    const revision = ++this.loadRevision
    this.loading = true
    this.renderReady = false
    this.outlineVisible = false
    this.outlineRequest++
    this.chapters = []
    this.activeChapter = -1
    try {
      const params = this.getUIContext().getRouter().getParams() as NotebookParams
      this.path = params.path || ''
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      let file: CoreOrgFile | undefined = undefined
      const repository = config.repos.find((item) => item.id === params.repoId)
      let historyLabel = ''
      if (params.syncId) {
        if (!repository) throw new Error('此存储库已不存在')
        const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
        file = await repo.historyFile(params.syncId, this.path, false)
        historyLabel = `历史备份 · ${params.backupPath || this.path}\n${params.repositoryName || ''}${params.backupTime ? ` · ${syncLogTimeLabel(params.backupTime)}` : ''}`
      } else {
        file = await NotebookService.open(config.repos, params.repoId || '', this.path, config.todoDefaults)
      }
      if (revision !== this.loadRevision) return
      if (!file) { this.message = '该文件已不存在，请返回存储库列表。'; return }
      this.historyLabel = historyLabel
      this.fileContext = `${repositoryLabel(repository)} / ${this.path}`
      this.displayMode = config.fileDisplayMode
      this.title = file.title() || this.path
      this.titleParts = file.titleParts()
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      this.renderedHtml = file.renderHtml()
      this.message = ''
    } catch (e) {
      if (revision === this.loadRevision) this.message = `读取文件失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      if (revision === this.loadRevision) this.loading = false
    }
  }

  async expandAll(expand: boolean) {
    if (!this.renderReady || this.displayMode !== 'rendered' || this.loading) return
    const revision = this.loadRevision
    try {
      await this.controller.runJavaScript(documentExpandScript(expand))
      if (revision === this.loadRevision && this.outlineVisible) await this.openOutline()
    } catch (e) {
      if (revision === this.loadRevision) this.readingError(e as CoreBridgeError)
    }
  }

  readingError(error: CoreBridgeError) {
    try { this.getUIContext().getPromptAction().showToast({ message: `阅读操作失败：${coreErrorMessage(error)}` }) }
    catch (_) { /* 页面退出时无需继续显示提示。 */ }
  }

  async openOutline() {
    if (!this.renderReady || this.displayMode !== 'rendered' || this.loading) return
    const revision = this.loadRevision
    const request = ++this.outlineRequest
    try {
      const result = await this.controller.runJavaScript(documentOutlineScript())
      if (revision !== this.loadRevision || request !== this.outlineRequest) return
      // 兼容 Web 引擎将字符串结果作为 JSON 字符串再次编码的返回形式。
      const payload = result.startsWith('"') ? JSON.parse(result) as string : result
      const outline = JSON.parse(payload) as OrgDocumentOutline
      this.chapters = outline.chapters
      this.activeChapter = outline.activeIndex
      this.outlineVisible = true
    } catch (e) {
      if (revision === this.loadRevision && request === this.outlineRequest) this.readingError(e as CoreBridgeError)
    }
  }

  async openChapter(chapter: OrgDocumentChapter) {
    if (!this.renderReady || this.displayMode !== 'rendered' || this.loading) return
    const revision = this.loadRevision
    this.outlineRequest++
    try {
      const result = await this.controller.runJavaScript(documentChapterScript(chapter.index))
      if (revision !== this.loadRevision) return
      if (result !== 'true') throw new Error('目录已失效，请重新打开文件')
      this.activeChapter = chapter.index
      this.outlineVisible = false
    } catch (e) {
      if (revision === this.loadRevision) this.readingError(e as CoreBridgeError)
    }
  }

  @Builder
  outlineSheet() {
    Column() {
      Row() {
        Text('文档目录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
        Button('全部展开').fontSize(12).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
          .onClick((): void => { this.expandAll(true) })
        Button('全部收起').fontSize(12).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(44)
          .onClick((): void => { this.expandAll(false) })
      }.width('100%')
      Text(`${this.title} · ${this.chapters.length} 个章节`).fontSize(12).fontColor(UiColor.secondary)
        .width('100%').margin({ top: 2, bottom: 16 })
      if (this.chapters.length === 0) {
        Text('本文没有章节标题').fontSize(14).fontColor(UiColor.secondary).padding({ top: 24, bottom: 32 })
      } else {
        List({ space: 4, initialIndex: Math.max(0, this.activeChapter) }) {
          ForEach(this.chapters, (chapter: OrgDocumentChapter) => {
            ListItem() {
              Row() {
                Row().width(2).height(24).backgroundColor(chapter.index === this.activeChapter ? UiColor.primary : Color.Transparent)
                Text(chapter.title).fontSize(chapter.level === 1 ? 15 : 14)
                  .fontColor(chapter.index === this.activeChapter ? UiColor.primary : chapter.level === 1 ? UiColor.text : UiColor.secondary)
                  .fontWeight(chapter.level === 1 ? FontWeight.Medium : FontWeight.Normal)
                  .padding({ left: 12 + Math.min(chapter.level - 1, 4) * 16, right: 12, top: 12, bottom: 12 }).layoutWeight(1)
              }.width('100%').constraintSize({ minHeight: 48 }).borderRadius(8)
                .backgroundColor(chapter.index === this.activeChapter ? UiColor.selected : Color.Transparent)
                .accessibilityText(`${chapter.level} 级标题，${chapter.title}${chapter.index === this.activeChapter ? '，当前章节' : ''}`)
                .onClick((): void => { this.openChapter(chapter) })
            }
          }, (chapter: OrgDocumentChapter) => `${chapter.index}`)
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 8, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || '文件', titleParts: this.titleParts, titleIcon: $r('app.media.ui_folder'), synchronized: (): void => { this.loadFile() }, back: true, drawerOpen: $drawerOpen,
        secondaryActionIcon: $r('app.media.ui_document_outline'), secondaryActionLabel: this.displayMode === 'rendered' && this.renderReady ? '文档目录' : '',
        secondaryAction: (): void => { this.openOutline() },
        actionIcon: $r('app.media.ui_more'), actionLabel: this.displayMode === 'rendered' && this.renderReady ? '更多阅读操作' : '',
        actionMenuItems: [{ title: '展开全部章节', action: (): void => { this.expandAll(true) } },
          { title: '收起全部章节', action: (): void => { this.expandAll(false) } }] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开文件', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            if (this.historyLabel.length > 0) {
              Text(this.historyLabel).fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
            }
            if (this.displayMode === 'source') {
              Scroll() {
                Text(this.content || '空白 Org 文件').width('100%').fontSize(14).fontFamily('monospace')
                  .fontColor(UiColor.text).copyOption(CopyOptions.LocalDevice).padding(20)
              }.width('100%').layoutWeight(1).align(Alignment.TopStart)
            } else {
              OrgContentView({ fragment: this.renderedHtml, empty: this.content.trim().length === 0, controller: this.controller,
                fileReading: true, fileContext: this.fileContext,
                ready: (): void => { this.renderReady = true }, failed: (message: string): void => { this.message = message } })
                .width('100%').layoutWeight(1)
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.outlineVisible, this.outlineSheet, {
        height: '60%', detents: ['60%', '85%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: false,
        onDisappear: (): void => { this.outlineRequest++ }
      })
  }
}
