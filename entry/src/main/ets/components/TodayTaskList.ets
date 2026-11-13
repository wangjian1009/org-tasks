import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup } from '../ui/TodayPresentation'
import { TaskRegion } from './TaskRegion'
import { CategoryRegion } from './CategoryRegion'
import { taskRegion } from '../ui/TaskRegionPresentation'
import { TaskListItem } from './TaskListItem'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'

@Component
export struct TodayTaskList {
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop sections: TodaySection[] = []
  @Prop referenceTime: number = Date.now()
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskListItem({ task: item.task, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction, scrollHost: this.listScroller, scrollHostId: 'today_task_list', open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
    } })
  }

  @Builder
  projectBlock(group: TodayTaskGroup) {
    TaskRegion({ project: taskRegion(group.items[0].task) }) {
      ForEach(group.items, (item: TodayTaskItem) => {
        ListItem() { this.taskItem(item) }
      }, (item: TodayTaskItem) => taskRenderKey(item.task))
    }
  }

  build() {
    List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.sections, (section: TodaySection) => {
        ListItem() { CategoryRegion({ category: section.category || '未分类' }) }
        ForEach(section.groups, (group: TodayTaskGroup) => {
          if (group.project !== null) {
            this.projectBlock(group)
          } else {
            ListItem() { this.taskItem(group.items[0]) }
          }
        }, (group: TodayTaskGroup) => group.key)
      }, (section: TodaySection) => JSON.stringify(section))
    }.id('today_task_list').width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
