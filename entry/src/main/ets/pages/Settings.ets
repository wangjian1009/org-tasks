// 设置页面
// 配置 org 目录、inbox 文件、日历名称、同步间隔

import { router } from '@kit.ArkUI'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CredentialService } from '../services/CredentialService'
import { WebDavService } from '../services/WebDavService'

const PREF_NAME = 'org_tasks_config'

@Entry
@Component
struct Settings {
  @State orgDir: string = DEFAULT_CONFIG.orgDir
  @State inboxFile: string = DEFAULT_CONFIG.inboxFile
  @State calendarName: string = DEFAULT_CONFIG.calendarName
  @State syncInterval: string = '15'
  @State webdavEnabled: boolean = DEFAULT_CONFIG.webdavEnabled
  @State webdavUrl: string = DEFAULT_CONFIG.webdavUrl
  @State webdavUsername: string = DEFAULT_CONFIG.webdavUsername
  @State webdavPassword: string = DEFAULT_CONFIG.webdavPassword
  @State saving: boolean = false
  @State testing: boolean = false
  @State message: string = ''

  aboutToAppear() {
    this.loadConfig()
  }

  async loadConfig() {
    try {
      const context = getContext(this)
      const store = await preferences.getPreferences(context, PREF_NAME)
      this.orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
      this.inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
      this.calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
      const interval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
      this.syncInterval = interval.toString()
      this.webdavEnabled = await store.get('webdavEnabled', DEFAULT_CONFIG.webdavEnabled) as boolean
      this.webdavUrl = await store.get('webdavUrl', DEFAULT_CONFIG.webdavUrl) as string
      this.webdavUsername = await store.get('webdavUsername', DEFAULT_CONFIG.webdavUsername) as string
      this.webdavPassword = await CredentialService.getWebDavPassword(context)
    } catch (e) {
      console.error('加载配置失败:', JSON.stringify(e))
    }
  }

  async saveConfig() {
    this.saving = true
    this.message = ''

    try {
      const context = getContext(this)
      await CredentialService.setWebDavPassword(this.webdavPassword)
      const store = await preferences.getPreferences(context, PREF_NAME)
      await store.put('orgDir', this.orgDir.trim())
      await store.put('inboxFile', this.inboxFile.trim())
      await store.put('calendarName', this.calendarName.trim())
      await store.put('syncInterval', parseInt(this.syncInterval) || 15)
      await store.put('webdavEnabled', this.webdavEnabled)
      await store.put('webdavUrl', this.webdavUrl.trim())
      await store.put('webdavUsername', this.webdavUsername.trim())
      await store.delete('webdavPassword')
      await store.flush()

      this.message = '设置已保存'
      setTimeout(() => {
        router.back()
      }, 1000)
    } catch (e) {
      this.message = '保存失败: ' + JSON.stringify(e)
    }

    this.saving = false
  }

