import { CoreTask, CoreContentBlock, CoreContentNode } from '../services/NativeCoreService'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskContentEditor } from './editors/TaskContentEditor'
import { TaskEditor } from './editors/TaskEditor'
import { DataSet } from '../services/DataSet'
import { UiColor, UiSize } from '../ui/Theme'

// 装饰线作为不参与命中的独立子节点，按正文实测高度收尾。
@Component
export struct OrgFileSectionBody {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  @Prop task: CoreTask | null = null
  @Prop blocks: CoreContentBlock[] = []
  @Prop contentTree: CoreContentNode[] | undefined = undefined
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop contentBackground: string = UiColor.surface
  @Prop documentContent: boolean = false
  @Prop addContentRequest: number = 0
  @State bodyHeight: number = 0

  @Builder
  bodyGuide() {
    if (this.task && this.task.level > 1 && this.bodyHeight > 6) {
      Rect().width(1).height(this.bodyHeight - 6).fill(UiColor.divider)
        .position({ x: this.task.state ? 8 : 0, y: 3 })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.bodyGuide()
      Column() {
        if (this.dataSet && this.task) {
          TaskEditor({ dataSet: this.dataSet, taskId: this.taskId, bodyOnly: true, instanceKey: `body:${this.taskId}`,
            documentContent: this.documentContent, addContentRequest: this.addContentRequest,
            internalLinkProcessor: this.internalLinkProcessor, scrollHost: this.scrollHost, scrollHostId: this.scrollHostId }).width('100%')
        } else {
          TaskContentEditor({ internalLinkProcessor: this.internalLinkProcessor, blocks: this.blocks, contentTree: this.contentTree,
            readonly: true, horizontalParentFirst: false, contentBackground: this.contentBackground }).width('100%')
        }
      }.width('100%').padding({ left: this.task ? (this.task.state ? UiSize.taskBodyIndent : 12) : 0 })
        .onAreaChange((_old: Area, area: Area): void => { this.bodyHeight = Math.max(0, Number(area.height)) })
    }.width('100%')
  }
}
