import { TaskEditorDataManager } from '../services/TaskEditorDataManager'
import { TaskPageDataManager, TaskPageSnapshot } from '../services/TaskPageDataManager'
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
import { overviewTitle, TaskOverview as OverviewKind } from '../services/TaskViewQueries'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
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
  private pageManager: TaskPageDataManager | undefined = undefined
  private stopPage: (() => void) | undefined = undefined
  private latestSnapshot: TaskPageSnapshot | undefined = undefined
  @State dataScope: number = 0
  @State pageReady: boolean = false
  private editorDataManager(): TaskEditorDataManager { return this.pageManager!.editor() }

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
  @StorageLink('taskInlineActive') @Watch('pageInlineChanged') pageInlineActive: string = ''
  private pageLayoutDeferred: boolean = false
  private entryMemoOpened: boolean = false

  aboutToAppear() {
    this.view = (this.getUIContext().getRouter().getParams() as OverviewParams | undefined)?.view ||
      (this.entryView === 'memo' ? 'memo' : 'today')
    this.loadTasks()
  }

  onPageShow() {
    this.loadTasks()
  }

  aboutToDisappear() {
    this.stopPage?.(); this.stopPage = undefined
    this.pageManager?.close().catch((): void => { console.error('保存页面数据失败') })
    this.pageManager = undefined
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
    if (this.deletingMemo || !this.pageReady) return
    this.getUIContext().showAlertDialog({ title: '删除这条备忘？', message: `“${task.heading}”及其子记录将从文件中删除。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.deleteMemo(task) } } })
  }

  async deleteMemo(task: CoreTask) {
    if (this.deletingMemo || !this.pageReady) return
    this.deletingMemo = true
    try {
      await this.pageManager?.remove(task)
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
    const keyOf = (task: CoreTask): string => this.pageManager?.dataSets()?.itemKey('tasks', task.id) ?? task.id
    if (!layout || !this.pageManager || !sameTodayTimedItems(this.timedItems, layout.timedItems, keyOf)) this.timedItems = layout?.timedItems ?? []
    if (!layout || !this.pageManager || !sameTodaySections(this.sections, layout.sections, keyOf)) this.sections = layout?.sections ?? (this.view === 'anytime' ? todaySections(this.visibleTasks) : [])
  }

  async selectPlanRegion(region: TaskRegionData | null): Promise<void> {
    if (!await TaskInlineSession.end(true)) return
    this.selectedPlanRegion = region
    await this.pageManager?.selectRegion(region)
  }

  async loadTasks() {
    if (!this.pageManager) {
      this.pageManager = new TaskPageDataManager(this.getUIContext().getHostContext()!, this.view)
      this.stopPage = this.pageManager.subscribe((snapshot: TaskPageSnapshot): void => {
        this.latestSnapshot = snapshot
        this.applyPageSnapshot()
      })
    }
    await this.pageManager.start()
  }

  pageInlineChanged(): void {
    if (!this.pageInlineActive && this.pageLayoutDeferred) {
      this.pageLayoutDeferred = false
      this.applyPageSnapshot()
    }
  }

  applyPageSnapshot(): void {
    if (TaskInlineSession.active()) { this.pageLayoutDeferred = true; return }
    const snapshot = this.latestSnapshot
    if (!snapshot) return
    this.loading = false; this.message = snapshot.message
    this.dataScope = snapshot.scope
    this.pageReady = snapshot.ready
    this.needsConfiguration = snapshot.needsConfiguration
    this.tasks = snapshot.tasks
    this.priorityOrder = snapshot.priorityOrder
    this.tagGroups = snapshot.tagGroups
    this.tagOptions = this.supportsTagFilter() ? taskTagOptions(snapshot.tasks, snapshot.tagOptions) : []
    this.planRegionOptions = snapshot.regionOptions
    this.selectedPlanRegion = snapshot.selectedRegion
    if (new Date(this.referenceTime).toDateString() !== new Date().toDateString()) this.referenceTime = Date.now()
    this.applyTagFilter(reconcileTaskTags({ tags: this.selectedTags, includeUntagged: this.includeUntagged }, this.tagOptions, this.tagGroups))
    this.planGroups = this.view === 'planned' ? plannedGroups(snapshot.tasks) : []
    this.logbookTaskGroups = this.view === 'logbook' ? logbookGroups(snapshot.tasks, new Date(this.referenceTime)) : []
    this.openEntryMemo()
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
          this.pageManager?.refresh().catch((error: Error): void => { this.message = error.message })
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
            expandOnRowClick: this.view === 'today', dataManager: this.editorDataManager(),
            positionKey: this.view, readOnly: !this.pageReady })
        } else if (this.view === 'planned') {
          PlannedTaskList({ dataManager: this.editorDataManager(), readOnly: !this.pageReady, groups: this.planGroups, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction() })
        } else if (this.view === 'logbook') {
          LogbookTaskList({ ready: this.pageReady, dataManager: this.editorDataManager(), perform: async (tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> => { await this.pageManager?.logbook(tasks, action) }, groups: this.logbookTaskGroups, referenceTime: this.referenceTime })
        } else {
          List({ scroller: this.listScroller }) {
            if (this.notificationState.notifications.length > 0) {
              ListItem() { CoreNotificationsView({ horizontalInset: 12 }) }
                .margin({ bottom: this.view === 'memo' ? 12 : 0 })
            }
            ForEach(this.visibleTasks, (task: CoreTask) => {
              if (this.view === 'memo') {
                ListItem() {
                  MemoListItem({ task, busy: this.deletingMemo || !this.pageReady, open: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/MemoEdit', params: { task } }) } })
                    .margin({ left: 16, right: 16 })
                }.margin({ bottom: 12 })
                  .swipeAction({ end: this.memoDeleteAction(task), edgeEffect: SwipeEdgeEffect.None })
              } else {
                ListItem() {
                  TaskEditor({ dataManager: this.editorDataManager(), dataSet: this.editorDataManager().dataSet(task), readOnly: !this.pageReady, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction(), scrollHost: this.listScroller, scrollHostId: 'overview_task_list' })
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
        ForEach([this.dataScope], (_scope: number) => { this.overviewContent() }, (scope: number) => `${scope}`)
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
