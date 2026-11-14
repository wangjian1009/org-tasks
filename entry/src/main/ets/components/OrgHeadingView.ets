import { CoreTask } from '../services/NativeCoreService'
import { TitleText } from './TitleText'
import { UiColor } from '../ui/Theme'
import { taskTagColor } from '../ui/TaskListPresentation'
import { visibleProjectTags } from '../ui/ProjectReadingPresentation'

// 普通标题独立渲染，不提供任务状态或任务编辑入口。
@Component
export struct OrgHeadingView {
  @Prop node: CoreTask
  @Prop specialTags: string[] = []

  build() {
    Column({ space: 8 }) {
      TitleText({ text: this.node.heading, parts: this.node.headingParts,
        textSize: this.node.level === 1 ? 22 : this.node.level === 2 ? 20 : 18,
        weight: FontWeight.Medium, copyable: true }).width('100%')
      if (visibleProjectTags(this.node.ownTags, this.specialTags).length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(visibleProjectTags(this.node.ownTags, this.specialTags), (tag: string) => {
            Text(tag).fontSize(12).fontColor(UiColor.text).wordBreak(WordBreak.BREAK_ALL)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10)
              .backgroundColor(taskTagColor(tag)).margin({ right: 6, bottom: 6 })
          }, (tag: string) => tag)
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ top: this.node.level === 1 ? 32 : 24, bottom: 8 })
      .accessibilityGroup(true).accessibilityText(`${this.node.level} 级标题，${this.node.heading}`)
  }
}
