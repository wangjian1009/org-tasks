import { TrashDataManager } from '../services/TrashDataManager'
import { PageNavigator } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { NotebookFileRow } from '../components/NotebookFileRow'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { IconButton } from '../components/controls/IconButton'
import { PopupMenuButton } from '../components/controls/PopupMenuButton'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { NotebookDataManager, NotebookSnapshot } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { NotebookGroup } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { fileUsageKinds } from '../ui/NotebookPresentation'
import { SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'

@Entry
@Component
struct Files {
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showIgnoredRepoIds: string[] = []
  @State config: AppConfig = DEFAULT_CONFIG
  private trashMaintenance: Promise<void> | undefined = undefined
  private dataManager: NotebookDataManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  aboutToAppear(): void {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
  }

  onPageShow(): void { this.loadFiles() }
  aboutToDisappear(): void {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopData?.(); this.dataManager?.close()
  }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  toggleIgnored(group: NotebookGroup) {
    this.showIgnoredRepoIds = this.showIgnoredRepoIds.includes(group.repoId)
      ? this.showIgnoredRepoIds.filter((id: string) => id !== group.repoId)
      : this.showIgnoredRepoIds.concat(group.repoId)
  }

  visibleFiles(group: NotebookGroup): CoreOrgFileMetadata[] {
    return this.showIgnoredRepoIds.includes(group.repoId) ? group.files : group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore)
  }

  repositoryActions(group: NotebookGroup): PopupMenuItem[] {
    return [
      { title: '设置', icon: $r('app.media.ui_settings'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/RepositorySettings', params: { repoId: group.configId } })
      } },
      { title: '历史', icon: $r('app.media.ui_sync_log'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/SyncLog', params: { repoId: group.configId } })
      } }
    ]
  }

  async loadFiles(reload: boolean = false) {
    if (!this.trashMaintenance) {
      const trash = new TrashDataManager(this.getUIContext().getHostContext()!)
      this.trashMaintenance = trash.start().catch((): void => {
        try { this.getUIContext().getPromptAction().showToast({ message: '废纸篓过期清理失败，可打开废纸篓重试' }) }
        catch (_) { console.error('显示废纸篓清理提示失败') }
      }).finally(async (): Promise<void> => { await trash.close() }).catch((): void => { console.error('关闭废纸篓清理数据集失败') })
    }
    if (!this.dataManager) {
      this.dataManager = new NotebookDataManager(this.getUIContext().getHostContext()!)
      this.stopData = this.dataManager.subscribe((state: SnapshotState<NotebookSnapshot>): void => {
        if (state.value) { this.config = state.value.config; this.groups = state.value.groups; this.loading = false }
        this.message = state.message ? `读取笔记本失败：${state.message}` : ''
        if (state.message) this.loading = false
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  build() {
    Column() {
      AppShell({ title: '笔记本', titleIcon: $r('app.media.nav_repository'),
        actionIcon: $r('app.media.ui_add'), actionLabel: '添加存储库',
        action: (): void => { addRepository(this.getUIContext()) },
        activeRoute: 'pages/Files', drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() {
          if (this.loading) {
            NotificationEmptyState({ title: '正在读取笔记本', busy: true })
          } else if (this.message) {
            NotificationEmptyState({ title: '笔记本读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles(true) } })
          } else if (this.groups.length === 0) {
            NotificationEmptyState({ title: '还没有存储库', actionLabel: '添加存储库', action: (): void => { addRepository(this.getUIContext()) } })
          } else {
            List() {
              if (this.showNotifications) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
              ForEach(this.groups, (group: NotebookGroup) => {
                ListItemGroup({ header: this.repositoryHeader(group) }) {
                  if (this.visibleFiles(group).length === 0) {
                    ListItem() {
                      Text(group.message || (group.files.length > 0 ? '暂无可见 Org 文件' : '暂无 Org 文件')).fontSize(13)
                        .fontColor(group.message ? UiColor.error : UiColor.secondary)
                        .width('100%').padding({ left: 8, right: 8, top: 12, bottom: 16 })
                    }
                  }
                  ForEach(this.visibleFiles(group), (file: CoreOrgFileMetadata) => {
                    ListItem() {
                      NotebookFileRow({ file, configRepoId: group.configId, usages: fileUsageKinds(this.config, group.configId, file.path) })
                    }
                  }, (file: CoreOrgFileMetadata) => JSON.stringify(file))
                }
              }, (group: NotebookGroup) => JSON.stringify(group))
            }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }

  @Builder
  repositoryHeader(group: NotebookGroup) {
    Column({ space: 10 }) {
      Row() {
        Row({ space: 10 }) {
          Image($r('app.media.ui_category')).width(22).height(22)
          Text(group.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).height(48)
          .accessibilityText(`存储库 ${group.name}`)
        if (group.configId !== SYSTEM_REPOSITORY_ID) {
          IconButton({ icon: this.showIgnoredRepoIds.includes(group.repoId) ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
            iconSize: 20, buttonWidth: 40,
            label: `${group.name}：${this.showIgnoredRepoIds.includes(group.repoId) ? '隐藏配置的隐藏文件' : '显示配置的隐藏文件'}`,
            action: (): void => { this.toggleIgnored(group) } })
          PopupMenuButton({ label: `${group.name}：更多`, disabled: group.configId.length === 0,
            iconSize: 20, buttonWidth: 40, items: this.repositoryActions(group) })
        }
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
  }
}
