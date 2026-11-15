import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreNotification, CoreSyncConflictNotification, CoreWorkspace, NativeCoreService, notificationResult } from './NativeCoreService'
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

export class NotificationManager {
  private static state: CoreNotificationsState = emptyCoreNotificationsState()
  private static requestId: number = 0
  private static workspace: CoreWorkspace | undefined = undefined
  private static monitoring: Promise<void> = Promise.resolve()
  private static context: Context | undefined = undefined
  private static session: number = 0
  private static workspaceSession: number = -1
  private static changeRevision: number = 0
  private static pending: boolean = false
  private static running: Promise<void> | undefined = undefined
  private static timer: number = -1
  private static configChanged: () => void = (): void => { NotificationManager.invalidate() }

  // 应用进程共享，页面切换不启停；配置变化由管理对象重新取得当前 Workspace。
  static start(context: Context): Promise<void> {
    if (NotificationManager.context) return NotificationManager.running ?? (NotificationManager.workspace ? Promise.resolve() : NotificationManager.refresh())
    NotificationManager.context = context
    NotificationManager.session++
    AppConfigService.watchChanges(NotificationManager.configChanged)
    return NotificationManager.refresh()
  }

  static stop(): void {
    AppConfigService.stopWatchingChanges(NotificationManager.configChanged)
    NotificationManager.context = undefined
    NotificationManager.session++; NotificationManager.requestId++
    NotificationManager.pending = false
    clearTimeout(NotificationManager.timer); NotificationManager.timer = -1
    NotificationManager.workspace?.stopWatchingNotifications()
    NotificationManager.workspace = undefined
    NotificationManager.running = undefined
  }

  static refresh(): Promise<void> {
    if (!NotificationManager.context) return Promise.resolve()
    NotificationManager.pending = true
    clearTimeout(NotificationManager.timer); NotificationManager.timer = -1
    if (NotificationManager.running) return NotificationManager.running
    const session = NotificationManager.session
    const running = NotificationManager.drain(session).finally((): void => {
      if (NotificationManager.running !== running) return
      NotificationManager.running = undefined
      if (NotificationManager.pending) NotificationManager.schedule()
    })
    NotificationManager.running = running
    return running
  }

  // 等待已失效的通知快照归并，不为退后台额外发起查询。
  static async hasSyncRequired(): Promise<boolean> {
    while (NotificationManager.context && (NotificationManager.pending || NotificationManager.running)) {
      await (NotificationManager.running ?? NotificationManager.refresh())
    }
    return NotificationManager.context !== undefined && NotificationManager.state.notifications.some(item => item.type === 'syncRequired')
  }

  private static invalidate(): void {
    if (!NotificationManager.context) return
    NotificationManager.changeRevision++; NotificationManager.requestId++
    NotificationManager.pending = true
    NotificationManager.schedule()
  }
  private static schedule(): void {
    if (!NotificationManager.context || NotificationManager.running || NotificationManager.timer >= 0) return
    NotificationManager.timer = setTimeout((): void => {
      NotificationManager.timer = -1
      NotificationManager.refresh().catch((error: Error): void => { console.error(`更新通知失败：${error.message}`) })
    }, 50)
  }
  private static active(session: number): boolean { return NotificationManager.context !== undefined && NotificationManager.session === session }

  private static async connect(workspace: CoreWorkspace, session: number): Promise<void> {
    const connecting = NotificationManager.monitoring.then(async (): Promise<void> => {
      if (!NotificationManager.active(session)) return
      if (NotificationManager.workspace === workspace && NotificationManager.workspaceSession === session) return
      NotificationManager.workspace?.stopWatchingNotifications()
      NotificationManager.workspace = workspace; NotificationManager.workspaceSession = session
      try {
        await workspace.watchNotifications((): void => {
          if (NotificationManager.active(session) && NotificationManager.workspace === workspace) NotificationManager.invalidate()
        })
      } catch (error) {
        if (NotificationManager.workspace === workspace && NotificationManager.workspaceSession === session) NotificationManager.workspace = undefined
        throw error as Error
      }
      if (!NotificationManager.active(session)) {
        workspace.stopWatchingNotifications()
        if (NotificationManager.workspace === workspace && NotificationManager.workspaceSession === session) NotificationManager.workspace = undefined
      }
    })
    NotificationManager.monitoring = connecting.catch((): void => {})
    await connecting
  }

  private static async drain(session: number): Promise<void> {
    while (NotificationManager.pending && NotificationManager.active(session)) {
      NotificationManager.pending = false
      const revision = NotificationManager.changeRevision
      const config = await AppConfigService.load(NotificationManager.context!, false)
      if (!NotificationManager.active(session)) return
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      await NotificationManager.connect(workspace, session)
      if (!NotificationManager.active(session)) return
      const request = NotificationManager.begin()
      const results = await workspace.query([{ type: 'notification', query: {} }])
      if (!NotificationManager.active(session)) return
      if (revision !== NotificationManager.changeRevision) { NotificationManager.pending = true; continue }
      if (!NotificationManager.publish(config, notificationResult(results[0]), request)) NotificationManager.pending = true
    }
  }

  static begin(): number { return ++NotificationManager.requestId }

  static publish(config: AppConfig, notifications: CoreNotification[], request: number): boolean {
    if (request !== NotificationManager.requestId) return false
    const repositories: NotificationRepository[] = []
    for (const notification of notifications) {
      if (notification.type !== 'syncConflict') continue
      const configured = config.repos.find(item => item.rootDirectory === notification.rootDirectory)
      if (configured && !repositories.some(item => item.coreRepoId === notification.repoId)) {
        repositories.push({ coreRepoId: notification.repoId, configRepoId: configured.id, name: repositoryLabel(configured) })
      }
    }
    const current = NotificationManager.state
    const sameNotifications = notifications.length === current.notifications.length && notifications.every((item: CoreNotification, index: number): boolean => {
      const previous = current.notifications[index]
      return item.type === previous.type && (item.type === 'syncRequired' || previous.type === 'syncConflict' &&
        item.repoId === previous.repoId && item.path === previous.path && item.rootDirectory === previous.rootDirectory)
    })
    const sameRepositories = repositories.length === current.repositories.length && repositories.every((item: NotificationRepository, index: number): boolean => {
      const previous = current.repositories[index]
      return item.coreRepoId === previous.coreRepoId && item.configRepoId === previous.configRepoId && item.name === previous.name
    })
    if (sameNotifications && sameRepositories) return true
    const snapshot: CoreNotificationsState = { notifications: notifications.slice(), repositories,
      revision: NotificationManager.state.revision + 1 }
    NotificationManager.state = snapshot
    AppStorage.setOrCreate<CoreNotificationsState>('coreNotifications', snapshot)
    return true
  }

  static async syncConflictTarget(context: Context, notification: CoreSyncConflictNotification): Promise<SyncConflictTarget> {
    const known = NotificationManager.state.repositories.find((repo) => repo.coreRepoId === notification.repoId)
    const config = await AppConfigService.load(context, false)
    const configured = config.repos.find((repo) => repo.id === known?.configRepoId)
    if (!configured) throw new Error('此存储库已不存在，请刷新后重试')
    const repo = await NativeCoreService.repository(config.repos, configured, config.todoDefaults, config.coreSettings)
    await repo.load()
    if (repo.id !== notification.repoId) throw new Error('存储库已发生变化，请刷新后重试')
    return { repoId: configured.id, path: notification.path }
  }
}
