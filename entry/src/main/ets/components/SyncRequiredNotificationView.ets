import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { UiColor } from '../ui/Theme'

// 通知由 Core 生成和去重；点击复用全仓库同步，成功确认后由 Core 清除。
@Component
export struct SyncRequiredNotificationView {
  @Prop disabled: boolean = false
  @State starting: boolean = false
  @StorageLink('repositorySync') syncState: RepositorySyncState = emptyRepositorySyncState()

  async synchronize() {
    if (this.disabled || this.starting || this.syncState.running) return
    this.starting = true
    try {
      await RepositorySyncService.start(this.getUIContext().getHostContext()!, 'manual')
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
      .enabled(!this.disabled && !this.starting && !this.syncState.running)
      .accessibilityText('本地有修改，点击同步所有存储库')
      .onClick((): void => { this.synchronize() })
  }
}
