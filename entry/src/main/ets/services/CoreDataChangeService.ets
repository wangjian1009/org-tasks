import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreWorkspace, CoreDataChangeEvent, NativeCoreService } from './NativeCoreService'

export interface CoreDataChangeState { revision: number; operationId: string | null; repoId: string | null }

export function emptyCoreDataChangeState(): CoreDataChangeState {
  return { revision: 0, operationId: null, repoId: null }
}

export class CoreDataChangeService {
  private static eventListeners: Set<(event: CoreDataChangeEvent) => void> = new Set()
  static watchEvents(listener: (event: CoreDataChangeEvent) => void): () => void {
    CoreDataChangeService.eventListeners.add(listener)
    return (): void => { CoreDataChangeService.eventListeners.delete(listener) }
  }
  private static listeners: Set<(event: CoreDataChangeState) => void> = new Set()
  static watch(listener: (event: CoreDataChangeState) => void) { CoreDataChangeService.listeners.add(listener) }
  static unwatch(listener: (event: CoreDataChangeState) => void) { CoreDataChangeService.listeners.delete(listener) }
  private static workspace: CoreWorkspace | undefined = undefined
  private static subscriptionId: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  private static state: CoreDataChangeState = emptyCoreDataChangeState()

  static async refresh(context: Context): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await CoreDataChangeService.connect(workspace)
  }

  static invalidate(operationId: string | null = null, repoId: string | null = null): void {
    const updated: CoreDataChangeState = { revision: CoreDataChangeService.state.revision + 1, operationId, repoId }
    CoreDataChangeService.state = updated
    for (const listener of CoreDataChangeService.listeners) listener(updated)
    AppStorage.setOrCreate<CoreDataChangeState>('coreDataChanges', updated)
  }

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
      CoreDataChangeService.invalidate(event.operationId ?? null, event.repoId)
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
