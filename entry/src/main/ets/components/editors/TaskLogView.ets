import { CoreTaskLog } from '../../services/NativeCoreService'
import { TaskLogItem } from './TaskLogItem'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'

@Component
export struct TaskLogView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop logs: CoreTaskLog[] = []
  @Prop contentBackground: string = '#00000000'
  @Prop expanded: boolean = true

  build() {
    if (this.logs.length > 0) {
      // 收起时仅裁切布局，保留阅读器及其测量高度，避免重新展开时加载空白页。
      Column({ space: 6 }) {
        ForEach(this.logs, (log: CoreTaskLog) => {
          TaskLogItem({ internalLinkProcessor: this.internalLinkProcessor, log: log, contentBackground: this.contentBackground }).width('100%')
        }, (log: CoreTaskLog, index: number) => `${index}:${JSON.stringify(log)}`)
      }.width('100%').height(this.expanded ? undefined : 0).clip(true)
        .hitTestBehavior(this.expanded ? HitTestMode.Default : HitTestMode.None)
        .accessibilityLevel(this.expanded ? 'auto' : 'no-hide-descendants')
    }
  }
}
