import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TodaySection, TodayTaskItem } from '../ui/TodayPresentation'
import { ListSectionHeader } from './Controls'
import { TaskListItem } from './TaskListItem'

@Component
export struct TodayTaskList {
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop sections: TodaySection[] = []
  @Prop referenceTime: number = Date.now()

  @Builder
  sectionHeader(section: TodaySection) {
    ListSectionHeader({ title: section.category ?? '未分类' }).padding({ left: 8, right: 8 })
  }

  build() {
    List() {
              if (this.notificationState.notifications.length > 0) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
      ForEach(this.sections, (section: TodaySection) => {
        ListItemGroup({ header: this.sectionHeader(section) }) {
          ForEach(section.items, (item: TodayTaskItem) => {
            ListItem() {
              TaskListItem({ task: item.task, referenceTime: this.referenceTime, open: (): void => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
              } })
            }
          }, (item: TodayTaskItem) => taskRenderKey(item.task))
        }
      }, (section: TodaySection) => JSON.stringify(section))
    }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
