// 后台同步回调
// WorkScheduler 触发时执行，解析 org 文件并同步到日历

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit'
import { CalendarSync } from '../services/CalendarSync'
import { FileService } from '../services/FileService'
import { preferences } from '@kit.ArkData'
import { WebDavService } from '../services/WebDavService'
import { NativeSyncRecordService } from '../services/NativeSyncRecordService'
import { AppConfigService, APP_CONFIG_PREFERENCES } from '../services/AppConfigService'

export default class SyncWorkExtension extends WorkSchedulerExtensionAbility {
  async onWorkStart(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务开始')
    const syncStartedAt = Date.now()
    let syncSucceeded = false
    let repoId = ''

    try {
      const config = await AppConfigService.load(this.context)
      repoId = config.repoId

      let sourceDir = config.orgDir
      if (config.webdavEnabled) {
        const webdav = await new WebDavService(this.context, config).syncToCache()
        if (!webdav.ok) {
          console.error('WebDAV 同步失败:', webdav.message)
          return
        }
        sourceDir = webdav.localDir
      } else if (!FileService.dirExists(sourceDir)) {
        console.error('org 目录不存在:', sourceDir)
        return
      }

      // 解析任务
      const parsed = await FileService.parseAllTasks(sourceDir)
      if (parsed.errors.length > 0) {
        console.error(`读取 org 文件失败，取消本轮同步: ${parsed.errors[0]}`)
        return
      }
      console.info(`解析到 ${parsed.tasks.length} 个任务`)

      // 同步到日历
      const sync = new CalendarSync(this.context, config.calendarName)
      const ok = await sync.init()
      if (!ok) {
        console.error('初始化日历失败')
        return
      }

      const result = await sync.syncTasks(parsed.tasks)
      console.info(`同步完成: ${result.synced}/${result.total}，新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}`)

      // 更新最后同步时间
      const store = await preferences.getPreferences(this.context, APP_CONFIG_PREFERENCES)
      await store.put('lastSyncTime', Date.now())
      await store.flush()
      syncSucceeded = true
    } catch (e) {
      console.error('后台同步失败:', JSON.stringify(e))
    } finally {
      try {
        if (repoId) {
          await NativeSyncRecordService.recordSyncResult(
            this.context.filesDir,
            repoId,
            syncStartedAt,
            syncSucceeded
          )
        }
      } catch (e) {
        console.warn('Rust 核心服务保存后台同步记录失败:', JSON.stringify(e))
      }
    }
  }

  onWorkStop(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务结束')
  }
}
