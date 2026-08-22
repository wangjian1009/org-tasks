// 主页面 - 同步按钮 + 状态显示

import { router } from '@kit.ArkUI'
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { CalendarSync } from '../services/CalendarSync'
import { FileService } from '../services/FileService'
import { OrgTask, SyncResult, AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CredentialService } from '../services/CredentialService'
import { WebDavService } from '../services/WebDavService'
import { NativeCoreService } from '../services/NativeCoreService'

const PREF_NAME = 'org_tasks_config'

@Entry
@Component
struct Index {
  @State syncing: boolean = false
  @State lastSync: string = '尚未同步'
  @State taskCount: number = 0
  @State syncMessage: string = ''
  @State config: AppConfig = DEFAULT_CONFIG

  private calendarSync: CalendarSync | undefined = undefined

  aboutToAppear() {
    this.loadConfig()
  }

  async loadConfig() {
    try {
      const context = getContext(this)
      const store = await preferences.getPreferences(context, PREF_NAME)
      const orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
      const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
      const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
      const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
      const webdavEnabled = await store.get('webdavEnabled', DEFAULT_CONFIG.webdavEnabled) as boolean
      const webdavUrl = await store.get('webdavUrl', DEFAULT_CONFIG.webdavUrl) as string
      const webdavUsername = await store.get('webdavUsername', DEFAULT_CONFIG.webdavUsername) as string
      const webdavPassword = await CredentialService.getWebDavPassword(context)
      const lastSyncTime = await store.get('lastSyncTime', 0) as number

      this.config = { orgDir, inboxFile, calendarName, syncInterval, webdavEnabled, webdavUrl, webdavUsername, webdavPassword }
      this.calendarSync = new CalendarSync(context, calendarName)

      if (lastSyncTime > 0) {
        const d = new Date(lastSyncTime)
        this.lastSync = `${d.getMonth() + 1}/${d.getDate()} ${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}`
      }
    } catch (e) {
      console.error('加载配置失败:', JSON.stringify(e))
    }
  }

  async doSync() {
    if (this.syncing) return

    this.syncing = true
    this.syncMessage = '正在同步...'
    let nativeSyncRecorded = false
    let syncSucceeded = false

    try {
      try {
        await NativeCoreService.recordSyncIntent(getContext(this).filesDir, 'manual', true, true)
        nativeSyncRecorded = true
      } catch (e) {
        console.warn('Rust 核心服务登记手动同步失败:', JSON.stringify(e))
      }

      if (!await this.requestSyncPermissions()) {
        this.syncMessage = '需要日历权限才能同步'
        this.syncing = false
        return
      }

      let orgDir = this.config.orgDir
      if (this.config.webdavEnabled) {
        this.syncMessage = '正在从 WebDAV 下载 org 文件...'
        const webdav = await new WebDavService(getContext(this), this.config).syncToCache()
        if (!webdav.ok) {
          this.syncMessage = `WebDAV 同步失败: ${webdav.message}`
          this.syncing = false
          return
        }
        orgDir = webdav.localDir
      } else if (!FileService.dirExists(orgDir)) {
        this.syncMessage = `目录不存在: ${orgDir}`
        this.syncing = false
        return
      }

      // 解析所有 org 文件
      this.syncMessage = '正在解析 org 文件...'
      const parsed = await FileService.parseAllTasks(orgDir)
      if (parsed.errors.length > 0) {
        this.syncMessage = `读取 org 文件失败，已取消同步: ${parsed.errors[0]}`
        this.syncing = false
        return
      }
      this.taskCount = parsed.tasks.length

      // 初始化日历
      this.syncMessage = '正在写入日历...'
      if (!this.calendarSync) {
        this.syncMessage = '配置尚未加载完成'
        this.syncing = false
        return
      }
      const ok = await this.calendarSync.init()
      if (!ok) {
        this.syncMessage = '无法初始化日历，请检查权限'
        this.syncing = false
        return
      }

      const result = await this.calendarSync.syncTasks(parsed.tasks)

      // 保存同步时间
      const context = getContext(this)
      const store = await preferences.getPreferences(context, PREF_NAME)
      await store.put('lastSyncTime', Date.now())
      await store.flush()
      syncSucceeded = true

      const now = new Date()
      this.lastSync = `${now.getMonth() + 1}/${now.getDate()} ${now.getHours()}:${now.getMinutes().toString().padStart(2, '0')}`
      this.syncMessage = `同步完成: ${result.synced}/${result.total} 个任务（新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}）`

      if (result.errors.length > 0) {
        this.syncMessage += `\n${result.errors.length} 个错误`
      }
    } catch (e) {
      this.syncMessage = `同步失败: ${JSON.stringify(e)}`
    } finally {
      if (nativeSyncRecorded) {
        try {
          await NativeCoreService.finishSync(syncSucceeded)
        } catch (e) {
          console.warn('Rust 核心服务完成手动同步失败:', JSON.stringify(e))
        }
      }
      this.syncing = false
    }
  }

  private async requestSyncPermissions(): Promise<boolean> {
    const context = getContext(this)
    const manager = abilityAccessCtrl.createAtManager()
    const permissions: Permissions[] = [
      'ohos.permission.READ_CALENDAR' as Permissions,
      'ohos.permission.WRITE_CALENDAR' as Permissions
    ]
    const requestResult = await manager.requestPermissionsFromUser(context, permissions)
    for (const authResult of requestResult.authResults) {
      if (authResult !== 0) {
        return false
      }
    }
    return true
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('Org Tasks')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
        Blank()
        Button('文件')
          .fontSize(14)
          .onClick(() => {
            router.pushUrl({ url: 'pages/Files' })
          })
        Button('设置')
          .fontSize(14)
          .onClick(() => {
            router.pushUrl({ url: 'pages/Settings' })
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      // 状态信息
      Column() {
        Text(`上次同步: ${this.lastSync}`)
          .fontSize(14)
          .fontColor('#666')
        if (this.taskCount > 0) {
          Text(`共 ${this.taskCount} 个任务`)
            .fontSize(14)
            .fontColor('#666')
            .margin({ top: 4 })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8 })

      // 同步消息
      if (this.syncMessage) {
        Text(this.syncMessage)
          .fontSize(14)
          .fontColor(this.syncMessage.includes('失败') ? '#F44336' : '#4CAF50')
          .width('100%')
          .padding({ left: 20, right: 20, top: 12 })
      }

      Blank()

      // 同步按钮
      Button(this.syncing ? '同步中...' : '同步到日历')
        .type(ButtonType.Capsule)
        .width('80%')
        .height(48)
        .fontSize(18)
        .enabled(!this.syncing)
        .onClick(() => this.doSync())

      // 新增任务按钮
      Button('新增任务')
        .type(ButtonType.Capsule)
        .width('80%')
        .height(48)
        .fontSize(18)
        .backgroundColor('#2196F3')
        .margin({ top: 12, bottom: 40 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/AddTask' })
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
