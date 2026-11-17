import { CoreTaskLog } from '../../services/NativeCoreService'
import { taskLogHtml, taskNoteHtml, taskNoteTime } from '../../ui/TaskLogPresentation'
import { UiColor } from '../../ui/Theme'
import { OrgContentView } from '../OrgContentView'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'

// 单条日志的排版与富文本阅读统一由此组件承载。
@Component
export struct TaskLogItem {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop log: CoreTaskLog
  @Prop contentBackground: string = '#00000000'
  @Prop notesOnly: boolean = false

  build() {
    if (this.notesOnly) {
      Row({ space: 10 }) {
        Text(taskNoteTime(this.log)).fontSize(11).fontColor(UiColor.disabled).width(86).flexShrink(0)
          .padding({ top: 2 })
        OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: taskNoteHtml(this.log), embedded: true, embeddedPadding: 0,
          compactLogs: true, contentBackground: this.contentBackground }).layoutWeight(1).constraintSize({ minWidth: 0 })
      }.width('100%').alignItems(VerticalAlign.Top)
    } else {
      OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: taskLogHtml(this.log), embedded: true, embeddedPadding: 0,
        compactLogs: true, contentBackground: this.contentBackground }).width('100%')
    }
  }
}
