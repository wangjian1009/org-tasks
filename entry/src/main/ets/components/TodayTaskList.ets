import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup, TodayTimedTaskItem } from '../ui/TodayPresentation'
import { RegionAreaPolicy } from '../ui/TaskListPresentation'
import { UiColor } from '../ui/Theme'
import { TaskRegion } from './TaskRegion'
import { CategoryRegion } from './CategoryRegion'
import { taskRegion } from '../ui/TaskRegionPresentation'
import { TaskEditor } from './editors/TaskEditor'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'

@Component
export struct TodayTaskList {
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop sections: TodaySection[] = []
  @Prop timedItems: TodayTimedTaskItem[] = []
  @Prop referenceTime: number = Date.now()
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'
  @Prop expandOnRowClick: boolean = false

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskEditor({ task: item.task, referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction,
      expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
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
      if (this.timedItems.length > 0) {
        ListItemGroup() {
          ForEach(this.timedItems, (item: TodayTimedTaskItem) => {
            ListItem() {
              TaskEditor({ task: item.task, timeDisplay: item.timeDisplay, regionAreaPolicy: RegionAreaPolicy.None,
                referenceTime: this.referenceTime, rightSwipeAction: this.rightSwipeAction,
                expandOnRowClick: this.expandOnRowClick, scrollHost: this.listScroller, scrollHostId: 'today_task_list' })
            }
          }, (item: TodayTimedTaskItem) => JSON.stringify([taskRenderKey(item.task), item.timeDisplay]))
        }.width('100%').backgroundColor(UiColor.container).borderRadius(8)
          .padding({ top: 8, bottom: 8 }).margin({ top: 12 })
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
