import { common } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { AppConfigService } from './AppConfigService'
import { BackgroundSyncPresentation } from './BackgroundSyncPresentation'
import { NativeCoreService } from './NativeCoreService'
import { RepositorySyncService, RepositorySyncState, SyncStartPolicy, SyncStartResult } from './RepositorySyncService'

// 每次退后台至多一个会话；本地变化由 Core 读盘判断，不缓存 dirty 标记。
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
    const presentation = new BackgroundSyncPresentation(context)
    const observer = (state: RepositorySyncState): void => { presentation.update(state) }
    try {
      // 先保护配置读取和 Core 检查，取得数据传输长时任务后立即释放短时任务。
      delayId = backgroundTaskManager.requestSuspendDelay('检查并同步本地修改', (): void => {
        expired = true
        if (delayId !== -1) {
          try { backgroundTaskManager.cancelSuspendDelay(delayId) }
          catch (_) { console.error('释放到期同步检查任务失败') }
          delayId = -1
        }
      }).requestId
      let requested: SyncStartResult | undefined = undefined
      if (RepositorySyncService.runningSync()) {
        requested = RepositorySyncService.start(context, { triggerReason: 'appBackground', policy: SyncStartPolicy.Reject })
      } else {
        const config = await AppConfigService.load(context, false)
        const changed = await NativeCoreService.hasLocalWebDavChanges(config.repos, config.todoDefaults, config.coreSettings)
        if (!changed || expired) return
        if (RepositorySyncService.runningSync()) {
          requested = RepositorySyncService.start(context, { triggerReason: 'appBackground', policy: SyncStartPolicy.Reject })
        }
      }
      await presentation.start()
      if (expired) return
      backgroundTaskManager.cancelSuspendDelay(delayId)
      delayId = -1
      // 已有会话仅延续后台保护；新请求用 Reject，防止准备期间出现并发同步。
      RepositorySyncService.watch(observer)
      const result = requested ?? RepositorySyncService.start(context, {
        triggerReason: 'appBackground', policy: SyncStartPolicy.Reject })
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
