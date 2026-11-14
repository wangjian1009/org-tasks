import { CoreTaskLog } from '../../services/NativeCoreService'
import { taskLogHtml } from '../../ui/TaskLogPresentation'
import { OrgContentView } from '../OrgContentView'

// 单条日志的排版与富文本阅读统一由此组件承载。
@Component
export struct TaskLogItem {
  @Prop log: CoreTaskLog
  @Prop contentBackground: string = '#00000000'

  build() {
    OrgContentView({ fragment: taskLogHtml(this.log), embedded: true, embeddedPadding: 0,
      compactLogs: true, contentBackground: this.contentBackground }).width('100%')
  }
}
