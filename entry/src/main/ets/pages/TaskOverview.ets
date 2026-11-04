import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { overviewTaskQuery, overviewTitle, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

interface OverviewParams { view?: OverviewKind }

@Entry
@Component
struct TaskOverview {
  @State view: OverviewKind = 'today'
  @State tasks: CoreTask[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State needsConfiguration: boolean = false
  @State drawerOpen: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadTasks() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadTasks() {
    const request = ++this.requestId
    this.view = (router.getParams() as OverviewParams | undefined)?.view || 'today'
    this.loading = true
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(getContext(this))
      if (this.view === 'someday' && !config.somedayFile) {
        this.needsConfiguration = true
        this.tasks = []
        return
      }
      const result = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery(this.view, config.somedayFile), config.todoDefaults)
      if (request !== this.requestId) return
      this.tasks = result.tasks
    } catch (e) {
      if (request === this.requestId) {
        this.tasks = []
        this.message = `读取任务失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  build() {
    Column() {
      AppShell({ title: overviewTitle(this.view), activeRoute: 'pages/TaskOverview', activeOverview: this.view,
        drawerOpen: $drawerOpen, actionIcon: $r('app.media.ui_sync'), actionLabel: '刷新任务',
        action: (): void => { this.loadTasks() }, fabLabel: '新增任务',
        fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取任务', busy: true })
          } else if (this.needsConfiguration) {
            EmptyState({ title: '尚未配置某天文件', detail: '请在设置的“笔记与笔记本”中配置某天文件。',
              actionLabel: '前往设置', action: (): void => {
                router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
              } })
          } else if (this.message) {
            EmptyState({ title: '任务读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadTasks() } })
          } else {
            Text(`${this.tasks.length} 个${this.view === 'logbook' ? '已完成' : '未完成'}任务`)
              .fontSize(13).fontColor(UiColor.secondary).width('100%').padding(16).backgroundColor(UiColor.container)
            if (this.tasks.length === 0) {
              EmptyState({ title: '没有符合条件的任务', detail: this.view === 'today' ? '今天没有到期或过期任务。' : '新增任务或同步后可以刷新此列表。' })
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
