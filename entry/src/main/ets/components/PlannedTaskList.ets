import { router } from '@kit.ArkUI'
import { UiColor } from '../ui/Theme'
import { PlannedGroup, PlannedTaskItem, plannedDateText, plannedTaskDate } from '../ui/PlannedPresentation'
import { taskRenderKey } from '../ui/TaskPresentation'
import { TitleText } from './TitleText'

@Component
struct PlannedTaskRow {
  @Prop item: PlannedTaskItem
  @Prop groupKind: string = 'day'
  @Prop referenceTime: number = Date.now()

  dateText(): string {
    return this.groupKind === 'day' ? '' : plannedDateText(plannedTaskDate(this.item.task))
  }

  build() {
    Row({ space: 8 }) {
      Blank().width(12).height(12).border({ width: 1, color: '#777572' }).borderRadius(3).flexShrink(0)
        .accessibilityText('未完成')
      if (this.dateText().length > 0) {
        Text(this.dateText()).fontSize(11).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
          .backgroundColor('#5A5856').borderRadius(2).padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .maxLines(1).flexShrink(0)
      }
      if (this.item.task.isRepeating) {
        Text('◷').fontSize(17).fontColor('#4A9AFF').width(18).height(22).textAlign(TextAlign.Center).flexShrink(0)
          .accessibilityText('重复任务')
      }
      Column({ space: 1 }) {
        TitleText({ text: this.item.task.heading, parts: this.item.task.headingParts, textSize: 14,
          weight: FontWeight.Medium, lineLimit: 1, showCounts: false })
          .width('100%')
        if (this.item.category && this.item.category.length > 0) {
          Text(this.item.category).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 4, right: 4, top: 5, bottom: 5 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => { router.pushUrl({ url: 'pages/TaskEdit', params: { task: this.item.task } }) })
      .accessibilityText(`${this.item.task.heading}，点击查看详情`)
  }
}

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
        PlannedTaskRow({ item, groupKind: group.kind, referenceTime: this.referenceTime })
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
