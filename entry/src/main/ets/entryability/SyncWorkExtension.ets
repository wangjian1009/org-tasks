// 后台同步回调
// WorkScheduler 触发时执行，解析 org 文件并同步到日历

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit'
import { CalendarSync } from '../services/CalendarSync'
import { preferences } from '@kit.ArkData'
import { NativeCoreService } from '../services/NativeCoreService'
import { AppConfigService, APP_CONFIG_PREFERENCES } from '../services/AppConfigService'

export default class SyncWorkExtension extends WorkSchedulerExtensionAbility {
  async onWorkStart(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务开始')
    try {
      const config = await AppConfigService.load(this.context)
      const tasks = config.repos.some((repository) => repository.webdavEnabled)
        ? await NativeCoreService.syncWorkspaceWebDav(config.repos, undefined, config.todoDefaults)
        : await NativeCoreService.loadWorkspace(config.repos, config.todoDefaults)
      console.info(`core workspace 提供 ${tasks.length} 个任务`)

      // 同步到日历
      const sync = new CalendarSync(this.context, config.calendarName)
      const ok = await sync.init()
      if (!ok) {
        console.error('初始化日历失败')
        return
      }

      const result = await sync.syncTasks(tasks)
      console.info(`同步完成: ${result.synced}/${result.total}，新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}`)

      // 更新最后同步时间
      const store = await preferences.getPreferences(this.context, APP_CONFIG_PREFERENCES)
      await store.put('lastSyncTime', Date.now())
      await store.flush()
    } catch (e) {
      console.error('后台同步失败:', JSON.stringify(e))
    }
  }

  onWorkStop(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务结束')
  }
}
