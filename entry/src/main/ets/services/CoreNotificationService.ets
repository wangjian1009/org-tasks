import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { CoreDataChangeService } from './CoreDataChangeService'
import { AppConfigService } from './AppConfigService'
import { CoreNotification, CoreSyncConflictNotification, CoreWorkspace, NativeCoreService } from './NativeCoreService'
import { repositoryLabel } from '../ui/Theme'

// 宿主展示上下文单独保存，不作为通知的公共数据或持久化字段。
export interface NotificationRepository {
  coreRepoId: string
  configRepoId: string
  name: string
}

export interface CoreNotificationsState {
  notifications: CoreNotification[]
  repositories: NotificationRepository[]
  revision: number
}

export interface SyncConflictTarget {
  repoId: string
  path: string
}

export function emptyCoreNotificationsState(): CoreNotificationsState {
  return { notifications: [], repositories: [], revision: 0 }
}

export class CoreNotificationService {
  private static state: CoreNotificationsState = emptyCoreNotificationsState()
  private static requestId: number = 0
  private static workspace: CoreWorkspace | undefined = undefined
  private static monitoring: Promise<void> = Promise.resolve()

  static async connect(workspace: CoreWorkspace): Promise<void> {
    if (CoreNotificationService.workspace === workspace) { await CoreNotificationService.monitoring; return }
    CoreNotificationService.workspace?.stopWatchingNotifications()
    CoreNotificationService.workspace = workspace
    CoreNotificationService.monitoring = workspace.watchNotifications((event): void => {
      if (CoreNotificationService.workspace !== workspace) return
      // 仓库变更由数据订阅负责；全局通知失效也交给页面统一重查。
      if (event.type === 'globalNotificationsChanged') CoreDataChangeService.invalidate()
    }).catch((error: Error): void => {
      if (CoreNotificationService.workspace === workspace) CoreNotificationService.workspace = undefined
      throw error
    })
    await CoreNotificationService.monitoring
  }

  static begin(): number { return ++CoreNotificationService.requestId }

  static publish(config: AppConfig, notifications: CoreNotification[], request: number): void {
    if (request !== CoreNotificationService.requestId) return
    const repositories: NotificationRepository[] = []
    for (const notification of notifications) {
      if (notification.type !== 'syncConflict') continue
      const configured = config.repos.find(item => item.rootDirectory === notification.rootDirectory)
      if (configured && !repositories.some(item => item.coreRepoId === notification.repoId)) {
        repositories.push({ coreRepoId: notification.repoId, configRepoId: configured.id, name: repositoryLabel(configured) })
      }
    }
    const snapshot: CoreNotificationsState = { notifications: notifications.slice(), repositories,
      revision: CoreNotificationService.state.revision + 1 }
    CoreNotificationService.state = snapshot
    AppStorage.setOrCreate<CoreNotificationsState>('coreNotifications', snapshot)
  }

  static async syncConflictTarget(context: Context, notification: CoreSyncConflictNotification): Promise<SyncConflictTarget> {
    const known = CoreNotificationService.state.repositories.find((repo) => repo.coreRepoId === notification.repoId)
    const config = await AppConfigService.load(context, false)
    const configured = config.repos.find((repo) => repo.id === known?.configRepoId)
    if (!configured) throw new Error('此存储库已不存在，请刷新后重试')
    const repo = await NativeCoreService.repository(config.repos, configured, config.todoDefaults, config.coreSettings)
    await repo.load()
    if (repo.id !== notification.repoId) throw new Error('存储库已发生变化，请刷新后重试')
    return { repoId: configured.id, path: notification.path }
  }
}
