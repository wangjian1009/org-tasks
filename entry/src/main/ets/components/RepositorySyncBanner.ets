import { router } from '@kit.ArkUI'
import { CoreConflict } from '../services/NativeCoreService'
import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { UiColor } from '../ui/Theme'

@Component
export struct RepositorySyncBanner {
  @StorageLink('repositorySync') state: RepositorySyncState = emptyRepositorySyncState()

  openConflicts() {
    this.getUIContext().showActionSheet({ title: '同步冲突', message: '选择需要处理的同步作业',
      sheets: this.state.conflicts.map((conflict: CoreConflict): SheetInfo => ({
        title: `${conflict.paths.length} 个文件：${conflict.paths.join('、')}`,
        action: (): void => {
          router.pushUrl({ url: 'pages/MergeConflict', params: { repoId: conflict.repoId, syncId: conflict.syncId } })
        }
      })) })
  }

  build() {
    if (this.state.message) {
      Column() {
        if (this.state.running) {
          Progress({ value: this.state.determinate ? this.state.progress : 50, total: 100, type: ProgressType.Linear })
            .width('100%').color(UiColor.primary).backgroundColor(UiColor.outline)
            .style({ strokeWidth: 3, enableScanEffect: !this.state.determinate, enableSmoothEffect: true })
            .accessibilityText(this.state.determinate ? `同步进度 ${this.state.progress}%` : '正在同步')
        }
        Row({ space: 8 }) {
          Text(this.state.message).fontSize(12).fontColor(this.state.error ? UiColor.error : UiColor.secondary)
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.state.running && this.state.determinate) {
            Text(`${this.state.progress}%`).fontSize(12).fontColor(UiColor.primary)
          } else if (!this.state.running) {
            if (this.state.conflicts.length > 0) {
              Button('处理冲突').fontSize(12).height(36).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
                .onClick((): void => { this.openConflicts() })
            } else if (this.state.needsRepository) {
              Button('添加存储库').fontSize(12).height(36).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
                .onClick((): void => { router.pushUrl({ url: 'pages/Repositories' }) })
            } else if (this.state.error) {
              Button('重试').fontSize(12).height(36).backgroundColor(Color.Transparent).fontColor(UiColor.primary)
                .onClick((): void => { RepositorySyncService.start(getContext(this)) })
            }
            if (this.state.conflicts.length === 0) {
              Button('×').fontSize(20).width(36).height(36).backgroundColor(Color.Transparent).fontColor(UiColor.secondary)
                .accessibilityText('关闭同步提示').onClick((): void => { RepositorySyncService.dismiss() })
            }
          }
        }.width('100%').constraintSize({ minHeight: 36 }).padding({ left: 16, right: 8, top: 2, bottom: 2 })
      }.width('100%').backgroundColor(UiColor.container)
    }
  }
}
