import { NotebookFileRow } from '../components/NotebookFileRow'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppMenuItem, AppShell } from '../components/AppShell'
import { EmptyState, ListSectionHeader } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { fileUsageKinds } from '../ui/NotebookPresentation'

@Entry
@Component
struct Files {
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showIgnored: boolean = false
  @State config: AppConfig = DEFAULT_CONFIG
  private requestId: number = 0

  onPageShow() { this.loadFiles() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  toggleIgnored() {
    this.showIgnored = !this.showIgnored
  }

  visibleFiles(group: NotebookGroup): CoreOrgFileMetadata[] {
    return this.showIgnored ? group.files : group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore)
  }

  async loadFiles() {
    const request = ++this.requestId
    this.loading = this.groups.length === 0
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const groups = await NotebookService.list(config.repos, config.todoDefaults)
      if (request !== this.requestId) return
      this.config = config
      this.groups = groups
    } catch (e) {
      if (request === this.requestId) {
        this.groups = []
        this.message = `读取存储库失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  build() {
    Column() {
      AppShell({ title: '存储库', titleIcon: $r('app.media.nav_repository'),
        actionIcon: $r('app.media.ui_more'), actionLabel: '更多',
        actionMenuItems: [
          { title: '同步日志', action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SyncLog' }) } },
          { title: this.showIgnored ? '隐藏配置的隐藏文件' : '显示配置的隐藏文件', action: (): void => { this.toggleIgnored() } }
        ] as AppMenuItem[],
        synchronized: (): void => { this.loadFiles() }, activeRoute: 'pages/Files', drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取存储库', busy: true })
          } else if (this.message) {
            EmptyState({ title: '存储库读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles() } })
          } else if (this.groups.length === 0) {
            EmptyState({ title: '还没有存储库', detail: '尚未配置可浏览的本地或 WebDAV 存储库。' })
          } else {
            List() {
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
                      NotebookFileRow({ file, usages: fileUsageKinds(this.config, group.configId, file.path) })
                    }
                  }, (file: CoreOrgFileMetadata) => JSON.stringify(file))
                }
              }, (group: NotebookGroup) => `${group.configId}:${group.name}`)
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
    ListSectionHeader({ title: group.name }).padding({ left: 8, right: 8 })
      .accessibilityText(`存储库 ${group.name}，点击打开存储库设置`)
      .enabled(group.configId.length > 0)
      .onClick((): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/RepositorySettings', params: { repoId: group.configId } }) })
  }
}
