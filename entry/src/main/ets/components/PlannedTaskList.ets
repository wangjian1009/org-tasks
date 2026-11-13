import { ProjectNavigation } from '../services/ProjectNavigation'
import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedTaskGroup, PlannedTaskItem, plannedTaskDate } from '../ui/PlannedPresentation'
import { TaskDateDisplay } from '../ui/TaskListPresentation'
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
      plannedTaskDate(item.task) === item.task.scheduled ? TaskDateDisplay.Schedule : TaskDateDisplay.Deadline, showCategory: true,
      rightSwipeAction: this.rightSwipeAction,
      scrollHost: this.listScroller, scrollHostId: 'planned_task_list',
      referenceTime: this.referenceTime, open: (): void => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
      } })
  }

  @Builder
  projectGroup(group: PlannedGroup, project: PlannedTaskGroup) {
    Column({ space: 2 }) {
      if (project.project !== null) {
        Text(project.project || '未命名项目').fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8, top: 8 })
          .constraintSize({ minHeight: 48 }).onClick((): void => {
            const task = project.items[0].task
            ProjectNavigation.open(this.getUIContext(), task.repoId, task.filePath)
          })
      }
      ForEach(project.items, (item: PlannedTaskItem) => {
        this.taskItem(item, group)
      }, (item: PlannedTaskItem) => taskRenderKey(item.task))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 4, right: 4, top: 10, bottom: 8 })
      .backgroundColor(UiColor.projectBlock).borderRadius(12)
      .border({ width: 0.75, color: UiColor.projectOutline }).margin({ top: 12 })
  }

  @Builder
  groupContent(group: PlannedGroup) {
    Column() {
      if (group.kind === 'day') {
        this.dayHeader(group)
      } else {
        this.monthHeader(group)
      }
      if (group.kind === 'day') {
        ForEach(group.groups, (project: PlannedTaskGroup) => {
          this.projectGroup(group, project)
        }, (project: PlannedTaskGroup) => project.key)
      } else {
        ForEach(group.items, (item: PlannedTaskItem) => {
          this.taskItem(item, group)
        }, (item: PlannedTaskItem) => taskRenderKey(item.task))
      }
      if (group.kind === 'day' && group.items.length === 0) {
        Blank().height(32)
      }
    }.width('100%').padding({ left: 0, right: 0 })
  }

  build() {
    List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.groups, (group: PlannedGroup) => {
        ListItem() { this.groupContent(group) }
      }, (group: PlannedGroup) => JSON.stringify(group))
    }.id('planned_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
