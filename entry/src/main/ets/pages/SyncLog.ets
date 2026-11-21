import { PageNavigator } from '../services/PageNavigator'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { SyncLogDetails } from '../components/SyncLogDetails'
import { SyncLogItem } from '../components/SyncLogItem'
import { syncLogRenderKey, visibleSyncLogs } from '../ui/SyncLogPresentation'
import { SyncLogDataManager, SyncLogSnapshot } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { CoreSyncRecord } from '../services/NativeCoreService'
import { repositoryLabel } from '../ui/Theme'

interface SyncLogParams {
  repoId: string
  syncId?: string
}

@Entry
@Component
struct SyncLog {
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @State items: CoreSyncRecord[] = []
  @State repositoryName: string = ''
  @State repoId: string = ''
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showUnchanged: boolean = false
  @State expandedId: string = ''
  @State revision: number = 0
  private requestId: number = 0
  private initialTarget: boolean = false

  private dataManager: SyncLogDataManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  aboutToDisappear(): void {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopData?.(); this.dataManager?.close()
  }
  aboutToAppear(): void {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
  }

  onPageShow() { this.loadLogs() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  async loadLogs(reload: boolean = false) {
    const params = this.getUIContext().getRouter().getParams() as SyncLogParams | undefined
    if (!this.initialTarget && params?.syncId) {
      this.expandedId = params.syncId; this.showUnchanged = true; this.initialTarget = true
    }
    if (!this.dataManager) {
      this.dataManager = new SyncLogDataManager(this.getUIContext().getHostContext()!, this.repoId || params?.repoId || '')
      this.stopData = this.dataManager.subscribe((state: SnapshotState<SyncLogSnapshot>): void => {
        if (!state.value && !state.message) return
        this.loading = false
        this.message = state.message ? `读取同步日志失败：${state.message}` : ''
        if (!state.value) return
        this.repositoryName = state.value.repositoryName; this.repoId = state.value.repoId
        this.items = state.value.items; this.revision = state.revision
        if (params?.syncId && !this.items.some(item => item.id === params.syncId)) { this.items = []; this.message = '通知对应的同步记录已不存在' }
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  visibleItems(): CoreSyncRecord[] { return visibleSyncLogs(this.items, this.showUnchanged) }

  initialIndex(): number {
    const index = this.visibleItems().findIndex((item: CoreSyncRecord) => item.id === this.expandedId)
    return index < 0 ? 0 : index + (this.showNotifications ? 1 : 0)
  }

  @Builder
  content() {
    if (this.loading) {
      NotificationEmptyState({ title: '正在读取同步日志', busy: true })
    } else if (this.message) {
      NotificationEmptyState({ title: '同步日志读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadLogs(true) } })
    } else if (this.items.length === 0) {
      NotificationEmptyState({ title: '暂无同步日志', detail: '完成一次文件同步后，记录会显示在这里。' })
    } else if (this.visibleItems().length === 0) {
      NotificationEmptyState({ title: '暂无上传或下载记录', detail: '点击右上角显示全部日志' })
    } else {
      List({ initialIndex: this.initialIndex() }) {
              if (this.showNotifications) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
        ForEach(this.visibleItems(), (item: CoreSyncRecord) => {
          ListItem() {
            Column() {
              SyncLogItem({ record: item, expanded: this.expandedId === item.id, open: (): void => {
                this.expandedId = this.expandedId === item.id ? '' : item.id
              } })
              if (this.expandedId === item.id) {
                SyncLogDetails({ repoId: this.repoId, syncId: item.id, repositoryName: this.repositoryName })
              }
            }.width('100%')
          }
        }, (item: CoreSyncRecord) => `${this.revision}:${syncLogRenderKey(item)}`)
      }.width('100%').layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 16 }).edgeEffect(EdgeEffect.None)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
  }

  build() {
    Column() {
      AppShell({ title: this.repositoryName ? `${this.repositoryName} · 同步日志` : '同步日志', back: true, backAction: (): void => { PageNavigator.shared.back(this.getUIContext()) },
        actionIcon: this.showUnchanged ? $r('app.media.ui_visibility_selected') : $r('app.media.ui_visibility_off'),
        actionLabel: this.showUnchanged ? '隐藏无变化日志' : '显示全部日志',
        action: (): void => { this.showUnchanged = !this.showUnchanged },
        drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() { this.content() }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
