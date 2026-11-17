import { DataSet } from '../services/DataSet'
import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { LogbookTaskItem, LogbookTaskGroup, LogbookGroup } from '../ui/LogbookPresentation'
import { TaskEditor } from './editors/TaskEditor'
import { LogShowPolicy } from '../ui/TaskLogPresentation'
import { TaskRegion } from './TaskRegion'
import { RegionAreaPolicy, TaskDateDisplay, TaskTimeDisplay } from '../ui/TaskListPresentation'
import { TaskSelectionRow } from './TaskSelectionRow'
import { TaskBatchToolbar } from './TaskBatchToolbar'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskSwipeItem } from './TaskSwipeItem'
import { TaskEditorController } from '../ui/TaskEditorController'
import { TaskInlineSession } from '../services/TaskInlineService'
import { taskBatchMenu, taskActionPolicy, taskSwipeMenu, TaskBatchAction, TaskSwipeAction, TaskOperation } from '../ui/TaskActionPresentation'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

@Component
export struct LogbookTaskList {
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop ready: boolean = false
  @Prop trashMode: boolean = false
  @Prop groups: LogbookGroup[] = []
  @Prop referenceTime: number = Date.now()
  perform: (tasks: CoreTask[], action: 'delete' | 'restore') => Promise<void> = async (): Promise<void> => { throw new Error('未提供日志簿数据管理对象') }
  @State selectingTasks: boolean = false
  @State selectedTaskKeys: string[] = []
  @State selectionSnapshot: LogbookTaskItem[] = []
  @State actionBusy: boolean = false
  @State busyAction: string = ''
  @State selectionStarting: boolean = false

  policy() { if (this.trashMode) return taskActionPolicy({ singleOperations: [TaskOperation.Restore, TaskOperation.Clear],
    bulkOperations: [TaskOperation.Restore, TaskOperation.Clear] })
    return taskActionPolicy({ singleOperations: [TaskOperation.Delete],
    bulkOperations: [TaskOperation.Delete, TaskOperation.Restore] }) }

  allItems(): LogbookTaskItem[] {
    const result: LogbookTaskItem[] = []
    for (const group of this.groups) result.push(...group.items)
    return result
  }

  selectedItems(): LogbookTaskItem[] {
    return this.selectionSnapshot.filter((item: LogbookTaskItem) => this.selectedTaskKeys.includes(item.key))
  }

  @Builder
  groupHeader(group: LogbookGroup) {
    if (group.kind === 'day') {
      Row({ space: 8 }) {
        Text(group.title).fontSize(25).fontWeight(FontWeight.Bold).fontColor(UiColor.text).flexShrink(0)
        Text(group.subtitle).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).flexShrink(0)
        Divider().layoutWeight(1).color(UiColor.outline).strokeWidth(0.5)
      }.width('100%').height(48).alignItems(VerticalAlign.Center)
    } else {
      Column({ space: 7 }) {
        Divider().color(UiColor.outline).strokeWidth(0.5)
        Text(group.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
      }.width('100%').padding({ top: 9, bottom: 6 })
    }
  }

  async startSelection(item: LogbookTaskItem) {
    if (!this.ready || this.selectingTasks || this.actionBusy || this.selectionStarting) return
    this.selectionStarting = true
    try {
      if (!await TaskInlineSession.end(true)) return
      try { this.listScroller.closeAllSwipeActions() } catch (_) {}
      this.selectingTasks = true
      this.selectionSnapshot = this.allItems()
      this.selectedTaskKeys = [item.key]
    } finally { this.selectionStarting = false }
  }

  toggleSelection(item: LogbookTaskItem) {
    if (this.actionBusy || !this.selectionSnapshot.some((source: LogbookTaskItem) => source.key === item.key)) return
    this.selectedTaskKeys = this.selectedTaskKeys.includes(item.key)
      ? this.selectedTaskKeys.filter((key: string) => key !== item.key)
      : [...this.selectedTaskKeys, item.key]
  }

