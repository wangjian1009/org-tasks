import { Context } from '@kit.AbilityKit'
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

  private static async monitor(context: Context, workspace: CoreWorkspace): Promise<void> {
    if (CoreNotificationService.workspace === workspace) { await CoreNotificationService.monitoring; return }
    CoreNotificationService.workspace?.stopWatchingNotifications()
    CoreNotificationService.workspace = workspace
    CoreNotificationService.monitoring = workspace.watchNotifications((): void => {
      if (CoreNotificationService.workspace !== workspace) return
      const previous = CoreNotificationService.state
      const updated: CoreNotificationsState = { notifications: previous.notifications, repositories: previous.repositories,
        revision: previous.revision + 1 }
      CoreNotificationService.state = updated
      AppStorage.setOrCreate<CoreNotificationsState>('coreNotifications', updated)
      CoreNotificationService.refresh(context).catch((): void => { console.error('通知更新后重新读取失败，保留已有快照') })
    }).catch((error: Error): void => {
      if (CoreNotificationService.workspace === workspace) CoreNotificationService.workspace = undefined
      throw error
    })
    await CoreNotificationService.monitoring
  }

  static async refresh(context: Context): Promise<void> {
    const request = ++CoreNotificationService.requestId
    try {
      const config = await AppConfigService.load(context, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
      await CoreNotificationService.monitor(context, workspace)
      const notifications = await NativeCoreService.notifications(config.repos, config.todoDefaults)
      const repositories: NotificationRepository[] = []
      for (const notification of notifications) {
        if (notification.type !== 'syncConflict') continue
        const configured = config.repos.find((item) => item.rootDirectory === notification.rootDirectory)
        if (configured && !repositories.some((item) => item.coreRepoId === notification.repoId)) {
          repositories.push({ coreRepoId: notification.repoId, configRepoId: configured.id, name: repositoryLabel(configured) })
        }
      }
      if (request !== CoreNotificationService.requestId) return
      const snapshot: CoreNotificationsState = { notifications: notifications.slice(), repositories, revision: CoreNotificationService.state.revision }
      CoreNotificationService.state = snapshot
      AppStorage.setOrCreate<CoreNotificationsState>('coreNotifications', snapshot)
    } catch (e) {
      if (request === CoreNotificationService.requestId) throw e as Error
    }
  }

  static async syncConflictTarget(context: Context, notification: CoreSyncConflictNotification): Promise<SyncConflictTarget> {
    const known = CoreNotificationService.state.repositories.find((repo) => repo.coreRepoId === notification.repoId)
    const config = await AppConfigService.load(context, false)
    const configured = config.repos.find((repo) => repo.id === known?.configRepoId)
    if (!configured) throw new Error('此存储库已不存在，请刷新后重试')
    const repo = await NativeCoreService.repository(config.repos, configured, config.todoDefaults)
    await repo.load()
    if (repo.id !== notification.repoId) throw new Error('存储库已发生变化，请刷新后重试')
    return { repoId: configured.id, path: notification.path }
  }
}
