import { addRepository } from '../services/RepositoryNavigation'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { NotebookFileRow } from '../components/NotebookFileRow'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { IconButton } from '../components/controls/IconButton'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { fileUsageKinds } from '../ui/NotebookPresentation'

@Entry
@Component
struct Files {
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showIgnoredRepoIds: string[] = []
  @State config: AppConfig = DEFAULT_CONFIG
  private requestId: number = 0

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  toggleIgnored(group: NotebookGroup) {
    this.showIgnoredRepoIds = this.showIgnoredRepoIds.includes(group.repoId)
      ? this.showIgnoredRepoIds.filter((id: string) => id !== group.repoId)
      : this.showIgnoredRepoIds.concat(group.repoId)
  }

  visibleFiles(group: NotebookGroup): CoreOrgFileMetadata[] {
    return this.showIgnoredRepoIds.includes(group.repoId) ? group.files : group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore)
  }

  async loadFiles() {
    const request = ++this.requestId
    this.loading = this.groups.length === 0
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const groups = await NotebookService.list(config)
      if (request !== this.requestId) return
      this.config = config
      this.groups = groups
    } catch (e) {
      if (request === this.requestId) {
        this.groups = []
        this.message = `读取笔记本失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  build() {
    Column() {
      AppShell({ refreshOnPageShow: true, title: '笔记本', titleIcon: $r('app.media.nav_repository'),
        actionIcon: $r('app.media.ui_add'), actionLabel: '添加存储库',
        action: (): void => { addRepository(this.getUIContext()) },
        synchronized: (): void => { this.loadFiles() }, activeRoute: 'pages/Files', drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() {
          if (this.loading) {
            NotificationEmptyState({ title: '正在读取笔记本', busy: true })
          } else if (this.message) {
            NotificationEmptyState({ title: '笔记本读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles() } })
          } else if (this.groups.length === 0) {
            NotificationEmptyState({ title: '还没有存储库', actionLabel: '添加存储库', action: (): void => { addRepository(this.getUIContext()) } })
          } else {
            List() {
              if (this.notificationState.notifications.length > 0) {
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
        IconButton({ icon: $r('app.media.ui_settings'), label: `${group.name}：管理存储库`, disabled: group.configId.length === 0,
          iconSize: 20, buttonWidth: 40,
          action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/RepositorySettings', params: { repoId: group.configId } }) } })
        IconButton({ icon: this.showIgnoredRepoIds.includes(group.repoId) ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
          iconSize: 20, buttonWidth: 40,
          label: `${group.name}：${this.showIgnoredRepoIds.includes(group.repoId) ? '隐藏配置的隐藏文件' : '显示配置的隐藏文件'}`,
          action: (): void => { this.toggleIgnored(group) } })
        IconButton({ icon: $r('app.media.ui_sync_log'), label: `${group.name}：同步日志`, disabled: group.configId.length === 0,
          iconSize: 20, buttonWidth: 40,
          action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SyncLog', params: { repoId: group.configId } }) } })
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
  }
}
