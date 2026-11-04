import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, ListSectionHeader } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookGroup, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { fileSizeLabel, fileModifiedLabel } from '../ui/NotebookPresentation'

@Entry
@Component
struct Files {
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false

  onPageShow() { this.loadFiles() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadFiles() {
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      this.groups = await NotebookService.list(config.repos, config.todoDefaults)
    } catch (e) {
      this.groups = []
      this.message = `读取存储库失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.loading = false }
  }

  addRepository() {
    this.getUIContext().showActionSheet({ title: '新增存储库', message: '选择 Org 文件的来源', sheets: [
      { title: 'WebDAV', action: (): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: true } }) } },
      { title: '本地目录', action: (): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { webdav: false } }) } }
    ] })
  }

  build() {
    Column() {
      AppShell({ title: '存储库', synchronized: (): void => { this.loadFiles() }, activeRoute: 'pages/Files', drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_add'), actionLabel: '新增存储库', action: (): void => { this.addRepository() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取存储库', busy: true })
          } else if (this.message) {
            EmptyState({ title: '存储库读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles() } })
          } else if (this.groups.length === 0) {
            EmptyState({ title: '还没有存储库', detail: '添加本地目录或 WebDAV 存储库后，org 文件会显示在这里。',
              actionLabel: '新增存储库', action: (): void => { this.addRepository() } })
          } else {
            List() {
              ForEach(this.groups, (group: NotebookGroup) => {
                ListItemGroup({ header: this.repositoryHeader(group) }) {
                  if (group.files.length === 0) {
                    ListItem() {
                      Text(group.message || '暂无 Org 文件').fontSize(13).fontColor(group.message ? UiColor.error : UiColor.secondary)
                        .width('100%').padding({ top: 12, bottom: 16 })
                    }
                  }
                  ForEach(group.files, (file: CoreOrgFileMetadata) => {
                    ListItem() {
                      Column({ space: 4 }) {
                        Text(file.title || file.path).fontSize(16).fontColor(UiColor.text).width('100%')
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(file.path).fontSize(12).fontColor(UiColor.secondary).width('100%')
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(`${file.taskCount} 条笔记 · ${fileSizeLabel(file.byteLength)}`).fontSize(12)
                          .fontColor(UiColor.secondary).width('100%')
                        Text(fileModifiedLabel(file.modifiedAt)).fontSize(12).fontColor(UiColor.secondary).width('100%')
                      }.width('100%').constraintSize({ minHeight: 60 }).padding({ top: 10, bottom: 10 })
                        .accessibilityGroup(true).accessibilityText(`${file.title || file.path}，文件 ${file.path}，${file.taskCount} 条笔记，${fileSizeLabel(file.byteLength)}，${fileModifiedLabel(file.modifiedAt)}`)
                        .onClick((): void => { router.pushUrl({ url: 'pages/FileDetail', params: { repoId: file.repoId, path: file.path } }) })
                    }
                  }, (file: CoreOrgFileMetadata) => `${file.repoId}:${file.path}`)
                }
              }, (group: NotebookGroup) => `${group.configId}:${group.name}`)
            }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
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
      .onClick((): void => { router.pushUrl({ url: 'pages/RepositorySettings', params: { repoId: group.configId } }) })
  }
}
