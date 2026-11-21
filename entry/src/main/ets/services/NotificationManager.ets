import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreNotification, CoreNotificationChange, CoreNotificationUpdate, CoreWorkspace, NativeCoreService } from './NativeCoreService'
import { repositoryLabel } from '../ui/Theme'

// 宿主展示上下文单独保存，不作为通知的公共数据或持久化字段。
export interface NotificationRepository {
  coreRepoId: string
  configRepoId: string
  rootDirectory: string
  name: string
}

export interface CoreNotificationsState {
  notifications: CoreNotification[]
  repositories: NotificationRepository[]
  revision: number
}

type NotificationListener = (state: CoreNotificationsState) => void
interface NotificationViewSnapshot {
  type: 'snapshot'
  state: CoreNotificationsState
}
interface NotificationViewDelta {
  type: 'changed'
  state: CoreNotificationsState
  changes: CoreNotificationChange[]
}
type NotificationViewEvent = NotificationViewSnapshot | NotificationViewDelta
type NotificationViewListener = (event: NotificationViewEvent) => void

export function emptyCoreNotificationsState(): CoreNotificationsState {
  return { notifications: [], repositories: [], revision: 0 }
}

export class NotificationManager {
  private static state: CoreNotificationsState = emptyCoreNotificationsState()
  private static workspace: CoreWorkspace | undefined = undefined
  private static context: Context | undefined = undefined
  private static listeners: Set<NotificationListener> = new Set()
  private static viewListeners: Set<NotificationViewListener> = new Set()
  private static snapshotReady: boolean = false
  private static bindingFailed: boolean = false
  private static generation: number = 0
  private static monitoring: Promise<void> = Promise.resolve()
  private static ready: Promise<void> = Promise.resolve()
  private static finishReady: (() => void) | undefined = undefined
  private static configChanged: () => void = (): void => {
    NotificationManager.bind().catch((error: Error): void => { console.error(`更新通知订阅失败：${error.message}`) })
  }

  static start(context: Context): Promise<void> {
    if (NotificationManager.context) return NotificationManager.ready
    NotificationManager.context = context
    AppConfigService.watchChanges(NotificationManager.configChanged)
    return NotificationManager.bind()
  }

  static resume(): void {
    if (NotificationManager.bindingFailed) NotificationManager.configChanged()
  }

  static hasMissingRepository(): boolean {
    return NotificationManager.state.notifications.some(item => item.type === 'repositoryRootMissing')
  }

  static stop(): void {
    AppConfigService.stopWatchingChanges(NotificationManager.configChanged)
    NotificationManager.context = undefined
    NotificationManager.generation++
    NotificationManager.snapshotReady = false
    NotificationManager.bindingFailed = false
    NotificationManager.listeners.clear()
    NotificationManager.viewListeners.clear()
    NotificationManager.state = emptyCoreNotificationsState()
    NotificationManager.finishReady?.(); NotificationManager.finishReady = undefined
    NotificationManager.workspace?.stopWatchingNotifications()
    NotificationManager.workspace = undefined
  }

