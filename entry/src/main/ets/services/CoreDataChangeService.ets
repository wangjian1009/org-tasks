import { CoreWorkspace, CoreDataChangeEvent } from './NativeCoreService'

export class CoreDataChangeService {
  private static eventListeners: Set<(event: CoreDataChangeEvent) => void> = new Set()
  static watchEvents(listener: (event: CoreDataChangeEvent) => void): () => void {
    CoreDataChangeService.eventListeners.add(listener)
    return (): void => { CoreDataChangeService.eventListeners.delete(listener) }
  }
  private static workspace: CoreWorkspace | undefined = undefined
  private static subscriptionId: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  static async connect(workspace: CoreWorkspace): Promise<void> {
    if (CoreDataChangeService.workspace === workspace) {
      await CoreDataChangeService.monitoring
      return
    }
    if (CoreDataChangeService.workspace && CoreDataChangeService.subscriptionId !== 0) {
      CoreDataChangeService.workspace.stopWatchingDataChanges(CoreDataChangeService.subscriptionId)
    }
    CoreDataChangeService.workspace = workspace
    CoreDataChangeService.subscriptionId = 0
    CoreDataChangeService.monitoring = workspace.watchDataChanges((event): void => {
      if (CoreDataChangeService.workspace !== workspace) return
      for (const listener of CoreDataChangeService.eventListeners) {
        try { listener(event) } catch (_) { console.error('处理数据集变更失败') }
      }
    }).then((subscriptionId: number): void => {
      if (CoreDataChangeService.workspace !== workspace) {
        workspace.stopWatchingDataChanges(subscriptionId)
        return
      }
      CoreDataChangeService.subscriptionId = subscriptionId
    }).catch((error: Error): never => {
      if (CoreDataChangeService.workspace === workspace) {
        CoreDataChangeService.workspace = undefined
        CoreDataChangeService.subscriptionId = 0
      }
      throw error
    })
    await CoreDataChangeService.monitoring
  }
}
