import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { LogbookEvent, LogbookEventGroup, LogbookGroup, logbookEventTime } from '../ui/LogbookPresentation'
import { TaskListItem } from './TaskListItem'
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
  @State selectingEvents: boolean = false
  @State selectedEventKeys: string[] = []
  @State actionBusy: boolean = false
  @State selectionStarting: boolean = false

  policy() { return taskPageActionPolicy('logbook') }

  allEvents(): LogbookEvent[] {
    const result: LogbookEvent[] = []
    for (const group of this.groups) result.push(...group.events)
    return result
  }

  selectedEvents(): LogbookEvent[] {
    return this.allEvents().filter((event: LogbookEvent) => this.selectedEventKeys.includes(event.key))
  }

  uniqueTasks(events: LogbookEvent[]): CoreTask[] {
    const result: CoreTask[] = []
    const ids = new Set<string>()
    for (const event of events) {
      if (ids.has(event.task.id)) continue
      ids.add(event.task.id)
      result.push(event.task)
    }
    return result
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

  async startSelection(event: LogbookEvent) {
    if (this.selectingEvents || this.actionBusy || this.selectionStarting) return
    this.selectionStarting = true
    try {
      if (!await TaskInlineSession.end(true)) return
      try { this.listScroller.closeAllSwipeActions() } catch (_) {}
      this.selectingEvents = true
      this.selectedEventKeys = [event.key]
    } finally { this.selectionStarting = false }
  }

  toggleSelection(event: LogbookEvent) {
    if (this.actionBusy) return
    this.selectedEventKeys = this.selectedEventKeys.includes(event.key)
      ? this.selectedEventKeys.filter((key: string) => key !== event.key)
      : [...this.selectedEventKeys, event.key]
  }

  resetSelection() {
    this.selectingEvents = false
    this.selectedEventKeys = []
  }

  confirmDelete(events: LogbookEvent[]) {
    if (this.actionBusy || events.length === 0) return
    const tasks = this.uniqueTasks(events)
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

  activateSwipe(event: LogbookEvent, action: TaskSwipeAction) {
    if (action === 'select') this.startSelection(event)
    else if (action === 'delete') this.confirmDelete([event])
  }

  @Builder
  swipeMenu(event: LogbookEvent) {
    TaskSwipeActions({ busy: this.actionBusy || this.selectionStarting, idPrefix: 'logbook_swipe',
      items: taskSwipeMenu(this.policy(), (action: TaskSwipeAction): void => { this.activateSwipe(event, action) }) })
  }

  @Builder
  eventRow(event: LogbookEvent, group: LogbookGroup) {
    ListItem() {
      TaskSelectionRow({ batchEditing: this.policy().batchEditing, selecting: this.selectingEvents,
        busy: this.actionBusy || this.selectionStarting, selectedIndex: this.selectedEventKeys.indexOf(event.key),
        heading: event.task.heading, horizontalInset: 0,
        begin: (): void => { this.startSelection(event) }, toggle: (): void => { this.toggleSelection(event) } }) {
          Column({ space: 2 }) {
            Row({ space: 8 }) {
              Text(event.label).fontSize(12).fontColor(event.kind === 'created' ? UiColor.secondary : UiColor.done)
              if (group.kind !== 'day') {
                Text(logbookEventTime(event, group)).fontSize(12).fontColor(UiColor.secondary)
              }
            }.width('100%').padding({ left: 8, top: 6 })
            TaskListItem({ task: event.task, readOnly: true, allowCompletion: true, instanceKey: event.key,
              dateDisplay: event.dateDisplay, rightSwipeAction: 'none', enableSwipeActions: false,
              showCategory: true, referenceTime: this.referenceTime, scrollHost: this.listScroller,
              scrollHostId: 'logbook_task_list' })
          }.width('100%').margin({ bottom: 8 })
        }
    }.id(`logbook_event_${event.key}`).swipeAction(this.selectingEvents || this.actionBusy || this.selectionStarting ? {} : {
      end: { builder: (): void => { this.swipeMenu(event) } }, edgeEffect: SwipeEdgeEffect.None
    })
  }

  @Builder
  projectHeader(project: string) {
    ListItem() {
      Text(project || '未命名项目').fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8, top: 8, bottom: 2 })
    }
  }

  @Builder
  groupItems(group: LogbookGroup) {
    if (group.kind === 'day') {
      ForEach(group.groups, (projectGroup: LogbookEventGroup) => {
        if (projectGroup.project !== null) this.projectHeader(projectGroup.project)
        ForEach(projectGroup.events, (event: LogbookEvent) => {
          this.eventRow(event, group)
        }, (event: LogbookEvent) => event.key)
      }, (projectGroup: LogbookEventGroup) => projectGroup.key)
    } else {
      ForEach(group.events, (event: LogbookEvent) => {
        this.eventRow(event, group)
      }, (event: LogbookEvent) => event.key)
    }
  }

  @Builder
  batchToolbar() {
    if (this.selectingEvents) {
      TaskBatchToolbar({ items: taskBatchMenu(this.policy(), (action: TaskBatchAction): void => {
          if (action === 'delete') this.confirmDelete(this.selectedEvents())
        }), count: this.selectedEventKeys.length, busy: this.actionBusy, busyAction: this.actionBusy ? 'delete' : '',
        caption: this.selectedEventKeys.length > 0 ? `删除：${this.uniqueTasks(this.selectedEvents()).length} 条任务` : '请选择记录',
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
          ListItemGroup({ header: this.groupHeader(group) }) {
            this.groupItems(group)
          }
        }, (group: LogbookGroup) => group.key)
      }.id('logbook_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None)
      this.batchToolbar()
    }.width('100%').height('100%')
  }
}
