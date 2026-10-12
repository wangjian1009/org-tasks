import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from '../services/AppConfigService'
import { CredentialService } from '../services/CredentialService'

interface RepoSettingsParams {
  repoId?: string
}

@Entry
@Component
struct Settings {
  @State config: AppConfig = DEFAULT_CONFIG
  @State repoId: string = ''
  @State rootDirectory: string = ''
  @State webdavEnabled: boolean = false
  @State webdavUrl: string = ''
  @State webdavUsername: string = ''
  @State webdavPassword: string = ''
  @State inboxFile: string = DEFAULT_CONFIG.inboxFile
  @State calendarName: string = DEFAULT_CONFIG.calendarName
  @State syncInterval: string = '15'
  @State saving: boolean = false
  @State message: string = ''

  aboutToAppear() {
    this.loadConfig()
  }

  async loadConfig() {
    try {
      const config = await AppConfigService.load(getContext(this))
      const params = router.getParams() as RepoSettingsParams | undefined
      const repository = config.repos.find((item: RepoConfig) => item.id === params?.repoId) || AppConfigService.newRepository()
      this.config = config
      this.repoId = repository.id
      this.rootDirectory = repository.rootDirectory
      this.webdavEnabled = repository.webdavEnabled
      this.webdavUrl = repository.webdavUrl
      this.webdavUsername = repository.webdavUsername
      this.webdavPassword = repository.webdavPassword
      this.inboxFile = config.inboxFile
      this.calendarName = config.calendarName
      this.syncInterval = config.syncInterval.toString()
    } catch (e) {
      this.message = '读取仓库配置失败'
    }
  }

  async saveConfig() {
    if (!this.rootDirectory.trim()) {
      this.message = '请输入 Org 文件目录'
      return
    }
    this.saving = true
    try {
      const repository: RepoConfig = {
        id: this.repoId,
        rootDirectory: this.rootDirectory.trim(),
        webdavEnabled: this.webdavEnabled,
        webdavUrl: this.webdavUrl.trim(),
        webdavUsername: this.webdavUsername.trim(),
        webdavPassword: this.webdavPassword
      }
      const repositories = this.config.repos.filter((item: RepoConfig) => item.id !== repository.id)
      repositories.push(repository)
      await AppConfigService.save(getContext(this), {
        repos: repositories,
        inboxFile: this.inboxFile,
        calendarName: this.calendarName,
        syncInterval: parseInt(this.syncInterval) || 15
      })
      this.message = '仓库配置已保存'
      setTimeout(() => router.back(), 500)
    } catch (e) {
      this.message = '保存失败'
    } finally {
      this.saving = false
    }
  }

  async deleteRepository() {
    if (!this.config.repos.some((item: RepoConfig) => item.id === this.repoId)) return
    this.saving = true
    try {
      await CredentialService.clearWebDavPassword(this.repoId)
      await AppConfigService.save(getContext(this), {
        repos: this.config.repos.filter((item: RepoConfig) => item.id !== this.repoId),
        inboxFile: this.inboxFile,
        calendarName: this.calendarName,
        syncInterval: parseInt(this.syncInterval) || 15
      })
      router.back()
    } catch (e) {
      this.message = '删除仓库失败'
    } finally {
      this.saving = false
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回').fontSize(14).backgroundColor('#FFFFFF').fontColor('#34423B').onClick(() => router.back())
        Column() {
          Text('仓库配置').fontSize(22).fontWeight(FontWeight.Medium)
          Text('目录与 WebDAV 远端').fontSize(12).fontColor('#65746B')
        }
        .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })

      Scroll() {
        Column() {
          Text('Org 文件目录').fontSize(14).fontColor('#4E5A53')
          TextInput({ placeholder: '本地 org 文件目录路径', text: this.rootDirectory })
            .height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
            .onChange((value: string) => this.rootDirectory = value)
          Row() {
            Text('使用 WebDAV 远端').fontSize(14).fontColor('#4E5A53')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.webdavEnabled })
              .onChange((enabled: boolean) => this.webdavEnabled = enabled)
          }
          .width('100%')
          .margin({ top: 20 })
          if (this.webdavEnabled) {
            Text('WebDAV 目录地址').fontSize(14).fontColor('#4E5A53').margin({ top: 16 })
            TextInput({ placeholder: 'https://dav.example.com/org-tasks/', text: this.webdavUrl })
              .height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
              .onChange((value: string) => this.webdavUrl = value)
            Text('用户名').fontSize(14).fontColor('#4E5A53').margin({ top: 16 })
            TextInput({ placeholder: 'WebDAV 用户名', text: this.webdavUsername })
              .height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
              .onChange((value: string) => this.webdavUsername = value)
            Text('密码或应用专用密码').fontSize(14).fontColor('#4E5A53').margin({ top: 16 })
            TextInput({ placeholder: 'WebDAV 密码', text: this.webdavPassword })
              .type(InputType.Password).height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
              .onChange((value: string) => this.webdavPassword = value)
          }
          Text('新增任务文件').fontSize(14).fontColor('#4E5A53').margin({ top: 24 })
          TextInput({ placeholder: 'inbox.org', text: this.inboxFile })
            .height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
            .onChange((value: string) => this.inboxFile = value)
          Text('日历名称').fontSize(14).fontColor('#4E5A53').margin({ top: 16 })
          TextInput({ placeholder: 'Org Tasks', text: this.calendarName })
            .height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
            .onChange((value: string) => this.calendarName = value)
          Text('自动同步间隔（分钟）').fontSize(14).fontColor('#4E5A53').margin({ top: 16 })
          TextInput({ placeholder: '15', text: this.syncInterval })
            .type(InputType.Number).height(44).backgroundColor('#FFFFFF').margin({ top: 8 })
            .onChange((value: string) => this.syncInterval = value)
          if (this.config.repos.some((item: RepoConfig) => item.id === this.repoId)) {
            Button('删除仓库').width('100%').height(44).fontColor('#B3261E').backgroundColor('#FFFFFF')
              .margin({ top: 28 }).onClick(() => this.deleteRepository())
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 20 })
      }
      .layoutWeight(1)
      if (this.message) {
        Text(this.message).fontSize(13).fontColor(this.message.includes('失败') ? '#B3261E' : '#357A55')
          .width('100%').padding({ left: 20, right: 20, bottom: 8 })
      }
      Button(this.saving ? '保存中...' : '保存仓库')
        .width('80%').height(48).backgroundColor('#175C43').enabled(!this.saving)
        .margin({ bottom: 28 }).onClick(() => this.saveConfig())
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
