import { common, Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { notificationManager } from '@kit.NotificationKit'
import { DeviceBadgeService } from './DeviceBadgeService'
import { PreferencesStore } from './PreferencesStore'

export type NotificationPermissionState = 'unrequested' | 'disabled' | 'enabled'

const STORE_NAME = 'org_tasks_notification'
const HANDLED_KEY = 'notificationPromptHandled'

// 仅主界面前台可请求授权；系统状态实时读取，本地只保存首次请求标记。
export class NotificationPermissionService {
  private static foreground: boolean = false
  private static session: number = 0
  private static queue: Promise<void> = Promise.resolve()

  static isForeground(): boolean { return NotificationPermissionService.foreground }

  static async state(context: Context): Promise<NotificationPermissionState> {
    if (await NotificationPermissionService.enabled()) return 'enabled'
    const store = await PreferencesStore.open(context, STORE_NAME)
    return await store.get(HANDLED_KEY, false) === true ? 'disabled' : 'unrequested'
  }

  static async refresh(context: Context): Promise<NotificationPermissionState> {
    const state = await NotificationPermissionService.state(context)
    if (state === 'enabled') await DeviceBadgeService.refresh(context)
    return state
  }

  // 由主窗口内容就绪与前台生命周期共同触发，不由角标刷新或后台业务调用。
  static start(context: common.UIAbilityContext): Promise<void> {
    NotificationPermissionService.foreground = true
    const session = ++NotificationPermissionService.session
    return NotificationPermissionService.serialize(async (): Promise<void> => {
      if (!NotificationPermissionService.active(session)) return
      const enabled = await NotificationPermissionService.enabled()
      const store = await PreferencesStore.open(context, STORE_NAME)
      const handled = await store.get(HANDLED_KEY, false) === true
      if (!NotificationPermissionService.active(session)) return
      if (enabled) {
        if (!handled) await NotificationPermissionService.mark(store, true)
        await DeviceBadgeService.refresh(context)
      } else if (!handled) {
        await NotificationPermissionService.request(context, store, session)
      }
    })
  }

  static stop(): void {
    NotificationPermissionService.foreground = false
    NotificationPermissionService.session++
  }

  static manage(context: common.UIAbilityContext): Promise<void> {
    const session = NotificationPermissionService.session
    return NotificationPermissionService.serialize(async (): Promise<void> => {
      if (!NotificationPermissionService.active(session)) return
      const state = await NotificationPermissionService.state(context)
      if (!NotificationPermissionService.active(session)) return
      if (state === 'unrequested') {
        const store = await PreferencesStore.open(context, STORE_NAME)
        await NotificationPermissionService.request(context, store, session)
      } else {
        await notificationManager.openNotificationSettings(context)
        if (await NotificationPermissionService.enabled()) await DeviceBadgeService.refresh(context)
      }
    })
  }

  private static active(session: number): boolean {
    return NotificationPermissionService.foreground && session === NotificationPermissionService.session
  }

  private static serialize(action: () => Promise<void>): Promise<void> {
    const operation = NotificationPermissionService.queue.then(action)
    NotificationPermissionService.queue = operation.catch((): void => {})
    return operation
  }

  private static async mark(store: PreferencesStore, handled: boolean): Promise<void> {
    const previous = await store.get(HANDLED_KEY, false)
    try {
      await store.put(HANDLED_KEY, handled)
      await store.flush()
    } catch (error) {
      // flush 失败时也恢复 Preferences 内存值，避免本进程误以为已完成请求。
      try { await store.put(HANDLED_KEY, previous); await store.flush() }
      catch (_) { console.error('恢复通知授权请求标记失败') }
      throw error as Error
    }
  }

  private static async enabled(): Promise<boolean> {
    try { return await notificationManager.isNotificationEnabled() }
    catch (error) {
      const code = (error as BusinessError).code
      throw new Error(code ? `读取通知状态失败（错误码 ${code}）` : '读取通知状态失败')
    }
  }

  private static async request(context: common.UIAbilityContext, store: PreferencesStore, session: number): Promise<void> {
    if (!NotificationPermissionService.active(session)) return
    // 先落盘，避免系统弹窗期间进程退出导致下次启动重复自动请求。
    await NotificationPermissionService.mark(store, true)
    if (!NotificationPermissionService.active(session)) {
      await NotificationPermissionService.mark(store, false)
      return
    }
    try {
      await notificationManager.requestEnableNotification(context)
    } catch (error) {
      // 用户拒绝是正常结果；服务异常与弹窗冲突保留后续重试机会。
      if ((error as BusinessError).code !== 1600004) {
        await NotificationPermissionService.mark(store, false)
        const code = (error as BusinessError).code
        throw new Error(code ? `请求通知授权失败（错误码 ${code}）` : '请求通知授权失败')
      }
    }
    if (await NotificationPermissionService.enabled()) await DeviceBadgeService.refresh(context)
  }
}
