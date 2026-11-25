import { localizedText } from '../ui/LocalizedText'
import { RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { UiColor } from '../ui/Theme'

@Component
export struct RepositorySyncBanner {
  @StorageLink('repositorySync') state: RepositorySyncState = emptyRepositorySyncState()

  build() {
    if (this.state.running) {
      Progress({ value: this.state.determinate ? this.state.progress : 50, total: 100, type: ProgressType.Linear })
        .width('100%').height(2).color(UiColor.primary).backgroundColor(UiColor.field)
        .style({ strokeWidth: 2, enableScanEffect: !this.state.determinate, enableSmoothEffect: true })
        .accessibilityText(this.state.determinate ? localizedText($r('app.string.text_sync_progress'), `${this.state.progress}%`) : localizedText($r('app.string.text_synchronising')))
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
    }
  }
}
