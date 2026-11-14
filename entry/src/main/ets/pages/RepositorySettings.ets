import { PageQueryService } from '../services/PageQueryService'
import { fileIo } from '@kit.CoreFileKit'
import { defaultSyncOptions, SyncOptions as NativeSyncOptions } from 'liborg_tasks_harmony.so'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, CoreWebDavSyncPolicy, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/controls/MessageBar'
import { SettingsGroup } from '../components/controls/SettingsGroup'
import { SettingsRow } from '../components/controls/SettingsRow'
import { SettingsField } from '../components/controls/SettingsField'
import { LocalDirectorySheet } from '../components/editors/LocalDirectorySheet'
import { repositoryLabel, repositoryName, UiColor } from '../ui/Theme'

interface RepositoryParams { repoId?: string; webdav?: boolean }

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
  @State existing: boolean = false
  @State testing: boolean = false
  @State testMessage: string = ''
  @State testSucceeded: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  @State directoryOpen: boolean = false
  @State directoryBusy: boolean = false
  private loaded: boolean = false
  private originalDraft: string = ''

  aboutToAppear() { this.load() }
  onBackPress(): boolean {
    if (this.directoryOpen) { if (!this.directoryBusy) this.directoryOpen = false; return true }
    if (!this.saving && !this.testing && !this.deleting && !this.resetting) this.save()
    return true
  }

  draft(): RepoConfig {
    return { id: this.repoId, name: this.name.trim(), rootDirectory: this.rootDirectory.trim(),
      webdavEnabled: this.webdavEnabled, webdavUrl: this.webdavUrl.trim(),
      webdavUsername: this.webdavUsername.trim(), webdavPassword: this.webdavPassword,
      excludedDirectories: this.excludedDirectoriesText.split(',').map((value: string) => value.trim())
        .filter((value: string) => value.length > 0) }
  }

  cannotSave(message: string) {
    this.message = message
    this.getUIContext().showAlertDialog({ title: '无法保存修改', message,
      primaryButton: { value: '继续编辑', action: () => {} },
      secondaryButton: { value: '放弃修改并返回', fontColor: UiColor.error, action: (): void => { this.getUIContext().getRouter().back() } } })
  }

  clearTestResult() {
    this.testMessage = ''
    this.testSucceeded = false
  }

  async testConnection() {
    if (this.testing || this.saving || this.loading) return
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
      const params = this.getUIContext().getRouter().getParams() as RepositoryParams | undefined
      const existing = this.config.repos.find((item: RepoConfig) => item.id === params?.repoId)
      if (params?.repoId && !existing) throw new Error('此存储库已不存在，请返回存储库列表')
      this.existing = existing !== undefined
      const repo = existing || AppConfigService.newRepository()
      this.repoId = repo.id
      this.name = repo.name
      this.rootDirectory = repo.rootDirectory
      this.webdavEnabled = params?.repoId ? repo.webdavEnabled : params?.webdav || false
      this.webdavUrl = repo.webdavUrl
      this.webdavUsername = repo.webdavUsername
      this.webdavPassword = repo.webdavPassword
      this.excludedDirectoriesText = repo.excludedDirectories.join(', ')
      if (!existing && this.webdavEnabled) {
        const defaults: NativeSyncOptions = await defaultSyncOptions()
        this.excludedDirectoriesText = defaults.excludedDirectories.join(', ')
      }
      if (!this.rootDirectory && this.webdavEnabled) this.rootDirectory = `${this.getUIContext().getHostContext()!.filesDir}/repositories/${repo.id}`
      this.originalDraft = JSON.stringify(this.draft())
      this.loaded = true
    } catch (e) { this.message = `读取配置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  async save() {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    if (!this.loaded || JSON.stringify(this.draft()) === this.originalDraft) { this.getUIContext().getRouter().back(); return }
    if (!this.rootDirectory.trim().startsWith('/')) { this.cannotSave('请输入本地 Org 文件目录的绝对路径'); return }
    if (this.webdavEnabled && (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword)) {
      this.cannotSave('请填写 HTTPS WebDAV 地址、用户名和密码'); return
    }
    this.saving = true
    try {
      const current = await AppConfigService.load(this.getUIContext().getHostContext()!)
      if (current.repos.some((repo: RepoConfig) => repo.id !== this.repoId && repo.rootDirectory === this.rootDirectory.trim())) {
        this.cannotSave('此本地目录已属于另一个存储库'); return
      }
      if (this.existing && !current.repos.some((repo: RepoConfig) => repo.id === this.repoId)) {
        this.cannotSave('此存储库已不存在，请放弃修改并返回'); return
      }
      const repository = this.draft()
      const managed = `${this.getUIContext().getHostContext()!.filesDir}/repositories/${this.repoId}`
      if (repository.rootDirectory === managed && !await fileIo.access(managed)) await fileIo.mkdir(managed, true)
      await NativeCoreService.validateRepository(repository.rootDirectory)
      const repos = current.repos.slice()
      const index = repos.findIndex((repo: RepoConfig) => repo.id === this.repoId)
      if (index < 0) repos.push(repository); else repos[index] = repository
      await AppConfigService.save(this.getUIContext().getHostContext()!, { repos, inboxFile: current.inboxFile, inboxRepoId: current.inboxRepoId, somedayFile: current.somedayFile, somedayRepoId: current.somedayRepoId, memoFile: current.memoFile, memoRepoId: current.memoRepoId, calendarName: current.calendarName, todoDefaults: current.todoDefaults, coreSettings: current.coreSettings, fileDisplayMode: current.fileDisplayMode })
      this.getUIContext().getRouter().back()
    } catch (e) { this.cannotSave(`保存失败：${coreErrorMessage(e as CoreBridgeError)}`) }
    finally { this.saving = false }
  }

  confirmDelete() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    this.getUIContext().showAlertDialog({ title: '删除存储库？',
      message: `将移除“${repositoryLabel(repo)}”的配置和密码，保留本地 Org 文件及远端文件。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: UiColor.error, action: (): void => { this.removeRepository() } } })
  }

  async removeRepository() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.deleting = true
    try {
      await AppConfigService.removeRepository(this.getUIContext().getHostContext()!, this.repoId)
      try { await PageQueryService.query(await AppConfigService.load(this.getUIContext().getHostContext()!, false), []) } catch (_) {}
      this.getUIContext().getRouter().back()
    } catch (e) { this.message = `删除存储库失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.deleting = false }
  }

  confirmReset() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    if (this.rootDirectory.trim() !== repo.rootDirectory) {
      this.message = '本地目录已修改，请先返回保存后再重置'
      return
    }
    this.getUIContext().showAlertDialog({ title: '重置本地目录？',
      message: `将清空“${repositoryLabel(repo)}”的全部本地文件、同步历史和未上传修改。仓库身份、配置及远端文件保留。此操作无法撤销。\n${repo.rootDirectory}`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重置', fontColor: UiColor.error, action: (): void => { this.resetRepository(repo.rootDirectory) } } })
  }

  async resetRepository(expectedRoot: string) {
    if (this.saving || this.testing || this.deleting || this.resetting || this.loading) return
    this.resetting = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const repository = config.repos.find((item: RepoConfig) => item.id === this.repoId)
      if (!repository || repository.rootDirectory !== expectedRoot) throw new Error('仓库配置已改变，请重新打开')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      await repo.reset()
      try { await PageQueryService.query(await AppConfigService.load(this.getUIContext().getHostContext()!, false), []) } catch (_) {}
      this.getUIContext().getPromptAction().showToast({ message: '本地目录已重置' })
    } catch (e) { this.message = `重置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.resetting = false }
  }

  @Builder
  directoryPicker() {
    LocalDirectorySheet({ initialDirectory: this.rootDirectory, busy: $directoryBusy,
      selected: (path: string): void => { this.rootDirectory = path; this.directoryOpen = false } })
  }

  @Builder
  webdavSwitch() {
    Row({ space: 12 }) {
      Text('使用 WebDAV 远端').fontSize(16).fontColor(UiColor.text).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.webdavEnabled }).selectedColor(UiColor.primary)
        .onChange((value: boolean): void => { this.webdavEnabled = value; this.clearTestResult() })
    }.width('100%').constraintSize({ minHeight: 58 }).padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .border({ width: { bottom: this.webdavEnabled ? 0.5 : 0 }, color: UiColor.divider })
  }

  build() {
    Column() {
      AppShell({ title: '仓库', titleIcon: $r('app.media.nav_repository'), back: true, drawerOpen: $drawerOpen,
        busy: this.saving || this.testing || this.deleting || this.resetting || this.directoryBusy,
        backAction: (): void => { this.onBackPress() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column() {
              SettingsGroup({ title: '基本信息', detail: '名称可留空，默认使用目录名称。修改后返回保存。' }) {
                SettingsField({ title: '名称', text: this.name, placeholder: repositoryName(this.rootDirectory), divider: false,
                  changed: (value: string): void => { this.name = value } })
              }
              SettingsGroup({ title: '文件位置', detail: '选择应用可访问的目录，支持浏览子目录和新建文件夹。' }) {
                SettingsRow({ title: this.webdavEnabled ? '本地文件目录' : 'Org 文件目录', value: this.rootDirectory ? repositoryName(this.rootDirectory) : '未选择',
                  detail: this.rootDirectory, icon: $r('app.media.ui_folder'), divider: false,
                  action: (): void => { this.directoryOpen = true } })
              }
              SettingsGroup({ title: 'WebDAV 连接', detail: '测试连接验证认证与目录访问，不保存配置或同步文件；上传权限在实际同步时验证。修改后返回保存。' }) {
                this.webdavSwitch()
                if (this.webdavEnabled) {
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
                  SettingsRow({ title: this.resetting ? '正在重置…' : '重置本地目录', danger: true, disclosure: false, action: (): void => { this.confirmReset() } })
                  SettingsRow({ title: this.deleting ? '正在删除…' : '删除存储库', danger: true, disclosure: false, divider: false, action: (): void => { this.confirmDelete() } })
                }
              }
            }.width('100%').padding({ left: 16, right: 16, bottom: 32 })
              .enabled(!this.loading && this.loaded && !this.saving && !this.testing && !this.deleting && !this.resetting)
          }.width('100%').layoutWeight(1)
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
