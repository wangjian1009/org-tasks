import { localizedText } from '../ui/LocalizedText'
import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { PageNavigator } from '../services/PageNavigator'
import { PageParameters, RepositoryCreationMode } from '../services/PagePath'
import { PageQueryService } from '../services/PageQueryService'
import { defaultSyncOptions, SyncOptions as NativeSyncOptions } from 'liborg_tasks_harmony.so'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { RepositorySetupService } from '../services/RepositorySetupService'
import { RepositorySyncService, SyncStartPolicy } from '../services/RepositorySyncService'
import { CoreBridgeError, coreErrorMessage, CoreWebDavSyncPolicy, NativeCoreService, RepositorySyncSource } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/controls/MessageBar'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { SettingsChoiceRow } from '../components/controls/SettingsChoiceRow'
import { PopupMenuItem } from '../components/controls/PopupMenu'
import { SettingsField } from '../components/controls/SettingsField'
import { LocalDirectorySheet } from '../components/editors/LocalDirectorySheet'
import { repositoryLabel, repositoryName, UiColor } from '../ui/Theme'
import { SYSTEM_REPOSITORY_ID } from '../models/SystemRepository'

@Entry
@Component
struct RepositorySettings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State repoId: string = ''
  @State name: string = ''
  @State rootDirectory: string = ''
  @State webdavEnabled: boolean = false
  @State webdavUrl: string = ''
  @State webdavUsername: string = ''
  @State webdavPassword: string = ''
  @State excludedDirectoriesText: string = ''
  @State saving: boolean = false
  @State deleting: boolean = false
  @State resetting: boolean = false
  @State retryInitialization: boolean = false
  @State syncRetry: RepositorySyncSource | '' = ''
  @State existing: boolean = false
  @State creationMode: RepositoryCreationMode | undefined = undefined
  @State testing: boolean = false
  @State testMessage: string = ''
  @State testSucceeded: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State directoryOpen: boolean = false
  @State directoryBusy: boolean = false
  @State cleanupPending: boolean = false
  @State originalDraft: string = ''
  private loaded: boolean = false

  private stopExternalGuard: (() => void) | undefined = undefined
  onPageShow(): void {
    this.stopExternalGuard?.()
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean =>
      this.loaded && !this.loading && !this.saving && !this.testing && !this.deleting && !this.resetting &&
      !this.directoryOpen && !this.directoryBusy && !this.hasChanges())
  }
  onPageHide(): void { this.stopExternalGuard?.(); this.stopExternalGuard = undefined }
  aboutToDisappear(): void { this.stopExternalGuard?.() }
  aboutToAppear() { this.load() }
  onBackPress(): boolean {
    if (this.directoryOpen) { if (!this.directoryBusy) this.directoryOpen = false; return true }
    if (!this.loading && !this.saving && !this.testing && !this.deleting && !this.resetting) {
      PageNavigator.shared.back(this.getUIContext())
    }
    return true
  }

  hasChanges(): boolean {
    return JSON.stringify(this.draft()) !== this.originalDraft
  }

  draft(): RepoConfig {
    return { id: this.repoId, name: this.name.trim(), rootDirectory: this.rootDirectory.trim(),
      webdavEnabled: this.webdavEnabled, webdavUrl: this.webdavUrl.trim(),
      webdavUsername: this.webdavUsername.trim(), webdavPassword: this.webdavPassword,
      webdavCleanupPending: this.cleanupPending || undefined,
      excludedDirectories: this.excludedDirectoriesText.split(',').map((value: string) => value.trim())
        .filter((value: string) => value.length > 0) }
  }

  cannotSave(message: string) {
    this.message = message
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_unable_to_save_changes')), message,
      cancelLabel: localizedText($r('app.string.text_continue_editing')),
      confirmLabel: localizedText($r('app.string.text_discard_changes_and_return')), onConfirm: (): void => { PageNavigator.shared.back(this.getUIContext()) } })
  }

  clearTestResult() {
    this.testMessage = ''
    this.testSucceeded = false
  }

  changeSyncMethod(enabled: boolean): void {
    if (!this.loaded || this.loading || this.saving || this.testing || this.deleting || this.resetting || this.webdavEnabled === enabled) return
    if (this.cleanupPending) {
      this.message = localizedText($r('app.string.text_please_complete_the_sync_message_first'))
      return
    }
    this.webdavEnabled = enabled
    this.clearTestResult()
  }

  syncMethodChoices(): PopupMenuItem[] {
    return [
      { title: localizedText($r('app.string.text_do_not_sync')), checked: !this.webdavEnabled, action: (): void => { this.changeSyncMethod(false) } },
      { title: 'WebDAV', checked: this.webdavEnabled, action: (): void => { this.changeSyncMethod(true) } }
    ]
  }

  async testConnection() {
    if (!this.webdavEnabled || this.testing || this.saving || this.loading) return
    this.clearTestResult()
    if (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword) {
      this.testMessage = localizedText($r('app.string.text_please_fill_in_https_webdav_address_username'))
      return
    }
    this.testing = true
    this.message = ''
    this.testMessage = localizedText($r('app.string.text_testing_connection'))
    try {
      const policy = new CoreWebDavSyncPolicy(this.webdavUrl.trim(), this.webdavUsername.trim(), this.webdavPassword)
      await policy.testConnection()
      this.testSucceeded = true
      this.testMessage = localizedText($r('app.string.text_you_can_access_the_directory'))
    } catch (e) {
      this.testMessage = localizedText($r('app.string.text_connection_test_failed'), String(coreErrorMessage(e as CoreBridgeError)))
    } finally {
      this.testing = false
    }
  }

  async load() {
    try {
      this.config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const params = this.getUIContext().getRouter().getParams() as PageParameters | undefined
      if (params?.repoId === SYSTEM_REPOSITORY_ID) throw new Error(localizedText($r('app.string.text_the_system_repository_is_managed_by_application')))
      const existing = this.config.repos.find((item: RepoConfig) => item.id === params?.repoId)
      if (params?.repoId && !existing) throw new Error(localizedText($r('app.string.text_this_repository_does_not_exist_please_return')))
      this.existing = existing !== undefined
      this.creationMode = existing ? undefined : params?.repositoryCreation
      const repo = existing || AppConfigService.newRepository()
      this.repoId = repo.id
      this.name = repo.name
      this.rootDirectory = repo.rootDirectory || this.managedDirectory()
      this.webdavEnabled = this.creationMode === 'remote' || repo.webdavEnabled
      this.webdavUrl = repo.webdavUrl
      this.webdavUsername = repo.webdavUsername
      this.webdavPassword = repo.webdavPassword
      this.cleanupPending = !!repo.webdavCleanupPending
      this.excludedDirectoriesText = repo.excludedDirectories.join(', ')
      if (!existing) {
        const defaults: NativeSyncOptions = await defaultSyncOptions()
        this.excludedDirectoriesText = defaults.excludedDirectories.join(', ')
      }
      this.originalDraft = JSON.stringify(this.draft())
      this.loaded = true
    } catch (e) { this.message = localizedText($r('app.string.text_reading_configuration_failed'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.loading = false }
  }

  private pageTitle(): string {
    if (this.existing) return localizedText($r('app.string.text_repository_2'))
    switch (this.creationMode) {
      case 'initialize': return localizedText($r('app.string.text_initialize_a_new_repository'))
      case 'remote': return localizedText($r('app.string.text_add_remote_repository'))
      default: return localizedText($r('app.string.text_add_repository_2'))
    }
  }

  private managedDirectory(): string {
    return RepositorySetupService.managedDirectory(this.getUIContext().getHostContext()!, this.repoId)
  }

  private async syncRepository(repository: RepoConfig, source: RepositorySyncSource, reset: boolean = false): Promise<void> {
    const context = this.getUIContext().getHostContext()!
    const request = RepositorySyncService.start(context, {
      source, policy: SyncStartPolicy.Wait, repositoryId: repository.id,
      beforeSync: async (config: AppConfig): Promise<void> => {
        const saved = config.repos.find(item => item.id === repository.id)
        if (!saved || saved.rootDirectory !== repository.rootDirectory || !saved.webdavEnabled) {
          throw new Error(localizedText($r('app.string.text_reopen_repository_configuration_please')))
        }
        if (reset) {
          const repo = await NativeCoreService.repository(config.repos, saved, config.todoDefaults, config.coreSettings)
          await repo.reset()
        }
        this.syncRetry = source
      }
    })
    if (request.kind === 'rejected') throw new Error(localizedText($r('app.string.text_synchronization_not_accepted_please_try_again')))
    const completion = await request.handle.completion
    if (completion.status === 'failed') throw new Error(completion.message || localizedText($r('app.string.text_synchronization_not_completed')))
    await RepositorySetupService.finishSync(context, repository, source)
    this.syncRetry = ''
  }

  private async retrySync() {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading || !this.syncRetry) return
    const repository = this.config.repos.find(item => item.id === this.repoId)
    if (!repository) return
    this.saving = true
    this.message = ''
    try {
      await this.syncRepository(repository, this.syncRetry)
      this.getUIContext().getPromptAction().showToast({ message: localizedText($r('app.string.text_repository_synchronized')) })
    } catch (e) { this.message = localizedText($r('app.string.text_repository_sync_not_completed'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.saving = false }
  }

  async save(confirmedDraft?: string) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    if (!this.loaded || (this.existing && !this.hasChanges())) return
    if (confirmedDraft !== undefined && confirmedDraft !== JSON.stringify(this.draft())) return
    const saved = this.config.repos.find(item => item.id === this.repoId)
    if (this.cleanupPending && this.rootDirectory.trim() !== saved?.rootDirectory) {
      this.cannotSave(localizedText($r('app.string.text_please_complete_the_hotsync_info_cleanup_and')))
      return
    }
    if (saved?.webdavEnabled && !this.webdavEnabled) {
      if (this.rootDirectory.trim() !== saved.rootDirectory) {
        this.cannotSave(localizedText($r('app.string.text_save_changes_to_local_directories_and_switch')))
        return
      }
      showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_switch_to_local_repository')),
        message: localizedText($r('app.string.text_the_webdav_address_account_numbers_passwords_sync')),
        onCancel: (): void => { this.changeSyncMethod(true) },
        confirmLabel: localizedText($r('app.string.text_switch_to_local')), onConfirm: (): void => { this.finishLocalConversion(saved.rootDirectory) } })
      return
    }
    if (!this.rootDirectory.trim().startsWith('/')) { this.cannotSave(localizedText($r('app.string.text_please_enter_an_absolute_path_to_the'))); return }
    if (this.webdavEnabled && (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword)) {
      this.cannotSave(localizedText($r('app.string.text_please_fill_in_https_webdav_address_username'))); return
    }
    this.saving = true
    try {
      const context = this.getUIContext().getHostContext()!
      let current = await AppConfigService.load(context)
      if (current.repos.some((repo: RepoConfig) => repo.id !== this.repoId && repo.rootDirectory === this.rootDirectory.trim())) {
        this.cannotSave(localizedText($r('app.string.text_this_local_directory_belongs_to_another_repository'))); return
      }
      const previous = current.repos.find((repo: RepoConfig) => repo.id === this.repoId)
      if (this.existing && !previous) {
        this.cannotSave(localizedText($r('app.string.text_this_repository_does_not_exist_please_give'))); return
      }
      const repository = this.draft()
      const encodedDraft = JSON.stringify(repository)
      if (previous && !previous.webdavEnabled && repository.webdavEnabled && confirmedDraft !== encodedDraft) {
        showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_enable_webdav_sync')),
          message: localizedText($r('app.string.text_local_org_files_of_the_same_path')),
          confirmLabel: localizedText($r('app.string.text_enable_synchronization')), onConfirm: (): void => { this.save(encodedDraft) } })
        return
      }
      await RepositorySetupService.prepareDirectory(context, repository, !this.existing)
      if (!this.existing && !repository.webdavEnabled) {
        current.repos.push(repository)
        const files = await RepositorySetupService.initialize(context, current, repository)
        current = await AppConfigService.load(context)
        RepositorySetupService.bindEntries(current, repository, files)
      }
      const index = current.repos.findIndex((repo: RepoConfig) => repo.id === this.repoId)
      if (index < 0) current.repos.push(repository); else current.repos[index] = repository
      await AppConfigService.save(context, current)
      if (!this.existing && repository.webdavEnabled) {
        this.config = current
        this.existing = true
        this.name = repository.name
        this.originalDraft = JSON.stringify(this.draft())
        this.syncRetry = 'repositoryCreated'
        try { await this.syncRepository(repository, 'repositoryCreated') }
        catch (e) {
          this.message = localizedText($r('app.string.text_repository_created_sync_not_completed'), String(coreErrorMessage(e as CoreBridgeError)))
          return
        }
      }
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.cannotSave(localizedText($r('app.string.text_save_failed'), String(coreErrorMessage(e as CoreBridgeError)))) }
    finally { this.saving = false }
  }

  async finishLocalConversion(expectedRoot: string) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.saving = true
    this.message = ''
    const context = this.getUIContext().getHostContext()!
    try {
      const result = RepositorySyncService.start(context, {
        source: 'manual', policy: SyncStartPolicy.Wait, repositoryId: this.repoId,
        beforeSync: async (config: AppConfig): Promise<void> => {
          const repository = config.repos.find(item => item.id === this.repoId)
          if (!repository || repository.rootDirectory !== expectedRoot) throw new Error(localizedText($r('app.string.text_reopen_repository_configuration_please')))
          if (!repository.webdavEnabled) return
          repository.name = this.name.trim()
          repository.webdavEnabled = false
          repository.webdavUrl = ''
          repository.webdavUsername = ''
          repository.webdavPassword = ''
          repository.excludedDirectories = []
          repository.webdavCleanupPending = true
          await AppConfigService.save(context, config)
          this.config = config
          this.cleanupPending = true
          this.webdavUrl = ''
          this.webdavUsername = ''
          this.webdavPassword = ''
          this.excludedDirectoriesText = ''
          this.originalDraft = JSON.stringify(this.draft())
        }
      })
      if (result.kind === 'rejected') throw new Error(localizedText($r('app.string.text_the_repository_is_synchronized_please_try_again')))
      const completion = await result.handle.completion
      if (completion.status === 'failed') throw new Error(completion.message || localizedText($r('app.string.text_synchronization_information_cleanup_not_completed')))
      this.cleanupPending = false
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.message = localizedText($r('app.string.text_switch_to_local_repository_not_completed'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.saving = false }
  }

  confirmDelete() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_delete_the_repository')),
      message: localizedText($r('app.string.text_this_removes_settings_the_password_and_notebook'), String(repositoryLabel(repo))),
      confirmLabel: localizedText($r('app.string.text_delete')), onConfirm: (): void => { this.removeRepository() } })
  }

  async removeRepository() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.deleting = true
    try {
      await AppConfigService.removeRepository(this.getUIContext().getHostContext()!, this.repoId)
      try { await PageQueryService.query(await AppConfigService.load(this.getUIContext().getHostContext()!, false), []) } catch (_) {}
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.message = localizedText($r('app.string.text_failed_to_delete_repository'), String(coreErrorMessage(e as CoreBridgeError))) }
    finally { this.deleting = false }
  }

  confirmReset() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    if (this.cleanupPending) { this.message = localizedText($r('app.string.text_please_complete_the_sync_message_first')); return }
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    if (this.rootDirectory.trim() !== repo.rootDirectory) {
      this.message = localizedText($r('app.string.text_local_directory_modified_tap_ok_before_resetting'))
      return
    }
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_reset_local_directories')),
      message: localizedText($r('app.string.text_clears_all_local_files_sync_history_and'), String(repositoryLabel(repo)), String(repo.webdavEnabled ? localizedText($r('app.string.text_then_re_sync_from_webdav')) : localizedText($r('app.string.text_the_inbox_one_day_memo_and_my'))), String(repo.rootDirectory)),
      confirmLabel: localizedText($r('app.string.text_reset')), onConfirm: (): void => { this.resetRepository(repo.rootDirectory) } })
  }

  async resetRepository(expectedRoot: string, initializeOnly: boolean = false) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.resetting = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      const config = await AppConfigService.load(context)
      const repository = config.repos.find((item: RepoConfig) => item.id === this.repoId)
      if (!repository || repository.rootDirectory !== expectedRoot) throw new Error(localizedText($r('app.string.text_reopen_repository_configuration_please')))
      if (repository.webdavEnabled) {
        if (initializeOnly) throw new Error(localizedText($r('app.string.text_reopen_repository_sync_mode_changed')))
        await this.syncRepository(repository, 'repositoryReset', true)
      } else {
        this.retryInitialization = true
        const files = await RepositorySetupService.initialize(context, config, repository, !initializeOnly)
        const current = await AppConfigService.load(context)
        const saved = current.repos.find((item: RepoConfig) => item.id === this.repoId)
        if (!saved || saved.rootDirectory !== expectedRoot || saved.webdavEnabled) throw new Error(localizedText($r('app.string.text_reopen_repository_configuration_please')))
        if (RepositorySetupService.bindEntries(current, repository, files, true)) await AppConfigService.save(context, current)
        this.retryInitialization = false
      }
      this.getUIContext().getPromptAction().showToast({ message: repository.webdavEnabled ? localizedText($r('app.string.text_reset_and_synchronized_repository')) : localizedText($r('app.string.text_local_directory_resetd')) })
    } catch (e) {
      const detail = coreErrorMessage(e as CoreBridgeError)
      this.message = this.syncRetry === 'repositoryReset' ? localizedText($r('app.string.text_local_directory_has_been_reset_sync_is'), String(detail)) : localizedText($r('app.string.text_reset_failed'), String(detail))
    }
    finally { this.resetting = false }
  }

  @Builder
  directoryPicker() {
    LocalDirectorySheet({ initialDirectory: this.rootDirectory, busy: $directoryBusy,
      selected: (path: string): void => { this.rootDirectory = path; this.directoryOpen = false } })
  }

  build() {
    Column() {
      AppShell({ title: this.pageTitle(), titleIcon: $r('app.media.nav_repository'), back: true, drawerOpen: $drawerOpen,
        busy: this.loading || this.saving || this.testing || this.deleting || this.resetting || this.directoryBusy,
        actionLabel: this.existing ? localizedText($r('app.string.text_reset_local_directory')) : '',
        actionText: this.resetting ? localizedText($r('app.string.text_reseting')) : localizedText($r('app.string.text_reset')),
        action: (): void => { this.confirmReset() },
        backAction: (): void => { this.onBackPress() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column() {
              SettingsGroup({ title: localizedText($r('app.string.text_basic_information')), detail: this.creationMode ?
                localizedText($r('app.string.text_stores_files_using_an_application_directory')) :
                (this.existing ? localizedText($r('app.string.text_you_can_leave_a_name_empty_and')) : localizedText($r('app.string.text_by_default_use_the_application_directory_or'))) }) {
                SettingsField({ title: localizedText($r('app.string.text_name')), text: this.name,
                  placeholder: !this.existing && this.rootDirectory === this.managedDirectory() ? (this.webdavEnabled ? localizedText($r('app.string.text_webdav_repository')) : localizedText($r('app.string.text_local_repository'))) : repositoryName(this.rootDirectory),
                  changed: (value: string): void => { this.name = value } })
                SettingsRow({ title: localizedText($r('app.string.text_local_directory')), value: this.rootDirectory === this.managedDirectory() ? localizedText($r('app.string.text_apply_a_special_directory')) : repositoryName(this.rootDirectory),
                  detail: this.rootDirectory, icon: $r('app.media.ui_folder'), divider: false,
                  disclosure: this.existing || !this.creationMode,
                  action: (): void => {
                    if (this.existing || !this.creationMode) this.directoryOpen = true
                  } })
              }
              if (this.existing || !this.creationMode) {
                SettingsGroup({ title: localizedText($r('app.string.text_sync')), detail: localizedText($r('app.string.text_local_warehouses_use_only_their_own_machine')) }) {
                  SettingsChoiceRow({ title: localizedText($r('app.string.text_synchronisation_method')), value: this.webdavEnabled ? 'WebDAV' : localizedText($r('app.string.text_do_not_sync')),
                    divider: false, items: this.syncMethodChoices() })
                  if (this.cleanupPending) {
                    SettingsRow({ title: localizedText($r('app.string.text_retry_clearing_sync_data')), divider: false, disclosure: false,
                      action: (): void => { this.finishLocalConversion(this.rootDirectory) } })
                  }
                }
              }
              if (this.webdavEnabled) {
                SettingsGroup({ title: localizedText($r('app.string.text_webdav_connection')), detail: localizedText($r('app.string.text_tests_the_connection_to_verify_authentication_and')) }) {
                  SettingsField({ title: localizedText($r('app.string.text_server_address')), text: this.webdavUrl, placeholder: 'https://dav.example.com/org/',
                    changed: (value: string): void => { this.webdavUrl = value; this.clearTestResult() } })
                  SettingsField({ title: localizedText($r('app.string.text_username')), text: this.webdavUsername, placeholder: localizedText($r('app.string.text_webdav_username')),
                    changed: (value: string): void => { this.webdavUsername = value; this.clearTestResult() } })
                  SettingsField({ title: localizedText($r('app.string.text_password_or_application_of_a_specific_password')), text: this.webdavPassword, placeholder: localizedText($r('app.string.text_webdav_password')), password: true,
                    changed: (value: string): void => { this.webdavPassword = value; this.clearTestResult() } })
                  SettingsRow({ title: this.testing ? localizedText($r('app.string.text_testing_connection_2')) : localizedText($r('app.string.text_test_connection')), divider: false, disclosure: false, disabled: this.testing,
                    action: (): void => { this.testConnection() } })
                }
              }
              if (this.webdavEnabled && this.testMessage) {
                Text(this.testMessage).fontSize(13).lineHeight(21).width('100%').padding({ left: 12, right: 12, top: 10 })
                  .fontColor(this.testing ? UiColor.secondary : this.testSucceeded ? UiColor.done : UiColor.error)
              }
              if (this.webdavEnabled) {
                SettingsGroup({ title: localizedText($r('app.string.text_synchronise_filter_directory')), detail: localizedText($r('app.string.text_catalogues_are_separated_by_commas_to_match')) }) {
                  SettingsField({ title: localizedText($r('app.string.text_filter_directory')), text: this.excludedDirectoriesText, placeholder: localizedText($r('app.string.text_catalogue_name_separated_by_comma')),
                    changed: (value: string): void => { this.excludedDirectoriesText = value } })
                  SettingsRow({ title: localizedText($r('app.string.text_restore_default_filter_directory')), divider: false, disclosure: false, action: (): void => { this.restoreDefaultExclusions() } })
                }
              }
              if (this.existing) {
                SettingsGroup({ title: localizedText($r('app.string.text_repository_management')), detail: localizedText($r('app.string.text_reset_will_empty_local_files_deleting_the')) }) {
                  if (this.syncRetry) {
                    SettingsRow({ title: localizedText($r('app.string.text_retry_repository_sync')), disclosure: false, action: (): void => { this.retrySync() } })
                  }
                  if (this.retryInitialization) {
                    SettingsRow({ title: localizedText($r('app.string.text_retry_initializing_entry_files')), disclosure: false,
                      action: (): void => { this.resetRepository(this.rootDirectory.trim(), true) } })
                  }
                  SettingsRow({ title: this.deleting ? localizedText($r('app.string.text_deleting')) : localizedText($r('app.string.text_remove_repository')), danger: true, disclosure: false, divider: false, action: (): void => { this.confirmDelete() } })
                }
              }
            }.width('100%').padding({ left: 16, right: 16, bottom: 32 })
              .enabled(!this.loading && this.loaded && !this.saving && !this.testing && !this.deleting && !this.resetting)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          if (!this.loading && this.loaded && (!this.existing || this.hasChanges())) {
            Column() {
              Button(this.saving ? localizedText($r('app.string.text_saving_4')) : this.existing ? localizedText($r('app.string.text_ok')) : localizedText($r('app.string.text_new_repository')))
                .id(this.existing ? 'repository_confirm' : 'repository_create')
                .width('100%').height(48).borderRadius(12)
                .backgroundColor(UiColor.primary).fontColor(UiColor.onPrimary)
                .enabled(!this.saving && !this.testing && !this.deleting && !this.resetting && !this.directoryBusy && !!this.rootDirectory)
                .onClick((): void => { this.save() })
            }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.directoryOpen, this.directoryPicker, {
        height: '70%', detents: ['70%', '90%'], preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.container, showClose: true,
        onWillDismiss: (action): void => { if (!this.directoryBusy) action.dismiss() }
      })
  }

  async restoreDefaultExclusions() {
    try {
      const defaults: NativeSyncOptions = await defaultSyncOptions()
      this.excludedDirectoriesText = defaults.excludedDirectories.join(', ')
    } catch (e) { this.message = localizedText($r('app.string.text_reading_default_filter_directory_failed'), String(coreErrorMessage(e as CoreBridgeError))) }
  }
}
