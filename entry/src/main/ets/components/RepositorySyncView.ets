import { uiObserver } from '@kit.ArkUI'
import { RepositorySyncBanner } from './RepositorySyncBanner'
import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'

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
      // 页面事件先于路由状态切换完成时，getRouter().getState() 仍可能指向刚离开的页面。
      // 这里直接按页面事件处理版本，避免错过冲突解决后对文件列表的失效通知。
      this.presentSyncFailure()
      if (this.syncRevision !== this.syncState.revision) {
        this.syncRevision = this.syncState.revision
        this.onDataInvalidated()
      }
    }
  }

  aboutToAppear() {
    this.syncRevision = this.syncState.revision
    this.pageIndex = this.getUIContext().getRouter().getState().index
    this.pageVisible = true
    this.getUIContext().getUIObserver().on('routerPageUpdate', this.pageChanged)
    this.presentSyncFailure()
  }

  aboutToDisappear() {
    this.pageVisible = false
    this.getUIContext().getUIObserver().off('routerPageUpdate', this.pageChanged)
  }

  repositorySyncChanged() {
    if (!this.pageVisible || this.getUIContext().getRouter().getState().index !== this.pageIndex) return
    this.presentSyncFailure()
    if (this.syncRevision === this.syncState.revision) return
    this.syncRevision = this.syncState.revision
    // 同步部分失败也可能已修改本地文件，按数据版本而非成功状态刷新。
    this.onDataInvalidated()
  }

  presentSyncFailure() {
    if (!this.pageVisible || this.getUIContext().getRouter().getState().index !== this.pageIndex) return
    const failure = RepositorySyncService.takeFailure()
    if (!failure) return
    const message = failure.needsRepository ? '尚未配置可同步的存储库。' : failure.message
    try {
      this.getUIContext().getPromptAction().showToast({ message })
    } catch (_) {
      console.error('显示同步失败提示失败')
    }
  }

  syncFromPull() {
    // 松手后内容复位；持续进度由标题下的共享进度线展示。
    this.refreshing = false
    if (!this.pullEnabled || this.disabled || !this.pageVisible || this.syncState.running || this.getUIContext().getRouter().getState().index !== this.pageIndex) return
    RepositorySyncService.start(this.getUIContext().getHostContext()!)
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
