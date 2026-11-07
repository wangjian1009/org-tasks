import { taskRenderKey } from '../ui/TaskPresentation'
import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState, TaskRow } from '../components/Controls'
import { TaskListItem } from '../components/TaskListItem'
import { TodayTaskList } from '../components/TodayTaskList'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
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
  @State referenceTime: number = Date.now()
  @State loading: boolean = true
  @State message: string = ''
  @State needsConfiguration: boolean = false
  @State drawerOpen: boolean = false
  private requestId: number = 0

  aboutToAppear() {
    this.view = (router.getParams() as OverviewParams | undefined)?.view || 'today'
  }

  onPageShow() { this.loadTasks() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  openTask(task: CoreTask): () => void {
    return (): void => {
      router.pushUrl({
        url: this.view === 'memo' ? 'pages/MemoEdit' : 'pages/TaskEdit',
        params: { task }
      })
    }
  }

  async loadTasks() {
    const request = ++this.requestId
    this.loading = this.tasks.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(getContext(this))
      const result = this.view === 'someday' || this.view === 'memo'
        ? await FileTargetService.query(config, this.view)
        : await NativeCoreService.queryTasks(config.repos, overviewTaskQuery(this.view), config.todoDefaults)
      if (request !== this.requestId) return
      if (!result) {
        this.needsConfiguration = true
        this.tasks = []
        return
      }
      const sections = this.view === 'today'
        ? await todaySections(result.tasks, await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)) : []
      if (request !== this.requestId) return
      this.tasks = result.tasks
      this.referenceTime = Date.now()
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

  overviewIcon(): Resource {
    switch (this.view) {
      case 'today': return $r('app.media.nav_today')
      case 'planned': return $r('app.media.nav_planned')
      case 'anytime': return $r('app.media.nav_anytime')
      case 'someday': return $r('app.media.nav_someday')
      case 'memo': return $r('app.media.nav_memo')
      case 'logbook': return $r('app.media.nav_logbook')
    }
    return $r('app.media.nav_today')
  }

  @Builder
  overviewContent() {
    Column() {
      if (this.loading) {
        EmptyState({ title: '正在读取任务', busy: true })
      } else if (this.needsConfiguration) {
        EmptyState({ title: `${overviewTitle(this.view)}文件未选择或已失效`, detail: '请在设置的“笔记与笔记本”中重新选择仓库和文件。',
          actionLabel: '前往设置', action: (): void => {
            router.pushUrl({ url: 'pages/Settings', params: { section: '笔记与笔记本' } })
          } })
      } else if (this.message) {
        EmptyState({ title: '任务读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadTasks() } })
      } else {
        if (this.view === 'memo' || this.view === 'logbook') {
          Text(this.view === 'memo' ? `${this.tasks.length} 条备忘` : `${this.tasks.length} 个${this.view === 'logbook' ? '已完成' : '未完成'}任务`)
            .fontSize(13).fontColor(UiColor.secondary).width('100%').padding(16).backgroundColor(UiColor.container)
        }
        if (this.tasks.length === 0) {
          EmptyState({ title: this.view === 'memo' ? '没有备忘记录' : '没有符合条件的任务',
            detail: this.view === 'memo' ? '配置文件中的所有标题记录都会显示在这里。' : this.view === 'today' ? '今天没有到期或过期任务。' : '下拉同步后可刷新此列表。' })
        } else if (this.view === 'today') {
          TodayTaskList({ sections: this.sections, referenceTime: this.referenceTime })
        } else {
          List() {
            ForEach(this.tasks, (task: CoreTask) => {
              ListItem() {
                if (this.view === 'planned' || this.view === 'anytime' || this.view === 'someday') {
                  TaskListItem({ task, referenceTime: this.referenceTime, open: this.openTask(task) })
                } else {
                  TaskRow({ task, showBody: true, open: this.openTask(task) })
                }
              }
            }, (task: CoreTask) => taskRenderKey(task))
          }.width('100%').layoutWeight(1).padding({ bottom: 16 })
            .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
            .edgeEffect(EdgeEffect.None)
        }
      }
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      AppShell({ title: overviewTitle(this.view), synchronized: (): void => { this.loadTasks() }, activeRoute: 'pages/TaskOverview', activeOverview: this.view,
        titleIcon: this.overviewIcon(),
        drawerOpen: $drawerOpen, pullToSync: true }) {
        this.overviewContent()
      }
    }.width('100%').height('100%')
  }
}
