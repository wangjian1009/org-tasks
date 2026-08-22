// 后台同步回调
// WorkScheduler 触发时执行，解析 org 文件并同步到日历

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit'
import { CalendarSync } from '../services/CalendarSync'
import { FileService } from '../services/FileService'
import { AppConfig, DEFAULT_CONFIG } from '../models/OrgTask'
import { preferences } from '@kit.ArkData'
import { CredentialService } from '../services/CredentialService'
import { WebDavService } from '../services/WebDavService'
import { NativeCoreService } from '../services/NativeCoreService'

const PREF_NAME = 'org_tasks_config'

export default class SyncWorkExtension extends WorkSchedulerExtensionAbility {
  async onWorkStart(workInfo: workScheduler.WorkInfo) {
    console.info('后台同步任务开始')

    try {
      try {
        await NativeCoreService.recordSyncIntent('background', true, false)
      } catch (e) {
        console.warn('Rust 核心服务登记后台同步失败:', JSON.stringify(e))
      }

      // 读取配置
      const store = await preferences.getPreferences(this.context, PREF_NAME)
      const orgDir = await store.get('orgDir', DEFAULT_CONFIG.orgDir) as string
      const inboxFile = await store.get('inboxFile', DEFAULT_CONFIG.inboxFile) as string
      const calendarName = await store.get('calendarName', DEFAULT_CONFIG.calendarName) as string
      const syncInterval = await store.get('syncInterval', DEFAULT_CONFIG.syncInterval) as number
      const webdavEnabled = await store.get('webdavEnabled', DEFAULT_CONFIG.webdavEnabled) as boolean
      const webdavUrl = await store.get('webdavUrl', DEFAULT_CONFIG.webdavUrl) as string
      const webdavUsername = await store.get('webdavUsername', DEFAULT_CONFIG.webdavUsername) as string
      const webdavPassword = await CredentialService.getWebDavPassword(this.context)
      const config: AppConfig = {
        orgDir, inboxFile, calendarName, syncInterval,
        webdavEnabled, webdavUrl, webdavUsername, webdavPassword
      }

      let sourceDir = orgDir
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
      const sync = new CalendarSync(this.context, calendarName)
      const ok = await sync.init()
      if (!ok) {
        console.error('初始化日历失败')
        return
      }

      const result = await sync.syncTasks(parsed.tasks)
      console.info(`同步完成: ${result.synced}/${result.total}，新增 ${result.created}，更新 ${result.updated}，删除 ${result.deleted}`)

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
