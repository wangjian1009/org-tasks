import { CoreTaskLog } from '../../services/NativeCoreService'
import { taskLogHtml } from '../../ui/TaskLogPresentation'
import { OrgContentView } from '../OrgContentView'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'

// 单条日志的排版与富文本阅读统一由此组件承载。
@Component
export struct TaskLogItem {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop log: CoreTaskLog
  @Prop contentBackground: string = '#00000000'

  build() {
    OrgContentView({ internalLinkProcessor: this.internalLinkProcessor, fragment: taskLogHtml(this.log), embedded: true, embeddedPadding: 0,
      compactLogs: true, contentBackground: this.contentBackground }).width('100%')
  }
}
