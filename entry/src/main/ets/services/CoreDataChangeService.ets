import { CoreWorkspace } from './NativeCoreService'

export class CoreDataChangeService {
  private static eventListeners: Set<() => void> = new Set()
  static watchEvents(listener: () => void): () => void {
    CoreDataChangeService.eventListeners.add(listener)
    return (): void => { CoreDataChangeService.eventListeners.delete(listener) }
  }
  private static workspace: CoreWorkspace | undefined = undefined
  private static subscriptionId: number = 0
  private static externalSubscriptionId: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  static async connect(workspace: CoreWorkspace): Promise<void> {
    if (CoreDataChangeService.workspace === workspace) {
      await CoreDataChangeService.monitoring
      return
    }
    if (CoreDataChangeService.workspace && CoreDataChangeService.subscriptionId !== 0) {
      CoreDataChangeService.workspace.stopWatchingDataChanges(CoreDataChangeService.subscriptionId)
    }
    if (CoreDataChangeService.workspace && CoreDataChangeService.externalSubscriptionId) CoreDataChangeService.workspace.stopWatchingExternalFileChanges(CoreDataChangeService.externalSubscriptionId)
    CoreDataChangeService.externalSubscriptionId = 0
    CoreDataChangeService.workspace = workspace
    CoreDataChangeService.subscriptionId = 0
    const changed = (): void => {
      if (CoreDataChangeService.workspace !== workspace) return
      for (const listener of CoreDataChangeService.eventListeners) {
        try { listener() } catch (_) { console.error('处理数据集变更失败') }
      }
    }
    CoreDataChangeService.monitoring = (async (): Promise<void> => {
      let dataId = 0, externalId = 0
      try {
        dataId = await workspace.watchDataChanges(changed)
        externalId = await workspace.watchExternalFileChanges(changed)
        if (CoreDataChangeService.workspace !== workspace) {
          workspace.stopWatchingDataChanges(dataId); workspace.stopWatchingExternalFileChanges(externalId); return
        }
        CoreDataChangeService.subscriptionId = dataId; CoreDataChangeService.externalSubscriptionId = externalId
      } catch (error) {
        if (dataId) workspace.stopWatchingDataChanges(dataId)
        if (externalId) workspace.stopWatchingExternalFileChanges(externalId)
        if (CoreDataChangeService.workspace === workspace) CoreDataChangeService.workspace = undefined
        throw error as Error
      }
    })()
    await CoreDataChangeService.monitoring
  }
}
