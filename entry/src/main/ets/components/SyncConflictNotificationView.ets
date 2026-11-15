import { PageNavigator } from '../services/PageNavigator'
import { CoreSyncConflictNotification, coreErrorMessage, CoreBridgeError } from '../services/NativeCoreService'
import { NotificationManager, NotificationRepository } from '../services/NotificationManager'
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
      const target = await NotificationManager.syncConflictTarget(this.getUIContext().getHostContext()!, this.notification)
      await PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/ConflictFile', params: { repoId: target.repoId, path: target.path } })
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: `无法打开冲突文件：${coreErrorMessage(e as CoreBridgeError)}` })
      } catch (_) { console.error('显示冲突文件读取错误失败') }
      try { await NotificationManager.refresh() } catch (_) {}
    } finally {
      this.opening = false
    }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Image($r('app.media.ui_notification_conflict')).width(16).height(16).flexShrink(0)
        Row({ space: 4 }) {
          Text(`${this.name()} · ${this.notification.path} 有冲突`).fontSize(13).fontColor(UiColor.secondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          Image($r('app.media.ui_goto')).width(16).height(16).flexShrink(0)
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
      }.width('100%').height(32).padding({ left: 18, right: 12 }).alignItems(VerticalAlign.Center)
    }.width('100%').height(32).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
      .enabled(!this.disabled && !this.opening)
      .accessibilityText(`${this.name()}，${this.notification.path} 有冲突，点击打开冲突解决界面`)
      .onClick((): void => { this.resolve() })
  }
}
