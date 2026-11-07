import { router } from '@kit.ArkUI'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedTaskItem } from '../ui/PlannedPresentation'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TaskListItem } from './TaskListItem'

@Component
export struct PlannedTaskList {
  @Prop groups: PlannedGroup[] = []
  @Prop referenceTime: number = Date.now()

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
  groupContent(group: PlannedGroup) {
    Column() {
      if (group.kind === 'day') {
        this.dayHeader(group)
      } else {
        this.monthHeader(group)
      }
      ForEach(group.items, (item: PlannedTaskItem) => {
        TaskListItem({ task: item.task, showDate: group.kind !== 'day', showCategory: true,
          referenceTime: this.referenceTime, open: (): void => {
            router.pushUrl({ url: 'pages/TaskEdit', params: { task: item.task } })
          } })
      }, (item: PlannedTaskItem) => taskRenderKey(item.task))
      if (group.kind === 'day' && group.items.length === 0) {
        Blank().height(32)
      }
    }.width('100%').padding({ left: 0, right: 0 })
  }

  build() {
    List() {
      ForEach(this.groups, (group: PlannedGroup) => {
        ListItem() { this.groupContent(group) }
      }, (group: PlannedGroup) => group.key)
    }.width('100%').layoutWeight(1).padding({ left: 20, right: 20, bottom: 16 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
  }
}
