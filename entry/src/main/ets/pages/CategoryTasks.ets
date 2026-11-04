import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { categoryTaskQuery, categoryNavigationQuery } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, CoreTaskCategory, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface CategoryParams { categories?: (string | null)[]; drawerOpen?: boolean }

@Entry
@Component
struct CategoryTasks {
  @State categoryValues: (string | null)[] = []
  @State categories: CoreTaskCategory[] = []
  private initialized: boolean = false
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
    if (!this.initialized) {
      const params = router.getParams() as CategoryParams | undefined
      this.categoryValues = params?.categories || []
      this.drawerOpen = params?.drawerOpen === true
      this.initialized = true
    }
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      const result = await NativeCoreService.queryTasks(config.repos,
        categoryTaskQuery(config.inboxFile, this.categoryValues), config.todoDefaults)
      const navigation = await NativeCoreService.queryTasks(config.repos,
        categoryNavigationQuery(config.inboxFile), config.todoDefaults)
      if (request !== this.requestId) return
      this.categories = navigation.categories
      this.tasks = result.tasks
    } catch (e) {
      if (request === this.requestId) {
        this.tasks = []
        this.message = `读取分类任务失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  toggleCategory(category: string | null) {
    this.categoryValues = this.categoryValues.includes(category)
      ? this.categoryValues.filter((value: string | null) => value !== category)
      : [...this.categoryValues, category]
    this.loadTasks()
  }

  title(): string {
    if (this.categoryValues.length === 0) return '全部任务'
    if (this.categoryValues.length > 1) return `已选 ${this.categoryValues.length} 个分类`
    return this.categoryValues[0] || '未分类'
  }

  build() {
    Column() {
      AppShell({ title: this.title(), activeRoute: 'pages/CategoryTasks',
        activeCategoryValues: this.categoryValues, activeCategories: this.categories, categoryBusy: this.loading,
        categoryToggled: (category: string | null): void => { this.toggleCategory(category) },
        drawerOpen: $drawerOpen,
        actionIcon: $r('app.media.ui_sync'), actionLabel: '刷新任务', action: (): void => { this.loadTasks() },
        fabLabel: '新增任务', fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取分类任务', busy: true })
          } else if (this.message) {
            EmptyState({ title: '分类任务读取失败', detail: this.message,
              actionLabel: '重试', action: (): void => { this.loadTasks() } })
          } else {
            Text(`${this.tasks.length} 个未完成任务`).fontSize(13).fontColor(UiColor.secondary)
              .width('100%').padding(16).backgroundColor(UiColor.container)
            if (this.tasks.length === 0) {
              EmptyState({ title: '此分类下没有未完成任务', detail: '可以从侧边栏选择其他分类，或打开笔记本查看所有任务。' })
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
