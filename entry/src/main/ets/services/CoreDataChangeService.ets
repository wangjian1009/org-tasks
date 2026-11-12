import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreWorkspace, NativeCoreService } from './NativeCoreService'

export interface CoreDataChangeState { revision: number }

export function emptyCoreDataChangeState(): CoreDataChangeState {
  return { revision: 0 }
}

export class CoreDataChangeService {
  private static workspace: CoreWorkspace | undefined = undefined
  private static subscriptionId: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  private static state: CoreDataChangeState = emptyCoreDataChangeState()

  static async refresh(context: Context): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await CoreDataChangeService.connect(workspace)
  }

  static invalidate(): void {
    const updated: CoreDataChangeState = { revision: CoreDataChangeService.state.revision + 1 }
    CoreDataChangeService.state = updated
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
    CoreDataChangeService.monitoring = workspace.watchDataChanges((): void => {
      if (CoreDataChangeService.workspace !== workspace) return
      CoreDataChangeService.invalidate()
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
