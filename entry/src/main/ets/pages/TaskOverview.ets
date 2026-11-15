import { TaskEditorDataManager } from '../services/TaskEditorDataManager'
import { DataSetManager, DataSetEvent } from '../services/DataSetManager'
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
import { PageQueryService } from '../services/PageQueryService'
import { AppConfigService } from '../services/AppConfigService'
import { FileTargetService } from '../services/FileTargetService'
import { NoteService } from '../services/NoteService'
import { overviewTaskQuery, todayPriorityQuery, overviewTitle, plannedRegionQuery, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreQuery, CoreTask, CoreTaskQueryResult, taskResult, coreErrorMessage } from '../services/NativeCoreService'
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
  private taskEditorManager: TaskEditorDataManager | undefined = undefined
  private editorDataManager(): TaskEditorDataManager {
    if (!this.taskEditorManager) this.taskEditorManager = new TaskEditorDataManager(this.getUIContext().getHostContext()!)
    return this.taskEditorManager
  }

  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @LocalStorageProp('entryView') entryView: string = ''
  @LocalStorageProp('entryMemoAction') entryMemoAction: string = ''
  @LocalStorageProp('entryMemoId') entryMemoId: string = ''
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
  private todayManager: DataSetManager | undefined = undefined
  private stopToday: (() => void) | undefined = undefined
  private todayStart: Promise<void> | undefined = undefined
  @State todayReady: boolean = false
  @StorageLink('taskInlineActive') @Watch('todayInlineChanged') todayInlineActive: string = ''
  private todayLayoutDeferred: boolean = false
  private todayRevision: number = -1
  private requestId: number = 0
  private entryMemoOpened: boolean = false

  aboutToAppear() {
    this.view = (this.getUIContext().getRouter().getParams() as OverviewParams | undefined)?.view ||
      (this.entryView === 'memo' ? 'memo' : 'today')
    if (this.view === 'today') this.loadTasks()
  }

  onPageShow() {
    if (this.view === 'today') this.loadTasks()
  }

  aboutToDisappear() {
    this.stopToday?.(); this.stopToday = undefined
    const manager = this.todayManager; this.todayManager = undefined
    manager?.close().catch((): void => { console.error('保存今天页面缓存失败') })
  }


  onBackPress(): boolean {
    if (TaskInlineSession.active()) { TaskInlineSession.end(!AppStorage.get<boolean>('taskInlineTyping')); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async openEntryMemo(): Promise<void> {
    if (this.view !== 'memo' || this.entryMemoOpened || !this.entryMemoAction) return
    this.entryMemoOpened = true
    try {
      if (this.entryMemoAction === 'create') {
        await this.getUIContext().getRouter().pushUrl({ url: 'pages/MemoEdit', params: { create: true } })
      } else if (this.entryMemoAction === 'edit') {
        const task = this.tasks.find((item: CoreTask): boolean => item.id === this.entryMemoId)
        if (task) {
          await this.getUIContext().getRouter().pushUrl({ url: 'pages/MemoEdit', params: { task } })
        } else {
          try {
            this.getUIContext().getPromptAction().showToast({ message: '此备忘已变更或删除，请从列表重新选择' })
          } catch (_) {
            // 页面退出时提示可能不可用。
          }
        }
      }
    } catch (_) {
      this.entryMemoOpened = false
    }
  }

  supportsTagFilter(): boolean {
    return this.view === 'today' || this.view === 'anytime' || this.view === 'someday' || this.view === 'memo'
  }

  rightSwipeAction(): TaskRightSwipeAction {
    return this.view === 'memo' ? 'none' : taskPageActionPolicy(this.view).rightSwipeAction
  }

  confirmDeleteMemo(task: CoreTask) {
    if (this.deletingMemo) return
    this.getUIContext().showAlertDialog({ title: '删除这条备忘？', message: `“${task.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.deleteMemo(task) } } })
  }

  async deleteMemo(task: CoreTask) {
    if (this.deletingMemo) return
    this.deletingMemo = true
    try {
      await NoteService.remove(this.getUIContext().getHostContext()!, task)
      await this.loadTasks()
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
    const keyOf = (task: CoreTask): string => this.todayManager?.itemKey('tasks', task.id) ?? task.id
    if (!layout || !this.todayManager || !sameTodayTimedItems(this.timedItems, layout.timedItems, keyOf)) this.timedItems = layout?.timedItems ?? []
    if (!layout || !this.todayManager || !sameTodaySections(this.sections, layout.sections, keyOf)) this.sections = layout?.sections ?? (this.view === 'anytime' ? todaySections(this.visibleTasks) : [])
  }

  async selectPlanRegion(region: TaskRegionData | null): Promise<void> {
    this.selectedPlanRegion = region
    await this.loadTasks()
  }

  async loadTasks() {
    if (this.view === 'today') { await this.loadToday(); return }
    const request = ++this.requestId
    const selectedRegion = this.selectedPlanRegion ?? null
    this.loading = this.tasks.length === 0
    this.message = ''
    this.needsConfiguration = false
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      let result: CoreTaskQueryResult | undefined = undefined
      let priorityOrder: string[] = []
      let configuredTags: string[] = []
      let configuredGroups: string[][] = []
      let regionOptions: TaskRegionData[] = []
      if (this.view === 'someday' || this.view === 'memo') {
        const fileResult = await FileTargetService.query(config, this.view)
        result = fileResult
        if (this.view === 'memo') {
          configuredTags = fileResult?.tagOptions ?? []
          configuredGroups = fileResult?.tagGroups ?? []
        }
      } else {
        const queries: CoreQuery[] = [{ type: 'task', query: overviewTaskQuery(this.view) }]
        if (this.view === 'planned' && selectedRegion !== null) queries.push(plannedRegionQuery(selectedRegion))
        const results = await PageQueryService.query(config, queries)
        result = taskResult(results[0])
        if (this.view === 'planned') {
          regionOptions = plannedRegionOptions(result.tasks)
          if (selectedRegion !== null && regionOptions.some((region: TaskRegionData) => region.key === selectedRegion.key)) {
            result = taskResult(results[1])
          }
        }
      }
      if (request !== this.requestId) return
      if (!result) {
        this.needsConfiguration = true
        this.priorityOrder = []
        this.tasks = []
        this.visibleTasks = []
        this.tagOptions = []
        this.tagGroups = []
        this.sections = []
        this.timedItems = []
        this.planGroups = []
        this.logbookTaskGroups = []
        return
      }
      let planGroups: PlannedGroup[] = []
      if (this.view === 'planned') planGroups = plannedGroups(result.tasks)
      if (request !== this.requestId) return
      this.priorityOrder = priorityOrder
      this.tasks = result.tasks
      if (this.view === 'planned') {
        this.planRegionOptions = regionOptions
        this.selectedPlanRegion = regionOptions.find((region: TaskRegionData) => region.key === selectedRegion?.key) ?? null
      }
      this.tagOptions = this.supportsTagFilter() ? taskTagOptions(result.tasks, configuredTags) : []
      this.tagGroups = configuredGroups
      this.referenceTime = Date.now()
      this.applyTagFilter(reconcileTaskTags({ tags: this.selectedTags, includeUntagged: this.includeUntagged },
        this.tagOptions, this.tagGroups))
      this.planGroups = planGroups
      this.logbookTaskGroups = this.view === 'logbook' ? logbookGroups(result.tasks, new Date(this.referenceTime)) : []
      await this.openEntryMemo()
    } catch (e) {
      if (request === this.requestId) {
        this.priorityOrder = []
        this.tasks = []
        this.visibleTasks = []
        this.tagOptions = []
        this.tagGroups = []
        this.sections = []
        this.timedItems = []
        this.planGroups = []
        this.logbookTaskGroups = []
        this.message = `读取任务失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  async loadToday(): Promise<void> {
    if (this.todayStart) return await this.todayStart
    if (this.todayManager && !this.todayManager.hasValidScope()) {
      this.stopToday?.(); this.stopToday = undefined
      const previous = this.todayManager; this.todayManager = undefined
      await previous.close().catch((): void => {})
    }
    if (!this.todayManager) {
      this.todayRevision = -1
      this.todayManager = DataSetManager.create(this.getUIContext().getHostContext()!, '今天', [
        { name: 'tasks', query: { type: 'task', query: overviewTaskQuery('today') } },
        { name: 'priority', query: { type: 'task', query: todayPriorityQuery() } },
        { name: 'files', query: { type: 'file', query: {} } }
      ])
      const manager = this.todayManager
      this.stopToday = manager.subscribe((event: DataSetEvent): void => {
        if (this.todayManager !== manager) return
        if (event.type === 'error') {
          this.todayReady = manager.isReady()
          if (!this.todayReady && this.tasks.length === 0) this.message = event.message ?? '今天数据更新失败'
          return
        }
        if (event.type === 'complete' || event.name === 'files') return
        if (event.type === 'ready') { this.todayReady = manager.isReady(); return }
        this.applyTodaySnapshot()
      })
    }
    const manager = this.todayManager
    const work = manager.start().then((): void => { if (this.todayManager === manager) this.applyTodaySnapshot() })
      .catch((error: Error): void => { if (this.todayManager === manager) { this.loading = false; this.message = error.message } })
      .finally((): void => { if (this.todayStart === work) this.todayStart = undefined })
    this.todayStart = work
    return await work
  }

  todayInlineChanged(): void {
    if (!this.todayInlineActive && this.todayLayoutDeferred) {
      this.todayLayoutDeferred = false
      this.applyTodaySnapshot()
    }
  }

  applyTodaySnapshot(): void {
    // 编辑器独立接收数据集变化；列表重排等会话结束后应用，防止移动输入框导致失焦提交。
    if (TaskInlineSession.active()) { this.todayLayoutDeferred = true; return }
    const manager = this.todayManager
    const snapshot = manager?.get('tasks')
    if (!snapshot || snapshot.data.type !== 'task') return
    const priority = manager?.get('priority')?.data
    this.todayReady = manager?.isReady() ?? false
    const order = priority?.type === 'task' ? priority.result.tasks.map(task => task.id) : []
    if (snapshot.revision !== undefined && this.todayRevision === snapshot.revision &&
      order.length === this.priorityOrder.length && order.every((id: string, index: number): boolean => id === this.priorityOrder[index])) return
    this.todayRevision = snapshot.revision
    this.loading = false; this.message = ''; this.needsConfiguration = false
    this.priorityOrder = order
    this.tasks = snapshot.data.result.tasks
    this.tagOptions = taskTagOptions(this.tasks)
    if (new Date(this.referenceTime).toDateString() !== new Date().toDateString()) this.referenceTime = Date.now()
    this.applyTagFilter(reconcileTaskTags({ tags: this.selectedTags, includeUntagged: this.includeUntagged }, this.tagOptions, this.tagGroups))
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
            this.getUIContext().getRouter().pushUrl({ url: 'pages/Settings', params: { section: '文件入口' } })
          } })
      } else if (this.message) {
        NotificationEmptyState({ title: '任务读取失败', detail: this.message, actionLabel: '重试', action: (): void => {
          if (this.view === 'today' && this.todayManager?.hasValidScope()) this.todayManager.refresh().catch((error: Error): void => { this.message = error.message })
          else this.loadTasks()
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
            expandOnRowClick: this.view === 'today', dataSetManager: this.view === 'today' ? this.todayManager : undefined,
            dataSetName: 'tasks', positionKey: this.view, readOnly: this.view === 'today' && !this.todayReady })
        } else if (this.view === 'planned') {
          PlannedTaskList({ groups: this.planGroups, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction() })
        } else if (this.view === 'logbook') {
          LogbookTaskList({ groups: this.logbookTaskGroups, referenceTime: this.referenceTime, refresh: (): void => { this.loadTasks() } })
        } else {
          List({ scroller: this.listScroller }) {
            if (this.notificationState.notifications.length > 0) {
              ListItem() { CoreNotificationsView({ horizontalInset: 12 }) }
                .margin({ bottom: this.view === 'memo' ? 12 : 0 })
            }
            ForEach(this.visibleTasks, (task: CoreTask) => {
              if (this.view === 'memo') {
                ListItem() {
                  MemoListItem({ task, busy: this.deletingMemo, open: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/MemoEdit', params: { task } }) } })
                    .margin({ left: 16, right: 16 })
                }.margin({ bottom: 12 })
                  .swipeAction({ end: this.memoDeleteAction(task), edgeEffect: SwipeEdgeEffect.None })
              } else {
                ListItem() {
                  TaskEditor({ dataManager: this.editorDataManager(), dataSet: this.editorDataManager().dataSet(task), referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction(), scrollHost: this.listScroller, scrollHostId: 'overview_task_list' })
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
      AppShell({ refreshOnPageShow: this.view !== 'today', managedBody: this.view === 'today', title: overviewTitle(this.view), synchronized: (): void => { this.loadTasks() }, activeRoute: 'pages/TaskOverview', activeOverview: this.view,
        titleIcon: this.overviewIcon(),
        drawerOpen: $drawerOpen, pullToSync: true, busy: this.deletingMemo }) {
        this.overviewContent()
      }
      if (this.view === 'memo' && !this.drawerOpen) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ui_add_primary')).width(28).height(28)
        }.id('memo_create').width(56).height(56).backgroundColor(UiColor.primary)
          .shadow({ radius: 12, color: '#33000000', offsetY: 4 }).margin({ bottom: 24 })
          .accessibilityText('新增备忘')
          .enabled(!this.deletingMemo)
          .onClick((): void => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/MemoEdit', params: { create: true } })
          })
      }
    }.width('100%').height('100%')
  }
}
