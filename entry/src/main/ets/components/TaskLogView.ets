import { CoreTaskLog } from '../services/NativeCoreService'
import { taskLogsHtml } from '../ui/TaskLogPresentation'
import { OrgContentView } from './OrgContentView'

@Component
export struct TaskLogView {
  @Prop logs: CoreTaskLog[] = []
  @Prop contentBackground: string = '#00000000'
  @Prop expanded: boolean = true

  build() {
    if (this.logs.length > 0) {
      // 收起时仅裁切布局，保留阅读器及其测量高度，避免重新展开时加载空白页。
      Column() {
        OrgContentView({ fragment: taskLogsHtml(this.logs), embedded: true, embeddedPadding: 0,
          compactLogs: true, contentBackground: this.contentBackground }).width('100%')
      }.width('100%').height(this.expanded ? undefined : 0).clip(true)
        .hitTestBehavior(this.expanded ? HitTestMode.Default : HitTestMode.None)
        .accessibilityLevel(this.expanded ? 'auto' : 'no-hide-descendants')
    }
  }
}
