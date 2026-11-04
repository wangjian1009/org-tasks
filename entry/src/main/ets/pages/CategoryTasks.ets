import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { NotebookService } from '../services/NotebookService'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface CategoryParams { category?: string | null }

@Entry
@Component
struct CategoryTasks {
  @State category: string | null = null
  @State tasks: CoreTask[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadTasks() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadTasks() {
    const request = ++this.requestId
    this.category = (router.getParams() as CategoryParams | undefined)?.category || null
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      const notebooks = await NotebookService.load(config.repos, config.todoDefaults)
      if (request !== this.requestId) return
      this.tasks = NotebookService.tasksInCategory(notebooks, this.category)
    } catch (e) {
      if (request === this.requestId) {
        this.tasks = []
        this.message = `读取分类任务失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  build() {
    Column() {
      AppShell({ title: this.category || '未分类', activeRoute: 'pages/CategoryTasks',
        activeCategoryKey: NotebookService.categoryKey(this.category), drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_sync'), actionLabel: '刷新任务', action: (): void => { this.loadTasks() },
        fabLabel: '新增任务', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取分类任务', busy: true })
          } else if (this.message) {
            EmptyState({ title: '分类任务读取失败', detail: this.message,
              actionLabel: '重试', action: (): void => { this.loadTasks() } })
          } else {
            Text(`${this.tasks.length} 个任务`).fontSize(13).fontColor(UiColor.secondary)
              .width('100%').padding(16).backgroundColor(UiColor.container)
            if (this.tasks.length === 0) {
              EmptyState({ title: '此分类下没有任务', detail: '可以从侧边栏选择其他分类，或打开笔记本查看文件。' })
            } else {
              List() {
                ForEach(this.tasks, (task: CoreTask) => {
                  ListItem() {
                    TaskRow({ task, showBody: true, open: (): void => {
                      router.pushUrl({ url: 'pages/TaskDetail', params: { task } })
                    } })
                  }
                }, (task: CoreTask) => task.id)
              }.width('100%').layoutWeight(1).padding({ bottom: 88 })
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
