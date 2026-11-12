import { CoreTaskLog } from '../services/NativeCoreService'
import { taskLogsHtml } from '../ui/TaskLogPresentation'
import { OrgContentView } from './OrgContentView'

@Component
export struct TaskLogView {
  @Prop logs: CoreTaskLog[] = []
  @Prop contentBackground: string = '#00000000'

  build() {
    if (this.logs.length > 0) {
      OrgContentView({ fragment: taskLogsHtml(this.logs), embedded: true, embeddedPadding: 0,
        compactLogs: true, contentBackground: this.contentBackground }).width('100%')
    }
  }
}
