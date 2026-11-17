import { Context } from '@kit.AbilityKit'
import { APP_CONFIG_PREFERENCES } from './AppConfigService'
import { PreferencesStore } from './PreferencesStore'
import { TodayRegionOrder } from '../ui/TodayRegionOrderPresentation'

const ORDER_KEY = 'todayRegionOrder'

// 独立写入显示偏好，不经由仓库配置保存流程，避免触发凭据写入与查询重建。
export class TodayRegionOrderService {
  private static pending: Promise<void> = Promise.resolve()

  static async load(context: Context): Promise<TodayRegionOrder | null> {
    await TodayRegionOrderService.pending.catch((): void => {})
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const raw = await store.get(ORDER_KEY, '') as string
    if (!raw) return null
    try {
      const order = JSON.parse(raw) as TodayRegionOrder
      if (order.version !== 1 || !Array.isArray(order.regions) || !Array.isArray(order.projects) ||
        !order.regions.every(key => typeof key === 'string') ||
        !order.projects.every(item => !!item && typeof item.region === 'string' && Array.isArray(item.keys) && item.keys.every(key => typeof key === 'string'))) {
        throw new Error('无效排序配置')
      }
      return order
    } catch (_) { throw new Error('今天分区顺序配置无法读取，请恢复默认顺序后重新保存') }
  }

  static save(context: Context, order: TodayRegionOrder | null): Promise<void> {
    const encoded = order ? JSON.stringify(order) : ''
    const saving = TodayRegionOrderService.pending.catch((): void => {}).then(async (): Promise<void> => {
      const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
      const previous = await store.get(ORDER_KEY, '') as string
      try {
        if (encoded) await store.put(ORDER_KEY, encoded)
        else await store.delete(ORDER_KEY)
        await store.flush()
      } catch (error) {
        try { await store.put(ORDER_KEY, previous); await store.flush() } catch (_) { /* 保留原保存错误，面板继续保留待保存顺序。 */ }
        throw error as Error
      }
    })
    TodayRegionOrderService.pending = saving
    return saving
  }
}
