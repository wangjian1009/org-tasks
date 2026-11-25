import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'
import { DEFAULT_EVENT_DURATION_MINUTES } from './CalendarEventProjection'

export interface TaskReminderConfiguration { enabled: boolean; eventDurationMinutes: number }
export interface TaskReminderPatch { enabled?: boolean; eventDurationMinutes?: number }

function validate(config: TaskReminderConfiguration): void {
  if (typeof config.enabled !== 'boolean') throw new Error(localizedText($r('app.string.text_task_alarm_settings_invalid_save')))
  if (!Number.isInteger(config.eventDurationMinutes) || config.eventDurationMinutes < 1 || config.eventDurationMinutes > 1440) {
    throw new Error(localizedText($r('app.string.text_the_duration_of_the_event_must_be')))
  }
}

// 只保存本机开关与事件时长；串行读取后合并修改，避免两个设置互相覆盖。
export class TaskReminderSettings {
  static async load(context: Context): Promise<TaskReminderConfiguration> {
    const store = await PreferencesStore.open(context, 'org_tasks_reminders')
    const config: TaskReminderConfiguration = { enabled: await store.get('enabled', false) as boolean,
      eventDurationMinutes: await store.get('eventDurationMinutes', DEFAULT_EVENT_DURATION_MINUTES) as number }
    validate(config)
    return config
  }

  private static queue: Promise<void> = Promise.resolve()
  static save(context: Context, patch: TaskReminderPatch): Promise<void> {
    const work = TaskReminderSettings.queue.then(async (): Promise<void> => {
      const store = await PreferencesStore.open(context, 'org_tasks_reminders')
      const before: TaskReminderConfiguration = { enabled: await store.get('enabled', false) as boolean,
        eventDurationMinutes: await store.get('eventDurationMinutes', DEFAULT_EVENT_DURATION_MINUTES) as number }
      const next: TaskReminderConfiguration = { enabled: patch.enabled ?? before.enabled,
        eventDurationMinutes: patch.eventDurationMinutes ?? before.eventDurationMinutes }
      validate(next)
      try {
        await store.put('enabled', next.enabled); await store.put('eventDurationMinutes', next.eventDurationMinutes)
        await store.flush()
      } catch (error) {
        try {
          await store.put('enabled', before.enabled); await store.put('eventDurationMinutes', before.eventDurationMinutes); await store.flush()
        } catch (_) { console.error('恢复任务提醒设置失败') }
        throw error as Error
      }
    })
    TaskReminderSettings.queue = work.catch((): void => {})
    return work
  }
}
