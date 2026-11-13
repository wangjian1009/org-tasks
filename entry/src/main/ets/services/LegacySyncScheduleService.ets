import { workScheduler } from '@kit.BackgroundTasksKit'

// 仅取消旧版本持久化的同步作业，不注册或启动任何调度。
export class LegacySyncScheduleService {
  static async remove(): Promise<void> {
    try {
      const works = await workScheduler.obtainAllWorks()
      for (const work of works) {
        if (work.workId === 1001 && work.abilityName === 'SyncWorkExtension') {
          workScheduler.stopWork(work, true)
        }
      }
    } catch (_) {
      // 不记录完成标记，下次启动继续清理；失败不影响主界面和退出同步。
      console.error('取消旧版定时同步作业失败')
    }
  }
}
