import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from './PreferencesStore'

export interface CaptureDraft { id: string; title: string }

// 草稿读取和输入持久化不加载 native 模块。
export class CaptureDraftStore {
  private static queue: Promise<void> = Promise.resolve()

  static async drafts(context: Context): Promise<CaptureDraft[]> {
    await CaptureDraftStore.queue
    return await CaptureDraftStore.read(context)
  }

  private static async read(context: Context): Promise<CaptureDraft[]> {
    const store = await PreferencesStore.open(context, 'org_tasks_capture')
    return JSON.parse(await store.get('drafts', '[]') as string) as CaptureDraft[]
  }

  static putDraft(context: Context, draft: CaptureDraft): Promise<void> {
    return CaptureDraftStore.edit(context, draft.id, draft.title)
  }

  static removeDraft(context: Context, id: string): Promise<void> {
    return CaptureDraftStore.edit(context, id, '')
  }

  private static edit(context: Context, id: string, title: string): Promise<void> {
    const operation = CaptureDraftStore.queue.then(async (): Promise<void> => {
      const drafts = await CaptureDraftStore.read(context)
      const updated = drafts.filter((item: CaptureDraft) => item.id !== id)
      if (title.length > 0) updated.unshift({ id, title })
      const store = await PreferencesStore.open(context, 'org_tasks_capture')
      await store.put('drafts', JSON.stringify(updated))
      await store.flush()
    })
    CaptureDraftStore.queue = operation.catch((): void => {})
    return operation
  }
}
