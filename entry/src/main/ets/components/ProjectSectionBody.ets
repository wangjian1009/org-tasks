import { CoreTask, CoreContentBlock } from '../services/NativeCoreService'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskDocumentContent } from './editors/TaskDocumentContent'
import { UiColor } from '../ui/Theme'

// 以直属正文的实际高度画线，避免百分比高度沿滚动容器贯穿后续章节。
@Component
export struct ProjectSectionBody {
  @Prop task: CoreTask | null = null
  @Prop blocks: CoreContentBlock[] = []
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @State bodyHeight: number = 0

  @Builder
  bodyGuide() {
    if (this.task && this.bodyHeight > 6) {
      Rect().width(1).height(this.bodyHeight - 6).fill(UiColor.divider)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }
  }

  build() {
    TaskDocumentContent({ internalLinkProcessor: this.internalLinkProcessor, task: this.task,
      blocks: this.blocks, readonly: this.task === null, projectReading: true }).width('100%')
      .padding({ left: this.task ? (this.task.state ? 28 : 8) : 0 })
      .onAreaChange((_old: Area, area: Area): void => { this.bodyHeight = Math.max(0, Number(area.height)) })
      .overlay(this.bodyGuide(), { align: Alignment.TopStart, offset: { x: this.task?.state ? 8 : 0, y: 3 } })
  }
}
