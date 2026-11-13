import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

const HISTORY_STORE = 'org_tasks_move_targets'
const HISTORY_KEY = 'recentTargets'
const HISTORY_LIMIT = 100

// 单条、批量和跨页面的点选共用顺序队列，只保存宿主展示偏好。
export class MoveTargetHistoryService {
  private static pending: Promise<void> = Promise.resolve()

  private static async read(context: Context): Promise<string[]> {
    const store = await PreferencesStore.open(context, HISTORY_STORE)
    const value: string[] = JSON.parse(await store.get(HISTORY_KEY, '[]') as string) as string[]
    return value.filter((key: string, index: number): boolean => typeof key === 'string' &&
      value.indexOf(key) === index).slice(0, HISTORY_LIMIT)
  }

  static async load(context: Context): Promise<string[]> {
    await MoveTargetHistoryService.pending
    return await MoveTargetHistoryService.read(context)
  }

  static remember(context: Context, key: string): Promise<void> {
    const write = MoveTargetHistoryService.pending.then(async (): Promise<void> => {
      const recent = await MoveTargetHistoryService.read(context)
      const store = await PreferencesStore.open(context, HISTORY_STORE)
      await store.put(HISTORY_KEY, JSON.stringify([key].concat(recent.filter((item: string): boolean => item !== key)).slice(0, HISTORY_LIMIT)))
      await store.flush()
    })
    MoveTargetHistoryService.pending = write.catch((): void => {})
    return write
  }
}
