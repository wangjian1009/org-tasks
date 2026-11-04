import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { TodayTaskList } from '../components/TodayTaskList'
import { RepositorySyncService } from '../services/RepositorySyncService'
import { AppConfigService } from '../services/AppConfigService'
import { overviewTaskQuery, overviewTitle, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { TodaySection, todaySections } from '../ui/TodayPresentation'

interface OverviewParams { view?: OverviewKind }

@Entry
@Component
struct TaskOverview {
  @State view: OverviewKind = 'today'
  @State tasks: CoreTask[] = []
  @State sections: TodaySection[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State needsConfiguration: boolean = false
  @State drawerOpen: boolean = false
  @State refreshing: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadTasks() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadTasks() {
    const request = ++this.requestId
    this.view = (router.getParams() as OverviewParams | undefined)?.view || 'today'
    this.loading = this.tasks.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(getContext(this))
      if (this.view === 'someday' && !config.somedayFile || this.view === 'memo' && !config.memoFile) {
        this.needsConfiguration = true
        this.tasks = []
        return
      }
      const result = await NativeCoreService.queryTasks(config.repos, overviewTaskQuery(this.view, config.somedayFile, config.memoFile), config.todoDefaults)
      const sections = this.view === 'today'
        ? await todaySections(result.tasks, await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)) : []
      if (request !== this.requestId) return
      this.tasks = result.tasks
      this.sections = sections
    } catch (e) {
      if (request === this.requestId) {
        this.tasks = []
        this.sections = []
        this.message = `读取任务失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  async syncFromPull() {
    // 松手后内容复位；同步状态由标题下的共享进度线承载。
    this.refreshing = false
    if (this.view === 'today') await RepositorySyncService.start(getContext(this))
  }

  @Builder
  pullIndicator() {
    Row().width('100%').height(0)
  }

  @Builder
  overviewContent() {
    Column() {
      if (this.loading) {
        EmptyState({ title: '正在读取任务', busy: true })
      } else if (this.needsConfiguration) {
        EmptyState({ title: `尚未配置${overviewTitle(this.view)}文件`, detail: `请在设置的“笔记与笔记本”中配置${overviewTitle(this.view)}文件。`,
          actionLabel: '前往设置', action: (): void => {
            router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
          } })
      } else if (this.message) {
        EmptyState({ title: '任务读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadTasks() } })
      } else {
        if (this.view !== 'today') {
          Text(this.view === 'memo' ? `${this.tasks.length} 条备忘` : `${this.tasks.length} 个${this.view === 'logbook' ? '已完成' : '未完成'}任务`)
            .fontSize(13).fontColor(UiColor.secondary).width('100%').padding(16).backgroundColor(UiColor.container)
        }
        if (this.tasks.length === 0) {
          EmptyState({ title: this.view === 'memo' ? '没有备忘记录' : '没有符合条件的任务',
            detail: this.view === 'memo' ? '配置文件中的所有标题记录都会显示在这里。' : this.view === 'today' ? '今天没有到期或过期任务。' : '新增任务或同步后可以刷新此列表。' })
        } else if (this.view === 'today') {
          TodayTaskList({ sections: this.sections })
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

  build() {
    Column() {
      AppShell({ title: overviewTitle(this.view), synchronized: (): void => { this.loadTasks() }, activeRoute: 'pages/TaskOverview', activeOverview: this.view,
        titleIcon: this.view === 'today' ? $r('app.media.nav_today') : '',
        drawerOpen: $drawerOpen, actionIcon: $r('app.media.ui_sync'), actionLabel: this.view === 'today' ? '' : '刷新任务',
        action: (): void => { this.loadTasks() }, fabLabel: this.view === 'memo' ? '' : '新增任务',
        fabAction: (): void => { router.pushUrl({ url: 'pages/AddTask' }) } }) {
        if (this.view === 'today') {
          Refresh({ refreshing: $$this.refreshing, builder: this.pullIndicator }) {
            this.overviewContent()
          }.width('100%').height('100%').refreshOffset(64).pullDownRatio(0.4)
            .onRefreshing((): void => { this.syncFromPull() })
        } else {
          this.overviewContent()
        }
      }
    }.width('100%').height('100%')
  }
}
