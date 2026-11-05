import { router, uiObserver } from '@kit.ArkUI'
import { RepositorySyncBanner } from './RepositorySyncBanner'
import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { CoreConflict } from '../services/NativeCoreService'

// 统一文件同步交互；页面通过内容插槽和失效通知接入自己的查询。
@Component
export struct RepositorySyncView {
  @Prop pullEnabled: boolean = false
  @Prop disabled: boolean = false
  @BuilderParam content: () => void
  onDataInvalidated: () => void = () => {}
  @StorageLink('repositorySync') @Watch('repositorySyncChanged') syncState: RepositorySyncState = emptyRepositorySyncState()
  @State refreshing: boolean = false
  private syncRevision: number = 0
  private pageIndex: number = 0
  private pageVisible: boolean = true
  private pageChanged = (info: uiObserver.RouterPageInfo): void => {
    if (info.index !== this.pageIndex) return
    if (info.state === uiObserver.RouterPageState.ON_PAGE_HIDE) {
      this.pageVisible = false
    } else if (info.state === uiObserver.RouterPageState.ON_PAGE_SHOW) {
      this.pageVisible = true
      this.repositorySyncChanged()
    }
  }

  aboutToAppear() {
    this.syncRevision = this.syncState.revision
    this.pageIndex = router.getState().index
    this.pageVisible = true
    this.getUIContext().getUIObserver().on('routerPageUpdate', this.pageChanged)
    this.presentSyncFailure()
  }

  aboutToDisappear() {
    this.pageVisible = false
    this.getUIContext().getUIObserver().off('routerPageUpdate', this.pageChanged)
  }

  repositorySyncChanged() {
    if (!this.pageVisible || router.getState().index !== this.pageIndex) return
    this.presentSyncFailure()
    if (this.syncRevision === this.syncState.revision) return
    this.syncRevision = this.syncState.revision
    // 同步部分失败也可能已修改本地文件，按数据版本而非成功状态刷新。
    this.onDataInvalidated()
  }

  presentSyncFailure() {
    if (!this.pageVisible || router.getState().index !== this.pageIndex) return
    const failure = RepositorySyncService.takeFailure()
    if (!failure) return
    this.getUIContext().showAlertDialog({ title: '同步失败', message: failure.needsRepository ? '尚未配置可同步的存储库。' : failure.message,
      primaryButton: { value: '关闭', action: () => {} },
      secondaryButton: failure.needsRepository ? undefined : {
        value: failure.conflicts.length > 0 ? '处理冲突' : '重试',
        action: (): void => {
          if (failure.conflicts.length > 0) {
            this.getUIContext().showActionSheet({ title: '同步冲突', message: '选择需要处理的同步作业',
              sheets: failure.conflicts.map((conflict: CoreConflict): SheetInfo => ({
                title: `${conflict.paths.length} 个文件：${conflict.paths.join('、')}`,
                action: (): void => { router.pushUrl({ url: 'pages/MergeConflict', params: { repoId: conflict.repoId, syncId: conflict.syncId } }) }
              })) })
          } else {
            RepositorySyncService.start(getContext(this))
          }
        }
      } })
  }

  syncFromPull() {
    // 松手后内容复位；持续进度由标题下的共享进度线展示。
    this.refreshing = false
    if (!this.pullEnabled || this.disabled || !this.pageVisible || this.syncState.running || router.getState().index !== this.pageIndex) return
    RepositorySyncService.start(getContext(this))
  }

  @Builder
  pullIndicator() {
    Row().width('100%').height(0)
  }

  build() {
    Column() {
      RepositorySyncBanner()
      Column() {
        if (this.pullEnabled) {
          Refresh({ refreshing: $$this.refreshing, builder: this.pullIndicator }) {
            this.content()
          }.width('100%').height('100%').refreshOffset(64).pullDownRatio(0.4)
            .pullToRefresh(!this.disabled && !this.syncState.running)
            .onRefreshing((): void => { this.syncFromPull() })
        } else {
          this.content()
        }
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }
}
