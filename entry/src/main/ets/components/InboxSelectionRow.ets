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
    Row({ space: 9 }) {
      if (this.task.todoKind === 'done' && !this.task.isCancelled) {
        Image($r('app.media.ui_task_done')).width(18).height(18).accessibilityLevel('no')
      } else if (this.task.todoKind) {
        Row().width(18).height(18).borderRadius(4).border({ width: 1, color: UiColor.secondary })
          .accessibilityLevel('no')
      } else {
        Image($r('app.media.ui_note')).width(18).height(18).accessibilityLevel('no')
      }
      Column({ space: 3 }) {
        TitleText({ text: this.task.heading, parts: this.task.headingParts, textSize: 16, lineLimit: 2,
          cancelled: this.task.isCancelled }).width('100%').hitTestBehavior(HitTestMode.None)
        if (this.task.bodyFirstLine) {
          Text(this.task.bodyFirstLine).fontSize(12)
            .fontColor(UiColor.secondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Row() {
        if (this.selected) { Text(`${this.selectionOrder}`).fontSize(12).fontColor(Color.White) }
      }.width(24).height(24).borderRadius(12).border({ width: 1.5, color: this.selected ? UiColor.selection : UiColor.secondary })
        .backgroundColor(this.selected ? UiColor.selection : Color.Transparent).justifyContent(FlexAlign.Center)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 12, right: 8, top: 8, bottom: 8 })
      .backgroundColor(this.selected ? UiColor.selectionTint : Color.Transparent).borderRadius(8)
      .accessibilityText(`${this.task.heading}，${this.selected ? `已选择，第 ${this.selectionOrder} 条` : '未选择'}`)
      .enabled(!this.busy).onClick(this.choose)
  }
}