  resetSelection() {
    this.selectingTasks = false
    this.selectedTaskKeys = []
    this.selectionSnapshot = []
  }

  confirmDelete(items: LogbookTaskItem[]) {
    if (this.actionBusy || items.length === 0) return
    const tasks = items.map((item: LogbookTaskItem): CoreTask => item.task)
    this.getUIContext().showAlertDialog({
      title: this.trashMode ? `永久清除 ${tasks.length} 条记录？` : tasks.length === 1 ? '删除这条记录？' : `删除 ${tasks.length} 条记录？`,
      message: this.trashMode ? '清除后无法恢复。确定永久删除所选记录？' : tasks.length === 1 ? `“${tasks[0].heading}”将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。` : '所选任务将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: this.trashMode ? '清除' : '删除', fontColor: UiColor.error, action: (): void => { this.removeTasks(tasks) } }
    })
  }

  async removeTasks(tasks: CoreTask[]) {
    const operations = this.selectingTasks ? this.policy().bulkOperations : this.policy().singleOperations
    if (!operations.includes(this.trashMode ? TaskOperation.Clear : TaskOperation.Delete)) return
    await this.performTasks(tasks, 'delete')
  }

  async restoreTasks() {
    if (!this.selectingTasks || !this.policy().bulkOperations.includes(TaskOperation.Restore)) return
    await this.performTasks(this.selectedItems().map((item: LogbookTaskItem): CoreTask => item.task), 'restore')
  }

