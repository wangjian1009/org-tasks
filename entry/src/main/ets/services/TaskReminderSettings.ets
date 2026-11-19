import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export interface TaskReminderConfiguration { enabled: boolean }

// 仅保存本机开关；事件标记保存在日历中，不持久化 eventId 映射。
export class TaskReminderSettings {
  static async load(context: Context): Promise<TaskReminderConfiguration> {
    const store = await PreferencesStore.open(context, 'org_tasks_reminders')
    const enabled = await store.get('enabled', false)
    if (typeof enabled !== 'boolean') throw new Error('任务提醒设置无效，请重新保存')
    return { enabled }
  }

  private static queue: Promise<void> = Promise.resolve()
  static save(context: Context, config: TaskReminderConfiguration): Promise<void> {
    const work = TaskReminderSettings.queue.then(async (): Promise<void> => {
      const store = await PreferencesStore.open(context, 'org_tasks_reminders')
      const enabled = await store.get('enabled', false)
      try { await store.put('enabled', config.enabled); await store.flush() }
      catch (error) {
        try { await store.put('enabled', enabled); await store.flush() }
        catch (_) { console.error('恢复任务提醒设置失败') }
        throw error as Error
      }
    })
    TaskReminderSettings.queue = work.catch((): void => {})
    return work
  }
}
