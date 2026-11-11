import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem, TodayTaskGroup } from '../ui/TodayPresentation'
import { ListSectionHeader } from './Controls'
import { TaskListItem } from './TaskListItem'
import { UiColor } from '../ui/Theme'

@Component
export struct TodayTaskList {
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop sections: TodaySection[] = []
  @Prop referenceTime: number = Date.now()

  @Builder
  sectionHeader(section: TodaySection) {
    ListSectionHeader({ title: section.category ?? '未分类' }).padding({ left: 8, right: 8 })
  }

  @Builder
  taskItem(item: TodayTaskItem) {
    TaskListItem({ task: item.task, referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'today_task_list', open: (): void => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
    } })
  }

  @Builder
  projectBlock(group: TodayTaskGroup) {
    Column({ space: 8 }) {
      Text(group.project || '未命名项目').fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8 })
        .accessibilityText(group.project || '未命名项目')
      Column() {
        ForEach(group.items, (item: TodayTaskItem) => {
          this.taskItem(item)
        }, (item: TodayTaskItem) => taskRenderKey(item.task))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 4, right: 4, top: 10, bottom: 8 })
      .backgroundColor(UiColor.projectBlock).borderRadius(12)
      .border({ width: 0.75, color: UiColor.projectOutline }).margin({ top: 12 })
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
