import { localizedText } from '../ui/LocalizedText'
import { common } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { AppConfigService } from './AppConfigService'
import { BackgroundSyncPresentation } from './BackgroundSyncPresentation'
import { DataSetManager } from './DataSetManager'
import { CoreNotificationsState, NotificationManager } from './NotificationManager'
import { RepositorySyncService, RepositorySyncState, SyncStartPolicy, SyncStartResult } from './RepositorySyncService'

// 每次退后台至多一个会话；是否新建会话由共享本地同步通知决定。
export class BackgroundRepositorySyncService {
  private static operation: Promise<void> | undefined = undefined

  static start(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundRepositorySyncService.operation) {
      BackgroundRepositorySyncService.operation = BackgroundRepositorySyncService.run(context).finally((): void => {
        BackgroundRepositorySyncService.operation = undefined
      })
    }
    return BackgroundRepositorySyncService.operation
  }

  private static async run(context: common.UIAbilityContext): Promise<void> {
    let delayId: number = -1
    let expired: boolean = false
    let cancelNotificationWait: (() => void) | undefined = undefined
    const presentation = new BackgroundSyncPresentation(context)
    const observer = (state: RepositorySyncState): void => { presentation.update(state) }
    try {
      // 保护排队修改、通知归并及配置读取，取得长时任务后释放短时任务。
      delayId = backgroundTaskManager.requestSuspendDelay(localizedText($r('app.string.text_check_and_sync_local_changes')), (): void => {
        expired = true
        cancelNotificationWait?.()
        if (delayId !== -1) {
          try { backgroundTaskManager.cancelSuspendDelay(delayId) }
          catch (_) { console.error('释放到期同步检查任务失败') }
          delayId = -1
        }
      }).requestId
      let requested: SyncStartResult | undefined = undefined
      if (RepositorySyncService.runningSync()) {
        requested = RepositorySyncService.start(context, { source: 'background', policy: SyncStartPolicy.Reject })
      }
      try { await DataSetManager.flushAll() }
      catch (_) { console.error('页面缓存保存失败') }
      if (expired) return
      if (!requested) {
        let complete = (_required: boolean): void => {}
        const decision = new Promise<boolean>((resolve): void => { complete = resolve })
        cancelNotificationWait = (): void => { complete(false) }
        const unsubscribe = NotificationManager.subscribe((snapshot: CoreNotificationsState): void => {
          complete(snapshot.notifications.some(item => item.type === 'syncRequired'))
        })
        const syncRequired = await decision
        unsubscribe()
        cancelNotificationWait = undefined
        if (!syncRequired || expired) return
        const config = await AppConfigService.load(context, false)
        if (!config.repos.some(repo => repo.webdavEnabled) || expired) return
        if (RepositorySyncService.runningSync()) {
          requested = RepositorySyncService.start(context, { source: 'background', policy: SyncStartPolicy.Reject })
        }
      }
      await presentation.start()
      if (expired) return
      backgroundTaskManager.cancelSuspendDelay(delayId)
      delayId = -1
      // 已有会话仅延续后台保护；新请求用 Reject，防止准备期间出现并发同步。
      RepositorySyncService.watch(observer)
      const result = requested ?? RepositorySyncService.start(context, {
        source: 'background', policy: SyncStartPolicy.Reject })
      await (result.kind === 'rejected' ? result.active.completion : result.handle.completion)
    } catch (_) {
      // 不在后台弹授权或错误窗口，也不把失败标记为已同步；下次退后台可重试。
      console.error('退后台自动同步失败')
    } finally {
      RepositorySyncService.stopWatching(observer)
      try { await presentation.finish() }
      catch (_) { console.error('释放后台同步任务失败') }
      if (delayId !== -1) {
        try { backgroundTaskManager.cancelSuspendDelay(delayId) }
        catch (_) { console.error('释放同步检查短时任务失败') }
      }
    }
  }
}
