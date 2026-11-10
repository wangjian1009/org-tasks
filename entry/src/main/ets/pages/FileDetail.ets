import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { OrgContentView } from '../components/OrgContentView'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFile, CoreTitlePart, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { syncLogTimeLabel } from '../ui/SyncLogPresentation'
import { UiColor } from '../ui/Theme'

interface NotebookParams { repoId?: string; path?: string; syncId?: string; repositoryName?: string; backupTime?: number; backupPath?: string }

@Entry
@Component
struct FileDetail {
  @State path: string = ''
  @State historyLabel: string = ''
  @State title: string = ''
  @State titleParts: CoreTitlePart[] = []
  @State content: string = ''
  @State renderedHtml: string = ''
  @State displayMode: 'rendered' | 'source' = 'rendered'
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State renderReady: boolean = false
  @State allCollapsed: boolean = false
  private controller: webview.WebviewController = new webview.WebviewController()
  private loadRevision: number = 0

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
      const params = this.getUIContext().getRouter().getParams() as NotebookParams
      this.path = params.path || ''
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      let file: CoreOrgFile | undefined = undefined
      if (params.syncId) {
        const repository = config.repos.find((item) => item.id === params.repoId)
        if (!repository) throw new Error('此存储库已不存在')
        const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
        file = await repo.historyFile(params.syncId, this.path, false)
        this.historyLabel = `历史备份 · ${params.backupPath || this.path}\n${params.repositoryName || ''}${params.backupTime ? ` · ${syncLogTimeLabel(params.backupTime)}` : ''}`
      } else {
        file = await NotebookService.open(config.repos, params.repoId || '', this.path, config.todoDefaults)
        this.historyLabel = ''
      }
      if (revision !== this.loadRevision) return
      if (!file) { this.message = '该文件已不存在，请返回存储库列表。'; return }
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

  async toggleAll() {
    if (!this.renderReady || this.displayMode !== 'rendered' || this.loading) return
    // 仅改变阅读 DOM 的折叠状态，不向文档注入脚本或绑定写入接口。
    try {
      const result = await this.controller.runJavaScript("(function() { var collapse = !!document.querySelector('details.heading[open]'); document.querySelectorAll('details.heading').forEach(function(node) { node.open = !collapse; }); return collapse; })()")
      this.allCollapsed = result === 'true'
    } catch (e) {
      this.message = `阅读视图加载失败：${coreErrorMessage(e as CoreBridgeError)}`
    }
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || '文件', titleParts: this.titleParts, titleIcon: $r('app.media.ui_folder'), synchronized: (): void => { this.loadFile() }, back: true, drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_expand'), actionLabel: this.displayMode === 'rendered' && this.renderReady ? (this.allCollapsed ? '展开全部' : '收起全部') : '',
        action: (): void => { this.toggleAll() } }) {
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
                ready: (): void => { this.renderReady = true }, failed: (message: string): void => { this.message = message } })
                .width('100%').layoutWeight(1)
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
