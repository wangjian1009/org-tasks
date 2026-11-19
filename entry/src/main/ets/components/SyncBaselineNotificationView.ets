import { CoreSyncBaselineUnavailableNotification } from '../services/NativeCoreService'
import { NotificationRepository } from '../services/NotificationManager'
import { UiColor } from '../ui/Theme'

@Component
export struct SyncBaselineNotificationView {
  @Prop notification: CoreSyncBaselineUnavailableNotification
  @Prop repositories: NotificationRepository[] = []

  message(): string {
    const name = this.repositories.find(item => item.coreRepoId === this.notification.repoId)?.name || '存储库'
    return `${name}同步基线异常，暂时无法同步`
  }

  build() {
    Row({ space: 6 }) {
      Image($r('app.media.ui_notification_conflict')).width(16).height(16).flexShrink(0)
      Text(this.message()).fontSize(13).fontColor(UiColor.secondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }.width('100%').height(32).padding({ left: 18, right: 12 }).alignItems(VerticalAlign.Center)
      .accessibilityText(this.message())
  }
}
