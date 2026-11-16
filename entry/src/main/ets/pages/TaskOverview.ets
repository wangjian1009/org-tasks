import { PageNavigator } from '../services/PageNavigator'
import { DataSetManager, DataSet, DataSetDefinition } from '../services/DataSetManager'
import { AppConfig } from '../models/OrgTask'
import { FileTargetService } from '../services/FileTargetService'
import { LogbookService } from '../services/LogbookService'
import { TaskInlineSession } from '../services/TaskInlineService'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { taskRenderKey } from '../ui/TaskPresentation'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { TaskEditor } from '../components/editors/TaskEditor'
import { MemoListItem } from '../components/MemoListItem'
import { TodayTaskList } from '../components/TodayTaskList'
import { PlannedTaskList } from '../components/PlannedTaskList'
import { RegionProjectFilter } from '../components/RegionProjectFilter'
import { LogbookTaskList } from '../components/LogbookTaskList'
import { TaskTagFilter } from '../components/TaskTagFilter'
import { TaskRightSwipeAction, taskPageActionPolicy } from '../ui/TaskActionPresentation'
import { overviewTaskQuery, todayPriorityQuery, plannedRegionQuery, overviewTitle, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreRepo, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { TodaySection, TodayTimedTaskItem, todayLayout, todaySections, sameTodaySections, sameTodayTimedItems } from '../ui/TodayPresentation'
import { PlannedGroup, plannedGroups, plannedRegionOptions } from '../ui/PlannedPresentation'
import { TaskRegionData } from '../ui/TaskRegionPresentation'
import { LogbookGroup, logbookGroups } from '../ui/LogbookPresentation'
import { filterTasksByTags, reconcileTaskTags, taskTagOptions, TaskTagSelection } from '../ui/TaskTagFilterPresentation'

interface OverviewParams { view?: OverviewKind }

@Entry({ useSharedStorage: true })
@Component
struct TaskOverview {
  private dataManager: DataSetManager | undefined = undefined
  private tasksDataSet: DataSet | undefined = undefined
  private priorityDataSet: DataSet | undefined = undefined
  private rangeDataSet: DataSet | undefined = undefined
  private targetDataSet: DataSet | undefined = undefined
  private stops: (() => void)[] = []
  @State pageReady: boolean = false
  private taskDataSet(): DataSet { return this.view === 'planned' && !this.selectedPlanRegion ? this.rangeDataSet! : this.tasksDataSet! }

  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @LocalStorageProp('entryView') entryView: string = ''
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @State view: OverviewKind = 'today'
  @State tasks: CoreTask[] = []
  @State visibleTasks: CoreTask[] = []
  @State priorityOrder: string[] = []
  @State tagOptions: string[] = []
  @State tagGroups: string[][] = []
  @State selectedTags: string[] = []
  @State includeUntagged: boolean = false
  @State sections: TodaySection[] = []
  @State timedItems: TodayTimedTaskItem[] = []
  @State planGroups: PlannedGroup[] = []
  @State planRegionOptions: TaskRegionData[] = []
  @State selectedPlanRegion: TaskRegionData | null = null
  @State logbookTaskGroups: LogbookGroup[] = []
  @State referenceTime: number = Date.now()
  @State loading: boolean = true
  @State message: string = ''
  @State needsConfiguration: boolean = false
  @State drawerOpen: boolean = false
  @State deletingMemo: boolean = false
  @StorageLink('taskInlineActive') @Watch('pageInlineChanged') pageInlineActive: string = ''
  private pageLayoutDeferred: boolean = false

  aboutToAppear() {
    this.view = (this.getUIContext().getRouter().getParams() as OverviewParams | undefined)?.view ||
      (this.entryView === 'memo' ? 'memo' : 'today')
    this.loadTasks()
  }

  onPageShow() {
    this.loadTasks()
  }

  aboutToDisappear() {
    for (const stop of this.stops) stop()
    this.stops = []
    this.dataManager?.close().catch((): void => { console.error('保存页面数据失败') })
    this.dataManager = undefined
  }

  onBackPress(): boolean {
    if (TaskInlineSession.active()) { TaskInlineSession.end(!AppStorage.get<boolean>('taskInlineTyping')); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  supportsTagFilter(): boolean {
    return this.view === 'today' || this.view === 'anytime' || this.view === 'someday' || this.view === 'memo'
  }

  rightSwipeAction(): TaskRightSwipeAction {
    return this.view === 'memo' ? 'none' : taskPageActionPolicy(this.view).rightSwipeAction
  }

  confirmDeleteMemo(task: CoreTask) {
    if (this.deletingMemo || !this.pageReady) return
    this.getUIContext().showAlertDialog({ title: '删除这条备忘？', message: `“${task.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.deleteMemo(task) } } })
  }

  async deleteMemo(task: CoreTask) {
    if (this.deletingMemo || !this.pageReady) return
    this.deletingMemo = true
    try {
      await this.taskDataSet().removeTask(task.id)
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(e as CoreBridgeError), duration: 3000 })
      } catch (error) { console.error('显示备忘删除错误提示失败') }
    } finally { this.deletingMemo = false }
  }

  @Builder
  memoDeleteAction(task: CoreTask) {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ui_delete')).width(24).height(24)
      }.width(44).height(44).padding(0).backgroundColor('#513A40').enabled(!this.deletingMemo)
        .accessibilityText('删除备忘').onClick((): void => { this.confirmDeleteMemo(task) })
    }.height('100%').padding({ left: 8, right: 16 })
  }

  applyTagFilter(selection: TaskTagSelection) {
    this.selectedTags = selection.tags
    this.includeUntagged = selection.includeUntagged
    this.visibleTasks = this.supportsTagFilter() ? filterTasksByTags(this.tasks, selection, this.tagGroups) : this.tasks
    const layout = this.view === 'today' ? todayLayout(this.visibleTasks, this.priorityOrder, new Date(this.referenceTime)) : null
    const keyOf = (task: CoreTask): string => this.taskDataSet().taskKey(task.id) ?? task.id
    if (!layout || !this.dataManager || !sameTodayTimedItems(this.timedItems, layout.timedItems, keyOf)) this.timedItems = layout?.timedItems ?? []
    if (!layout || !this.dataManager || !sameTodaySections(this.sections, layout.sections, keyOf)) this.sections = layout?.sections ?? (this.view === 'anytime' ? todaySections(this.visibleTasks) : [])
  }

  defineDataSets(config: AppConfig, repos: CoreRepo[], view: OverviewKind, region: TaskRegionData | null): DataSetDefinition[] {
    const definitions: DataSetDefinition[] = []
    if (view === 'memo' || view === 'someday') {
      const target = FileTargetService.prepare(config, repos, view)
      if (target) definitions.push({ name: 'tasks', query: target.task }, { name: 'target', query: target.file })
    } else {
      definitions.push({ name: view === 'planned' ? 'range' : 'tasks', query: { type: 'task', query: overviewTaskQuery(view) } })
      if (view === 'today') definitions.push({ name: 'priority', query: { type: 'task', query: todayPriorityQuery() } })
      if (view === 'planned') definitions.push({ name: 'tasks', query: region ? plannedRegionQuery(region) : { type: 'task', query: overviewTaskQuery('planned') } })
    }
    definitions.push({ name: 'files', query: { type: 'file', query: {} } })
    return definitions
  }

  async selectPlanRegion(region: TaskRegionData | null): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    this.selectedPlanRegion = region
    if (region) await this.tasksDataSet?.setQuery(plannedRegionQuery(region))
    this.applyPageSnapshot()
  }

  async loadTasks() {
    if (!this.dataManager) {
      const view = this.view
      this.dataManager = DataSetManager.create(this.getUIContext().getHostContext()!, overviewTitle(view),
        (config: AppConfig, repos: CoreRepo[]): DataSetDefinition[] => this.defineDataSets(config, repos, view, null))
      this.tasksDataSet = this.dataManager.dataSet('tasks')
      this.stops.push(this.tasksDataSet.subscribe((): void => { this.applyPageSnapshot() }))
      if (view === 'today') {
        this.priorityDataSet = this.dataManager.dataSet('priority')
        this.stops.push(this.priorityDataSet.subscribe((): void => {
          const data = this.priorityDataSet?.data
          this.priorityOrder = data?.type === 'task' ? data.result.tasks.map(task => task.id) : []
          this.applyPageSnapshot()
        }))
      }
      if (view === 'planned') {
        this.rangeDataSet = this.dataManager.dataSet('range')
        this.stops.push(this.rangeDataSet.subscribe((): void => {
          const data = this.rangeDataSet?.data
          this.planRegionOptions = plannedRegionOptions(data?.type === 'task' ? data.result.tasks : [])
          if (this.rangeDataSet?.isReady() && this.selectedPlanRegion && !this.planRegionOptions.some(region => region.key === this.selectedPlanRegion?.key)) this.selectedPlanRegion = null
          this.applyPageSnapshot()
        }))
      }
      if (view === 'memo' || view === 'someday') {
        this.targetDataSet = this.dataManager.dataSet('target')
        this.stops.push(this.targetDataSet.subscribe((): void => { this.applyPageSnapshot() }))
      }
    }
    try { await this.dataManager.start() }
    catch (error) { this.loading = false; this.message = (error as Error).message }
  }

  pageInlineChanged(): void {
    if (!this.pageInlineActive && this.pageLayoutDeferred) {
      this.pageLayoutDeferred = false
      this.applyPageSnapshot()
    }
  }

  applyPageSnapshot(): void {
    if (TaskInlineSession.active()) { this.pageLayoutDeferred = true; return }
    const dataSet = this.taskDataSet()
    if (!dataSet) return
    const data = dataSet.data, target = this.targetDataSet?.data
    const file = target?.type === 'file' ? target.result[0] : undefined
    this.message = dataSet.error || this.targetDataSet?.error || this.rangeDataSet?.error || this.priorityDataSet?.error || ''
    this.loading = !this.message && (!data || (!!this.targetDataSet && !target))
    this.pageReady = dataSet.isReady()
    this.needsConfiguration = (this.view === 'memo' || this.view === 'someday') && !!target && !file
    this.tasks = data?.type === 'task' ? data.result.tasks : []
    this.tagGroups = this.view === 'memo' ? file?.tagGroups ?? [] : []
    this.tagOptions = this.supportsTagFilter() ? taskTagOptions(this.tasks, this.view === 'memo' ? file?.tagOptions ?? [] : []) : []
    if (new Date(this.referenceTime).toDateString() !== new Date().toDateString()) this.referenceTime = Date.now()
    this.applyTagFilter(reconcileTaskTags({ tags: this.selectedTags, includeUntagged: this.includeUntagged }, this.tagOptions, this.tagGroups))
    this.planGroups = this.view === 'planned' ? plannedGroups(this.tasks) : []
    this.logbookTaskGroups = this.view === 'logbook' ? logbookGroups(this.tasks, new Date(this.referenceTime)) : []
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
        NotificationEmptyState({ title: '正在读取任务', busy: true })
      } else if (this.needsConfiguration) {
        NotificationEmptyState({ title: `${overviewTitle(this.view)}文件未选择或已失效`, detail: '请在设置的“文件入口”中重新选择仓库和文件。',
          actionLabel: '前往设置', action: (): void => {
            PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '文件入口' } })
          } })
      } else if (this.message) {
        NotificationEmptyState({ title: '任务读取失败', detail: this.message, actionLabel: '重试', action: (): void => {
          const dataSet = this.targetDataSet?.error ? this.targetDataSet : this.rangeDataSet?.error ? this.rangeDataSet : this.priorityDataSet?.error ? this.priorityDataSet : this.taskDataSet()
          dataSet.refresh().catch((error: Error): void => { this.message = error.message })
        } })
      } else {
        if (this.view === 'planned') {
          RegionProjectFilter({ options: this.planRegionOptions, selectedKey: this.selectedPlanRegion?.key ?? '',
            changed: (region: TaskRegionData | null): void => { this.selectPlanRegion(region) } })
        }
        if (this.supportsTagFilter()) {
          TaskTagFilter({ tags: this.tagOptions, selectedTags: this.selectedTags, exclusiveGroups: this.tagGroups,
            includeUntagged: this.includeUntagged, changed: (selection: TaskTagSelection): void => {
              this.applyTagFilter(selection)
            } })
        }
        if (this.tasks.length === 0) {
          NotificationEmptyState({ title: this.view === 'memo' ? '没有备忘记录' : '没有符合条件的任务',
            detail: this.view === 'memo' ? '配置文件中的所有标题记录都会显示在这里。' : this.view === 'today' ? '今天没有到期或过期任务。' : '下拉同步后可刷新此列表。' })
        } else if (this.visibleTasks.length === 0) {
          NotificationEmptyState({ title: '没有匹配标签的任务', detail: '选择其他标签，或点击“全部”查看当前页面的所有任务。',
            actionLabel: '显示全部', action: (): void => { this.applyTagFilter({ tags: [], includeUntagged: false }) } })
        } else if (this.view === 'today' || this.view === 'anytime') {
          TodayTaskList({ sections: this.sections, timedItems: this.timedItems, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction(),
            expandOnRowClick: this.view === 'today', dataSet: this.taskDataSet(),
            positionKey: this.view, readOnly: !this.pageReady })
        } else if (this.view === 'planned') {
          PlannedTaskList({ dataSet: this.taskDataSet(), readOnly: !this.pageReady, groups: this.planGroups, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction() })
        } else if (this.view === 'logbook') {
          LogbookTaskList({ ready: this.pageReady, dataSet: this.taskDataSet(), perform: async (tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> => { await this.taskDataSet().operate( async (operationId: string): Promise<void> => {
            if (action === 'restore') await LogbookService.restore(this.getUIContext().getHostContext()!, tasks, operationId)
            else await LogbookService.remove(this.getUIContext().getHostContext()!, tasks, operationId)
          }) }, groups: this.logbookTaskGroups, referenceTime: this.referenceTime })
        } else {
          List({ scroller: this.listScroller }) {
            if (this.notificationState.notifications.length > 0) {
              ListItem() { CoreNotificationsView({ horizontalInset: 12 }) }
                .margin({ bottom: this.view === 'memo' ? 12 : 0 })
            }
            ForEach(this.visibleTasks, (task: CoreTask) => {
              if (this.view === 'memo') {
                ListItem() {
                  MemoListItem({ task, busy: this.deletingMemo || !this.pageReady, open: (): void => { PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/MemoEdit', params: { task } }) } })
                    .margin({ left: 16, right: 16 })
                }.margin({ bottom: 12 })
                  .swipeAction({ end: this.memoDeleteAction(task), edgeEffect: SwipeEdgeEffect.None })
              } else {
                ListItem() {
                  TaskEditor({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(task.id), readOnly: !this.pageReady, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction(), scrollHost: this.listScroller, scrollHostId: 'overview_task_list' })
                }
              }
            }, (task: CoreTask) => taskRenderKey(task))
            if (this.view === 'memo') {
              ListItem() { Column().height(104) }
            }
          }.id('overview_task_list').width('100%').layoutWeight(1).padding({ bottom: this.view === 'memo' ? 0 : 16 })
            .enableScrollInteraction(!this.checklistDragging)
            .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
            .edgeEffect(EdgeEffect.None)
        }
      }
    }.width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AppShell({ title: overviewTitle(this.view), activeRoute: 'pages/TaskOverview', activeOverview: this.view,
        titleIcon: this.overviewIcon(),
        drawerOpen: $drawerOpen, pullToSync: true, busy: this.deletingMemo }) {
        ForEach([this.taskDataSet()], (_dataSet: DataSet) => { this.overviewContent() }, (dataSet: DataSet) => dataSet.identity)
      }
      if (this.view === 'memo' && !this.drawerOpen) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ui_add_primary')).width(28).height(28)
        }.id('memo_create').width(56).height(56).backgroundColor(UiColor.primary)
          .shadow({ radius: 12, color: '#33000000', offsetY: 4 }).margin({ bottom: 24 })
          .accessibilityText('新增备忘')
          .enabled(!this.deletingMemo)
          .onClick((): void => {
            PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/MemoEdit', params: { create: true } })
          })
      }
    }.width('100%').height('100%')
  }
}
