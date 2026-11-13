import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { LogbookTaskItem, LogbookTaskGroup, LogbookGroup } from '../ui/LogbookPresentation'
import { TaskListItem } from './TaskListItem'
import { TaskRegion } from './TaskRegion'
import { RegionAreaPolicy, TaskDateDisplay } from '../ui/TaskListPresentation'
import { TaskSelectionRow } from './TaskSelectionRow'
import { TaskBatchToolbar } from './TaskBatchToolbar'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskInlineSession } from '../services/TaskInlineService'
import { LogbookService } from '../services/LogbookService'
import { taskBatchMenu, taskPageActionPolicy, taskSwipeMenu, TaskBatchAction, TaskSwipeAction } from '../ui/TaskActionPresentation'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'

@Component
export struct LogbookTaskList {
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop groups: LogbookGroup[] = []
  @Prop referenceTime: number = Date.now()
  refresh: () => void = () => {}
  @State selectingTasks: boolean = false
  @State selectedTaskKeys: string[] = []
  @State actionBusy: boolean = false
  @State selectionStarting: boolean = false

  policy() { return taskPageActionPolicy('logbook') }

  allItems(): LogbookTaskItem[] {
    const result: LogbookTaskItem[] = []
    for (const group of this.groups) result.push(...group.items)
    return result
  }

  selectedItems(): LogbookTaskItem[] {
    return this.allItems().filter((item: LogbookTaskItem) => this.selectedTaskKeys.includes(item.key))
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
    if (this.selectingTasks || this.actionBusy || this.selectionStarting) return
    this.selectionStarting = true
    try {
      if (!await TaskInlineSession.end(true)) return
      try { this.listScroller.closeAllSwipeActions() } catch (_) {}
      this.selectingTasks = true
      this.selectedTaskKeys = [item.key]
    } finally { this.selectionStarting = false }
  }

  toggleSelection(item: LogbookTaskItem) {
    if (this.actionBusy) return
    this.selectedTaskKeys = this.selectedTaskKeys.includes(item.key)
      ? this.selectedTaskKeys.filter((key: string) => key !== item.key)
      : [...this.selectedTaskKeys, item.key]
  }

  resetSelection() {
    this.selectingTasks = false
    this.selectedTaskKeys = []
  }

  confirmDelete(items: LogbookTaskItem[]) {
    if (this.actionBusy || items.length === 0) return
    const tasks = items.map((item: LogbookTaskItem): CoreTask => item.task)
    this.getUIContext().showAlertDialog({
      title: tasks.length === 1 ? '删除这条记录？' : `删除 ${tasks.length} 条记录？`,
      message: tasks.length === 1 ? `“${tasks[0].heading}”及其子记录将从文件中删除。` : '所选任务及其子记录将从文件中删除。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.removeTasks(tasks) } }
    })
  }

  async removeTasks(tasks: CoreTask[]) {
    if (this.actionBusy || tasks.length === 0) return
    this.actionBusy = true
    try {
      if (!await TaskInlineSession.end(true)) return
      await LogbookService.remove(this.getUIContext().getHostContext()!, tasks)
      this.resetSelection()
      this.refresh()
    } catch (error) {
      try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(error as CoreBridgeError), duration: 3000 }) }
      catch (_) {}
    } finally { this.actionBusy = false }
  }

  activateSwipe(item: LogbookTaskItem, action: TaskSwipeAction) {
    if (action === 'select') this.startSelection(item)
    else if (action === 'delete') this.confirmDelete([item])
  }

  @Builder
  swipeMenu(item: LogbookTaskItem) {
    TaskSwipeActions({ busy: this.actionBusy || this.selectionStarting, idPrefix: 'logbook_swipe',
      items: taskSwipeMenu(this.policy(), (action: TaskSwipeAction): void => { this.activateSwipe(item, action) }) })
  }

  @Builder
  itemRow(item: LogbookTaskItem, group: LogbookGroup) {
    ListItem() {
      TaskSelectionRow({ batchEditing: this.policy().batchEditing, selecting: this.selectingTasks,
        busy: this.actionBusy || this.selectionStarting, selectedIndex: this.selectedTaskKeys.indexOf(item.key),
        heading: item.task.heading, horizontalInset: 0,
        begin: (): void => { this.startSelection(item) }, toggle: (): void => { this.toggleSelection(item) } }) {
          TaskListItem({ task: item.task, readOnly: true, allowCompletion: true, instanceKey: item.key,
            dateDisplay: group.kind === 'day' ? TaskDateDisplay.None : TaskDateDisplay.Closed,
            rightSwipeAction: 'none', enableSwipeActions: false,
            regionAreaPolicy: group.kind === 'day' ? RegionAreaPolicy.None : RegionAreaPolicy.CategoryProject,
            referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'logbook_task_list' })
        }
    }.id(`logbook_item_${item.key}`).swipeAction(this.selectingTasks || this.actionBusy || this.selectionStarting ? {} : {
      end: { builder: (): void => { this.swipeMenu(item) } }, edgeEffect: SwipeEdgeEffect.None
    })
  }

  @Builder
  groupItems(group: LogbookGroup) {
    if (group.kind === 'day') {
      ForEach(group.groups, (region: LogbookTaskGroup) => {
        TaskRegion({ category: region.category || '未分类', project: region.kind === 'project' ? region : null }) {
          ForEach(region.items, (item: LogbookTaskItem) => {
            this.itemRow(item, group)
          }, (item: LogbookTaskItem) => item.key)
        }
      }, (region: LogbookTaskGroup) => region.key)
    } else {
      ForEach(group.items, (item: LogbookTaskItem) => {
        this.itemRow(item, group)
      }, (item: LogbookTaskItem) => item.key)
    }
  }

  @Builder
  batchToolbar() {
    if (this.selectingTasks) {
      TaskBatchToolbar({ items: taskBatchMenu(this.policy(), (action: TaskBatchAction): void => {
          if (action === 'delete') this.confirmDelete(this.selectedItems())
        }), count: this.selectedTaskKeys.length, busy: this.actionBusy, busyAction: this.actionBusy ? 'delete' : '',
        caption: this.selectedTaskKeys.length > 0 ? `删除：${this.selectedTaskKeys.length} 条任务` : '请选择记录',
        cancelLabel: '完成', cancel: (): void => { this.resetSelection() }, idPrefix: 'logbook' })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.listScroller }) {
        if (this.notificationState.notifications.length > 0) {
          ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        }
        ForEach(this.groups, (group: LogbookGroup) => {
          ListItem() { this.groupHeader(group) }
          this.groupItems(group)
        }, (group: LogbookGroup) => group.key)
      }.id('logbook_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None)
      this.batchToolbar()
    }.width('100%').height('100%')
  }
}
