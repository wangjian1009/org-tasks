import { TitleText } from '../components/TitleText'
import { AppShell } from '../components/AppShell'
import { EmptyState, ListSectionHeader } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, CoreTitlePart, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { fileSizeLabel, fileModifiedLabel } from '../ui/NotebookPresentation'

@Entry
@Component
struct Files {
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showIgnored: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadFiles() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  toggleIgnored() {
    this.showIgnored = !this.showIgnored
  }

  openMore() {
    this.getUIContext().showActionSheet({ title: '存储库', message: '选择操作', sheets: [
      { title: '同步日志', action: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SyncLog' }) } },
      { title: this.showIgnored ? '隐藏配置的隐藏文件' : '显示配置的隐藏文件', action: (): void => { this.toggleIgnored() } }
    ] })
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
        action: (): void => { this.openMore() },
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
                        .width('100%').padding({ top: 12, bottom: 16 })
                    }
                  }
                  ForEach(this.visibleFiles(group), (file: CoreOrgFileMetadata) => {
                    ListItem() {
                      Column({ space: 4 }) {
                        TitleText({ text: file.title || file.path, parts: file.titleParts, lineLimit: 2 }).width('100%')
                        Text(file.path).fontSize(12).fontColor(UiColor.secondary).width('100%')
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(`${file.taskCount} 条笔记 · ${fileSizeLabel(file.byteLength)}`).fontSize(12)
                          .fontColor(UiColor.secondary).width('100%')
                        Text(fileModifiedLabel(file.modifiedAt)).fontSize(12).fontColor(UiColor.secondary).width('100%')
                      }.width('100%').constraintSize({ minHeight: 60 }).padding({ top: 10, bottom: 10 })
                        .accessibilityGroup(true).accessibilityText(`${file.titleParts.length > 0 ? file.titleParts.map((part: CoreTitlePart): string => part.text).join('') : file.path}，文件 ${file.path}，${file.taskCount} 条笔记，${fileSizeLabel(file.byteLength)}，${fileModifiedLabel(file.modifiedAt)}`)
                        .onClick((): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/FileDetail', params: { repoId: file.repoId, path: file.path } }) })
                    }
                  }, (file: CoreOrgFileMetadata) => `${file.repoId}:${file.path}`)
                }
              }, (group: NotebookGroup) => `${group.configId}:${group.name}`)
            }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }

  @Builder
  repositoryHeader(group: NotebookGroup) {
    ListSectionHeader({ title: group.name })
      .accessibilityText(`存储库 ${group.name}，点击打开存储库设置`)
      .enabled(group.configId.length > 0)
      .onClick((): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/RepositorySettings', params: { repoId: group.configId } }) })
  }
}