  async performTasks(tasks: CoreTask[], action: 'delete' | 'restore') {
    if (this.actionBusy || tasks.length === 0) return
    this.actionBusy = true
    this.busyAction = this.trashMode && action === 'delete' ? 'clear' : action
    try {
      if (!await TaskInlineSession.end(true)) return
      const keys = tasks.map(task => this.taskDataSet().taskKey(task.id))
      await this.perform(tasks, action)
      await this.taskDataSet().settle()
      const retained = this.trashMode ? tasks.filter((task: CoreTask, index: number): boolean => this.taskDataSet().getTask(keys[index]) !== undefined) : []
      if (action === 'restore' && retained.length > 0) {
        this.selectedTaskKeys = this.selectedItems().filter(item => retained.some(task => task.id === item.task.id && task.repoId === item.task.repoId)).map(item => item.key)
        this.getUIContext().getPromptAction().showToast({ message: `${retained.length} 条记录原位置不可用，已保留在废纸篓`, duration: 3000 })
      } else this.resetSelection()
    } catch (error) {
      try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(error as CoreBridgeError), duration: 3000 }) }
      catch (_) {}
    } finally { this.actionBusy = false; this.busyAction = '' }
  }

  activateSwipe(item: LogbookTaskItem, action: TaskSwipeAction) {
    const task = this.taskDataSet().getTask(item.key)
    if (!task) return
    const current: LogbookTaskItem = { key: item.key, timestamp: this.trashMode ? task.deletedAt : task.closedAt, task }
    if (action === 'select') this.startSelection(current)
    else if (action === 'delete' || action === 'clear') this.confirmDelete([current])
    else if (action === 'restore') this.performTasks([current.task], 'restore')
  }

  @Builder
  swipeMenu(item: LogbookTaskItem, activate: (action: TaskOperation) => void) {
    TaskSwipeActions({ busy: this.actionBusy || this.selectionStarting, idPrefix: 'logbook_swipe',
      items: taskSwipeMenu(this.policy(), (action: TaskSwipeAction): void => {
        if (this.trashMode || action === TaskOperation.Select) this.activateSwipe(item, action)
        else activate(action)
      }) })
  }

  @Builder
  itemRow(item: LogbookTaskItem, group: LogbookGroup) {
    TaskSwipeItem({ dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id),
      readOnly: !this.ready, singleOperations: this.policy().singleOperations, itemId: `logbook_item_${item.key}`, busy: this.selectingTasks || this.actionBusy || this.selectionStarting,
      menuAvailable: (): boolean => true, menuContent: (activate: (action: TaskOperation) => void): void => { this.swipeMenu(item, activate) }, content: (controller: TaskEditorController): void => { this.taskContent(item, group, controller) } })
  }

  @Builder
  taskContent(item: LogbookTaskItem, group: LogbookGroup, controller: TaskEditorController) {
    TaskSelectionRow({ selecting: this.selectingTasks,
      busy: this.actionBusy || this.selectionStarting, selectedIndex: this.selectedTaskKeys.indexOf(item.key),
      heading: item.task.heading, horizontalInset: 0,
      begin: (): void => { this.startSelection(item) }, toggle: (): void => { this.toggleSelection(item) } }) {
        Column() {
        TaskEditor({ controller, allowDeletion: this.ready && !this.trashMode, dataSet: this.taskDataSet(), taskId: this.taskDataSet().taskKey(item.task.id), readOnly: true, logShowPolicy: LogShowPolicy.LogShowAlways, allowCompletion: this.ready && !this.trashMode, instanceKey: item.key,
          dateDisplay: group.kind === 'day' ? TaskDateDisplay.None : this.trashMode ? TaskDateDisplay.Deleted : TaskDateDisplay.Closed,
          timeDisplay: this.trashMode && group.kind === 'day' ? TaskTimeDisplay.Deleted : TaskTimeDisplay.None,
          regionAreaPolicy: this.trashMode || group.kind === 'day' ? RegionAreaPolicy.None : RegionAreaPolicy.CategoryProject,
          referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'logbook_task_list' })
        if (this.trashMode) {
          Text([item.task.property('CATEGORY'), item.task.property('PROJECT_NAME'), item.task.property('ARCHIVE_FILE')].filter((value: string | null): boolean => value !== null && value.length > 0).join(' · ') || '来源未记录')
            .fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 26, bottom: 8 }).maxLines(2)
        }
        }.width('100%')
      }
  }

  currentGroup(group: LogbookGroup): LogbookGroup { return this.groups.find(item => item.key === group.key) ?? group }

  currentItems(group: LogbookGroup, regionKey: string = ''): LogbookTaskItem[] {
    const current = this.currentGroup(group)
    return regionKey ? current.groups.find(region => region.key === regionKey)?.items ?? [] : current.items
  }

  @Builder
  groupItems(group: LogbookGroup) {
    if (group.kind === 'day' && !this.trashMode) {
      ForEach(this.currentGroup(group).groups, (region: LogbookTaskGroup) => {
        TaskRegion({ category: region.category || '未分类', project: region.kind === 'project' ? region : null }) {
          ForEach(this.currentItems(group, region.key), (item: LogbookTaskItem) => {
            this.itemRow(item, group)
          }, (item: LogbookTaskItem) => item.key)
        }
      }, (region: LogbookTaskGroup) => region.key)
    } else {
      ForEach(this.currentItems(group), (item: LogbookTaskItem) => {
        this.itemRow(item, group)
      }, (item: LogbookTaskItem) => item.key)
    }
  }

  @Builder
  batchToolbar() {
    if (this.selectingTasks) {
      TaskBatchToolbar({ items: taskBatchMenu(this.policy(), (action: TaskBatchAction): void => {
          if (action === 'delete' || action === 'clear') this.confirmDelete(this.selectedItems())
          else if (action === 'restore') this.restoreTasks()
        }), count: this.selectedTaskKeys.length, busy: this.actionBusy, busyAction: this.busyAction,
        cancel: (): void => { this.resetSelection() }, idPrefix: 'logbook' })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.listScroller }) {
        if (this.notificationState.notifications.length > 0) {
          ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        }
        ForEach(this.groups, (group: LogbookGroup) => {
          ListItem() { this.groupHeader(this.currentGroup(group)) }
          this.groupItems(this.currentGroup(group))
        }, (group: LogbookGroup) => group.key)
      }.id('logbook_task_list').width('100%').height('100%').padding({ left: 20, right: 20, bottom: this.selectingTasks ? 196 : 16 })
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None)
      this.batchToolbar()
    }.width('100%').height('100%')
  }
}