  // Core 缓存直接提供首次列表。
  private static bind(): Promise<void> {
    if (!NotificationManager.context) return Promise.resolve()
    const context = NotificationManager.context
    const generation = ++NotificationManager.generation
    NotificationManager.snapshotReady = false
    NotificationManager.bindingFailed = false
    NotificationManager.finishReady?.()
    let finish: () => void = (): void => {}
    const initial = new Promise<void>((resolve): void => { finish = resolve })
    NotificationManager.finishReady = finish
    const connecting = NotificationManager.monitoring.then(async (): Promise<void> => {
      if (!NotificationManager.active(generation)) return
      const config = await AppConfigService.load(context, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      if (!NotificationManager.active(generation)) return
      const syncRoots = config.repos.filter(repo => repo.webdavEnabled && repo.webdavUrl.trim().length > 0).map(repo => repo.rootDirectory)
      const repositoryErrorRoots = config.repos.map(repo => repo.rootDirectory)
      NotificationManager.workspace?.stopWatchingNotifications()
      NotificationManager.workspace = workspace
      let nativeRevision: number = -1
      let values: CoreNotification[] = []
      await workspace.watchNotifications((event: CoreNotificationUpdate): void => {
        if (!NotificationManager.active(generation) || NotificationManager.workspace !== workspace) return
        if (event.type === 'snapshot') {
          nativeRevision = event.revision
          values = event.notifications.slice()
        } else {
          if (event.fromRevision !== nativeRevision || event.revision <= nativeRevision) {
            NotificationManager.snapshotReady = false
            NotificationManager.bindingFailed = true
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
          if (left.type === 'repositoryRootMissing') {
            if (right.type !== 'repositoryRootMissing') return 1
            return left.rootDirectory < right.rootDirectory ? -1 : left.rootDirectory > right.rootDirectory ? 1 : 0
          }
          if (right.type === 'repositoryRootMissing') return -1
          if (left.repoId !== right.repoId) return left.repoId < right.repoId ? -1 : 1
          if (left.type !== right.type) return left.type === 'syncBaselineUnavailable' ? -1 : 1
          if (left.type === 'syncConflict' && right.type === 'syncConflict') return left.path < right.path ? -1 : left.path > right.path ? 1 : 0
          return 0
        })
        const changed = NotificationManager.publish(config, values)
        const first = !NotificationManager.snapshotReady
        NotificationManager.snapshotReady = true
        NotificationManager.bindingFailed = false
        if (changed) {
          const state = NotificationManager.state
          const update: NotificationViewEvent = event.type === 'changed'
            ? { type: 'changed', changes: event.changes, state }
            : { type: 'snapshot', state }
          for (const listener of NotificationManager.viewListeners) listener(update)
        }
        if (first || changed) {
          for (const listener of NotificationManager.listeners) listener(NotificationManager.state)
        }
        finish()
      }, { repositoryErrorRoots, syncRoots })
      if (!NotificationManager.active(generation)) workspace.stopWatchingNotifications()
    })
    NotificationManager.ready = connecting.then((): Promise<void> => initial).catch((error: Error): void => {
      if (NotificationManager.active(generation)) NotificationManager.bindingFailed = true
      throw error
    })
    NotificationManager.monitoring = NotificationManager.ready.then((): void => {}, (): void => {})
    return NotificationManager.ready
  }

  static subscribe(listener: NotificationListener): () => void {
    NotificationManager.listeners.add(listener)
    if (NotificationManager.snapshotReady) listener(NotificationManager.state)
    return (): void => { NotificationManager.listeners.delete(listener) }
  }

  static watch(listener: NotificationViewListener): () => void {
    NotificationManager.viewListeners.add(listener)
    listener({ type: 'snapshot', state: NotificationManager.state })
    return (): void => { NotificationManager.viewListeners.delete(listener) }
  }

  static watchVisibility(listener: (visible: boolean) => void): () => void {
    let visible: boolean | undefined
    return NotificationManager.watch((event: NotificationViewEvent): void => {
      const next = event.state.notifications.length > 0
      if (next === visible) return
      visible = next
      listener(next)
    })
  }

  private static active(generation: number): boolean {
    return NotificationManager.context !== undefined && NotificationManager.generation === generation
  }

  private static sameNotification(left: CoreNotification, right: CoreNotification): boolean {
    if (left.type === 'syncRequired') return right.type === 'syncRequired'
    if (left.type === 'repositoryRootMissing') return right.type === 'repositoryRootMissing' && left.rootDirectory === right.rootDirectory
    if (left.type === 'syncConflict') return right.type === 'syncConflict' && left.repoId === right.repoId && left.path === right.path && left.rootDirectory === right.rootDirectory
    return right.type === 'syncBaselineUnavailable' && left.repoId === right.repoId && left.reason === right.reason && left.rootDirectory === right.rootDirectory
  }

  private static publish(config: AppConfig, notifications: CoreNotification[]): boolean {
    const repositories: NotificationRepository[] = []
    for (const notification of notifications) {
      if (notification.type === 'syncRequired') continue
      const configured = config.repos.find(item => item.rootDirectory === notification.rootDirectory)
      if (configured && !repositories.some(item => item.rootDirectory === configured.rootDirectory)) {
        repositories.push({ coreRepoId: notification.type === 'repositoryRootMissing' ? '' : notification.repoId,
          configRepoId: configured.id, rootDirectory: configured.rootDirectory, name: repositoryLabel(configured) })
      }
    }
    const current = NotificationManager.state
    const sameNotifications = notifications.length === current.notifications.length && notifications.every((item: CoreNotification, index: number): boolean =>
      NotificationManager.sameNotification(item, current.notifications[index]))
    const sameRepositories = repositories.length === current.repositories.length && repositories.every((item: NotificationRepository, index: number): boolean => {
      const previous = current.repositories[index]
      return item.coreRepoId === previous.coreRepoId && item.configRepoId === previous.configRepoId &&
        item.rootDirectory === previous.rootDirectory && item.name === previous.name
    })
    if (sameNotifications && sameRepositories) return false
    const snapshot: CoreNotificationsState = { notifications: notifications.slice(), repositories,
      revision: NotificationManager.state.revision + 1 }
    NotificationManager.state = snapshot
    return true
  }
}
