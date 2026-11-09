import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export interface SavedSearch {
  id: string
  name: string
  query: string
}

export class SavedSearchService {
  static async load(context: Context): Promise<SavedSearch[]> {
    const store = await PreferencesStore.open(context, 'org_tasks_saved_searches')
    return JSON.parse(await store.get('items', '[]') as string) as SavedSearch[]
  }
}
