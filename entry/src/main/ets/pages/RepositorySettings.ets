import { router } from '@kit.ArkUI'
import { fileIo } from '@kit.CoreFileKit'
import { defaultSyncOptions } from 'liborg_tasks_harmony.so'
import { AppConfig, DEFAULT_CONFIG, RepoConfig, SyncOptions } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, CoreWebDavSyncPolicy, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/Controls'
import { repositoryLabel, repositoryName, UiColor } from '../ui/Theme'
import { RepositorySyncService } from '../services/RepositorySyncService'

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
  @State existing: boolean = false
  @State testing: boolean = false
  @State testMessage: string = ''
  @State testSucceeded: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  private loaded: boolean = false
  private originalDraft: string = ''

  aboutToAppear() { this.load() }
  onBackPress(): boolean {
    if (!this.saving && !this.testing && !this.deleting) this.save()
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
      secondaryButton: { value: '放弃修改并返回', action: (): void => { router.back() } } })
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
      this.testMessage = '连接成功，可以访问该目录。写入权限将在实际同步时验证。'
    } catch (e) {
      this.testMessage = `连接测试失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally {
      this.testing = false
    }
  }

  async load() {
    try {
      this.config = await AppConfigService.load(getContext(this))
      const params = router.getParams() as RepositoryParams | undefined
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
        const defaults = await defaultSyncOptions()
        this.excludedDirectoriesText = defaults.excludedDirectories.join(', ')
      }
      if (!this.rootDirectory && this.webdavEnabled) this.rootDirectory = `${getContext(this).filesDir}/repositories/${repo.id}`
      this.originalDraft = JSON.stringify(this.draft())
      this.loaded = true
    } catch (e) { this.message = `读取配置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  async save() {
    if (this.saving || this.testing || this.deleting || this.loading) return
    if (!this.loaded || JSON.stringify(this.draft()) === this.originalDraft) { router.back(); return }
    if (!this.rootDirectory.trim().startsWith('/')) { this.cannotSave('请输入本地 Org 文件目录的绝对路径'); return }
    if (this.webdavEnabled && (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword)) {
      this.cannotSave('请填写 HTTPS WebDAV 地址、用户名和密码'); return
    }
    this.saving = true
    try {
      const current = await AppConfigService.load(getContext(this))
      if (current.repos.some((repo: RepoConfig) => repo.id !== this.repoId && repo.rootDirectory === this.rootDirectory.trim())) {
        this.cannotSave('此本地目录已属于另一个存储库'); return
      }
      if (this.existing && !current.repos.some((repo: RepoConfig) => repo.id === this.repoId)) {
        this.cannotSave('此存储库已不存在，请放弃修改并返回'); return
      }
      const repository = this.draft()
      const managed = `${getContext(this).filesDir}/repositories/${this.repoId}`
      if (repository.rootDirectory === managed && !await fileIo.access(managed)) await fileIo.mkdir(managed, true)
      await NativeCoreService.validateRepository(repository.rootDirectory)
      const repos = current.repos.slice()
      const index = repos.findIndex((repo: RepoConfig) => repo.id === this.repoId)
      if (index < 0) repos.push(repository); else repos[index] = repository
      await AppConfigService.save(getContext(this), { repos, inboxFile: current.inboxFile, inboxRepoId: current.inboxRepoId, somedayFile: current.somedayFile, somedayRepoId: current.somedayRepoId, memoFile: current.memoFile, memoRepoId: current.memoRepoId, calendarName: current.calendarName, syncInterval: current.syncInterval, todoDefaults: current.todoDefaults, fileDisplayMode: current.fileDisplayMode })
      router.back()
    } catch (e) { this.cannotSave(`保存失败：${coreErrorMessage(e as CoreBridgeError)}`) }
    finally { this.saving = false }
  }

  confirmDelete() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.loading) return
    const repo = this.config.repos.find((item: RepoConfig) => item.id === this.repoId)
    if (!repo) return
    this.getUIContext().showAlertDialog({ title: '删除存储库？',
      message: `将移除“${repositoryLabel(repo)}”的配置和密码，保留本地 Org 文件及远端文件。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: (): void => { this.removeRepository() } } })
  }

  async removeRepository() {
    if (!this.existing || this.saving || this.testing || this.deleting || this.loading) return
    this.deleting = true
    try {
      await AppConfigService.removeRepository(getContext(this), this.repoId)
      try { await RepositorySyncService.refreshConflicts(getContext(this)) } catch (_) {}
      router.back()
    } catch (e) { this.message = `删除存储库失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.deleting = false }
  }

  build() {
    Column() {
      AppShell({ title: '仓库', titleIcon: $r('app.media.nav_repository'), back: true, drawerOpen: $drawerOpen, busy: this.saving || this.testing || this.deleting,
        backAction: (): void => { this.save() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column({ space: 16 }) {
              Text('名称').fontSize(13).fontColor(UiColor.primary).width('100%')
              TextInput({ text: this.name, placeholder: repositoryName(this.rootDirectory) }).height(56).borderRadius(6)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary)
                .onChange((value: string) => { this.name = value })
              Text('可留空，默认使用当前存储库名。').fontSize(13).fontColor(UiColor.secondary).width('100%')
              Row() {
                Text('使用 WebDAV 远端').fontSize(16).fontColor(UiColor.text).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.webdavEnabled }).selectedColor(UiColor.primary)
                  .onChange((value: boolean) => { this.webdavEnabled = value; this.clearTestResult() })
              }.width('100%').height(48)
              if (this.webdavEnabled) {
                Text('WebDAV 地址').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavUrl, placeholder: 'https://dav.example.com/org/' }).height(56).borderRadius(6)
                  .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.webdavUrl = value; this.clearTestResult() })
                Text('用户名').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavUsername, placeholder: 'WebDAV 用户名' }).height(56).borderRadius(6)
                  .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.webdavUsername = value; this.clearTestResult() })
                Text('密码或应用专用密码').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavPassword, placeholder: 'WebDAV 密码' }).height(56).borderRadius(6).type(InputType.Password)
                  .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.webdavPassword = value; this.clearTestResult() })
                Button(this.testing ? '测试中…' : '测试连接').width('100%').height(48)
                  .backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick((): void => { this.testConnection() })
                if (this.testMessage) {
                  Text(this.testMessage).width('100%').fontSize(13).lineHeight(21)
                    .fontColor(this.testing ? UiColor.secondary : this.testSucceeded ? UiColor.done : UiColor.error)
                }
                Text('同步过滤目录').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.excludedDirectoriesText, placeholder: '目录名，用逗号分隔' }).height(56).borderRadius(6)
                  .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.excludedDirectoriesText = value })
                Text('填写目录名，匹配任意层级的同名目录。目录中的文件不参与 WebDAV 同步；清空表示不过滤。已下载文件会保留。')
                  .fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
                Button('恢复默认过滤目录').fontSize(14).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick(async (): Promise<void> => {
                    const defaults = await defaultSyncOptions()
                    this.excludedDirectoriesText = defaults.excludedDirectories.join(', ')
                  })
              }
              Divider().color(UiColor.outline).margin({ top: 8 })
              Text(this.webdavEnabled ? '本地文件目录' : 'Org 文件目录').fontSize(13).fontColor(UiColor.primary).width('100%')
              TextInput({ text: this.rootDirectory, placeholder: '本地目录的绝对路径' }).height(56).borderRadius(6)
                .backgroundColor(UiColor.field).fontColor(UiColor.text).placeholderColor(UiColor.secondary).onChange((value: string) => { this.rootDirectory = value })
              Text(this.webdavEnabled ? '返回时自动保存修改。本地文件在离线时仍可浏览。' : '返回时自动保存修改。请使用应用可访问的目录。')
                .fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
              if (this.existing) {
                Divider().color(UiColor.outline).margin({ top: 16 })
                Button(this.deleting ? '删除中…' : '删除存储库').width('100%').height(48)
                  .backgroundColor(UiColor.container).fontColor(UiColor.error)
                  .onClick((): void => { this.confirmDelete() })
              }
            }.width('100%').padding({ left: 24, right: 24, top: 16, bottom: 104 }).enabled(!this.saving && !this.testing && !this.deleting && !this.loading)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
