import { AppDataManager } from '../services/AppDataManager'
import { NativeCoreService } from '../services/NativeCoreService'
import { NotificationManager } from '../services/NotificationManager'
import { PageNavigator, primaryPage } from '../services/PageNavigator'
import { PagePath } from '../services/PagePath'
import { entryNavigation } from '../services/EntryNavigation'
// 应用入口

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { LegacySyncScheduleService } from '../services/LegacySyncScheduleService'
import { BackgroundRepositorySyncService } from '../services/BackgroundRepositorySyncService'
import { RepositorySyncService, SyncStartPolicy, emptyRepositorySyncState } from '../services/RepositorySyncService'
import { UiColor } from '../ui/Theme'
import { DeviceBadgeService } from '../services/DeviceBadgeService'
import { HttpApiService } from '../services/HttpApiService'
import { NotificationPermissionService } from '../services/NotificationPermissionService'
import { SystemRepositoryService } from '../services/SystemRepositoryService'

interface MainPageStorage { entryView?: string; entryMemoCreate?: boolean; entryMemoId?: string }

export default class EntryAbility extends UIAbility {
  private mainStage: window.WindowStage | undefined = undefined
  private initialPath: PagePath = new PagePath([primaryPage('today')])
  private foreground: boolean = false
  private contentReady: boolean = false
  private startupSyncRequested: boolean = false
  private notificationBackgrounded: boolean = false

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    NativeCoreService.start()
    await SystemRepositoryService.ensure(this.context)
    AppDataManager.shared(this.context).start().catch((error: Error): void => { console.error(`初始化共享数据失败：${error.message}`) })
    this.readDestination(want)
    try { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK) }
    catch (error) { console.error('设置应用深色模式失败') }
    if (!AppStorage.has('repositorySync')) AppStorage.setOrCreate('repositorySync', emptyRepositorySyncState())
    NotificationManager.start(this.context).catch((error: Error): void => { console.error(`初始化通知失败：${error.message}`) })
    await LegacySyncScheduleService.remove()
    if (want.parameters?.httpApiEnabled === true) this.startHttpApi()
  }

  private startHttpApi(): void {
    HttpApiService.start(this.context).catch((error: Error): void => {
      console.error(`启动 HTTP 接口失败：${error.message}`)
    })
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam) {
    if (want.parameters?.httpApiEnabled === true) this.startHttpApi()
    else if (want.parameters?.httpApiEnabled === false) {
      HttpApiService.stop().catch((): void => { console.error('停止 HTTP 接口失败') })
    }
    if (!this.readDestination(want) || !this.mainStage) return
    this.loadMainPage(this.mainStage)
  }

  private readDestination(want: Want): boolean {
    const path = entryNavigation(want)
    if (!path) return false
    this.initialPath = path
    return true
  }

  private loadMainPage(stage: window.WindowStage) {
    this.contentReady = false
    PageNavigator.shared.start(this.context)
    const path = this.initialPath
    const page = path.current
    PageNavigator.shared.restore(path)
    const data: MainPageStorage = { entryView: undefined,
      entryMemoCreate: page.params?.create, entryMemoId: page.params?.memoId }
    const storage = new LocalStorage(data)
    stage.loadContent(page.url, storage, (err) => {
      if (err && err.code !== 0) {
        console.error('加载页面失败:', JSON.stringify(err))
        return
      }
      this.contentReady = true
      this.startStartupSync()
      this.checkNotificationPermission()
    })
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    this.mainStage = windowStage
    HttpApiService.attachWindow(windowStage)
    try {
      const mainWindow = await windowStage.getMainWindow()
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: UiColor.surface,
        navigationBarColor: UiColor.surface,
        statusBarContentColor: UiColor.text,
        navigationBarContentColor: UiColor.text
      })
      // 加载主页面
      this.loadMainPage(windowStage)
    } catch (error) { console.error('初始化应用窗口失败') }
  }

  private checkNotificationPermission(): void {
    if (!this.foreground || !this.contentReady) return
    NotificationPermissionService.start(this.context).catch((error: Error): void => {
      console.error(`检查通知授权失败：${error.message}`)
    })
  }

  private startStartupSync(): void {
    if (!this.foreground || !this.contentReady || this.startupSyncRequested) return
    this.startupSyncRequested = true
    RepositorySyncService.start(this.context, { triggerReason: 'appStartup', policy: SyncStartPolicy.Reuse })
  }

  onForeground(): void {
    if (this.notificationBackgrounded) {
      this.notificationBackgrounded = false
      NotificationManager.refresh().catch((error: Error): void => { console.error(`刷新通知失败：${error.message}`) })
    }
    this.foreground = true
    this.startStartupSync()
    DeviceBadgeService.start(this.context)
    this.checkNotificationPermission()
  }

  onBackground(): void {
    this.notificationBackgrounded = true
    this.foreground = false
    NotificationPermissionService.stop()
    DeviceBadgeService.stop()
    BackgroundRepositorySyncService.start(this.context)
  }

  onDestroy(): void {
    DeviceBadgeService.stop()
    AppDataManager.close().catch((): void => { console.error('关闭共享数据失败') })
    HttpApiService.attachWindow(undefined)
    PageNavigator.shared.close().catch((): void => { console.error('关闭页面导航失败') })
    NotificationManager.stop()
    HttpApiService.stop().catch((): void => { console.error('停止 HTTP 接口失败') })
    this.foreground = false
    this.contentReady = false
    NotificationPermissionService.stop()
  }
}
