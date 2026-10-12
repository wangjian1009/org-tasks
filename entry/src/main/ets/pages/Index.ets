// 主页面 - 同步按钮 + 状态显示

import { router } from '@kit.ArkUI'
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { CalendarSync } from '../services/CalendarSync'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CoreWebDavSyncEvent, NativeCoreService } from '../services/NativeCoreService'
import { AppConfigService, APP_CONFIG_PREFERENCES } from '../services/AppConfigService'

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
      const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
      const lastSyncTime = await store.get('lastSyncTime', 0) as number

      this.config = await AppConfigService.load(context)
      this.calendarSync = new CalendarSync(context, this.config.calendarName)

      const workspace = await NativeCoreService.loadWorkspace(this.config.repos)
      this.taskCount = workspace.tasks.length

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
    try {
      if (!await this.requestSyncPermissions()) {
        this.syncMessage = '需要日历权限才能同步'
        this.syncing = false
        return
      }

      const hasWebDav = this.config.repos.some((repository) => repository.webdavEnabled)
      this.syncMessage = hasWebDav ? '正在通过 core 同步 WebDAV...' : '正在通过 core 加载仓库...'
      const workspace = hasWebDav
        ? await NativeCoreService.syncWorkspaceWebDav(this.config.repos, (event: CoreWebDavSyncEvent) => this.updateWebDavProgress(event))
        : await NativeCoreService.loadWorkspace(this.config.repos)
      this.taskCount = workspace.tasks.length

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

      const result = await this.calendarSync.syncTasks(workspace.tasks)

      // 保存同步时间
      const context = getContext(this)
      const store = await preferences.getPreferences(context, APP_CONFIG_PREFERENCES)
      await store.put('lastSyncTime', Date.now())
      await store.flush()
      const now = new Date()
      this.lastSync = `${now.getMonth() + 1}/${now.getDate()} ${now.getHours()}:${now.getMinutes().toString().padStart(2, '0')}`
      const coreResult = workspace.sync ? ` · core ${workspace.sync.result}` : ''
      this.syncMessage = `同步完成: ${result.synced}/${result.total} 个任务（新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}）${coreResult}`

      if (result.errors.length > 0) {
        this.syncMessage += `\n${result.errors.length} 个错误`
      }
    } catch (e) {
      this.syncMessage = `同步失败: ${JSON.stringify(e)}`
    } finally {
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

  private updateWebDavProgress(event: CoreWebDavSyncEvent) {
    switch (event.type) {
      case 'listingStarted':
        this.syncMessage = '正在读取 WebDAV 文件列表...'
        break
      case 'listed':
        this.syncMessage = `已发现 ${event.files} 个远端文件`
        break
      case 'fileStarted':
        this.syncMessage = `正在同步 ${event.index + 1}/${event.total}: ${event.path}`
        break
      case 'fileProcessed':
        this.syncMessage = `已处理 ${event.path}`
        break
      case 'finished':
        this.syncMessage = `WebDAV 同步${event.result === 'succeeded' ? '完成' : '结束'}，共 ${event.files} 个文件`
        break
    }
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('Org Tasks')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text('任务同步工作台')
            .fontSize(12)
            .fontColor('#65746B')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        Button('工作区')
          .fontSize(14)
          .backgroundColor('#E6F1EC')
          .fontColor('#175C43')
          .onClick(() => {
            router.pushUrl({ url: 'pages/Workspace' })
          })
        Button('设置')
          .fontSize(14)
          .margin({ left: 8 })
          .backgroundColor('#F0F2F1')
          .fontColor('#34423B')
          .onClick(() => {
            router.pushUrl({ url: 'pages/Settings' })
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 18 })

      Scroll() {
        Column({ space: 20 }) {
          Column() {
            Text('同步状态')
              .fontSize(14)
              .fontColor('#65746B')
            Text(this.lastSync === '尚未同步' ? '等待首次同步' : `上次同步 ${this.lastSync}`)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .margin({ top: 6 })
            Text(this.config.repos.some((repository) => repository.webdavEnabled) ? 'WebDAV 缓存将写入系统日历' : '本地仓库将写入系统日历')
              .fontSize(13)
              .fontColor('#65746B')
              .margin({ top: 8 })
          }
          .width('100%')
          .backgroundColor('#E6F1EC')
          .padding(20)

          Row() {
            Column() {
              Text(this.taskCount.toString())
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor('#175C43')
              Text('已发现任务')
                .fontSize(12)
                .fontColor('#65746B')
            }
            .layoutWeight(1)
            Column() {
              Text(this.config.calendarName || 'Org Tasks')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('目标日历')
                .fontSize(12)
                .fontColor('#65746B')
                .margin({ top: 4 })
            }
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 4, right: 4 })

          Text('快捷入口')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Row() {
            Button('日程')
              .layoutWeight(1)
              .height(44)
              .backgroundColor('#FFFFFF')
              .fontColor('#175C43')
              .onClick(() => router.pushUrl({ url: 'pages/Agenda' }))
            Button('笔记本')
              .layoutWeight(1)
              .height(44)
              .margin({ left: 8 })
              .backgroundColor('#FFFFFF')
              .fontColor('#175C43')
              .onClick(() => router.pushUrl({ url: 'pages/Files' }))
            Button('搜索')
              .layoutWeight(1)
              .height(44)
              .margin({ left: 8 })
              .backgroundColor('#FFFFFF')
              .fontColor('#175C43')
              .onClick(() => router.pushUrl({ url: 'pages/Search' }))
          }
          .width('100%')

          if (this.syncMessage) {
            Text(this.syncMessage)
              .fontSize(13)
              .fontColor(this.syncMessage.includes('失败') ? '#B3261E' : '#175C43')
              .width('100%')
              .backgroundColor('#FFFFFF')
              .padding(14)
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 18 })
      }
      .layoutWeight(1)

      Row() {
        Button('新增任务')
          .layoutWeight(1)
          .height(48)
          .backgroundColor('#FFFFFF')
          .fontColor('#175C43')
          .onClick(() => {
            router.pushUrl({ url: 'pages/AddTask' })
          })
        Button(this.syncing ? '同步中...' : '同步到日历')
          .layoutWeight(2)
          .height(48)
          .margin({ left: 10 })
          .backgroundColor('#175C43')
          .enabled(!this.syncing)
          .onClick(() => this.doSync())
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8F7')
  }
}
