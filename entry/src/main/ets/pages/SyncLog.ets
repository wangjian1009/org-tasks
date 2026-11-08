import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { SyncLogItem } from '../components/SyncLogItem'
import { syncLogRenderKey, visibleSyncLogs } from '../ui/SyncLogPresentation'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreSyncRecord, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { repositoryLabel } from '../ui/Theme'

interface SyncLogParams {
  repoId: string
}

@Entry
@Component
struct SyncLog {
  @State items: CoreSyncRecord[] = []
  @State repositoryName: string = ''
  @State repoId: string = ''
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showUnchanged: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadLogs() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadLogs() {
    const request = ++this.requestId
    this.loading = this.items.length === 0
    this.message = ''
    try {
      const params = this.getUIContext().getRouter().getParams() as SyncLogParams | undefined
      const repoId = this.repoId || params?.repoId
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      if (request !== this.requestId) return
      const repository = config.repos.find((repo) => repo.id === repoId)
      if (!repository) throw new Error('此存储库已不存在，请返回存储库列表')
      this.repositoryName = repositoryLabel(repository)
      this.repoId = repository.id
      const items = await NativeCoreService.repositoryHistory(config.repos, repository, config.todoDefaults)
      if (request !== this.requestId) return
      items.sort((left: CoreSyncRecord, right: CoreSyncRecord): number => right.started_at - left.started_at)
      this.items = items
    } catch (e) {
      if (request === this.requestId) {
        this.items = []
        this.message = `读取同步日志失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  visibleItems(): CoreSyncRecord[] { return visibleSyncLogs(this.items, this.showUnchanged) }

  @Builder
  content() {
    if (this.loading) {
      EmptyState({ title: '正在读取同步日志', busy: true })
    } else if (this.message) {
      EmptyState({ title: '同步日志读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadLogs() } })
    } else if (this.items.length === 0) {
      EmptyState({ title: '暂无同步日志', detail: '完成一次文件同步后，记录会显示在这里。' })
    } else if (this.visibleItems().length === 0) {
      EmptyState({ title: '暂无上传或下载记录', detail: '点击右上角显示全部日志' })
    } else {
      List() {
        ForEach(this.visibleItems(), (item: CoreSyncRecord) => {
          ListItem() { SyncLogItem({ record: item, open: (): void => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/SyncDetail', params: { repoId: this.repoId, syncId: item.id } })
          } }) }
        }, (item: CoreSyncRecord) => syncLogRenderKey(item))
      }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 }).edgeEffect(EdgeEffect.None)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
  }

  build() {
    Column() {
      AppShell({ title: this.repositoryName ? `${this.repositoryName} · 同步日志` : '同步日志', back: true, backAction: (): void => { this.getUIContext().getRouter().back() },
        actionIcon: this.showUnchanged ? $r('app.media.ui_visibility_selected') : $r('app.media.ui_visibility_off'),
        actionLabel: this.showUnchanged ? '隐藏无变化日志' : '显示全部日志',
        action: (): void => { this.showUnchanged = !this.showUnchanged },
        synchronized: (): void => { this.loadLogs() }, drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() { this.content() }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
