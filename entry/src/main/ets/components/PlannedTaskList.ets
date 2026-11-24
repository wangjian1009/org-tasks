import { DataSet } from '../services/DataSet'
import { CoreNotificationsView } from './CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedScheduleItem, PlannedTaskGroup, PlannedTaskItem, plannedTaskDate } from '../ui/PlannedPresentation'
import { CoreTask } from '../services/NativeCoreService'
import { TaskRegion } from './TaskRegion'
import { TaskDateDisplay, TaskTimeDisplay, RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskSwipeItem } from './TaskSwipeItem'
import { TaskSelectionRow } from './TaskSelectionRow'
import { TaskSelectionToolbar } from './TaskSelectionToolbar'
import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskEditorController } from '../ui/TaskEditorController'
import { TaskEditor } from './editors/TaskEditor'
import { TaskOperation, TaskSingleOperation, TaskBatchAction } from '../ui/TaskActionPresentation'

@Component
export struct PlannedTaskList {
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @Prop readOnly: boolean = false
  @Prop singleOperations: TaskSingleOperation[] = []
  @Prop bulkOperations: TaskBatchAction[] = []
  @ObjectLink selection: TaskSelectionController
  changed: () => void = () => {}
  @Prop groups: PlannedGroup[] = []
  @Prop referenceTime: number = Date.now()

  aboutToAppear(): void {
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
    this.selection.connect(this.taskDataSet(), (): CoreTask[] => this.allTasks(), () => this.bulkOperations,
      (): boolean => !this.readOnly, this.listScroller, this.changed)
  }
  aboutToDisappear(): void {
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.selection.close()
  }

  private allTasks(): CoreTask[] { return this.groups.flatMap(group => group.items.map(item => item.task)) }
  private group(key: string): PlannedGroup { return this.groups.find(group => group.key === key)! }
  private region(groupKey: string, key: string): PlannedTaskGroup | undefined { return this.groups.find(group => group.key === groupKey)?.groups.find(region => region.key === key) }
  private taskKey(task: CoreTask): string { return this.taskDataSet().taskKey(task.id) ?? task.id }
  private task(key: string): CoreTask | undefined { return this.taskDataSet().getTask(key) ?? this.allTasks().find(task => this.taskKey(task) === key) }
  private scheduleItem(groupKey: string, key: string): PlannedScheduleItem | undefined {
    return this.groups.find(group => group.key === groupKey)?.scheduleItems.find(item => this.taskKey(item.task) === key)
  }

  private dateGroupChanged(before: CoreTask, after: CoreTask): boolean {
    return plannedTaskDate(before) !== plannedTaskDate(after)
  }

  private dateDisplay(groupKey: string, taskKey: string): TaskDateDisplay {
    const group = this.groups.find(item => item.key === groupKey), task = this.task(taskKey)
    if (!group || group.kind === 'day' || !task) return TaskDateDisplay.None
    return plannedTaskDate(task) === task.scheduled ? TaskDateDisplay.Schedule : TaskDateDisplay.Deadline
  }

  private regionPolicy(groupKey: string, taskKey: string): RegionAreaPolicy {
    const group = this.groups.find(item => item.key === groupKey), task = this.task(taskKey)
    if (!group || group.kind === 'day' || !task) return RegionAreaPolicy.None
    return task.project() !== null ? RegionAreaPolicy.Project : RegionAreaPolicy.Category
  }

  @Builder
  dayHeader(group: PlannedGroup) {
    Row({ space: 8 }) {
      Text(group.title).fontSize(25).fontWeight(FontWeight.Bold).fontColor(UiColor.text).flexShrink(0)
      Text(group.subtitle).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).flexShrink(0)
      Divider().layoutWeight(1).color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').height(48).alignItems(VerticalAlign.Center)
  }

