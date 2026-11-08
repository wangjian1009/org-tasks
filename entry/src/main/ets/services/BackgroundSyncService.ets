import { workScheduler } from '@kit.BackgroundTasksKit'

// 入口和设置页共用调度配置，修改间隔时替换原有作业。
export class BackgroundSyncService {
  static async configure(intervalMinutes: number): Promise<void> {
    // 系统要求重复作业至少间隔 20 分钟。
    const cycle = Math.max(20, intervalMinutes) * 60 * 1000
    let current: workScheduler.WorkInfo | undefined = undefined
    try { current = await workScheduler.getWorkStatus(1001) } catch (_) {}
    if (current?.repeatCycleTime === cycle) return
    try {
      if (current) workScheduler.stopWork(current, true)
      workScheduler.startWork({
        workId: 1001,
        bundleName: 'com.example.orgtasks',
        abilityName: 'SyncWorkExtension',
        isCharging: false,
        isPersisted: true,
        isRepeat: true,
        repeatCycleTime: cycle,
        isDeepIdle: true,
        parameters: { 'action': 'sync' }
      })
    } catch (error) { throw new Error('配置后台同步失败，请检查系统后台任务权限后重试') }
  }
}
