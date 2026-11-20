import { Context } from '@kit.AbilityKit'
import { notificationManager } from '@kit.NotificationKit'
import { AppDataManager } from './AppDataManager'
import { CoreNotificationsState, NotificationManager } from './NotificationManager'

interface BadgeRequest { app: AppDataManager; settle: boolean }

// 只向系统写角标；任务计数与外部刷新由全局 DataSet 提供。
export class DeviceBadgeService {
  private static foreground: Context | undefined = undefined
  private static readonly stops: (() => void)[] = []
  private static stopNotifications: (() => void) | undefined = undefined
  private static conflicts: number | undefined = undefined
  private static pending: BadgeRequest | undefined = undefined
  private static revision: number = 0
  private static running: Promise<void> | undefined = undefined
  private static changed = (): void => {
    const context = DeviceBadgeService.foreground
    if (context && AppDataManager.shared(context).badgeCount() !== undefined) DeviceBadgeService.refresh(context)
  }
  private static notificationsChanged = (snapshot: CoreNotificationsState): void => {
    const conflicts = snapshot.notifications.filter(item => item.type === 'syncConflict').length
    if (conflicts === DeviceBadgeService.conflicts) return
    DeviceBadgeService.conflicts = conflicts
    if (DeviceBadgeService.stopNotifications) DeviceBadgeService.changed()
  }

  static start(context: Context): void {
    if (!DeviceBadgeService.foreground) {
      const app = AppDataManager.shared(context)
      for (const name of ['badgeDeadline', 'inboxTasks', 'inboxFile']) DeviceBadgeService.stops.push(app.dataSet(name).subscribe(DeviceBadgeService.changed))
    }
    DeviceBadgeService.foreground = context
    DeviceBadgeService.refresh(context)
  }
  static stop(): void {
    DeviceBadgeService.foreground = undefined
    DeviceBadgeService.pending = undefined; DeviceBadgeService.revision++
    for (const stop of DeviceBadgeService.stops) stop()
    DeviceBadgeService.stops.length = 0
  }
  static close(): void {
    DeviceBadgeService.stop()
    DeviceBadgeService.stopNotifications?.()
    DeviceBadgeService.stopNotifications = undefined
    DeviceBadgeService.conflicts = undefined
  }
  static refresh(context: Context, existingOnly: boolean = false): Promise<void> {
    const app = existingOnly ? AppDataManager.active : AppDataManager.shared(context)
    if (!app) return Promise.resolve()
    if (!DeviceBadgeService.stopNotifications) {
      DeviceBadgeService.stopNotifications = NotificationManager.subscribe(DeviceBadgeService.notificationsChanged)
    }
    DeviceBadgeService.pending = { app, settle: existingOnly }; DeviceBadgeService.revision++
    if (!DeviceBadgeService.running) DeviceBadgeService.running = DeviceBadgeService.drain().finally((): void => { DeviceBadgeService.running = undefined })
    return DeviceBadgeService.running
  }
  private static async drain(): Promise<void> {
    while (DeviceBadgeService.pending) {
      const request = DeviceBadgeService.pending
      DeviceBadgeService.pending = undefined
      const revision = DeviceBadgeService.revision
      try {
        const app = request.app
        await app.start()
        if (request.settle) {
          try { await app.manager.flush() } catch (_) { console.error('保存共享数据失败') }
        }
        const count = app.badgeCount()
        const conflicts = DeviceBadgeService.conflicts
        if (count === undefined || conflicts === undefined || revision !== DeviceBadgeService.revision) continue
        await notificationManager.setBadgeNumber(count + conflicts)
      } catch (_) { console.error('更新设备提示计数失败') }
    }
  }
}
