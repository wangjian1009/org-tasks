import { localizedText } from '../ui/LocalizedText'
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
    } catch (error) { throw storageFailure(localizedText($r('app.string.text_failed_to_open_local_storage')), error) }
  }

  async has(key: string): Promise<boolean> {
    try { return await this.store.has(key) }
    catch (error) { throw storageFailure(localizedText($r('app.string.text_reading_local_storage_failed')), error) }
  }

  async get(key: string, fallback: preferences.ValueType): Promise<preferences.ValueType> {
    try { return await this.store.get(key, fallback) }
    catch (error) { throw storageFailure(localizedText($r('app.string.text_reading_local_storage_failed')), error) }
  }

  async put(key: string, value: preferences.ValueType): Promise<void> {
    try { await this.store.put(key, value) }
    catch (error) { throw storageFailure(localizedText($r('app.string.text_writing_to_local_storage_failed')), error) }
  }

  async flush(): Promise<void> {
    try { await this.store.flush() }
    catch (error) { throw storageFailure(localizedText($r('app.string.text_saving_local_storage_failed')), error) }
  }

  async delete(key: string): Promise<void> {
    try { await this.store.delete(key) }
    catch (error) { throw storageFailure(localizedText($r('app.string.text_failed_to_remove_local_storage')), error) }
  }
}

function storageFailure(action: string, error: Object): Error {
  const code = (error as BusinessError).code
  return new Error(code ? localizedText($r('app.string.text_error_code_2'), String(action), String(code)) : action)
}
