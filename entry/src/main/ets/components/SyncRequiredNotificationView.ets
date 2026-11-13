import { RepositorySyncService, SyncStartPolicy } from '../services/RepositorySyncService'
import { UiColor } from '../ui/Theme'

// 通知由 Core 生成和去重；点击提交全仓库同步请求，完成后由 Core 确认。
@Component
export struct SyncRequiredNotificationView {
  @Prop disabled: boolean = false
  @State starting: boolean = false

  synchronize() {
    if (this.disabled || this.starting) return
    this.starting = true
    try {
      RepositorySyncService.start(this.getUIContext().getHostContext()!, { triggerReason: 'manual', policy: SyncStartPolicy.Wait })
    } finally { this.starting = false }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Image($r('app.media.ui_sync_upload')).width(16).height(16).flexShrink(0)
        Row({ space: 4 }) {
          Text('本地有修改，点击同步').fontSize(13).fontColor(UiColor.text)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          Image($r('app.media.ui_goto')).width(16).height(16).flexShrink(0)
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
      }.width('100%').height(32).padding({ left: 18, right: 12 }).alignItems(VerticalAlign.Center)
    }.width('100%').height(32).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
      .enabled(!this.disabled && !this.starting)
      .accessibilityText('本地有修改，点击同步所有存储库')
      .onClick((): void => { this.synchronize() })
  }
}
