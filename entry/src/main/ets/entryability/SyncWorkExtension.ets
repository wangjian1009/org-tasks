// 后台同步回调
// WorkScheduler 触发时执行，解析 org 文件并同步到日历

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit'
import { CalendarSync } from '../services/CalendarSync'
import { FileService } from '../services/FileService'
import { DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'

const PREF_NAME = 'org_tasks_config'

export default class SyncWorkExtension extends WorkSchedulerExtensionAbility {
  async onWorkStart(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务开始')

    try {
      // 读取配置
      const store = await preferences.getPreferences(this.context, PREF_NAME)
      const orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
      const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string

      // 检查目录
      if (!FileService.dirExists(orgDir)) {
        console.error('org 目录不存在:', orgDir)
        return
      }

      // 解析任务
      const tasks = await FileService.parseAllTasks(orgDir)
      console.info(`解析到 ${tasks.length} 个任务`)

      // 同步到日历
      const sync = new CalendarSync(this.context, calendarName)
      const ok = await sync.init()
      if (!ok) {
        console.error('初始化日历失败')
        return
      }

      const result = await sync.syncTasks(tasks, new Set<string>())
      console.info(`同步完成: ${result.synced}/${result.total}`)

      // 更新最后同步时间
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
