import { CoreTask, CoreContentBlock, CoreTaskModification } from '../services/NativeCoreService'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { TaskDocumentContent } from './editors/TaskDocumentContent'
import { UiColor } from '../ui/Theme'

// 装饰线作为不参与命中的独立子节点，按正文实测高度收尾。
@Component
export struct OrgFileSectionBody {
  modify: (task: CoreTask, changes: CoreTaskModification[]) => Promise<CoreTask> = async (): Promise<CoreTask> => { throw new Error('未提供项目数据管理接口') }
  readTask: (() => CoreTask | undefined) | undefined = undefined
  @Prop task: CoreTask | null = null
  @Prop blocks: CoreContentBlock[] = []
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop contentRevision: string = ''
  @Prop contentBackground: string = UiColor.surface
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
      TaskDocumentContent({ modify: this.modify, readTask: this.readTask, internalLinkProcessor: this.internalLinkProcessor, task: this.task,
        blocks: this.blocks, contentRevision: this.contentRevision, readonly: this.task === null, projectReading: true, contentBackground: this.contentBackground }).width('100%')
        .padding({ left: this.task ? (this.task.state ? 28 : 8) : 0 })
        .onAreaChange((_old: Area, area: Area): void => { this.bodyHeight = Math.max(0, Number(area.height)) })
    }.width('100%')
  }
}
