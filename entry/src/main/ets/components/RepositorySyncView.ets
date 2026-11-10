import { uiObserver } from '@kit.ArkUI'
import { RepositorySyncBanner } from './RepositorySyncBanner'
import { RepositorySyncService, RepositorySyncState, emptyRepositorySyncState } from '../services/RepositorySyncService'

// 统一同步手势、进度与错误；正文刷新由通知模块驱动。
@Component
export struct RepositorySyncView {
  @Prop pullEnabled: boolean = false
  @Prop disabled: boolean = false
  beforePull: () => Promise<boolean> = async (): Promise<boolean> => true
  @BuilderParam content: () => void
  @StorageLink('repositorySync') @Watch('repositorySyncChanged') syncState: RepositorySyncState = emptyRepositorySyncState()
  @State refreshing: boolean = false
  private pageIndex: number = 0
  private pageVisible: boolean = true
  private preparingPull: boolean = false
  private pageChanged = (info: uiObserver.RouterPageInfo): void => {
    if (info.index !== this.pageIndex) return
    if (info.state === uiObserver.RouterPageState.ON_PAGE_HIDE) {
      this.pageVisible = false
    } else if (info.state === uiObserver.RouterPageState.ON_PAGE_SHOW) {
      this.pageVisible = true
      this.presentSyncFailure()
    }
  }

  aboutToAppear() {
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

  private canPull(): boolean {
    return this.pullEnabled && !this.disabled && this.pageVisible && !this.syncState.running &&
      this.getUIContext().getRouter().getState().index === this.pageIndex
  }

  async syncFromPull() {
    // 松手后内容复位；持续进度由标题下的共享进度线展示。
    this.refreshing = false
    if (this.preparingPull || !this.canPull()) return
    this.preparingPull = true
    try {
      if (!await this.beforePull() || !this.canPull()) return
      await RepositorySyncService.start(this.getUIContext().getHostContext()!)
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '保存任务失败，请重试。' })
    } finally {
      this.preparingPull = false
    }
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
