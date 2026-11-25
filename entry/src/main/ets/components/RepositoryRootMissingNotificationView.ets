import { localizedText } from '../ui/LocalizedText'
import { CoreRepositoryRootMissingNotification } from '../services/NativeCoreService'
import { NotificationRepository } from '../services/NotificationManager'
import { PageNavigator } from '../services/PageNavigator'
import { UiColor } from '../ui/Theme'

@Component
export struct RepositoryRootMissingNotificationView {
  @Prop notification: CoreRepositoryRootMissingNotification
  @Prop repositories: NotificationRepository[] = []
  @Prop disabled: boolean = false
  @State opening: boolean = false

  private repository(): NotificationRepository | undefined {
    return this.repositories.find(repo => repo.rootDirectory === this.notification.rootDirectory)
  }

  private message(): string {
    const name = this.repository()?.name || localizedText($r('app.string.text_repositories'))
    return localizedText($r('app.string.text_local_directories_for_do_not_exist'), String(name))
  }

  private async openSettings(): Promise<void> {
    const repository = this.repository()
    if (!repository || this.opening) return
    this.opening = true
    try {
      await PageNavigator.shared.pushPage(this.getUIContext(), {
        url: 'pages/RepositorySettings', params: { repoId: repository.configRepoId }
      })
    } catch (_) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_cannot_open_repository_settings')) })
      } catch (_) {
        console.error('显示存储库设置打开失败提示失败')
      }
    } finally {
      this.opening = false
    }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        Image($r('app.media.ui_notification_conflict')).width(16).height(16).flexShrink(0)
        Row({ space: 4 }) {
          Text(this.message()).fontSize(13).fontColor(UiColor.secondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          Image($r('app.media.ui_goto')).width(16).height(16).flexShrink(0)
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
      }.width('100%').height(32).padding({ left: 18, right: 12 }).alignItems(VerticalAlign.Center)
    }.width('100%').height(32).padding(0).backgroundColor(Color.Transparent).borderRadius(0)
      .enabled(!this.disabled && !this.opening && this.repository() !== undefined)
      .accessibilityText(localizedText($r('app.string.text_tap_to_open_repository_settings'), String(this.message())))
      .onClick((): void => { this.openSettings() })
  }
}
