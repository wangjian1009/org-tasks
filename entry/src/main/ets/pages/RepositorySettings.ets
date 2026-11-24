import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { PageNavigator } from '../services/PageNavigator'
import { PageParameters, RepositoryCreationMode } from '../services/PagePath'
import { PageQueryService } from '../services/PageQueryService'
import { fileIo } from '@kit.CoreFileKit'
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
    showDangerousConfirmation(this.getUIContext(), { title: '无法保存修改', message,
      cancelLabel: '继续编辑',
      confirmLabel: '放弃修改并返回', onConfirm: (): void => { PageNavigator.shared.back(this.getUIContext()) } })
  }

  clearTestResult() {
    this.testMessage = ''
    this.testSucceeded = false
  }

  changeSyncMethod(enabled: boolean): void {
    if (!this.loaded || this.loading || this.saving || this.testing || this.deleting || this.resetting || this.webdavEnabled === enabled) return
    if (this.cleanupPending) {
      this.message = '请先完成同步信息清理'
      return
    }
    this.webdavEnabled = enabled
    this.clearTestResult()
  }

  syncMethodChoices(): PopupMenuItem[] {
    return [
      { title: '不同步', checked: !this.webdavEnabled, action: (): void => { this.changeSyncMethod(false) } },
      { title: 'WebDAV', checked: this.webdavEnabled, action: (): void => { this.changeSyncMethod(true) } }
    ]
  }

  async testConnection() {
    if (!this.webdavEnabled || this.testing || this.saving || this.loading) return
    this.clearTestResult()
    if (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword) {
      this.testMessage = '请填写 HTTPS WebDAV 地址、用户名和密码'
      return
    }
    this.testing = true
    this.message = ''
    this.testMessage = '正在测试连接…'
    try {
      const policy = new CoreWebDavSyncPolicy(this.webdavUrl.trim(), this.webdavUsername.trim(), this.webdavPassword)
      await policy.testConnection()
      this.testSucceeded = true
      this.testMessage = '连接成功，可以访问该目录。'
    } catch (e) {
      this.testMessage = `连接测试失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.testing = false
    }
  }

  async load() {
    try {
      this.config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const params = this.getUIContext().getRouter().getParams() as PageParameters | undefined
      if (params?.repoId === SYSTEM_REPOSITORY_ID) throw new Error('系统仓库由应用管理，不能修改')
      const existing = this.config.repos.find((item: RepoConfig) => item.id === params?.repoId)
      if (params?.repoId && !existing) throw new Error('此存储库已不存在，请返回存储库列表')
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
    } catch (e) { this.message = `读取配置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  private pageTitle(): string {
    if (this.existing) return '仓库'
    switch (this.creationMode) {
      case 'initialize': return '初始化新仓库'
      case 'remote': return '新增远程仓库'
      default: return '添加仓库'
    }
  }

  private managedDirectory(): string {
    return `${this.getUIContext().getHostContext()!.filesDir}/repositories/${this.repoId}`
  }

  private async syncRepository(repository: RepoConfig, source: RepositorySyncSource, reset: boolean = false): Promise<void> {
    const context = this.getUIContext().getHostContext()!
    const request = RepositorySyncService.start(context, {
      source, policy: SyncStartPolicy.Wait, repositoryId: repository.id,
      beforeSync: async (config: AppConfig): Promise<void> => {
        const saved = config.repos.find(item => item.id === repository.id)
        if (!saved || saved.rootDirectory !== repository.rootDirectory || !saved.webdavEnabled) {
          throw new Error('仓库配置已改变，请重新打开')
        }
        if (reset) {
          const repo = await NativeCoreService.repository(config.repos, saved, config.todoDefaults, config.coreSettings)
          await repo.reset()
        }
        this.syncRetry = source
      }
    })
    if (request.kind === 'rejected') throw new Error('同步未受理，请重试')
    const completion = await request.handle.completion
    if (completion.status === 'failed') throw new Error(completion.message || '同步未完成')
    const config = await AppConfigService.load(context)
    const saved = config.repos.find(item => item.id === repository.id)
    if (!saved || saved.rootDirectory !== repository.rootDirectory || !saved.webdavEnabled) {
      throw new Error('仓库配置已改变，请重新打开')
    }
    const files = source === 'repositoryCreated' ? await RepositorySetupService.initialize(context, config, saved)
      : await RepositorySetupService.listEntries(config, saved)
    const current = await AppConfigService.load(context)
    const before = current.repos.find(item => item.id === saved.id)
    if (!before || before.rootDirectory !== saved.rootDirectory || !before.webdavEnabled) throw new Error('仓库配置已改变，请重新打开')
    if (RepositorySetupService.bindEntries(current, before, files, source === 'repositoryReset')) {
      await AppConfigService.save(context, current)
    }
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
      this.getUIContext().getPromptAction().showToast({ message: '仓库已同步' })
    } catch (e) { this.message = `仓库同步未完成：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  async save(confirmedDraft?: string) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    if (!this.loaded || (this.existing && !this.hasChanges())) return
    if (confirmedDraft !== undefined && confirmedDraft !== JSON.stringify(this.draft())) return
    const saved = this.config.repos.find(item => item.id === this.repoId)
    if (this.cleanupPending && this.rootDirectory.trim() !== saved?.rootDirectory) {
      this.cannotSave('请先完成同步信息清理，再修改本地目录')
      return
    }
    if (saved?.webdavEnabled && !this.webdavEnabled) {
      if (this.rootDirectory.trim() !== saved.rootDirectory) {
        this.cannotSave('请先保存本地目录的修改，再切换为本地仓库')
        return
      }
      showDangerousConfirmation(this.getUIContext(), { title: '切换为本地仓库？',
        message: '将清除本机保存的 WebDAV 地址、账号、密码、同步历史和待上传记录。本机与远端的文件都会保留。以后重新开启同步时，同路径文件将采用远端版本。',
        onCancel: (): void => { this.changeSyncMethod(true) },
        confirmLabel: '切换为本地', onConfirm: (): void => { this.finishLocalConversion(saved.rootDirectory) } })
      return
    }
    if (!this.rootDirectory.trim().startsWith('/')) { this.cannotSave('请输入本地 Org 文件目录的绝对路径'); return }
    if (this.webdavEnabled && (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword)) {
      this.cannotSave('请填写 HTTPS WebDAV 地址、用户名和密码'); return
    }
    this.saving = true
    try {
      const context = this.getUIContext().getHostContext()!
      let current = await AppConfigService.load(context)
      if (current.repos.some((repo: RepoConfig) => repo.id !== this.repoId && repo.rootDirectory === this.rootDirectory.trim())) {
        this.cannotSave('此本地目录已属于另一个存储库'); return
      }
      const previous = current.repos.find((repo: RepoConfig) => repo.id === this.repoId)
      if (this.existing && !previous) {
        this.cannotSave('此存储库已不存在，请放弃修改并返回'); return
      }
      const repository = this.draft()
      const encodedDraft = JSON.stringify(repository)
      if (previous && !previous.webdavEnabled && repository.webdavEnabled && confirmedDraft !== encodedDraft) {
        showDangerousConfirmation(this.getUIContext(), { title: '启用 WebDAV 同步？',
          message: '首次同步时，同路径的本地 Org 文件会被远端版本覆盖，未被远端版本保留的本地任务会在同步后移入废纸篓。本地独有文件会保留并上传。',
          confirmLabel: '启用同步', onConfirm: (): void => { this.save(encodedDraft) } })
        return
      }
      const managed = this.managedDirectory()
      if (repository.rootDirectory === managed && !await fileIo.access(managed)) await fileIo.mkdir(managed, true)
      await NativeCoreService.validateRepository(repository.rootDirectory)
      if (!this.existing && repository.rootDirectory === managed && !repository.name) {
        repository.name = repository.webdavEnabled ? 'WebDAV 仓库' : '本地仓库'
      }
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
          this.message = `仓库已创建，同步未完成：${coreErrorMessage(e as CoreBridgeError)}`
          return
        }
      }
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.cannotSave(`保存失败：${coreErrorMessage(e as CoreBridgeError)}`) }
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
          if (!repository || repository.rootDirectory !== expectedRoot) throw new Error('仓库配置已改变，请重新打开')
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
      if (result.kind === 'rejected') throw new Error('仓库正在同步，请重试')
      const completion = await result.handle.completion
      if (completion.status === 'failed') throw new Error(completion.message || '同步信息清理未完成')
      this.cleanupPending = false
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.message = `切换为本地仓库未完成：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  confirmDelete() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    showDangerousConfirmation(this.getUIContext(), { title: '删除存储库？',
      message: `将移除“${repositoryLabel(repo)}”的配置、密码和指向该仓库的文件入口，保留本地 Org 文件及远端文件。`,
      confirmLabel: '删除', onConfirm: (): void => { this.removeRepository() } })
  }

  async removeRepository() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.deleting = true
    try {
      await AppConfigService.removeRepository(this.getUIContext().getHostContext()!, this.repoId)
      try { await PageQueryService.query(await AppConfigService.load(this.getUIContext().getHostContext()!, false), []) } catch (_) {}
      PageNavigator.shared.back(this.getUIContext())
    } catch (e) { this.message = `删除存储库失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.deleting = false }
  }

  confirmReset() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    if (this.cleanupPending) { this.message = '请先完成同步信息清理'; return }
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    if (this.rootDirectory.trim() !== repo.rootDirectory) {
      this.message = '本地目录已修改，请先点击“确定”保存后再重置'
      return
    }
    showDangerousConfirmation(this.getUIContext(), { title: '重置本地目录？',
      message: `将清空“${repositoryLabel(repo)}”的全部本地文件、同步历史和未上传修改。${repo.webdavEnabled ? '随后从 WebDAV 重新同步。' : '随后从模板重新创建收件箱、某天、备忘和我的任务文件。'}此操作无法撤销。\n${repo.rootDirectory}`,
      confirmLabel: '重置', onConfirm: (): void => { this.resetRepository(repo.rootDirectory) } })
  }

  async resetRepository(expectedRoot: string, initializeOnly: boolean = false) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.resetting = true
    this.message = ''
    try {
      const context = this.getUIContext().getHostContext()!
      const config = await AppConfigService.load(context)
      const repository = config.repos.find((item: RepoConfig) => item.id === this.repoId)
      if (!repository || repository.rootDirectory !== expectedRoot) throw new Error('仓库配置已改变，请重新打开')
      if (repository.webdavEnabled) {
        if (initializeOnly) throw new Error('仓库同步方式已改变，请重新打开')
        await this.syncRepository(repository, 'repositoryReset', true)
      } else {
        this.retryInitialization = true
        const files = await RepositorySetupService.initialize(context, config, repository, !initializeOnly)
        const current = await AppConfigService.load(context)
        const saved = current.repos.find((item: RepoConfig) => item.id === this.repoId)
        if (!saved || saved.rootDirectory !== expectedRoot || saved.webdavEnabled) throw new Error('仓库配置已改变，请重新打开')
        if (RepositorySetupService.bindEntries(current, repository, files, true)) await AppConfigService.save(context, current)
        this.retryInitialization = false
      }
      this.getUIContext().getPromptAction().showToast({ message: repository.webdavEnabled ? '仓库已重置并同步' : '本地目录已重置' })
    } catch (e) {
      const detail = coreErrorMessage(e as CoreBridgeError)
      this.message = this.syncRetry === 'repositoryReset' ? `本地目录已重置，同步未完成：${detail}` : `重置失败：${detail}`
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
        actionLabel: this.existing ? '重置本地目录' : '',
        actionText: this.resetting ? '正在重置…' : '重置',
        action: (): void => { this.confirmReset() },
        backAction: (): void => { this.onBackPress() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column() {
              SettingsGroup({ title: '基本信息', detail: this.creationMode ?
                '使用应用专用目录存放文件。' :
                (this.existing ? '名称可留空，默认使用目录名称。修改后点击底部“确定”保存。' : '默认使用应用专用目录，也可选择应用可访问的其他目录。') }) {
                SettingsField({ title: '名称', text: this.name,
                  placeholder: !this.existing && this.rootDirectory === this.managedDirectory() ? (this.webdavEnabled ? 'WebDAV 仓库' : '本地仓库') : repositoryName(this.rootDirectory),
                  changed: (value: string): void => { this.name = value } })
                SettingsRow({ title: '本地目录', value: this.rootDirectory === this.managedDirectory() ? '应用专用目录' : repositoryName(this.rootDirectory),
                  detail: this.rootDirectory, icon: $r('app.media.ui_folder'), divider: false,
                  disclosure: this.existing || !this.creationMode,
                  action: (): void => {
                    if (this.existing || !this.creationMode) this.directoryOpen = true
                  } })
              }
              if (this.existing || !this.creationMode) {
                SettingsGroup({ title: '同步', detail: '本地仓库仅使用本机文件。WebDAV 仓库切换为不同步时，需要确认清理同步信息。' }) {
                  SettingsChoiceRow({ title: '同步方式', value: this.webdavEnabled ? 'WebDAV' : '不同步',
                    divider: false, items: this.syncMethodChoices() })
                  if (this.cleanupPending) {
                    SettingsRow({ title: '重试清理同步信息', divider: false, disclosure: false,
                      action: (): void => { this.finishLocalConversion(this.rootDirectory) } })
                  }
                }
              }
              if (this.webdavEnabled) {
                SettingsGroup({ title: 'WebDAV 连接', detail: '测试连接验证认证与目录访问，不保存配置或同步文件；上传权限在实际同步时验证。' }) {
                  SettingsField({ title: '服务器地址', text: this.webdavUrl, placeholder: 'https://dav.example.com/org/',
                    changed: (value: string): void => { this.webdavUrl = value; this.clearTestResult() } })
                  SettingsField({ title: '用户名', text: this.webdavUsername, placeholder: 'WebDAV 用户名',
                    changed: (value: string): void => { this.webdavUsername = value; this.clearTestResult() } })
                  SettingsField({ title: '密码或应用专用密码', text: this.webdavPassword, placeholder: 'WebDAV 密码', password: true,
                    changed: (value: string): void => { this.webdavPassword = value; this.clearTestResult() } })
                  SettingsRow({ title: this.testing ? '测试连接中…' : '测试连接', divider: false, disclosure: false, disabled: this.testing,
                    action: (): void => { this.testConnection() } })
                }
              }
              if (this.webdavEnabled && this.testMessage) {
                Text(this.testMessage).fontSize(13).lineHeight(21).width('100%').padding({ left: 12, right: 12, top: 10 })
                  .fontColor(this.testing ? UiColor.secondary : this.testSucceeded ? UiColor.done : UiColor.error)
              }
              if (this.webdavEnabled) {
                SettingsGroup({ title: '同步过滤目录', detail: '目录名用逗号分隔，匹配任意层级。过滤目录不参与同步，已下载文件会保留。' }) {
                  SettingsField({ title: '过滤目录', text: this.excludedDirectoriesText, placeholder: '目录名，用逗号分隔',
                    changed: (value: string): void => { this.excludedDirectoriesText = value } })
                  SettingsRow({ title: '恢复默认过滤目录', divider: false, disclosure: false, action: (): void => { this.restoreDefaultExclusions() } })
                }
              }
              if (this.existing) {
                SettingsGroup({ title: '仓库管理', detail: '重置会清空本地文件；删除存储库仅移除配置和密码。操作前均需确认。' }) {
                  if (this.syncRetry) {
                    SettingsRow({ title: '重试仓库同步', disclosure: false, action: (): void => { this.retrySync() } })
                  }
                  if (this.retryInitialization) {
                    SettingsRow({ title: '重试初始化入口文件', disclosure: false,
                      action: (): void => { this.resetRepository(this.rootDirectory.trim(), true) } })
                  }
                  SettingsRow({ title: this.deleting ? '正在删除…' : '删除存储库', danger: true, disclosure: false, divider: false, action: (): void => { this.confirmDelete() } })
                }
              }
            }.width('100%').padding({ left: 16, right: 16, bottom: 32 })
              .enabled(!this.loading && this.loaded && !this.saving && !this.testing && !this.deleting && !this.resetting)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
          if (!this.loading && this.loaded && (!this.existing || this.hasChanges())) {
            Column() {
              Button(this.saving ? '正在保存…' : this.existing ? '确定' : '新建仓库')
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
    } catch (e) { this.message = `读取默认过滤目录失败：${coreErrorMessage(e as CoreBridgeError)}` }
  }
}
