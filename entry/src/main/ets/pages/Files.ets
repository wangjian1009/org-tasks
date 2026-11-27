import { localizedText } from '../ui/LocalizedText'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { TrashDataManager } from '../services/TrashDataManager'
import { PageNavigator } from '../services/PageNavigator'
import { addRepository } from '../services/RepositoryNavigation'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { CoreNotificationsView } from '../components/CoreNotificationsView'
import { NotificationManager } from '../services/NotificationManager'
import { NotebookFileRow } from '../components/NotebookFileRow'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
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
import { OrgFileRepositoryOption, orgFileName } from '../ui/OrgFileCreatePresentation'
import { UiColor } from '../ui/Theme'
import { filePathLabel, fileUsageKinds } from '../ui/NotebookPresentation'
import { ONBOARDING_FILE, SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'

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
  @State expandedFileKey: string = ''
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
  @State renameOpen: boolean = false
  @State renameBusy: boolean = false
  @State renameName: string = ''
  @State renameMessage: string = ''
  @State renamedPath: string = ''
  private renameSource: CoreOrgFileMetadata | undefined = undefined
  private renameRepoId: string = ''
  private originalRenameName: string = ''
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
    this.closeRename()
    this.closeCreate()
    this.stopNotifications?.()
    this.stopNotifications = undefined
    this.stopData?.(); this.dataManager?.close()
  }

  onBackPress(): boolean {
    if (this.deletePending) return true
    if (this.renameOpen) { this.closeRename(); return true }
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
      !this.canChangeFile(repository.id, file)) return
    const pagePath = PageNavigator.shared.path
    const allowed = (): boolean => this.active && PageNavigator.shared.path === pagePath
    const remote = repository.webdavEnabled ? localizedText($r('app.string.text_subsequent_sync_may_delete_the_corresponding_file')) : ''
    this.deletePending = true
    try {
      showDangerousConfirmation(this.getUIContext(), {
        title: localizedText($r('app.string.text_delete_files')),
        message: localizedText($r('app.string.text_the_in_and_all_its_contents_will'), String(group.name), String(file.path), String(remote)),
        confirmLabel: localizedText($r('app.string.text_delete_file')),
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
    try { this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_failed_to_delete_file'), String(coreErrorMessage(error))) }) }
    catch (_) { /* 离开页面后不再显示提示。 */ }
  }

  private openRename(file: CoreOrgFileMetadata, group: NotebookGroup): void {
    if (!this.active || this.renameOpen || this.deletePending || !file.fileVersion ||
      !group.configId || group.configId === SYSTEM_REPOSITORY_ID) return
    this.renameSource = file
    this.renameRepoId = group.configId
    this.originalRenameName = filePathLabel(file.path.slice(file.path.lastIndexOf('/') + 1))
    this.renameName = this.originalRenameName
    this.renamedPath = ''
    this.renameMessage = ''
    const ui = this.getUIContext()
    this.keyboardAvoidMode = ui.getKeyboardAvoidMode()
    ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    this.renameOpen = true
  }

  private closeRename(): void {
    if (this.renameBusy && this.active) return
    this.renameOpen = false
    this.renameSource = undefined
    if (this.keyboardAvoidMode !== undefined) {
      this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode)
      this.keyboardAvoidMode = undefined
    }
  }

  private async submitRename(): Promise<void> {
    const file = this.renameSource
    const manager = this.dataManager
    if (!this.renameOpen || this.renameBusy || !file || !manager) return
    const name = this.renameName.trim()
    if (!this.renamedPath) {
      if (!name || name === '.' || name === '..' || /[\/\\\x00-\x1f\x7f]/.test(name) || orgFileName(name) === '.org') {
        this.renameMessage = localizedText($r('app.string.text_please_enter_a_valid_filename_which_does'))
        return
      }
      if (orgFileName(name) === this.originalRenameName) { this.closeRename(); return }
    }
    const pagePath = PageNavigator.shared.path
    const allowed = (): boolean => this.active && PageNavigator.shared.path === pagePath
    const context = this.getUIContext().getHostContext()!
    const repoId = this.renameRepoId
    this.renameBusy = true
    this.renameMessage = ''
    try {
      if (!this.renamedPath) {
        const newName = orgFileName(name)
        await manager.renameFile(file, newName, allowed)
        this.renamedPath = file.path.slice(0, file.path.lastIndexOf('/') + 1) + newName
      }
      await AppConfigService.renameFileTargets(context, repoId, file.path, this.renamedPath)
    } catch (error) {
      this.renameMessage = (this.renamedPath ? localizedText($r('app.string.text_the_document_has_been_renamed_and_the')) : '') + coreErrorMessage(error as CoreBridgeError)
      return
    } finally {
      this.renameBusy = false
    }
    if (allowed()) this.closeRename()
  }

  @Builder
  renamePanel() {
    Column({ space: 16 }) {
      Row() {
        Text($r('app.string.text_change_file_name')).fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1)
        Button($r('app.string.text_cancel')).height(44).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .enabled(!this.renameBusy).onClick((): void => { this.closeRename() })
      }.width('100%')
      TextInput({ text: this.renameName, placeholder: localizedText($r('app.string.text_filename')) }).id('notebook_rename_name')
        .width('100%').height(48).fontSize(16).fontColor(UiColor.text).backgroundColor('#414542')
        .enabled(!this.renameBusy && !this.renamedPath).onChange((value: string): void => { this.renameName = value })
        .onSubmit((): void => { this.submitRename() })
      if (this.renameMessage) {
        Text(this.renameMessage).fontSize(14).fontColor(UiColor.error).width('100%')
      }
      Button(this.renameBusy ? localizedText($r('app.string.text_saving_3')) : this.renamedPath ? localizedText($r('app.string.text_try_again_to_update_the_portal')) : localizedText($r('app.string.text_save')))
        .id('notebook_rename_save').width('100%').height(48).backgroundColor(UiColor.primary)
        .fontColor(UiColor.onPrimary).enabled(!this.renameBusy).onClick((): void => { this.submitRename() })
    }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 24 })
  }

  private async openCreate(repoId: string): Promise<void> {
    if (!this.active || this.createOpen || this.createLoading) return
    this.createLoading = true
    try {
      const ui = this.getUIContext()
      const repositories = await OrgFileCreateService.repositories(ui.getHostContext()!)
      if (!this.active) return
      if (!repositories.some(repo => repo.repoId === repoId)) throw new Error(localizedText($r('app.string.text_target_repository_is_dead_please_re_select')))
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

  private fileKey(file: CoreOrgFileMetadata): string {
    return JSON.stringify([file.repoId, file.path])
  }

  private canChangeFile(configId: string, file: CoreOrgFileMetadata): boolean {
    return !!configId && !!file.fileVersion && (configId !== SYSTEM_REPOSITORY_ID || file.path === ONBOARDING_FILE)
  }

  private toggleFileDetails(file: CoreOrgFileMetadata): void {
    const key = this.fileKey(file)
    this.expandedFileKey = this.expandedFileKey === key ? '' : key
  }

  repositoryActions(group: NotebookGroup): PopupMenuItem[] {
    return [
      { title: localizedText($r('app.string.text_add_3')), icon: $r('app.media.ui_add_file'), disabled: this.createLoading || this.createOpen,
        action: (): void => { this.openCreate(group.repoId) } },
      { title: localizedText($r('app.string.text_settings')), icon: $r('app.media.ui_settings'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/RepositorySettings', params: { repoId: group.configId } })
      } },
      { title: localizedText($r('app.string.text_history')), icon: $r('app.media.ui_sync_log'), action: (): void => {
        PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/SyncLog', params: { repoId: group.configId } })
      } }
    ]
  }

  async loadFiles(reload: boolean = false) {
    if (!this.trashMaintenance) {
      const trash = new TrashDataManager(this.getUIContext().getHostContext()!)
      this.trashMaintenance = trash.start().catch((): void => {
        try { this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_waste_paper_expiry_cleanup_failed_to_open')) }) }
        catch (_) { console.error('显示废纸篓清理提示失败') }
      }).finally(async (): Promise<void> => { await trash.close() }).catch((): void => { console.error('关闭废纸篓清理数据集失败') })
    }
    if (!this.dataManager) {
      this.dataManager = new NotebookDataManager(this.getUIContext().getHostContext()!)
      this.stopData = this.dataManager.subscribe((state: SnapshotState<NotebookSnapshot>): void => {
        if (state.value) {
          const expandedFileKey = this.expandedFileKey
          if (expandedFileKey && !state.value.groups.some(group =>
            group.files.some(file => this.fileKey(file) === expandedFileKey))) {
            this.expandedFileKey = ''
          }
          this.config = state.value.config; this.groups = state.value.groups; this.loading = false
        }
        this.message = state.message ? localizedText($r('app.string.text_reading_notebook_failed'), String(state.message)) : ''
        if (state.message) this.loading = false
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  build() {
    Column() {
      AppShell({ title: localizedText($r('app.string.text_notebooks')), titleIcon: $r('app.media.nav_repository'),
        actionIcon: $r('app.media.ui_add'), actionLabel: localizedText($r('app.string.text_add_repository')),
        action: (): void => { addRepository(this.getUIContext()) },
        activeRoute: 'pages/Files', drawerOpen: $drawerOpen, pullToSync: true, busy: this.deletePending || this.renameOpen,
        pullDisabled: this.deletePending || this.renameOpen,
        beforePull: async (): Promise<void> => await this.loadFiles(true) }) {
        Column() {
          if (this.loading) {
            NotificationEmptyState({ title: localizedText($r('app.string.text_reading_notebooks')), busy: true })
          } else if (this.message) {
            NotificationEmptyState({ title: localizedText($r('app.string.text_notebook_reading_failed')), detail: this.message, actionLabel: localizedText($r('app.string.text_retry')), action: (): void => { this.loadFiles(true) } })
          } else if (this.groups.length === 0) {
            NotificationEmptyState({ title: localizedText($r('app.string.text_no_repository_yet')), actionLabel: localizedText($r('app.string.text_add_repository')), action: (): void => { addRepository(this.getUIContext()) } })
          } else {
            List({ scroller: this.listScroller }) {
              if (this.showNotifications) {
                ListItem() { CoreNotificationsView({ horizontalInset: 0 }) }
              }
              ForEach(this.groups, (group: NotebookGroup) => {
                ListItemGroup({ header: this.repositoryHeader(group) }) {
                  if (this.visibleFiles(group).length === 0) {
                    ListItem() {
                      Text(group.message || (group.files.length > 0 ? localizedText($r('app.string.text_not_seen_org_file')) : localizedText($r('app.string.text_no_org_file_available')))).fontSize(13)
                        .fontColor(group.message ? UiColor.error : UiColor.secondary)
                        .width('100%').padding({ left: 8, right: 8, top: 12, bottom: 16 })
                    }
                  }
                  ForEach(this.visibleFiles(group), (file: CoreOrgFileMetadata) => {
                    NotebookFileRow({ file, configRepoId: group.configId, usages: fileUsageKinds(this.config, group.configId, file.path),
                      expanded: this.expandedFileKey === this.fileKey(file),
                      toggleExpanded: (): void => { this.toggleFileDetails(file) },
                      actionsEnabled: this.canChangeFile(group.configId, file),
                      closeSwipe: (): void => { this.closeFileSwipe() },
                      rename: (): void => { this.openRename(file, group) },
                      remove: (): void => { this.confirmFileDeletion(file, group) } })
                  }, (file: CoreOrgFileMetadata) => JSON.stringify(file))
                }
              }, (group: NotebookGroup) => JSON.stringify(group))
            }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 16 }).enabled(!this.deletePending)
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
              .edgeEffect(EdgeEffect.None)
          }
        }.width('100%').height('100%').bindSheet($$this.renameOpen, this.renamePanel, {
          height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, backgroundColor: '#363A38', showClose: false,
          onWillDismiss: (): void => { this.closeRename() }
        })
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
          .accessibilityText(localizedText($r('app.string.text_repository_3'), String(group.name)))
        if (group.configId !== SYSTEM_REPOSITORY_ID) {
          IconButton({ icon: this.showIgnoredRepoIds.includes(group.repoId) ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
            iconSize: 20, buttonWidth: 40,
            label: `${group.name}：${this.showIgnoredRepoIds.includes(group.repoId) ? localizedText($r('app.string.text_hide_the_hidden_file_of_the_configuration')) : localizedText($r('app.string.text_show_the_hidden_files_of_the_configuration'))}`,
            action: (): void => { this.toggleIgnored(group) } })
          PopupMenuButton({ label: localizedText($r('app.string.text_more'), String(group.name)), disabled: group.configId.length === 0,
            iconSize: 20, buttonWidth: 40, items: this.repositoryActions(group) })
        }
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
  }
}
