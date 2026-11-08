import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'

// 统一处理 Preferences 的同步异常和异步拒绝，失败时不返回默认配置或报告保存成功。
export class PreferencesStore {
  private store: preferences.Preferences

  private constructor(store: preferences.Preferences) { this.store = store }

  static async open(context: Context, name: string): Promise<PreferencesStore> {
    try {
      return new PreferencesStore(await preferences.getPreferences(context, name))
    } catch (error) { throw storageFailure('打开本地存储失败', error) }
  }

  async get(key: string, fallback: preferences.ValueType): Promise<preferences.ValueType> {
    try { return await this.store.get(key, fallback) }
    catch (error) { throw storageFailure('读取本地存储失败', error) }
  }

  async put(key: string, value: preferences.ValueType): Promise<void> {
    try { await this.store.put(key, value) }
    catch (error) { throw storageFailure('写入本地存储失败', error) }
  }

  async flush(): Promise<void> {
    try { await this.store.flush() }
    catch (error) { throw storageFailure('保存本地存储失败', error) }
  }
}

function storageFailure(action: string, error: Object): Error {
  const code = (error as BusinessError).code
  return new Error(code ? `${action}（错误码 ${code}）` : action)
}
