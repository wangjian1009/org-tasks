import { PageNavigator } from '../services/PageNavigator'
import { util } from '@kit.ArkTS'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { OrgFilePreviewView, OrgFilePreviewNavigation } from '../components/OrgFilePreviewView'
import { FileDataManager, FileReadingSnapshot } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { CoreBridgeError, CoreTitlePart, coreErrorMessage } from '../services/NativeCoreService'
import { syncLogTimeLabel } from '../ui/SyncLogPresentation'
import { UiColor } from '../ui/Theme'

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
  private navigation: OrgFilePreviewNavigation = new OrgFilePreviewNavigation()
  private loadRevision: number = 0

  private dataManager: FileDataManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  private pageVisible: boolean = true
  private latestState: SnapshotState<FileReadingSnapshot> | undefined = undefined
  aboutToDisappear(): void { this.stopData?.(); this.dataManager?.close() }
  onPageShow() { this.pageVisible = true; this.loadFile(); if (this.latestState) this.applyFileSnapshot(this.latestState) }
  onPageHide() {
    this.pageVisible = false
    this.loadRevision++
    this.renderReady = false
  }
  onBackPress(): boolean {
    if (this.navigation.closePanel()) return true
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  async loadFile(reload: boolean = false) {
    if (!this.dataManager) {
      const params = this.getUIContext().getRouter().getParams() as NotebookParams
      this.path = params.path || ''
      this.dataManager = new FileDataManager(this.getUIContext().getHostContext()!, { repoId: params.repoId || '', path: this.path, syncId: params.syncId })
      this.stopData = this.dataManager.subscribe((state: SnapshotState<FileReadingSnapshot>): void => {
        this.latestState = state
        this.applyFileSnapshot(state)
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  async applyFileSnapshot(state: SnapshotState<FileReadingSnapshot>): Promise<void> {
    if (!this.pageVisible || (!state.value && !state.message)) return
    const revision = ++this.loadRevision
    try {
      if (state.message) throw new Error(state.message)
      const params = this.getUIContext().getRouter().getParams() as NotebookParams
      const config = state.value!.config
      const file = state.value!.file
      if (!file) { this.message = '该文件已不存在，请返回存储库列表。'; return }
      if (!params.syncId && file.project() !== null) {
        await PageNavigator.shared.replacePage(this.getUIContext(), { url: 'pages/ProjectDetail', params: { repoId: params.repoId, path: this.path } })
        return
      }
      if (revision !== this.loadRevision) return
      this.historyLabel = params.syncId ? `历史备份 · ${params.backupPath || this.path}\n${params.repositoryName || ''}${params.backupTime ? ` · ${syncLogTimeLabel(params.backupTime)}` : ''}` : ''
      this.fileContext = `${state.value!.repositoryName} / ${this.path}`
      this.displayMode = config.fileDisplayMode
      this.title = file.title() || this.path
      this.titleParts = file.titleParts()
      this.content = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(file.sourceBytes())
      this.renderedHtml = file.renderHtml()
      this.message = ''
    } catch (e) { if (revision === this.loadRevision) this.message = `读取文件失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { if (revision === this.loadRevision) this.loading = false }
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || '文件', titleParts: this.titleParts, titleIcon: $r('app.media.ui_folder'),
        activeRoute: 'pages/FileDetail', back: PageNavigator.shared.path.depth > 1,
        backAction: (): void => { this.onBackPress() }, drawerOpen: $drawerOpen,
        secondaryActionIcon: $r('app.media.ui_document_outline'), secondaryActionLabel: this.displayMode === 'rendered' && this.renderReady ? '文档目录' : '',
        secondaryAction: (): void => { this.navigation.openOutline() },
        actionIcon: $r('app.media.ui_more'), actionLabel: this.displayMode === 'rendered' && this.renderReady ? '更多阅读操作' : '',
        actionMenuItems: [{ title: '展开全部章节', action: (): void => { this.navigation.expandAll(true) } },
          { title: '收起全部章节', action: (): void => { this.navigation.expandAll(false) } }] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在打开文件', busy: true })
          } else if (this.message) {
            EmptyState({ title: '无法打开文件', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFile(true) } })
          } else {
            if (this.historyLabel.length > 0) {
              Text(this.historyLabel).fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
            }
            OrgFilePreviewView({ content: this.content, renderedHtml: this.renderedHtml,
              displayMode: this.displayMode, fileContext: this.fileContext, title: this.title,
              revision: `${this.loadRevision}`, navigation: this.navigation,
              ready: (): void => { this.renderReady = true }, failed: (message: string): void => { this.message = message } })
              .width('100%').layoutWeight(1)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')

  }
}
