import { CoreNotification, CoreSyncConflictNotification } from '../services/NativeCoreService'
import { NotificationRepository } from '../services/CoreNotificationService'

export function syncConflictRepositoryName(notification: CoreSyncConflictNotification, repositories: NotificationRepository[]): string {
  return repositories.find((repo: NotificationRepository) => repo.coreRepoId === notification.repoId)?.name || '存储库'
}

export function coreNotificationRenderKey(notification: CoreNotification): string {
  return JSON.stringify(notification)
}
