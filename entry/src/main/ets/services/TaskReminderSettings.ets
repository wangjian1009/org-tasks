import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export interface TaskReminderConfiguration { enabled: boolean; ringDuration: number }

// 本机偏好独立于任务属性与仓库配置；写入失败恢复原值。
export class TaskReminderSettings {
  static async load(context: Context): Promise<TaskReminderConfiguration> {
    const store = await PreferencesStore.open(context, 'org_tasks_reminders')
    const enabled = await store.get('enabled', false)
    const duration = await store.get('ringDuration', 30)
    if (typeof enabled !== 'boolean' || typeof duration !== 'number' || !Number.isInteger(duration) || duration < 1 || duration > 1800) {
      throw new Error('任务提醒设置无效，请重新保存')
    }
    return { enabled, ringDuration: duration }
  }

  private static queue: Promise<void> = Promise.resolve()
  static save(context: Context, config: TaskReminderConfiguration): Promise<void> {
    const work = TaskReminderSettings.queue.then(async (): Promise<void> => {
      if (!Number.isInteger(config.ringDuration) || config.ringDuration < 1 || config.ringDuration > 1800) throw new Error('响铃时长须为 1 至 1800 秒')
      const store = await PreferencesStore.open(context, 'org_tasks_reminders')
      const enabled = await store.get('enabled', false)
      const duration = await store.get('ringDuration', 30)
      try {
        await store.put('enabled', config.enabled)
        await store.put('ringDuration', config.ringDuration)
        await store.flush()
      } catch (error) {
        try { await store.put('enabled', enabled); await store.put('ringDuration', duration); await store.flush() }
        catch (_) { console.error('恢复任务提醒设置失败') }
        throw error as Error
      }
    })
    TaskReminderSettings.queue = work.catch((): void => {})
    return work
  }
}
