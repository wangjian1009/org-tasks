import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export interface SavedSearch {
  id: string
  name: string
  query: string
}

export const BUILTIN_SEARCHES: SavedSearch[] = [
  { id: 'planned', name: '已计划', query: '.it.done s.ge.-100y' },
  { id: 'todo', name: '待办', query: 'i.todo' }
]

export class SavedSearchService {
  static async load(context: Context): Promise<SavedSearch[]> {
    const store = await PreferencesStore.open(context, 'org_tasks_saved_searches')
    return JSON.parse(await store.get('items', '[]') as string) as SavedSearch[]
  }

  static async save(context: Context, searches: SavedSearch[]): Promise<void> {
    const store = await PreferencesStore.open(context, 'org_tasks_saved_searches')
    await store.put('items', JSON.stringify(searches))
    await store.flush()
  }
}
