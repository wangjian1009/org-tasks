import { PageNavigator } from '../services/PageNavigator'
import { DataSetManager, DataSet, DataSetDefinition } from '../services/DataSetManager'
import { AppConfig } from '../models/OrgTask'
import { FileTargetService, configuredSpecialFileExclusions, systemTrashExclusions } from '../services/FileTargetService'
import { LogbookService } from '../services/LogbookService'
import { TaskInlineSession } from '../services/TaskInlineService'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { taskRenderKey } from '../ui/TaskPresentation'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { TaskSwipeItem } from '../components/TaskSwipeItem'
import { TaskSwipeOperations } from '../components/TaskSwipeOperations'
import { MemoListItem } from '../components/MemoListItem'
import { TodayTaskList } from '../components/TodayTaskList'
import { PlannedTaskList } from '../components/PlannedTaskList'
import { RegionProjectFilter } from '../components/RegionProjectFilter'
import { LogbookTaskList } from '../components/LogbookTaskList'
import { TaskTagFilter } from '../components/TaskTagFilter'
import { RegionOrderSheet, RegionOrderSheetController } from '../components/editors/RegionOrderSheet'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { RegionOrderService } from '../services/RegionOrderService'
import { RegionOrder, OrderRegion, regionOrderCatalog, regionOrderFromDraft, orderTodaySections, todayVisibleRegionKeys } from '../ui/RegionOrderPresentation'
import { TaskRightSwipeAction, taskPageActionPolicy } from '../ui/TaskActionPresentation'
import { overviewTaskQuery, todayPriorityQuery, plannedRegionQuery, overviewTitle, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { TodaySection, TodayTimedTaskItem, todayLayout, anytimeSections, sameTodaySections, sameTodayTimedItems } from '../ui/TodayPresentation'
import { PlannedGroup, plannedGroups, plannedRegionOptions, samePlannedGroups } from '../ui/PlannedPresentation'
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
  private orderFilesDataSet: DataSet | undefined = undefined
  private trashConfig: AppConfig | undefined = undefined
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
  @State todayRegionKeys: string[] = []
  @State orderCatalog: OrderRegion[] = []
  @State regionOrder: RegionOrder | null = null
  @State orderSheetOpen: boolean = false
  @State orderSaving: boolean = false
  @State orderReadError: string = ''
  private orderLoaded: boolean = false
  private orderActive: boolean = false
  private orderController: RegionOrderSheetController = new RegionOrderSheetController()
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
    this.orderActive = true
    if (this.view === 'today') this.loadRegionOrder()
    this.loadTasks()
  }

  onPageShow() {
    this.loadTasks()
  }

  aboutToDisappear() {
    this.orderActive = false
    for (const stop of this.stops) stop()
    this.stops = []
    this.dataManager?.close().catch((): void => { console.error('保存页面数据失败') })
    this.dataManager = undefined
  }

  onBackPress(): boolean {
    if (this.orderSheetOpen) { this.orderController.requestClose(); return true }
    if (TaskInlineSession.active()) { TaskInlineSession.end(!AppStorage.get<boolean>('taskInlineTyping')); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  supportsTagFilter(): boolean {
    return this.view === 'today' || this.view === 'anytime' || this.view === 'waiting' || this.view === 'someday' || this.view === 'memo'
  }

  rightSwipeAction(): TaskRightSwipeAction {
    return this.view === 'memo' ? 'none' : taskPageActionPolicy(this.view).rightSwipeAction
  }

  confirmDeleteMemo(task: CoreTask) {
    if (this.deletingMemo || !this.pageReady) return
    this.getUIContext().showAlertDialog({ title: '删除这条备忘？', message: `“${task.heading}”将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。`,
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
    const sections = layout ? orderTodaySections(layout.sections, this.regionOrder) : ((this.view === 'anytime' || this.view === 'waiting') ? anytimeSections(this.visibleTasks) : [])
    if (!this.dataManager || !sameTodaySections(this.sections, sections, keyOf)) this.sections = sections
    if (layout) this.todayRegionKeys = todayVisibleRegionKeys(sections, layout.timedItems.length > 0, this.regionOrder)
  }

  async loadRegionOrder(): Promise<void> {
    try {
      const order = await RegionOrderService.load(this.getUIContext().getHostContext()!)
      if (!this.orderActive) return
      this.regionOrder = order; this.orderReadError = ''; this.orderLoaded = true
      this.applyPageSnapshot()
    } catch (error) {
      if (this.orderActive) { this.orderReadError = coreErrorMessage(error as CoreBridgeError); this.orderLoaded = false }
    }
  }

  todayActions(): PopupMenuItem[] {
    return this.view === 'today' ? [{ title: '调整分区顺序', disabled: !this.pageReady,
      action: (): void => { this.openRegionOrder() } }] : []
  }

  async openRegionOrder(): Promise<void> {
    if (this.orderSheetOpen || this.orderSaving || !this.pageReady || !await TaskInlineSession.end(true)) return
    if (!this.orderLoaded) await this.loadRegionOrder()
    if (!this.orderFilesDataSet?.isReady() || this.orderFilesDataSet.error) {
      try { this.getUIContext().getPromptAction().showToast({ message: '分类与项目尚未读取完成，请稍后重试' }) }
      catch (_) { console.error('显示分区读取提示失败') }
      return
    }
    this.applyPageSnapshot()
    this.orderSheetOpen = true
  }

  async saveRegionOrder(draft: OrderRegion[], reset: boolean): Promise<void> {
    if (!this.orderFilesDataSet?.isReady() || this.orderFilesDataSet.error) throw new Error('分类与项目尚未读取完成，请稍后重试')
    const order = reset ? null : regionOrderFromDraft(draft, this.orderCatalog)
    await RegionOrderService.save(this.getUIContext().getHostContext()!, order)
    if (!this.orderActive) return
    this.regionOrder = order; this.orderReadError = ''; this.orderLoaded = true
    this.applyPageSnapshot()
  }

  @Builder
  regionOrderSheet() {
    RegionOrderSheet({ catalog: this.orderCatalog, initialOrder: this.regionOrder, readError: this.orderReadError,
      visible: $orderSheetOpen, busy: $orderSaving, controller: this.orderController,
      save: async (draft: OrderRegion[], reset: boolean): Promise<void> => { await this.saveRegionOrder(draft, reset) } })
  }

  defineDataSets(config: AppConfig, view: OverviewKind, region: TaskRegionData | null): DataSetDefinition[] {
    this.trashConfig = config
    const definitions: DataSetDefinition[] = []
    if (view === 'memo' || view === 'someday') {
      const target = FileTargetService.prepareConfigured(config, view)
      if (target) definitions.push({ name: 'tasks', query: target.task, repositoryBindings: target.repositoryBindings },
        { name: 'target', query: target.file, repositoryBindings: target.repositoryBindings })
    } else {
      definitions.push({ name: view === 'planned' ? 'range' : 'tasks', query: { type: 'task', query: overviewTaskQuery(view) } })
      if (view === 'today') definitions.push({ name: 'priority', query: { type: 'task', query: todayPriorityQuery() } })
      if (view === 'planned') definitions.push({ name: 'tasks', query: region ? plannedRegionQuery(region) : { type: 'task', query: overviewTaskQuery('planned') } })
    }
    if (view !== 'someday') definitions.push({ name: 'files', query: { type: 'file', query: {} } })
    if (view === 'today') {
      const exclusions = configuredSpecialFileExclusions(config)
      definitions.push({ name: 'orderFiles', query: { type: 'file', query: { excludeFiles: exclusions.files } }, repositoryBindings: exclusions.repositoryBindings })
    }
    const trash = systemTrashExclusions(config)
    for (const definition of definitions) {
      if (trash.files.length > 0 && definition.query.type === 'task' && view !== 'memo' && view !== 'someday') {
        definition.query.query.excludeFiles = (definition.query.query.excludeFiles ?? []).concat(trash.files)
        definition.repositoryBindings = (definition.repositoryBindings ?? []).concat(trash.repositoryBindings)
      }
    }
    return definitions
  }

  async selectPlanRegion(region: TaskRegionData | null): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    this.selectedPlanRegion = region
    if (region) {
      const query = plannedRegionQuery(region)
      if (query.type === 'task' && this.trashConfig) query.query.excludeFiles = systemTrashExclusions(this.trashConfig).files
      await this.tasksDataSet?.setQuery(query)
    }
    this.applyPageSnapshot()
  }

  async loadTasks() {
    if (!this.dataManager) {
      const view = this.view
      this.dataManager = DataSetManager.create(this.getUIContext().getHostContext()!, overviewTitle(view),
        (config: AppConfig): DataSetDefinition[] => this.defineDataSets(config, view, null))
      this.tasksDataSet = this.dataManager.dataSet('tasks')
      this.stops.push(this.tasksDataSet.subscribe((): void => { this.applyPageSnapshot() }))
      if (view === 'today') {
        this.orderFilesDataSet = this.dataManager.dataSet('orderFiles')
        this.stops.push(this.orderFilesDataSet.subscribe((): void => { this.applyPageSnapshot() }))
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
    if (this.view === 'today') {
      const files = this.orderFilesDataSet?.data
      this.orderCatalog = regionOrderCatalog(files?.type === 'file' ? files.result : [], todayLayout(this.tasks, this.priorityOrder, new Date(this.referenceTime)))
    }
    this.tagGroups = this.view === 'memo' ? file?.tagGroups ?? [] : []
    this.tagOptions = this.supportsTagFilter() ? taskTagOptions(this.tasks, this.view === 'memo' ? file?.tagOptions ?? [] : []) : []
    if (new Date(this.referenceTime).toDateString() !== new Date().toDateString()) this.referenceTime = Date.now()
    this.applyTagFilter(reconcileTaskTags({ tags: this.selectedTags, includeUntagged: this.includeUntagged }, this.tagOptions, this.tagGroups))
    if (this.view === 'planned') {
      const groups = plannedGroups(this.tasks)
      if (!samePlannedGroups(this.planGroups, groups, (task: CoreTask): string => dataSet.taskKey(task.id) ?? task.id)) this.planGroups = groups
    }
    this.logbookTaskGroups = this.view === 'logbook' ? logbookGroups(this.tasks, new Date(this.referenceTime)) : []
  }

  overviewIcon(): Resource {
    switch (this.view) {
      case 'today': return $r('app.media.nav_today')
      case 'planned': return $r('app.media.nav_planned')
      case 'waiting': return $r('app.media.nav_waiting')
      case 'anytime': return $r('app.media.nav_anytime')
      case 'someday': return $r('app.media.nav_someday')
      case 'memo': return $r('app.media.nav_memo')
      case 'logbook': return $r('app.media.nav_logbook')
    }
    return $r('app.media.nav_today')
  }

  @Builder
  taskRow(task: CoreTask) {
    TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(task.id), readOnly: !this.pageReady,
      singleOperations: taskPageActionPolicy(this.view).singleOperations, referenceTime: this.referenceTime,
      rightSwipeAction: this.rightSwipeAction(), scrollHost: this.listScroller, scrollHostId: 'overview_task_list' })
  }

  @Builder
  overviewContent() {
    Column() {
      if (this.view === 'planned') {
        RegionProjectFilter({ options: this.planRegionOptions, selectedKey: this.selectedPlanRegion?.key ?? '',
          changed: (region: TaskRegionData | null): void => { this.selectPlanRegion(region) } })
      }
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
        } else if (this.view === 'today' || this.view === 'anytime' || this.view === 'waiting') {
          TodayTaskList({ sections: this.sections, timedItems: this.timedItems, referenceTime: this.referenceTime, singleOperations: taskPageActionPolicy(this.view).singleOperations,
            regionKeys: this.view === 'today' ? this.todayRegionKeys : [],
            regionPreviewLimit: (this.view === 'anytime' || this.view === 'waiting') ? 3 : 0,
            expandOnRowClick: this.view === 'today', dataSet: this.taskDataSet(),
            positionKey: this.view, readOnly: !this.pageReady })
        } else if (this.view === 'planned') {
          PlannedTaskList({ dataSet: this.taskDataSet(), readOnly: !this.pageReady, singleOperations: taskPageActionPolicy(this.view).singleOperations, groups: this.planGroups, referenceTime: this.referenceTime })
        } else if (this.view === 'logbook') {
          LogbookTaskList({ ready: this.pageReady, dataSet: this.taskDataSet(), perform: async (tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> => {
            await TaskSwipeOperations.submit(this.taskDataSet(), await LogbookService.operationGroups(this.getUIContext().getHostContext()!, tasks, action), (): boolean => this.pageReady)
          }, groups: this.logbookTaskGroups, referenceTime: this.referenceTime })
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
                this.taskRow(task)
              }
            }, (task: CoreTask) => taskRenderKey(task))
            if (this.view === 'memo') {
              ListItem() { Column().height(104) }
            }
          }.id('overview_task_list').width('100%').layoutWeight(1).padding({ bottom: this.view === 'memo' ? 0 : 16 })
            .scrollBar(BarState.Off)
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
        actionLabel: this.view === 'today' ? '今天更多操作' : '', actionMenuItems: this.todayActions(),
        drawerOpen: $drawerOpen, pullToSync: true, busy: this.deletingMemo || this.orderSaving, pullDisabled: this.orderSheetOpen }) {
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
      .bindSheet($$this.orderSheetOpen, this.regionOrderSheet, {
        height: '80%', detents: ['80%', '95%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: false,
        onWillDismiss: (_action): void => { this.orderController.requestClose() }
      })
  }
}
