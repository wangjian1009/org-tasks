import { KeyboardAvoidMode } from '@kit.ArkUI'
import { TrashDataManager } from '../services/TrashDataManager'
import { PageNavigator } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { NotebookFileRow } from '../components/NotebookFileRow'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppShell } from '../components/AppShell'
import { IconButton } from '../components/controls/IconButton'
import { PopupMenuButton } from '../components/controls/PopupMenuButton'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { OrgFileCreateSheet } from '../components/editors/OrgFileCreateSheet'
import { OrgFileCreateService } from '../services/OrgFileCreateService'
import { NotebookDataManager, NotebookSnapshot } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { NotebookGroup } from '../services/NotebookService'
import { CoreBridgeError, CoreOrgFileMetadata, CoreTaskOperationGroup, coreErrorMessage } from '../services/NativeCoreService'
import { OrgFileRepositoryOption } from '../ui/OrgFileCreatePresentation'
import { UiColor } from '../ui/Theme'
import { fileUsageKinds } from '../ui/NotebookPresentation'
import { SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'

@Entry
@Component
struct Files {
  @State showNotifications: boolean = false
  private stopNotifications: (() => void) | undefined = undefined
  @State groups: NotebookGroup[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State showIgnoredRepoIds: string[] = []
  @State config: AppConfig = DEFAULT_CONFIG
  @State createOpen: boolean = false
  @State createLoading: boolean = false
  @State createGenerating: boolean = false
  @State createSubmitting: boolean = false
  @State createTyping: boolean = false
  @State createMessage: string = ''
  @State createRepositories: OrgFileRepositoryOption[] = []
  @State createRepoId: string = ''
  @State deletePending: boolean = false
  private listScroller: ListScroller = new ListScroller()
  private keyboardAvoidMode: KeyboardAvoidMode | undefined = undefined
  private active: boolean = false
  private trashMaintenance: Promise<void> | undefined = undefined
  private dataManager: NotebookDataManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  aboutToAppear(): void {
    this.active = true
    this.stopNotifications = NotificationManager.watchVisibility(visible => { this.showNotifications = visible })
  }

  onPageShow(): void { this.loadFiles() }
  aboutToDisappear(): void {
    this.active = false
    this.closeCreate()
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopData?.(); this.dataManager?.close()
  }

  onBackPress(): boolean {
    if (this.deletePending) return true
    if (this.createOpen) { this.dismissCreate(); return true }
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext())
    return true
  }

  private closeFileSwipe(): void {
    try { this.listScroller.closeAllSwipeActions() } catch (_) { /* 列表退出时不再需要收起按钮。 */ }
  }

  private confirmFileDeletion(file: CoreOrgFileMetadata, group: NotebookGroup): void {
    const manager = this.dataManager
    const repository = this.config.repos.find(repo => repo.id === group.configId)
    if (!this.active || this.deletePending || !manager || !repository ||
      repository.id === SYSTEM_REPOSITORY_ID || !file.fileVersion) return
    const pagePath = PageNavigator.shared.path
    const allowed = (): boolean => this.active && PageNavigator.shared.path === pagePath
    const remote = repository.webdavEnabled ? '后续同步可能删除 WebDAV 上的对应文件。' : ''
    this.deletePending = true
    try {
      showDangerousConfirmation(this.getUIContext(), {
        title: '删除文件？',
        message: `将删除“${group.name}”中的“${file.path}”及其全部内容。整份文件无法通过废纸篓恢复。${remote}`,
        confirmLabel: '删除文件',
        onCancel: (): void => { this.deletePending = false },
        onConfirm: (): void => {
          if (!allowed()) { this.deletePending = false; return }
          manager.deleteFile(file, allowed)
            .catch((error: CoreBridgeError): void => {
              if (allowed()) this.reportFileDeletionError(error)
            })
            .finally((): void => { this.deletePending = false })
        }
      })
    } catch (error) {
      this.deletePending = false
      if (allowed()) this.reportFileDeletionError(error as CoreBridgeError)
    }
  }

  private reportFileDeletionError(error: CoreBridgeError): void {
    try { this.getUIContext().getPromptAction().showToast({ message: `删除文件失败：${coreErrorMessage(error)}` }) }
    catch (_) { /* 离开页面后不再显示提示。 */ }
  }

  private async openCreate(repoId: string): Promise<void> {
    if (!this.active || this.createOpen || this.createLoading) return
    this.createLoading = true
    try {
      const ui = this.getUIContext()
      const repositories = await OrgFileCreateService.repositories(ui.getHostContext()!)
      if (!this.active) return
      if (!repositories.some(repo => repo.repoId === repoId)) throw new Error('目标存储库已失效，请重新选择')
      this.createRepoId = repoId
      this.createRepositories = repositories
      this.createMessage = ''
      this.keyboardAvoidMode = ui.getKeyboardAvoidMode()
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
      this.createOpen = true
    } catch (error) {
      if (this.active) {
        try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(error as CoreBridgeError) }) }
        catch (_) { /* 页面退出时提示可能不可用。 */ }
      }
    } finally { this.createLoading = false }
  }

  private dismissCreate(): void {
    if (this.createGenerating || this.createSubmitting) return
    if (this.createTyping) {
      this.getUIContext().getFocusController().clearFocus()
      this.createTyping = false
      return
    }
    this.closeCreate()
  }

  private closeCreate(): void {
    this.createOpen = false
    this.createTyping = false
    if (this.keyboardAvoidMode !== undefined) {
      this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
      this.keyboardAvoidMode = undefined
    }
  }

  private async submitCreate(group: CoreTaskOperationGroup): Promise<void> {
    if (!this.createOpen || this.createSubmitting || !this.dataManager) return
    this.createSubmitting = true
    this.createMessage = ''
    try {
      await this.dataManager.createFile(group)
      if (this.active) this.closeCreate()
    } catch (error) {
      if (this.active) this.createMessage = coreErrorMessage(error as CoreBridgeError)
    } finally { this.createSubmitting = false }
  }

  @Builder
  createPanel() {
    OrgFileCreateSheet({ repositories: this.createRepositories, initialRepoId: this.createRepoId, repositoryHidden: true,
      busy: this.createSubmitting, generating: $createGenerating, message: this.createMessage,
      typingChanged: (typing: boolean): void => { this.createTyping = typing },
      cancel: (): void => { this.closeCreate() },
      generated: (group: CoreTaskOperationGroup): void => { this.submitCreate(group) } })
  }

  toggleIgnored(group: NotebookGroup) {
    this.showIgnoredRepoIds = this.showIgnoredRepoIds.includes(group.repoId)
      ? this.showIgnoredRepoIds.filter((id: string) => id !== group.repoId)
      : this.showIgnoredRepoIds.concat(group.repoId)
  }

  visibleFiles(group: NotebookGroup): CoreOrgFileMetadata[] {
    return this.showIgnoredRepoIds.includes(group.repoId) ? group.files : group.files.filter((file: CoreOrgFileMetadata) => !file.isIgnore)
  }

  repositoryActions(group: NotebookGroup): PopupMenuItem[] {
    return [
      { title: '新增文件', icon: $r('app.media.ui_add'), disabled: this.createLoading || this.createOpen,
        action: (): void => { this.openCreate(group.repoId) } },
      { title: '设置', icon: $r('app.media.ui_settings'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/RepositorySettings', params: { repoId: group.configId } })
      } },
      { title: '历史', icon: $r('app.media.ui_sync_log'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/SyncLog', params: { repoId: group.configId } })
      } }
    ]
  }

  async loadFiles(reload: boolean = false) {
    if (!this.trashMaintenance) {
      const trash = new TrashDataManager(this.getUIContext().getHostContext()!)
      this.trashMaintenance = trash.start().catch((): void => {
        try { this.getUIContext().getPromptAction().showToast({ message: '废纸篓过期清理失败，可打开废纸篓重试' }) }
        catch (_) { console.error('显示废纸篓清理提示失败') }
      }).finally(async (): Promise<void> => { await trash.close() }).catch((): void => { console.error('关闭废纸篓清理数据集失败') })
    }
    if (!this.dataManager) {
      this.dataManager = new NotebookDataManager(this.getUIContext().getHostContext()!)
      this.stopData = this.dataManager.subscribe((state: SnapshotState<NotebookSnapshot>): void => {
        if (state.value) { this.config = state.value.config; this.groups = state.value.groups; this.loading = false }
        this.message = state.message ? `读取笔记本失败：${state.message}` : ''
        if (state.message) this.loading = false
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  build() {
    Column() {
      AppShell({ title: '笔记本', titleIcon: $r('app.media.nav_repository'),
        actionIcon: $r('app.media.ui_add'), actionLabel: '添加存储库',
        action: (): void => { addRepository(this.getUIContext()) },
        activeRoute: 'pages/Files', drawerOpen: $drawerOpen, pullToSync: true, busy: this.deletePending,
        pullDisabled: this.deletePending,
        beforePull: async (): Promise<void> => await this.loadFiles(true) }) {
        Column() {
          if (this.loading) {
            NotificationEmptyState({ title: '正在读取笔记本', busy: true })
          } else if (this.message) {
            NotificationEmptyState({ title: '笔记本读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadFiles(true) } })
          } else if (this.groups.length === 0) {
            NotificationEmptyState({ title: '还没有存储库', actionLabel: '添加存储库', action: (): void => { addRepository(this.getUIContext()) } })
          } else {
            List({ scroller: this.listScroller }) {
              if (this.showNotifications) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
              ForEach(this.groups, (group: NotebookGroup) => {
                ListItemGroup({ header: this.repositoryHeader(group) }) {
                  if (this.visibleFiles(group).length === 0) {
                    ListItem() {
                      Text(group.message || (group.files.length > 0 ? '暂无可见 Org 文件' : '暂无 Org 文件')).fontSize(13)
                        .fontColor(group.message ? UiColor.error : UiColor.secondary)
                        .width('100%').padding({ left: 8, right: 8, top: 12, bottom: 16 })
                    }
                  }
                  ForEach(this.visibleFiles(group), (file: CoreOrgFileMetadata) => {
                    NotebookFileRow({ file, configRepoId: group.configId, usages: fileUsageKinds(this.config, group.configId, file.path),
                      actionsEnabled: !!group.configId && group.configId !== SYSTEM_REPOSITORY_ID && !!file.fileVersion,
                      closeSwipe: (): void => { this.closeFileSwipe() },
                      remove: (): void => { this.confirmFileDeletion(file, group) } })
                  }, (file: CoreOrgFileMetadata) => JSON.stringify(file))
                }
              }, (group: NotebookGroup) => JSON.stringify(group))
            }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 }).enabled(!this.deletePending)
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%').bindSheet($$this.createOpen, this.createPanel, {
      height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, backgroundColor: '#363A38', showClose: false,
      onWillDismiss: (): void => { this.dismissCreate() },
      onDisappear: (): void => { this.closeCreate() }
    })
  }

  @Builder
  repositoryHeader(group: NotebookGroup) {
    Column({ space: 10 }) {
      Row() {
        Row({ space: 10 }) {
          Image($r('app.media.ui_category')).width(22).height(22)
          Text(group.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).height(48)
          .accessibilityText(`存储库 ${group.name}`)
        if (group.configId !== SYSTEM_REPOSITORY_ID) {
          IconButton({ icon: this.showIgnoredRepoIds.includes(group.repoId) ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
            iconSize: 20, buttonWidth: 40,
            label: `${group.name}：${this.showIgnoredRepoIds.includes(group.repoId) ? '隐藏配置的隐藏文件' : '显示配置的隐藏文件'}`,
            action: (): void => { this.toggleIgnored(group) } })
          PopupMenuButton({ label: `${group.name}：更多`, disabled: group.configId.length === 0,
            iconSize: 20, buttonWidth: 40, items: this.repositoryActions(group) })
        }
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
  }
}
