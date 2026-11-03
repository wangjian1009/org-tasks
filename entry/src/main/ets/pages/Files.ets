import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { Notebook, NotebookService } from '../services/NotebookService'
import { CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { repositoryName, UiColor } from '../ui/Theme'

interface FileListParams { category?: string | null }

@Entry
@Component
struct Files {
  @State files: Notebook[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State categoryFiltered: boolean = false
  @State category: string | null = null

  onPageShow() { this.loadFiles() }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadFiles() {
    this.loading = true
    this.message = ''
    const params = router.getParams() as FileListParams | undefined
    this.categoryFiltered = params?.category !== undefined
    this.category = params?.category || null
    try {
      const config = await AppConfigService.load(getContext(this))
      const files = await NotebookService.load(config.repos, config.todoDefaults)
      this.files = this.categoryFiltered ? NotebookService.inCategory(files, this.category) : files
    } catch (e) {
      this.files = []
      this.message = `读取笔记本失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { this.loading = false }
  }

  build() {
    Column() {
      AppShell({ title: this.categoryFiltered ? this.category || '未分类' : '笔记本', activeRoute: 'pages/Files', drawerOpen: $drawerOpen,
      activeCategoryKey: this.categoryFiltered ? NotebookService.categoryKey(this.category) : '',
      actionLabel: '搜索笔记', action: (): void => { router.pushUrl({ url: 'pages/Search' }) },
      extraLabel: '笔记本操作', extraAction: (): void => { this.getUIContext().showActionSheet({ message: '',
        title: '笔记本', sheets: [
          { title: '刷新文件', action: (): void => { this.loadFiles() } },
          { title: '同步', action: (): void => { router.pushUrl({ url: 'pages/Index' }) } },
          { title: '存储库', action: (): void => { router.pushUrl({ url: 'pages/Repositories' }) } }
        ] }) },
      fabLabel: '新增任务', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取笔记本', busy: true })
          } else if (this.message) {
            EmptyState({ title: '笔记本读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles() } })
          } else if (this.files.length === 0) {
            EmptyState({ title: this.categoryFiltered ? '此分类下没有笔记本' : '还没有笔记本',
              detail: this.categoryFiltered ? '文件可能已移除或分类已变更。可以返回查看全部笔记本。' : '添加本地目录或 WebDAV 存储库后，org 文件会显示在这里。',
              actionLabel: this.categoryFiltered ? '全部笔记本' : '管理存储库', action: (): void => {
                if (this.categoryFiltered) router.replaceUrl({ url: 'pages/Files' })
                else router.pushUrl({ url: 'pages/Repositories' })
              } })
          } else {
            List({ space: 12 }) {
              ForEach(this.files, (file: Notebook) => {
                ListItem() {
                  Column({ space: 10 }) {
                    Text(file.path).fontSize(22).fontColor(UiColor.text).width('100%').maxLines(2)
                    Row({ space: 8 }) {
                      Image($r('app.media.ui_folder')).width(15).height(15)
                      Text(repositoryName(file.rootDirectory)).fontSize(13).fontColor(UiColor.secondary)
                    }.width('100%')
                    Text(`${file.tasks.length} 条笔记 · ${file.byteLength} 字节`).fontSize(12).fontColor(UiColor.secondary).width('100%')
                  }.width('100%').padding(16).backgroundColor(UiColor.container).borderRadius(16)
                    .border({ width: 0.5, color: UiColor.outline })
                    .onClick((): void => { router.pushUrl({ url: 'pages/FileDetail', params: { repoId: file.repoId, path: file.path } }) })
                }
              }, (file: Notebook) => file.id)
            }.width('100%').height('100%').padding({ left: 16, right: 16, top: 16, bottom: 88 })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
