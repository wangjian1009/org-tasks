// 应用入口
// 注册后台定时同步任务

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { BackgroundSyncService } from '../services/BackgroundSyncService'
import { emptyRepositorySyncState } from '../services/RepositorySyncService'
import { preferences } from '@kit.ArkData'
import { UiColor } from '../ui/Theme'

const PREF_NAME = 'org_tasks_config'
const DEFAULT_INTERVAL = 20 // 分钟

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    AppStorage.setOrCreate('repositorySync', emptyRepositorySyncState())
    // 注册后台定时任务
    await this.registerBackgroundSync()
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    const mainWindow = await windowStage.getMainWindow()
    await mainWindow.setWindowSystemBarProperties({
      statusBarColor: UiColor.surface,
      navigationBarColor: UiColor.surface,
      statusBarContentColor: UiColor.text,
      navigationBarContentColor: UiColor.text
    })
    // 加载主页面
    windowStage.loadContent('pages/TaskOverview', (err) => {
      if (err && err.code !== 0) {
        console.error('加载页面失败:', JSON.stringify(err))
      }
    })
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

  onDestroy() {
  }
}
