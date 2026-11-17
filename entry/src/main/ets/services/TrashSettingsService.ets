import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export class TrashSettingsService {
  static async retentionDays(context: Context): Promise<number> {
    const store = await PreferencesStore.open(context, 'org_tasks_config')
    const days = await store.get('trashRetentionDays', 30) as number
    if (!Number.isInteger(days) || days < 1 || days > 3650) throw new Error('废纸篓保留天数必须在 1 至 3650 之间')
    return days
  }

  static async saveRetentionDays(context: Context, days: number): Promise<void> {
    if (!Number.isInteger(days) || days < 1 || days > 3650) throw new Error('请输入 1 至 3650 之间的保留天数')
    const store = await PreferencesStore.open(context, 'org_tasks_config')
    await store.put('trashRetentionDays', days)
    await store.flush()
  }
}
