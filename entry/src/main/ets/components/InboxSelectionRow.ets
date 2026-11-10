import { CoreTask } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { UiColor } from '../ui/Theme'

// 多选只改变交互，不把选择圆圈复用为任务完成状态。
@Component
export struct InboxSelectionRow {
  @Prop task: CoreTask
  @Prop selected: boolean = false
  @Prop selectionOrder: number = 0
  @Prop busy: boolean = false
  choose: () => void = () => {}

  build() {
    Row({ space: 12 }) {
      Column({ space: 7 }) {
        TitleText({ text: this.task.heading, parts: this.task.headingParts, textSize: 16, lineLimit: 2,
          weight: FontWeight.Medium }).width('100%').hitTestBehavior(HitTestMode.None)
        Text(this.task.bodyFirstLine || this.task.todoState || '无正文').fontSize(13)
          .fontColor(UiColor.secondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Row() {
        if (this.selected) { Text(`${this.selectionOrder}`).fontSize(12).fontColor(UiColor.onPrimary) }
      }.width(24).height(24).borderRadius(12).border({ width: 1.5, color: this.selected ? UiColor.primary : UiColor.secondary })
        .backgroundColor(this.selected ? UiColor.primary : Color.Transparent).justifyContent(FlexAlign.Center)
    }.width('100%').constraintSize({ minHeight: 78 }).padding({ left: 14, right: 14, top: 14, bottom: 14 })
      .backgroundColor(this.selected ? UiColor.selected : Color.Transparent).borderRadius(12)
      .border({ width: this.selected ? 1 : 0, color: UiColor.primary })
      .accessibilityText(`${this.task.heading}，${this.selected ? '已选择' : '未选择'}`)
      .enabled(!this.busy).onClick(this.choose)
  }
}
