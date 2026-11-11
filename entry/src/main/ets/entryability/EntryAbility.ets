// 应用入口
// 注册后台定时同步任务

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { emptyRepositorySyncState } from '../services/RepositorySyncService'
import { preferences } from '@kit.ArkData'
import { UiColor } from '../ui/Theme'
import { CoreTask } from '../services/NativeCoreService'
import { DeviceBadgeService } from '../services/DeviceBadgeService'
import { NotificationPermissionService } from '../services/NotificationPermissionService'

const PREF_NAME = 'org_tasks_config'
const DEFAULT_INTERVAL = 20 // 分钟

interface MainPageStorage { entryTask?: CoreTask; entryView?: string; entryMemoAction?: string; entryMemoId?: string }

export default class EntryAbility extends UIAbility {
  private mainStage: window.WindowStage | undefined = undefined
  private initialPage: string = 'pages/TaskOverview'
  private initialView: string | undefined = undefined
  private taskToEdit: CoreTask | undefined = undefined
  private memoAction: string = ''
  private memoId: string = ''
  private foreground: boolean = false
  private contentReady: boolean = false

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.readDestination(want)
    try { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK) }
    catch (error) { console.error('设置应用深色模式失败') }
    AppStorage.setOrCreate('repositorySync', emptyRepositorySyncState())
    // 注册后台定时任务
    await this.registerBackgroundSync()
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam) {
    if (!this.readDestination(want) || !this.mainStage) return
    this.loadMainPage(this.mainStage)
  }

  private readDestination(want: Want): boolean {
    if (want.parameters?.page !== 'inbox' && want.parameters?.page !== 'taskEdit' && want.parameters?.page !== 'memo') return false
    this.initialPage = want.parameters?.page === 'memo' ? 'pages/TaskOverview' : 'pages/Inbox'
    this.initialView = want.parameters?.page === 'memo' ? 'memo' : undefined
    this.taskToEdit = undefined
    this.memoAction = ''
    this.memoId = ''
    if (want.parameters.page === 'memo') {
      const action = want.parameters.memoAction
      if (typeof action === 'string' && (action === 'create' || action === 'edit')) this.memoAction = action
      if (typeof want.parameters.memoId === 'string') this.memoId = want.parameters.memoId
    }
    if (want.parameters.page === 'taskEdit' && typeof want.parameters.task === 'string') {
      try { this.taskToEdit = JSON.parse(want.parameters.task) as CoreTask }
      catch (error) { console.error('读取任务编辑参数失败') }
    }
    return true
  }

  private loadMainPage(stage: window.WindowStage) {
    this.contentReady = false
    const task = this.taskToEdit
    this.taskToEdit = undefined
    const data: MainPageStorage = {}
    if (task) data.entryTask = task
    if (this.initialView) data.entryView = this.initialView
    data.entryMemoAction = this.memoAction
    data.entryMemoId = this.memoId
    this.memoAction = ''
    this.memoId = ''
    const storage = new LocalStorage(data)
    stage.loadContent(this.initialPage, storage, (err) => {
      if (err && err.code !== 0) {
        console.error('加载页面失败:', JSON.stringify(err))
        return
      }
      this.contentReady = true
      this.checkNotificationPermission()
    })
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    this.mainStage = windowStage
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

  /**
   * 注册 WorkScheduler 后台定时同步
   */
  async registerBackgroundSync() {
    try {
      // 读取配置的同步间隔
      const store = await preferences.getPreferences(this.context, PREF_NAME)
      const intervalMin = await store.get('syncInterval', DEFAULT_INTERVAL) as number

      await BackgroundSyncService.configure(intervalMin)
    } catch (e) {
      console.error('注册后台任务失败:', JSON.stringify(e))
    }
  }

  private checkNotificationPermission(): void {
    if (!this.foreground || !this.contentReady) return
    NotificationPermissionService.start(this.context).catch((error: Error): void => {
      console.error(`检查通知授权失败：${error.message}`)
    })
  }

  onForeground(): void {
    this.foreground = true
    DeviceBadgeService.start(this.context)
    this.checkNotificationPermission()
  }

  onBackground(): void {
    this.foreground = false
    NotificationPermissionService.stop()
    DeviceBadgeService.stop()
  }

  onDestroy(): void {
    this.foreground = false
    this.contentReady = false
    NotificationPermissionService.stop()
    DeviceBadgeService.stop()
  }
}