  @Builder
  monthHeader(group: PlannedGroup) {
    Column({ space: 7 }) {
      Divider().color(UiColor.outline).strokeWidth(0.5)
      Text(group.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
    }.width('100%').padding({ top: 9, bottom: 6 })
  }

  @Builder
  taskContent(taskKey: string, groupKey: string, controller: TaskEditorController, timed: boolean) {
    if (this.groups.some(group => group.key === groupKey) && this.task(taskKey)) {
      TaskSelectionRow({ selecting: this.selection.selecting, busy: this.selection.blocked(),
        selectedIndex: this.selection.selectedKeys.indexOf(taskKey), heading: this.task(taskKey)?.heading ?? '',
        begin: (): void => { const task = this.task(taskKey); if (task) this.selection.start(task.id) },
        toggle: (): void => { const task = this.task(taskKey); if (task) this.selection.toggle(task.id) } }) {
        TaskEditor({ controller, dataSet: this.taskDataSet(), taskId: taskKey, readOnly: this.readOnly,
          dateDisplay: timed ? TaskDateDisplay.None : this.dateDisplay(groupKey, taskKey),
          timeDisplay: timed ? (this.scheduleItem(groupKey, taskKey)?.timeDisplay ?? TaskTimeDisplay.None) : TaskTimeDisplay.None,
          regionAreaPolicy: timed ? RegionAreaPolicy.None : this.regionPolicy(groupKey, taskKey),
          referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'planned_task_list' })
      }
    }
  }

  @Builder
  taskItem(taskKey: string, groupKey: string) {
    TaskSwipeItem({ readOnly: this.readOnly, singleOperations: this.singleOperations, rightSwipeAction: TaskOperation.Schedule,
      dataSet: this.taskDataSet(), taskId: taskKey, selection: this.selection,
      busy: this.selection.selecting || this.selection.blocked(), menuIdPrefix: 'planned_swipe',
      dateGroupChanged: (before: CoreTask, after: CoreTask): boolean => this.dateGroupChanged(before, after),
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list',
      content: (controller: TaskEditorController): void => { this.taskContent(taskKey, groupKey, controller, false) } })
  }

  @Builder
  scheduleTaskItem(taskKey: string, groupKey: string) {
    TaskSwipeItem({ readOnly: this.readOnly, singleOperations: this.singleOperations, rightSwipeAction: TaskOperation.Schedule,
      dataSet: this.taskDataSet(), taskId: taskKey, selection: this.selection,
      busy: this.selection.selecting || this.selection.blocked(), menuIdPrefix: 'planned_swipe',
      dateGroupChanged: (before: CoreTask, after: CoreTask): boolean => this.dateGroupChanged(before, after),
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list',
      content: (controller: TaskEditorController): void => { this.taskContent(taskKey, groupKey, controller, true) } })
  }

  @Builder
  regionGroup(groupKey: string, regionKey: string) {
    TaskRegion({ category: this.region(groupKey, regionKey)?.kind === 'project' ? null : this.region(groupKey, regionKey)?.category || '未分类',
      project: this.region(groupKey, regionKey)?.kind === 'project' ? this.region(groupKey, regionKey) ?? null : null }) {
      ForEach(this.region(groupKey, regionKey)?.items ?? [], (item: PlannedTaskItem) => {
        this.taskItem(this.taskKey(item.task), groupKey)
      }, (item: PlannedTaskItem) => this.taskKey(item.task))
    }
  }

  @Builder
  groupContent(groupKey: string) {
    ListItem() {
      if (this.group(groupKey).kind === 'day') {
        this.dayHeader(this.group(groupKey))
      } else {
        this.monthHeader(this.group(groupKey))
      }
    }
    if (this.group(groupKey).kind === 'day') {
      if (this.group(groupKey).scheduleItems.length > 0) {
        TaskRegion({ category: '日程' }) {
          ForEach(this.group(groupKey).scheduleItems, (item: PlannedScheduleItem) => {
            this.scheduleTaskItem(this.taskKey(item.task), groupKey)
          }, (item: PlannedScheduleItem) => this.taskKey(item.task))
        }
      }
      ForEach(this.group(groupKey).groups, (region: PlannedTaskGroup) => {
        this.regionGroup(groupKey, region.key)
      }, (region: PlannedTaskGroup) => region.key)
    } else {
      ForEach(this.group(groupKey).items, (item: PlannedTaskItem) => {
        this.taskItem(this.taskKey(item.task), groupKey)
      }, (item: PlannedTaskItem) => this.taskKey(item.task))
    }
    if (this.group(groupKey).kind === 'day' && this.group(groupKey).items.length === 0) {
      ListItem() { Column().width('100%').height(32) }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.listScroller }) {
        if (this.showNotifications) {
          ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
        }
        ForEach(this.groups, (group: PlannedGroup) => {
          this.groupContent(group.key)
        }, (group: PlannedGroup) => group.key)
      }.id('planned_task_list').width('100%').height('100%').padding({ left: 20, right: 20, bottom: this.selection.selecting ? 196 : 16 })
        .scrollBar(BarState.Off)
        .enableScrollInteraction(!this.checklistDragging)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None)
      TaskSelectionToolbar({ selection: this.selection, operations: this.bulkOperations, idPrefix: 'planned' })
    }.width('100%').layoutWeight(1)
  }
}