  async testWebDavConnection() {
    this.testing = true
    this.message = ''
    try {
      const context = getContext(this)
      const config: AppConfig = {
        orgDir: this.orgDir.trim(),
        inboxFile: this.inboxFile.trim(),
        calendarName: this.calendarName.trim(),
        syncInterval: parseInt(this.syncInterval) || 15,
        webdavEnabled: true,
        webdavUrl: this.webdavUrl.trim(),
        webdavUsername: this.webdavUsername.trim(),
        webdavPassword: this.webdavPassword
      }
      const result = await new WebDavService(context, config).testConnection()
      this.message = result.ok ? result.message : `连接失败: ${result.message}`
    } catch (e) {
      this.message = `连接失败: ${JSON.stringify(e)}`
    }
    this.testing = false
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('设置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })

      Scroll() {
        Column() {
          Row() {
            Text('使用 WebDAV 同步')
              .fontSize(14)
              .fontColor('#666')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.webdavEnabled })
              .onChange((enabled: boolean) => { this.webdavEnabled = enabled })
          }
          .width('100%')

          if (this.webdavEnabled) {
            Text('WebDAV 目录地址')
              .fontSize(14)
              .fontColor('#666')
              .margin({ top: 16 })
            TextInput({ placeholder: 'https://dav.example.com/org-tasks/', text: this.webdavUrl })
              .onChange((value: string) => { this.webdavUrl = value })
              .margin({ top: 8 })
              .height(44)
            Text('填写包含 .org 文件的远端目录地址')
              .fontSize(12)
              .fontColor('#999')
              .margin({ top: 4 })

            Text('用户名')
              .fontSize(14)
              .fontColor('#666')
              .margin({ top: 16 })
            TextInput({ placeholder: 'WebDAV 用户名', text: this.webdavUsername })
              .onChange((value: string) => { this.webdavUsername = value })
              .margin({ top: 8 })
              .height(44)

            Text('密码或应用专用密码')
              .fontSize(14)
              .fontColor('#666')
              .margin({ top: 16 })
            TextInput({ placeholder: 'WebDAV 密码', text: this.webdavPassword })
              .type(InputType.Password)
              .onChange((value: string) => { this.webdavPassword = value })
              .margin({ top: 8 })
              .height(44)

            Button(this.testing ? '测试中...' : '测试 WebDAV 连接')
              .width('100%')
              .height(40)
              .margin({ top: 16 })
              .enabled(!this.testing)
              .onClick(() => this.testWebDavConnection())
          } else {
            Text('Org 文件目录')
              .fontSize(14)
              .fontColor('#666')
              .margin({ top: 16 })
            TextInput({ placeholder: '本地 org 文件目录路径', text: this.orgDir })
              .onChange((value: string) => { this.orgDir = value })
              .margin({ top: 8 })
              .height(44)
            Text('应用会直接读取此目录中的 org 文件')
              .fontSize(12)
              .fontColor('#999')
              .margin({ top: 4 })
          }

          // Inbox 文件
          Text('新增任务文件')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: 'inbox.org', text: this.inboxFile })
            .onChange((value: string) => { this.inboxFile = value })
            .margin({ top: 8 })
            .height(44)
          Text('新增的任务会追加到此文件（相对于 Org 目录）')
            .fontSize(12)
            .fontColor('#999')
            .margin({ top: 4 })

          // 日历名称
          Text('日历名称')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: 'Org Tasks', text: this.calendarName })
            .onChange((value: string) => { this.calendarName = value })
            .margin({ top: 8 })
            .height(44)
          Text('系统日历中显示的日历名称')
            .fontSize(12)
            .fontColor('#999')
            .margin({ top: 4 })

          // 同步间隔
          Text('自动同步间隔（分钟）')
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 16 })
          TextInput({ placeholder: '15', text: this.syncInterval })
            .type(InputType.Number)
            .onChange((value: string) => { this.syncInterval = value })
            .margin({ top: 8 })
            .height(44)
          Text('后台自动同步的间隔时间，建议 10-30 分钟')
            .fontSize(12)
            .fontColor('#999')
            .margin({ top: 4 })

          // 重置按钮
          Button('恢复默认')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontColor('#FF5722')
            .margin({ top: 24 })
            .onClick(() => {
              this.orgDir = DEFAULT_CONFIG.orgDir
              this.inboxFile = DEFAULT_CONFIG.inboxFile
              this.calendarName = DEFAULT_CONFIG.calendarName
              this.syncInterval = DEFAULT_CONFIG.syncInterval.toString()
              this.webdavEnabled = DEFAULT_CONFIG.webdavEnabled
              this.webdavUrl = DEFAULT_CONFIG.webdavUrl
              this.webdavUsername = DEFAULT_CONFIG.webdavUsername
              this.webdavPassword = DEFAULT_CONFIG.webdavPassword
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)

      // 消息
      if (this.message) {
        Text(this.message)
          .fontSize(14)
          .fontColor(this.message.includes('失败') ? '#F44336' : '#4CAF50')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

      // 保存按钮
      Button(this.saving ? '保存中...' : '保存设置')
        .type(ButtonType.Capsule)
        .width('80%')
        .height(48)
        .fontSize(18)
        .enabled(!this.saving)
        .margin({ bottom: 40 })
        .onClick(() => this.saveConfig())
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
