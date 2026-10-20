import { router } from '@kit.ArkUI'
import { fileIo } from '@kit.CoreFileKit'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, coreErrorMessage, CoreWebDavSyncPolicy, NativeCoreService } from '../services/NativeCoreService'
import { AppShell } from '../components/AppShell'
import { MessageBar } from '../components/Controls'
import { UiColor } from '../ui/Theme'

interface RepositoryParams { repoId?: string; webdav?: boolean }

@Entry
@Component
struct RepositorySettings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State repoId: string = ''
  @State rootDirectory: string = ''
  @State webdavEnabled: boolean = false
  @State webdavUrl: string = ''
  @State webdavUsername: string = ''
  @State webdavPassword: string = ''
  @State saving: boolean = false
  @State testing: boolean = false
  @State testMessage: string = ''
  @State testSucceeded: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false

  aboutToAppear() { this.load() }
  onBackPress(): boolean { return this.saving || this.testing }

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
      const repo = this.config.repos.find((item: RepoConfig) => item.id === params?.repoId) || AppConfigService.newRepository()
      this.repoId = repo.id
      this.rootDirectory = repo.rootDirectory
      this.webdavEnabled = params?.repoId ? repo.webdavEnabled : params?.webdav || false
      this.webdavUrl = repo.webdavUrl
      this.webdavUsername = repo.webdavUsername
      this.webdavPassword = repo.webdavPassword
      if (!this.rootDirectory && this.webdavEnabled) this.rootDirectory = `${getContext(this).filesDir}/repositories/${repo.id}`
    } catch (e) { this.message = `读取配置失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.loading = false }
  }

  async save() {
    if (this.saving || this.testing || this.loading) return
    if (!this.rootDirectory.trim().startsWith('/')) { this.message = '请输入本地 Org 文件目录的绝对路径'; return }
    if (this.webdavEnabled && (!this.webdavUrl.trim().startsWith('https://') || !this.webdavUsername.trim() || !this.webdavPassword)) {
      this.message = '请填写 HTTPS WebDAV 地址、用户名和密码'; return
    }
    this.saving = true
    try {
      const current = await AppConfigService.load(getContext(this))
      if (current.repos.some((repo: RepoConfig) => repo.id !== this.repoId && repo.rootDirectory === this.rootDirectory.trim())) {
        this.message = '此本地目录已属于另一个存储库'; return
      }
      const repository: RepoConfig = { id: this.repoId, rootDirectory: this.rootDirectory.trim(), webdavEnabled: this.webdavEnabled,
        webdavUrl: this.webdavUrl.trim(), webdavUsername: this.webdavUsername.trim(), webdavPassword: this.webdavPassword }
      const managed = `${getContext(this).filesDir}/repositories/${this.repoId}`
      if (repository.rootDirectory === managed && !await fileIo.access(managed)) await fileIo.mkdir(managed, true)
      await NativeCoreService.validateRepository(repository.rootDirectory)
      const repos = current.repos.slice()
      const index = repos.findIndex((repo: RepoConfig) => repo.id === this.repoId)
      if (index < 0) repos.push(repository); else repos[index] = repository
      await AppConfigService.save(getContext(this), { repos, inboxFile: current.inboxFile, calendarName: current.calendarName, syncInterval: current.syncInterval, todoDefaults: current.todoDefaults })
      router.back()
    } catch (e) { this.message = `保存失败：${coreErrorMessage(e as CoreBridgeError)}` }
    finally { this.saving = false }
  }

  build() {
    Column() {
      AppShell({ title: this.webdavEnabled ? 'WebDAV' : '本地目录', back: true, drawerOpen: $drawerOpen, busy: this.saving || this.testing,
        actionIcon: $r('app.media.ui_done'), actionLabel: '保存存储库', action: (): void => { this.save() },
        fabIcon: $r('app.media.ui_done'), fabLabel: '保存存储库', fabAction: (): void => { this.save() } }) {
        Column() {
          MessageBar({ message: this.message, error: true })
          Scroll() {
            Column({ space: 16 }) {
              Row() {
                Text('使用 WebDAV 远端').fontSize(16).fontColor(UiColor.text).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.webdavEnabled }).selectedColor(UiColor.primary)
                  .onChange((value: boolean) => { this.webdavEnabled = value; this.clearTestResult() })
              }.width('100%').height(48)
              if (this.webdavEnabled) {
                Text('WebDAV 地址').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavUrl, placeholder: 'https://dav.example.com/org/' }).height(56).borderRadius(6)
                  .backgroundColor(UiColor.field).onChange((value: string) => { this.webdavUrl = value; this.clearTestResult() })
                Text('用户名').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavUsername, placeholder: 'WebDAV 用户名' }).height(56).borderRadius(6)
                  .backgroundColor(UiColor.field).onChange((value: string) => { this.webdavUsername = value; this.clearTestResult() })
                Text('密码或应用专用密码').fontSize(13).fontColor(UiColor.primary).width('100%')
                TextInput({ text: this.webdavPassword, placeholder: 'WebDAV 密码' }).height(56).borderRadius(6).type(InputType.Password)
                  .backgroundColor(UiColor.field).onChange((value: string) => { this.webdavPassword = value; this.clearTestResult() })
                Button(this.testing ? '测试中…' : '测试连接').width('100%').height(48)
                  .backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
                  .onClick((): void => { this.testConnection() })
                if (this.testMessage) {
                  Text(this.testMessage).width('100%').fontSize(13).lineHeight(21)
                    .fontColor(this.testing ? UiColor.secondary : this.testSucceeded ? UiColor.done : UiColor.error)
                }
              }
              Divider().color(UiColor.outline).margin({ top: 8 })
              Text(this.webdavEnabled ? '本地文件目录' : 'Org 文件目录').fontSize(13).fontColor(UiColor.primary).width('100%')
              TextInput({ text: this.rootDirectory, placeholder: '本地目录的绝对路径' }).height(56).borderRadius(6)
                .backgroundColor(UiColor.field).onChange((value: string) => { this.rootDirectory = value })
              Text(this.webdavEnabled ? '可先测试远端连接，再保存配置。本地文件在离线时仍可浏览和新增任务。' : '应用将读取此目录中的 org 文件。请使用应用可访问的目录。')
                .fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%')
            }.width('100%').padding({ left: 24, right: 24, top: 16, bottom: 104 }).enabled(!this.saving && !this.testing && !this.loading)
          }.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
