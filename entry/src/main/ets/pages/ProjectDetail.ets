import { ProjectDataManager, ProjectFileState } from '../services/ProjectDataManager'
import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { ProjectDocumentView, ProjectDocumentNavigation } from '../components/ProjectDocumentView'
import { InternalLinkProcessor, CallbackInternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { ProjectReadingSection, projectReadingSections } from '../ui/ProjectReadingPresentation'
import { TaskInlineSession } from '../services/TaskInlineService'

interface ProjectParams { repoId?: string; path?: string }

@Entry
@Component
struct ProjectDetail {
  @State title: string = ''
  @State titleContext: string = ''
  @State sections: ProjectReadingSection[] = []
  @State fileTags: string[] = []
  @State specialTags: string[] = []
  @State content: string = ''
  @State sourceMode: boolean = false
  @State loading: boolean = true
  @State refreshing: boolean = false
  @State message: string = ''
  @State refreshMessage: string = ''
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  private stopFile: (() => void) | undefined = undefined
  private latestFileState: ProjectFileState | undefined = undefined
  @StorageLink('taskInlineActive') @Watch('projectInlineChanged') projectInlineActive: string = ''
  private projectDataManager: ProjectDataManager | undefined = undefined
  private readingState: string = ''
  @State renderRevision: number = 0
  private navigation: ProjectDocumentNavigation = new ProjectDocumentNavigation()
  private internalLinks: InternalLinkProcessor = new CallbackInternalLinkProcessor(
    async (target: string): Promise<boolean> =>
      this.pageVisible && !this.sourceMode && !this.refreshing && await this.navigation.isValidInternalLink(target),
    async (target: string): Promise<void> => {
      if (!this.pageVisible || this.sourceMode || this.refreshing) throw new Error('当前页面无法执行内部跳转')
      await this.navigation.followInternalLink(target)
    }
  )
  private sourceNavigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  private loadRevision: number = 0
  private fileVersion: string = ''
  private fileIdentity: string = ''
  @State pageVisible: boolean = true

  aboutToDisappear(): void {
    this.stopFile?.(); this.stopFile = undefined
    this.projectDataManager?.close().catch((): void => { console.error('关闭项目数据集失败') })
  }
  onPageShow() { this.pageVisible = true; this.loadFile(); if (this.latestFileState) this.applyFileState(this.latestFileState) }
  // 页面退出时使进行中的文件读取失效。
  onPageHide() { this.pageVisible = false; this.loadRevision++ }
  onBackPress(): boolean {
    if (this.navigation.closePanel()) return true
    if (this.sourceMode) { this.toggleSource(); return true }
    if (TaskInlineSession.active()) { this.leaveProject(); return true }
    return false
  }

  async leaveProject() {
    if (await TaskInlineSession.end(true)) this.getUIContext().getRouter().back()
  }

  async rememberReading(): Promise<string> {
    const version = this.fileVersion
    const identity = this.fileIdentity
    try {
      const state = await this.navigation.captureReadingState()
      if (version === this.fileVersion && identity === this.fileIdentity && state) this.readingState = state
    } catch (_) { /* 阅读组件已离开时保留最近一次有效位置。 */ }
    return this.readingState
  }

  async toggleSource() {
    if (this.refreshing || !await TaskInlineSession.end(false)) return
    if (!this.sourceMode) await this.rememberReading()
    this.navigation.closePanel()
    this.sourceMode = !this.sourceMode
  }

  async refreshFile() {
    if (this.refreshing || !await TaskInlineSession.end(true)) return
    await this.projectDataManager?.load()
  }

  async loadFile() {
    if (!this.pageVisible) return
    const params = this.getUIContext().getRouter().getParams() as ProjectParams
    const repoId = params.repoId || '', path = params.path || ''
    if (!this.projectDataManager || this.projectDataManager.repoId !== repoId || this.projectDataManager.path !== path) {
      this.stopFile?.(); this.projectDataManager?.close().catch((): void => {})
      this.projectDataManager = new ProjectDataManager(this.getUIContext().getHostContext()!, repoId, path)
      this.stopFile = this.projectDataManager.subscribeFile((state: ProjectFileState): void => {
        this.latestFileState = state
        this.applyFileState(state)
      })
      await this.projectDataManager.load().catch((error: Error): void => { this.applyFileState({ message: error.message }) })
    }
  }

  projectInlineChanged(): void { if (!this.projectInlineActive && this.latestFileState) this.applyFileState(this.latestFileState) }

  async applyFileState(state: ProjectFileState): Promise<void> {
    if (!this.pageVisible || TaskInlineSession.active() || (!state.snapshot && !state.message)) return
    const revision = ++this.loadRevision
    const hasSnapshot = this.fileVersion.length > 0
    this.refreshing = true
    if (hasSnapshot && !this.sourceMode) await this.rememberReading()
    if (revision !== this.loadRevision) return
    try {
      if (state.message) throw new Error(state.message)
      const snapshot = state.snapshot!
      const repoId = this.projectDataManager!.repoId, path = this.projectDataManager!.path
      const file = snapshot.file
      if (revision !== this.loadRevision) return
      if (!file) throw new Error('项目文件已不存在，请返回存储库列表。')
      if (file.project() === null) {
        await this.getUIContext().getRouter().replaceUrl({ url: 'pages/FileDetail', params: { repoId, path } })
        return
      }
      const sections = projectReadingSections(file, snapshot.tasks)
      const fileTags = file.fileTags().filter((tag: string) => tag !== 'todo')
      const specialTags = file.specialTags()
      const identity = JSON.stringify([repoId, path])
      const changed = identity !== this.fileIdentity || file.fileVersion !== this.fileVersion
      this.title = file.project() || '未命名项目'
      this.titleContext = file.category() || ''
      this.sections = sections
      this.fileTags = fileTags
      this.specialTags = specialTags
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      if (changed) {
        if (identity !== this.fileIdentity) this.readingState = ''
        this.fileIdentity = identity
        this.fileVersion = file.fileVersion
        this.renderReady = false
        this.renderRevision++
      }
      this.message = ''
      this.refreshMessage = ''
    } catch (e) {
      if (revision !== this.loadRevision) return
      const message = `读取项目失败：${coreErrorMessage(e as CoreBridgeError)}`
      if (hasSnapshot) this.refreshMessage = `${message}。当前保留上次读取的内容。`
      else this.message = message
    } finally {
      if (revision === this.loadRevision) { this.loading = false; this.refreshing = false }
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || '项目', titleContext: this.titleContext, back: true, drawerOpen: $drawerOpen,
        pullToSync: true, pullDisabled: this.refreshing,
        backAction: (): void => { if (!this.onBackPress()) this.getUIContext().getRouter().back() },
        secondaryActionIcon: $r('app.media.ui_document_outline'),
        secondaryActionLabel: this.renderReady && !this.sourceMode && !this.refreshing ? '文档目录' : '',
        secondaryAction: (): void => { this.navigation.openOutline() },
        actionIcon: $r('app.media.ui_more'),
        actionLabel: this.loading || this.message || this.refreshing ? '' : '更多阅读操作',
        actionMenuItems: this.sourceMode ? [
          { title: '返回项目文档', action: (): void => { this.toggleSource() } },
          { title: '刷新项目', action: (): void => { this.refreshFile() } }
        ] : [
          { title: '刷新项目', action: (): void => { this.refreshFile() } },
          { title: '查看原文', action: (): void => { this.toggleSource() } }
        ] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开项目', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开项目', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            if (this.refreshing) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color(UiColor.primary)
                Text('正在刷新项目').fontSize(12).fontColor(UiColor.secondary)
              }.width('100%').padding({ left: 20, top: 8, bottom: 8 })
            }
            if (this.refreshMessage) {
              Text(this.refreshMessage).fontSize(12).fontColor(UiColor.error).width('100%').padding(12)
                .onClick((): void => { this.loadFile() })
            }
            Stack() {
              ProjectDocumentView({ dataManager: this.projectDataManager, sections: this.sections, fileTags: this.fileTags, specialTags: this.specialTags,
                revision: `${this.fileIdentity}:${this.renderRevision}`, navigation: this.navigation,
                internalLinkProcessor: this.internalLinks,
                readingState: this.readingState, showing: this.pageVisible && !this.sourceMode && !this.refreshing,
                scrolled: (offset: number): void => { this.readingState = JSON.stringify({ scroll: offset }) },
                ready: (): void => { this.renderReady = true } })
                .width('100%').height('100%').visibility(this.sourceMode ? Visibility.None : Visibility.Visible)
              if (this.sourceMode) {
                OrgFilePreviewView({ content: this.content, displayMode: 'source',
                  title: this.title,
                  revision: `${this.fileIdentity}:${this.renderRevision}`, navigation: this.sourceNavigation })
                  .width('100%').height('100%')
              }
            }.width('100%').layoutWeight(1)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
