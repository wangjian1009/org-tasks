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
    const name = this.repository()?.name || '存储库'
    return `${name}的本地目录不存在`
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
        this.getUIContext().getPromptAction().showToast({ message: '无法打开存储库设置' })
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
      .accessibilityText(`${this.message()}，点击打开存储库设置`)
      .onClick((): void => { this.openSettings() })
  }
}
