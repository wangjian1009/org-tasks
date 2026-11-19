import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreNotification, CoreNotificationUpdate, CoreSyncConflictNotification, CoreWorkspace, NativeCoreService } from './NativeCoreService'
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
  private static workspace: CoreWorkspace | undefined = undefined
  private static context: Context | undefined = undefined
  private static listeners: Set<() => void> = new Set()
  private static generation: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  private static ready: Promise<void> = Promise.resolve()
  private static finishReady: (() => void) | undefined = undefined
  private static configChanged: () => void = (): void => {
    NotificationManager.refresh().catch((error: Error): void => { console.error(`更新通知订阅失败：${error.message}`) })
  }

  static start(context: Context): Promise<void> {
    if (NotificationManager.context) return NotificationManager.ready
    NotificationManager.context = context
    AppConfigService.watchChanges(NotificationManager.configChanged)
    return NotificationManager.refresh()
  }

  static stop(): void {
    AppConfigService.stopWatchingChanges(NotificationManager.configChanged)
    NotificationManager.context = undefined
    NotificationManager.generation++
    NotificationManager.finishReady?.(); NotificationManager.finishReady = undefined
    NotificationManager.workspace?.stopWatchingNotifications()
    NotificationManager.workspace = undefined
  }

  // 恢复前台及配置变化只重新绑定订阅；Core 缓存直接提供首次列表。
  static refresh(): Promise<void> {
    if (!NotificationManager.context) return Promise.resolve()
    const context = NotificationManager.context
    const generation = ++NotificationManager.generation
    NotificationManager.finishReady?.()
    let finish: () => void = (): void => {}
    const initial = new Promise<void>((resolve): void => { finish = resolve })
    NotificationManager.finishReady = finish
    const connecting = NotificationManager.monitoring.then(async (): Promise<void> => {
      const config = await AppConfigService.load(context, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      if (!NotificationManager.active(generation)) return
      NotificationManager.workspace?.stopWatchingNotifications()
      NotificationManager.workspace = workspace
      const roots = config.repos.filter(repo => repo.webdavEnabled && repo.webdavUrl.trim().length > 0).map(repo => repo.rootDirectory)
      const repositories = await workspace.repos()
      const repoIds = repositories.filter(repo => roots.includes(repo.rootDirectory)).map(repo => repo.id)
      let nativeRevision: number = -1
      let values: CoreNotification[] = []
      await workspace.watchNotifications((event: CoreNotificationUpdate): void => {
        if (!NotificationManager.active(generation) || NotificationManager.workspace !== workspace) return
        if (event.type === 'snapshot') {
          nativeRevision = event.revision
          values = event.notifications.slice()
        } else {
          if (event.fromRevision !== nativeRevision || event.revision <= nativeRevision) {
            console.error('通知增量版本不连续，保留最近快照')
            return
          }
          let next = values.slice()
          for (const change of event.changes) {
            if (change.kind === 'removed' || change.kind === 'updated') {
              const before = change.kind === 'removed' ? change.notification : change.before
              next = next.filter(item => !NotificationManager.sameNotification(item, before))
            }
            if (change.kind === 'added' || change.kind === 'updated') {
              const after = change.kind === 'added' ? change.notification : change.after
              if (!next.some(item => NotificationManager.sameNotification(item, after))) next.push(after)
            }
          }
          values = next
          nativeRevision = event.revision
        }
        values.sort((left: CoreNotification, right: CoreNotification): number => {
          if (left.type === 'syncRequired') return right.type === 'syncRequired' ? 0 : 1
          if (right.type === 'syncRequired') return -1
          if (left.repoId !== right.repoId) return left.repoId < right.repoId ? -1 : 1
          if (left.type !== right.type) return left.type === 'syncBaselineUnavailable' ? -1 : 1
          if (left.type === 'syncConflict' && right.type === 'syncConflict') return left.path < right.path ? -1 : left.path > right.path ? 1 : 0
          return 0
        })
        NotificationManager.publish(config, values)
        finish()
      }, repoIds)
    })
    NotificationManager.monitoring = connecting.catch((): void => {})
    NotificationManager.ready = connecting.then((): Promise<void> => initial)
    return NotificationManager.ready
  }

  static async hasSyncRequired(): Promise<boolean> {
    let ready: Promise<void>
    do { ready = NotificationManager.ready; await ready } while (ready !== NotificationManager.ready)
    return NotificationManager.context !== undefined && NotificationManager.state.notifications.some(item => item.type === 'syncRequired')
  }

  static watchChanges(callback: () => void): void { NotificationManager.listeners.add(callback) }
  static stopWatchingChanges(callback: () => void): void { NotificationManager.listeners.delete(callback) }
  static async conflictCount(): Promise<number> {
    await NotificationManager.ready
    return NotificationManager.state.notifications.filter(item => item.type === 'syncConflict').length
  }

  private static active(generation: number): boolean {
    return NotificationManager.context !== undefined && NotificationManager.generation === generation
  }

  private static sameNotification(left: CoreNotification, right: CoreNotification): boolean {
    if (left.type === 'syncRequired') return right.type === 'syncRequired'
    if (left.type === 'syncConflict') return right.type === 'syncConflict' && left.repoId === right.repoId && left.path === right.path && left.rootDirectory === right.rootDirectory
    return right.type === 'syncBaselineUnavailable' && left.repoId === right.repoId && left.reason === right.reason && left.rootDirectory === right.rootDirectory
  }

  private static publish(config: AppConfig, notifications: CoreNotification[]): void {
    const repositories: NotificationRepository[] = []
    for (const notification of notifications) {
      if (notification.type === 'syncRequired') continue
      const configured = config.repos.find(item => item.rootDirectory === notification.rootDirectory)
      if (configured && !repositories.some(item => item.coreRepoId === notification.repoId)) {
        repositories.push({ coreRepoId: notification.repoId, configRepoId: configured.id, name: repositoryLabel(configured) })
      }
    }
    const current = NotificationManager.state
    const sameNotifications = notifications.length === current.notifications.length && notifications.every((item: CoreNotification, index: number): boolean =>
      NotificationManager.sameNotification(item, current.notifications[index]))
    const sameRepositories = repositories.length === current.repositories.length && repositories.every((item: NotificationRepository, index: number): boolean => {
      const previous = current.repositories[index]
      return item.coreRepoId === previous.coreRepoId && item.configRepoId === previous.configRepoId && item.name === previous.name
    })
    if (sameNotifications && sameRepositories) return
    const snapshot: CoreNotificationsState = { notifications: notifications.slice(), repositories,
      revision: NotificationManager.state.revision + 1 }
    NotificationManager.state = snapshot
    AppStorage.setOrCreate<CoreNotificationsState>('coreNotifications', snapshot)
    for (const listener of NotificationManager.listeners) listener()
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
