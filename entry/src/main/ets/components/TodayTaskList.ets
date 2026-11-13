import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup } from '../ui/TodayPresentation'
import { TaskGroup } from './TaskGroup'
import { TaskRegionHeader } from './TaskRegionHeader'
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
  sectionHeader(section: TodaySection) {
    TaskRegionHeader({ region: taskRegion(section.items[0].task), category: true, project: false })
      .padding({ left: 8, right: 8 })
  }

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskListItem({ task: item.task, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction, scrollHost: this.listScroller, scrollHostId: 'today_task_list', open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
    } })
  }

  @Builder
  projectBlock(group: TodayTaskGroup) {
    TaskGroup({ region: taskRegion(group.items[0].task), category: false, project: true }) {
      ForEach(group.items, (item: TodayTaskItem) => {
        this.taskItem(item)
      }, (item: TodayTaskItem) => taskRenderKey(item.task))
    }
  }

  build() {
    List({ scroller: this.listScroller }) {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.sections, (section: TodaySection) => {
        ListItemGroup({ header: this.sectionHeader(section) }) {
          ForEach(section.groups, (group: TodayTaskGroup) => {
            if (group.project !== null) {
              ListItem() { this.projectBlock(group) }
            } else {
              ListItem() { this.taskItem(group.items[0]) }
            }
          }, (group: TodayTaskGroup) => group.key)
        }
      }, (section: TodaySection) => JSON.stringify(section))
    }.id('today_task_list').width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
      .enableScrollInteraction(!this.checklistDragging)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
