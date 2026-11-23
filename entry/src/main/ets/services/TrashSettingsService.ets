import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export const TRASH_RETENTION_KEY = 'trashRetentionDays'
export const DEFAULT_TRASH_RETENTION_DAYS = 30

export class TrashSettingsService {
  static async retentionDays(context: Context): Promise<number> {
    const store = await PreferencesStore.open(context, 'org_tasks_config')
    const days = await store.get(TRASH_RETENTION_KEY, DEFAULT_TRASH_RETENTION_DAYS) as number
    if (!Number.isInteger(days) || days < 1 || days > 3650) throw new Error('废纸篓保留天数必须在 1 至 3650 之间')
    return days
  }

  private static queue: Promise<void> = Promise.resolve()
  static saveRetentionDays(context: Context, days: number): Promise<void> {
    const work = TrashSettingsService.queue.then(async (): Promise<void> => {
      if (!Number.isInteger(days) || days < 1 || days > 3650) throw new Error('请输入 1 至 3650 之间的保留天数')
      const store = await PreferencesStore.open(context, 'org_tasks_config')
      const previous = await store.get(TRASH_RETENTION_KEY, DEFAULT_TRASH_RETENTION_DAYS)
      try { await store.put(TRASH_RETENTION_KEY, days); await store.flush() }
      catch (error) {
        try { await store.put(TRASH_RETENTION_KEY, previous); await store.flush() }
        catch (_) { console.error('恢复废纸篓保留天数失败') }
        throw error as Error
      }
    })
    TrashSettingsService.queue = work.catch((): void => {})
    return work
  }
}
