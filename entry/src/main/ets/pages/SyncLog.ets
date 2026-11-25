import { localizedText } from '../ui/LocalizedText'
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
        this.message = state.message ? localizedText($r('app.string.text_reading_sync_log_failed'), String(state.message)) : ''
        if (!state.value) return
        this.repositoryName = state.value.repositoryName; this.repoId = state.value.repoId
        this.items = state.value.items; this.revision = state.revision
        if (params?.syncId && !this.items.some(item => item.id === params.syncId)) { this.items = []; this.message = localizedText($r('app.string.text_the_simultaneous_log_for_notification_no_longer')) }
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
      NotificationEmptyState({ title: localizedText($r('app.string.text_reading_synchronization_log')), busy: true })
    } else if (this.message) {
      NotificationEmptyState({ title: localizedText($r('app.string.text_sync_log_reading_failed')), detail: this.message, actionLabel: localizedText($r('app.string.text_retry')), action: (): void => { this.loadLogs(true) } })
    } else if (this.items.length === 0) {
      NotificationEmptyState({ title: localizedText($r('app.string.text_synchronisation_log_not_available')), detail: localizedText($r('app.string.text_once_a_file_is_synchronized_the_records')) })
    } else if (this.visibleItems().length === 0) {
      NotificationEmptyState({ title: localizedText($r('app.string.text_no_uploads_or_downloads_at_this_time')), detail: localizedText($r('app.string.text_show_all_logs_by_tap_on_the')) })
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
      AppShell({ title: this.repositoryName ? localizedText($r('app.string.text_synchronization_log'), String(this.repositoryName)) : localizedText($r('app.string.text_synchronization_log_2')), back: true, backAction: (): void => { PageNavigator.shared.back(this.getUIContext()) },
        actionIcon: this.showUnchanged ? $r('app.media.ui_visibility_selected') : $r('app.media.ui_visibility_off'),
        actionLabel: this.showUnchanged ? localizedText($r('app.string.text_hide_no_change_log')) : localizedText($r('app.string.text_show_all_logs')),
        action: (): void => { this.showUnchanged = !this.showUnchanged },
        drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() { this.content() }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
