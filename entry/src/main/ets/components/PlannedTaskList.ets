import { DataSet } from '../services/DataSet'
import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/NotificationManager'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedScheduleItem, PlannedTaskGroup, PlannedTaskItem, plannedTaskDate } from '../ui/PlannedPresentation'
import { CoreTask } from '../services/NativeCoreService'
import { TaskRegion } from './TaskRegion'
import { TaskDateDisplay, RegionAreaPolicy } from '../ui/TaskListPresentation'
import { TaskSwipeEditor } from './TaskSwipeEditor'

@Component
export struct PlannedTaskList {
  dataSet: DataSet | undefined = undefined
  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop readOnly: boolean = false
  @Prop groups: PlannedGroup[] = []
  @Prop referenceTime: number = Date.now()

  private group(key: string): PlannedGroup { return this.groups.find(group => group.key === key)! }
  private region(groupKey: string, key: string): PlannedTaskGroup { return this.group(groupKey).groups.find(region => region.key === key)! }
  private taskKey(task: CoreTask): string { return this.taskDataSet().taskKey(task.id) ?? task.id }
  private task(key: string): CoreTask { return this.taskDataSet().getTask(key)! }
  private scheduleItem(groupKey: string, key: string): PlannedScheduleItem {
    return this.group(groupKey).scheduleItems.find(item => this.taskKey(item.task) === key)!
  }

  private dateDisplay(groupKey: string, taskKey: string): TaskDateDisplay {
    if (this.group(groupKey).kind === 'day') return TaskDateDisplay.None
    const task = this.task(taskKey)
    return plannedTaskDate(task) === task.scheduled ? TaskDateDisplay.Schedule : TaskDateDisplay.Deadline
  }

  private regionPolicy(groupKey: string, taskKey: string): RegionAreaPolicy {
    if (this.group(groupKey).kind === 'day') return RegionAreaPolicy.None
    return this.task(taskKey).project() !== null ? RegionAreaPolicy.Project : RegionAreaPolicy.Category
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
  taskItem(taskKey: string, groupKey: string) {
    TaskSwipeEditor({ readOnly: this.readOnly, dataSet: this.taskDataSet(), taskId: taskKey,
      dateDisplay: this.dateDisplay(groupKey, taskKey), regionAreaPolicy: this.regionPolicy(groupKey, taskKey),
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list',
      referenceTime: this.referenceTime })
  }

  @Builder
  scheduleTaskItem(taskKey: string, groupKey: string) {
    TaskSwipeEditor({ readOnly: this.readOnly, dataSet: this.taskDataSet(), taskId: taskKey,
      dateDisplay: TaskDateDisplay.None, timeDisplay: this.scheduleItem(groupKey, taskKey).timeDisplay,
      regionAreaPolicy: RegionAreaPolicy.None,
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list', referenceTime: this.referenceTime })
  }

  @Builder
  regionGroup(groupKey: string, regionKey: string) {
    TaskRegion({ category: this.region(groupKey, regionKey).kind === 'project' ? null : this.region(groupKey, regionKey).category || '未分类',
      project: this.region(groupKey, regionKey).kind === 'project' ? this.region(groupKey, regionKey) : null }) {
      ForEach(this.region(groupKey, regionKey).items, (item: PlannedTaskItem) => {
        ListItem() { this.taskItem(this.taskKey(item.task), groupKey) }
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
            ListItem() { this.scheduleTaskItem(this.taskKey(item.task), groupKey) }
          }, (item: PlannedScheduleItem) => this.taskKey(item.task))
        }
      }
      ForEach(this.group(groupKey).groups, (region: PlannedTaskGroup) => {
        this.regionGroup(groupKey, region.key)
      }, (region: PlannedTaskGroup) => region.key)
    } else {
      ForEach(this.group(groupKey).items, (item: PlannedTaskItem) => {
        ListItem() { this.taskItem(this.taskKey(item.task), groupKey) }
      }, (item: PlannedTaskItem) => this.taskKey(item.task))
    }
    if (this.group(groupKey).kind === 'day' && this.group(groupKey).items.length === 0) {
      ListItem() { Column().width('100%').height(32) }
    }
  }

  build() {
    List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.groups, (group: PlannedGroup) => {
        this.groupContent(group.key)
      }, (group: PlannedGroup) => group.key)
    }.id('planned_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
