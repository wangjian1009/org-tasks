import { Context } from '@kit.AbilityKit'
import { i18n } from '@kit.LocalizationKit'
import { PreferencesStore } from './PreferencesStore'

export type AppLanguage = 'default' | 'zh-Hans' | 'en'

const STORE = 'org_tasks_language'
const KEY = 'preferredLanguage'

export async function loadAppLanguage(context: Context): Promise<AppLanguage> {
  const store = await PreferencesStore.open(context, STORE)
  const language = await store.get(KEY, 'default')
  return language === 'zh-Hans' || language === 'en' ? language : 'default'
}

export async function saveAppLanguage(context: Context, language: AppLanguage): Promise<void> {
  const store = await PreferencesStore.open(context, STORE)
  const previous = await store.get(KEY, 'default')
  try {
    await store.put(KEY, language)
    await store.flush()
    i18n.System.setAppPreferredLanguage(language)
  } catch (error) {
    try {
      await store.put(KEY, previous)
      await store.flush()
    } catch (_) { console.error('恢复原界面语言失败') }
    throw error as Error
  }
}
