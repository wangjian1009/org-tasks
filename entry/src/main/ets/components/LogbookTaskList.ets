import { CoreNotificationsView } from './CoreNotificationsView'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { LogbookEvent, LogbookEventGroup, LogbookGroup, logbookEventTime } from '../ui/LogbookPresentation'
import { TaskListItem } from './TaskListItem'
import { UiColor } from '../ui/Theme'

@Component
export struct LogbookTaskList {
  private listScroller: ListScroller = new ListScroller()
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()
  @Prop groups: LogbookGroup[] = []
  @Prop referenceTime: number = Date.now()

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

  @Builder
  eventItem(event: LogbookEvent, group: LogbookGroup) {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        Text(event.label).fontSize(12).fontColor(event.kind === 'created' ? UiColor.secondary : UiColor.done)
        if (group.kind !== 'day') {
          Text(logbookEventTime(event, group)).fontSize(12).fontColor(UiColor.secondary)
        }
      }.width('100%').padding({ left: 8, top: 6 })
      TaskListItem({ task: event.task, readOnly: true, instanceKey: event.key, dateDisplay: event.dateDisplay,
        rightSwipeAction: 'none', enableSwipeActions: false, showCategory: true,
        referenceTime: this.referenceTime, scrollHost: this.listScroller, scrollHostId: 'logbook_task_list' })
    }.width('100%').margin({ bottom: 8 })
  }

  @Builder
  eventGroup(group: LogbookGroup, projectGroup: LogbookEventGroup) {
    Column({ space: 2 }) {
      if (projectGroup.project !== null) {
        Text(projectGroup.project || '未命名项目').fontSize(12).fontColor(UiColor.projectLabel).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 8, right: 8, top: 8 })
      }
      ForEach(projectGroup.events, (event: LogbookEvent) => {
        this.eventItem(event, group)
      }, (event: LogbookEvent) => event.key)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 4, right: 4, top: 10, bottom: 8 })
      .backgroundColor(UiColor.projectBlock).borderRadius(12)
      .border({ width: 0.75, color: UiColor.projectOutline }).margin({ top: 12 })
  }

  build() {
    List({ scroller: this.listScroller }) {
      if (this.notificationState.notifications.length > 0) {
        ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
      }
      ForEach(this.groups, (group: LogbookGroup) => {
        ListItem() {
          Column() {
            this.groupHeader(group)
            if (group.kind === 'day') {
              ForEach(group.groups, (projectGroup: LogbookEventGroup) => {
                this.eventGroup(group, projectGroup)
              }, (projectGroup: LogbookEventGroup) => projectGroup.key)
            } else {
              ForEach(group.events, (event: LogbookEvent) => {
                this.eventItem(event, group)
              }, (event: LogbookEvent) => event.key)
            }
          }.width('100%')
        }
      }, (group: LogbookGroup) => group.key)
    }.id('logbook_task_list').width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
