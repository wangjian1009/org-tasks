import { Context } from '@kit.AbilityKit'
import { APP_CONFIG_PREFERENCES } from './AppConfigService'
import { PreferencesStore } from './PreferencesStore'
import { RegionOrder } from '../ui/RegionOrderPresentation'

const ORDER_KEY = 'regionOrder'

// 独立写入显示偏好，不经由仓库配置保存流程，避免触发凭据写入与查询重建。
export class RegionOrderService {
  private static pending: Promise<void> = Promise.resolve()
  private static listeners: Set<(order: RegionOrder | null) => void> = new Set()

  static watchChanges(listener: (order: RegionOrder | null) => void): void { RegionOrderService.listeners.add(listener) }
  static stopWatchingChanges(listener: (order: RegionOrder | null) => void): void { RegionOrderService.listeners.delete(listener) }

  static async load(context: Context): Promise<RegionOrder | null> {
    await RegionOrderService.pending.catch((): void => {})
    const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
    const raw = await store.get(ORDER_KEY, '') as string
    if (!raw) return null
    try {
      const order = JSON.parse(raw) as RegionOrder
      if (order.version !== 1 || !Array.isArray(order.regions) || !Array.isArray(order.projects) ||
        !order.regions.every(key => typeof key === 'string') ||
        !order.projects.every(item => !!item && typeof item.region === 'string' && Array.isArray(item.keys) && item.keys.every(key => typeof key === 'string'))) {
        throw new Error('无效排序配置')
      }
      return order
    } catch (_) { throw new Error('分区与项目顺序配置无法读取，请恢复默认顺序后重新保存') }
  }

  static save(context: Context, order: RegionOrder | null): Promise<void> {
    const encoded = order ? JSON.stringify(order) : ''
    const saving = RegionOrderService.pending.catch((): void => {}).then(async (): Promise<void> => {
      const store = await PreferencesStore.open(context, APP_CONFIG_PREFERENCES)
      const previous = await store.get(ORDER_KEY, '') as string
      try {
        if (encoded) await store.put(ORDER_KEY, encoded)
        else await store.delete(ORDER_KEY)
        await store.flush()
      } catch (error) {
        try {
          if (previous) await store.put(ORDER_KEY, previous)
          else await store.delete(ORDER_KEY)
          await store.flush()
        } catch (_) { /* 保留原保存错误，面板继续保留待保存顺序。 */ }
        throw error as Error
      }
      RegionOrderService.listeners.forEach((listener: (order: RegionOrder | null) => void): void => {
        try { listener(encoded ? JSON.parse(encoded) as RegionOrder : null) }
        catch (_) { console.error('更新分区与项目顺序显示失败') }
      })
    })
    RegionOrderService.pending = saving
    return saving
  }
}
