import { localizedText } from '../ui/LocalizedText'
import { PageNavigator } from '../services/PageNavigator'
import { CoreSyncConflictNotification, coreErrorMessage, CoreBridgeError } from '../services/NativeCoreService'
import { NotificationRepository } from '../services/NotificationManager'
import { syncConflictRepositoryName } from '../ui/CoreNotificationPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct SyncConflictNotificationView {
  @Prop notification: CoreSyncConflictNotification
  @Prop repositories: NotificationRepository[] = []
  @Prop disabled: boolean = false
  @State opening: boolean = false

  name(): string { return syncConflictRepositoryName(this.notification, this.repositories) }

  async resolve() {
    if (this.disabled || this.opening) return
    this.opening = true
    try {
      const target = this.repositories.find(repo => repo.coreRepoId === this.notification.repoId)
      if (!target) throw new Error(localizedText($r('app.string.text_this_repository_does_not_exist_please_try')))
      await PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/ConflictFile',
        params: { repoId: target.configRepoId, coreRepoId: target.coreRepoId, path: this.notification.path } })
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_couldn_t_open_the_conflicting_file'), String(coreErrorMessage(e as CoreBridgeError))) })
      } catch (_) { console.error('显示冲突文件读取错误失败') }
    } finally {
      this.opening = false
    }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Image($r('app.media.ui_notification_conflict')).width(16).height(16).flexShrink(0)
        Row({ space: 4 }) {
          Text(localizedText($r('app.string.text_is_in_conflict'), String(this.name()), String(this.notification.path))).fontSize(13).fontColor(UiColor.secondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          Image($r('app.media.ui_goto')).width(16).height(16).flexShrink(0)
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
      }.width('100%').height(32).padding({ left: 18, right: 12 }).alignItems(VerticalAlign.Center)
    }.width('100%').height(32).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
      .enabled(!this.disabled && !this.opening)
      .accessibilityText(localizedText($r('app.string.text_conflict_tap_to_open_the_conflict_resolution'), String(this.name()), String(this.notification.path)))
      .onClick((): void => { this.resolve() })
  }
}
