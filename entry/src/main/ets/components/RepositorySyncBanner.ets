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
        .accessibilityText(this.state.determinate ? `同步进度 ${this.state.progress}%` : '正在同步')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
    }
  }
}
