import { CoreTask } from '../services/NativeCoreService'
import { UiColor } from '../ui/Theme'
import { memoSummaryText } from '../ui/MemoListPresentation'
import { TitleText } from './TitleText'

// 备忘卡片仅展示两行摘要，点击统一进入编辑页。
@Component
export struct MemoListItem {
  @Prop task: CoreTask
  @Prop busy: boolean = false
  open: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Blank().width(4).height(22).backgroundColor($r('app.color.memo_accent')).borderRadius(2).flexShrink(0)
        TitleText({ text: this.task.heading, parts: this.task.headingParts, textSize: 18,
          weight: FontWeight.Medium, lineLimit: 1, showCounts: true, openLinks: false, activate: this.open })
          .layoutWeight(1).constraintSize({ minWidth: 0 })
      }.width('100%')
      Text(memoSummaryText(this.task)).fontSize(15).fontColor(UiColor.secondary).lineHeight(22)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').padding({ left: 14 })
    }.width('100%').padding(16).backgroundColor(UiColor.taskCard).borderRadius(18)
      .enabled(!this.busy).accessibilityText(`编辑备忘：${this.task.heading}`)
      .onClick((): void => { this.open() })
  }
}
