import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor, repositoryLabel } from '../ui/Theme'

interface ProjectParams { repoId?: string; path?: string }

@Entry
@Component
struct ProjectDetail {
  @State title: string = ''
  @State fileContext: string = ''
  @State content: string = ''
  @State renderedHtml: string = ''
  @State sourceMode: boolean = false
  @State loading: boolean = true
  @State refreshing: boolean = false
  @State message: string = ''
  @State refreshMessage: string = ''
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  @State headerPassed: boolean = false
  @State readingState: string = ''
  @State renderRevision: number = 0
  private navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  private loadRevision: number = 0
  private fileVersion: string = ''
  private fileIdentity: string = ''

  onPageShow() { this.loadFile() }
  // 页面退出时只使读取失效，避免向正在销毁的 ArkWeb 再发送脚本。
  onPageHide() { this.loadRevision++ }
  onBackPress(): boolean {
    if (this.navigation.closePanel()) return true
    if (this.sourceMode) { this.toggleSource(); return true }
    return false
  }

  async rememberReading(): Promise<string> {
    const version = this.fileVersion
    const identity = this.fileIdentity
    try {
      const state = await this.navigation.captureReadingState()
      if (version === this.fileVersion && identity === this.fileIdentity && state) this.readingState = state
    } catch (_) { /* Web 已销毁时保留最近一次有效阅读状态。 */ }
    return this.readingState
  }

  async toggleSource() {
    if (this.refreshing) return
    if (!this.sourceMode) await this.rememberReading()
    this.navigation.closePanel()
    this.sourceMode = !this.sourceMode
    this.renderReady = false
    this.renderRevision++
  }

  async loadFile() {
    const revision = ++this.loadRevision
    const hasSnapshot = this.fileVersion.length > 0
    this.refreshing = true
    if (hasSnapshot && !this.sourceMode) await this.rememberReading()
    if (revision !== this.loadRevision) return
    try {
      const params = this.getUIContext().getRouter().getParams() as ProjectParams
      const repoId = params.repoId || ''
      const path = params.path || ''
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const file = await NotebookService.open(config.repos, repoId, path, config.todoDefaults, config.coreSettings)
      if (revision !== this.loadRevision) return
      if (!file) throw new Error('项目文件已不存在，请返回存储库列表。')
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      const repository = (await workspace.repos()).find(item => item.id === repoId)
      const host = config.repos.find(item => item.rootDirectory === repository?.rootDirectory)
      if (revision !== this.loadRevision) return
      if (file.project() === null) {
        await this.getUIContext().getRouter().replaceUrl({ url: 'pages/FileDetail', params: { repoId, path } })
        return
      }
      const identity = JSON.stringify([repoId, path])
      const changed = identity !== this.fileIdentity || file.fileVersion !== this.fileVersion
      this.title = file.project() || '未命名项目'
      this.fileContext = `${repositoryLabel(host)} / ${path}`
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      this.renderedHtml = file.renderDocumentHtml()
      if (changed) {
        this.readingState = ''
        this.headerPassed = false
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
      AppShell({ title: this.headerPassed || this.sourceMode ? this.title : '项目', back: true, drawerOpen: $drawerOpen,
        backAction: (): void => { if (!this.onBackPress()) this.getUIContext().getRouter().back() },
        synchronized: (): void => { this.loadFile() },
        secondaryActionIcon: $r('app.media.ui_document_outline'),
        secondaryActionLabel: this.renderReady && !this.sourceMode && !this.refreshing ? '文档目录' : '',
        secondaryAction: (): void => { this.navigation.openOutline() },
        actionIcon: $r('app.media.ui_more'),
        actionLabel: this.loading || this.message || this.refreshing ? '' : '更多阅读操作',
        actionMenuItems: this.sourceMode ? [
          { title: '返回项目文档', action: (): void => { this.toggleSource() } }
        ] : [
          { title: '展开全部任务', disabled: !this.renderReady, action: (): void => { this.navigation.expandAll(true) } },
          { title: '收起全部任务', disabled: !this.renderReady, action: (): void => { this.navigation.expandAll(false) } },
          { title: '查看原文', action: (): void => { this.toggleSource() } }
        ] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开项目', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开项目', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile() } })
          } else {
            if (this.refreshMessage) {
              Text(this.refreshMessage).fontSize(12).fontColor(UiColor.error).width('100%').padding(12)
                .onClick((): void => { this.loadFile() })
            }
            OrgFilePreviewView({ content: this.content, renderedHtml: this.renderedHtml,
              displayMode: this.sourceMode ? 'source' : 'rendered', fileContext: this.fileContext, title: this.title,
              projectReading: true, readingState: this.readingState, revision: `${this.fileIdentity}:${this.renderRevision}`,
              navigation: this.navigation, scrolled: (offset: number): void => { this.headerPassed = offset > 130 },
              ready: (): void => { this.renderReady = true },
              failed: (message: string): void => { this.message = message } }).width('100%').layoutWeight(1)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
