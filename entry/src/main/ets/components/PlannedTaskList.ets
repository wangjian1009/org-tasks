import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedTaskGroup, PlannedTaskItem, plannedTaskDate } from '../ui/PlannedPresentation'
import { TaskRegion } from './TaskRegion'
import { TaskDateDisplay, RegionAreaPolicy } from '../ui/TaskListPresentation'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TaskListItem } from './TaskListItem'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'

@Component
export struct PlannedTaskList {
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop groups: PlannedGroup[] = []
  @Prop referenceTime: number = Date.now()
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'

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
  taskItem(item: PlannedTaskItem, group: PlannedGroup) {
    TaskListItem({ task: item.task, dateDisplay: group.kind === 'day' ? TaskDateDisplay.None :
      plannedTaskDate(item.task) === item.task.scheduled ? TaskDateDisplay.Schedule : TaskDateDisplay.Deadline,
      regionAreaPolicy: group.kind === 'day' ? RegionAreaPolicy.None :
        item.task.project() !== null ? RegionAreaPolicy.Project : RegionAreaPolicy.Category,
      rightSwipeAction: this.rightSwipeAction,
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list',
      referenceTime: this.referenceTime, open: (): void => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
      } })
  }

  @Builder
  regionGroup(group: PlannedGroup, region: PlannedTaskGroup) {
    TaskRegion({ category: region.kind === 'project' ? null : region.category || '未分类',
      project: region.kind === 'project' ? region : null }) {
      ForEach(region.items, (item: PlannedTaskItem) => {
        ListItem() { this.taskItem(item, group) }
      }, (item: PlannedTaskItem) => taskRenderKey(item.task))
    }
  }

  @Builder
  groupContent(group: PlannedGroup) {
    ListItem() {
      if (group.kind === 'day') {
        this.dayHeader(group)
      } else {
        this.monthHeader(group)
      }
    }
    if (group.kind === 'day') {
      ForEach(group.groups, (region: PlannedTaskGroup) => {
        this.regionGroup(group, region)
      }, (region: PlannedTaskGroup) => region.key)
    } else {
      ForEach(group.items, (item: PlannedTaskItem) => {
        ListItem() { this.taskItem(item, group) }
      }, (item: PlannedTaskItem) => taskRenderKey(item.task))
    }
    if (group.kind === 'day' && group.items.length === 0) {
      ListItem() { Column().width('100%').height(32) }
    }
  }

  build() {
    List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.groups, (group: PlannedGroup) => {
        this.groupContent(group)
      }, (group: PlannedGroup) => JSON.stringify(group))
    }.id('planned_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
