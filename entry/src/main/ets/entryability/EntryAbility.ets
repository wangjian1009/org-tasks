// 应用入口
// 注册后台定时同步任务

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { workScheduler } from '@kit.BackgroundTasksKit'
import { preferences } from '@kit.ArkData'

const PREF_NAME = 'org_tasks_config'
const WORK_ID = 1001
const DEFAULT_INTERVAL = 15 // 分钟
const BUNDLE_NAME = 'com.example.orgtasks'
const WORK_ABILITY_NAME = 'SyncWorkExtension'

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    // 注册后台定时任务
    await this.registerBackgroundSync()
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    // 加载主页面
      windowStage.loadContent('pages/Agenda', (err) => {
      if (err) {
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

      // 创建后台任务
      const workInfo: workScheduler.WorkInfo = {
        workId: WORK_ID,
        bundleName: BUNDLE_NAME,
        abilityName: WORK_ABILITY_NAME,
        isCharging: false,
        isPersisted: true,
        isRepeat: true,
        repeatCycleTime: intervalMin * 60 * 1000, // 转为毫秒
        isDeepIdle: true,
        parameters: {
          'action': 'sync'
        }
      }

      try {
        await workScheduler.getWorkStatus(WORK_ID)
      } catch {
        await workScheduler.startWork(workInfo)
        console.info(`后台同步已注册，间隔 ${intervalMin} 分钟`)
      }
    } catch (e) {
      console.error('注册后台任务失败:', JSON.stringify(e))
    }
  }

  onDestroy() {
    // 可选：取消后台任务
    // workScheduler.cancelWork({ workId: WORK_ID } as workScheduler.WorkInfo)
  }
}
