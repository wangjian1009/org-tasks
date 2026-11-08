import { CoreSyncRecord } from '../services/NativeCoreService'
import { syncLogConflictLabel, syncLogErrorLabel, syncLogResultLabel, syncLogTimeLabel,
  syncLogTitle } from '../ui/SyncLogPresentation'
import { UiColor } from '../ui/Theme'

// 独立展示一条 Core 日志摘要，不解析历史或推导同步规则。
@Component
export struct SyncLogItem {
  @Prop record: CoreSyncRecord
  open: () => void = () => {}

  resultIcon(): Resource {
    switch (this.record.executionResult) {
      case 'succeeded': return $r('app.media.ui_sync_succeeded')
      case 'failed': return $r('app.media.ui_sync_failed')
      default: return $r('app.media.ui_sync_stopped')
    }
  }

  transferIcon(): Resource {
    switch (this.record.transfer) {
      case 'download': return $r('app.media.ui_sync_download')
      case 'upload': return $r('app.media.ui_sync_upload')
      case 'bidirectional': return $r('app.media.ui_sync_bidirectional')
      default: return $r('app.media.ui_sync_unchanged')
    }
  }

  build() {
    Row({ space: 6 }) {
      Image(this.resultIcon()).width(18).height(18).margin({ right: 2 }).flexShrink(0)
        .accessibilityText(syncLogResultLabel(this.record))
      Image(this.transferIcon()).width(20).height(20).flexShrink(0)
      Text(syncLogTitle(this.record)).fontSize(16).minFontSize(14).maxFontSize(16)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontColor(syncLogErrorLabel(this.record).length > 0 ? UiColor.error : this.record.transfer === 'unchanged' ? UiColor.secondary : UiColor.text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      if (syncLogConflictLabel(this.record).length > 0) {
        Text(syncLogConflictLabel(this.record)).fontSize(11).fontColor('#F5F5F5')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(10)
          .backgroundColor(this.record.pendingConflicts > 0 ? '#7F3548' : '#315C4B').flexShrink(0)
      }
      Text(syncLogTimeLabel(this.record.started_at, true)).fontSize(11).fontColor(UiColor.secondary)
        .width(68).maxLines(1).textAlign(TextAlign.End).flexShrink(0)
    }.width('100%').height(48).padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center).accessibilityGroup(true)
      .accessibilityText(`${syncLogResultLabel(this.record)}，${syncLogTitle(this.record)}，${syncLogConflictLabel(this.record)}，${syncLogTimeLabel(this.record.started_at)}，点击查看同步详情`)
      .onClick((): void => { this.open() })
  }
}
