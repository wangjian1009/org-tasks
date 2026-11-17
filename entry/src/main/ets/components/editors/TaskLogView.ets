import { CoreTaskLog } from '../../services/NativeCoreService'
import { TaskLogItem } from './TaskLogItem'
import { InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { UiColor } from '../../ui/Theme'

@Component
export struct TaskLogView {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop logs: CoreTaskLog[] = []
  @Prop contentBackground: string = '#00000000'
  @Prop expanded: boolean = true
  @Prop notesOnly: boolean = false

  build() {
    if (this.logs.length > 0) {
      // 收起时仅裁切布局，保留阅读器及其测量高度，避免重新展开时加载空白页。
      Column({ space: this.notesOnly ? 10 : 6 }) {
        Row({ space: 8 }) {
          Text(this.notesOnly ? '备注' : '日志').fontSize(12).fontColor(UiColor.secondary).flexShrink(0)
          Divider().color(UiColor.outline).strokeWidth(1).layoutWeight(1)
        }.width('100%')
        ForEach(this.logs, (log: CoreTaskLog) => {
          TaskLogItem({ internalLinkProcessor: this.internalLinkProcessor, log: log, notesOnly: this.notesOnly,
            contentBackground: this.contentBackground }).width('100%')
        }, (log: CoreTaskLog, index: number) => `${index}:${JSON.stringify(log)}`)
      }.width('100%').height(this.expanded ? undefined : 0).clip(true)
        .hitTestBehavior(this.expanded ? HitTestMode.Default : HitTestMode.None)
        .accessibilityLevel(this.expanded ? 'auto' : 'no-hide-descendants')
    }
  }
}
