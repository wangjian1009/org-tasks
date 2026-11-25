import { localizedText } from './LocalizedText'
import { CoreNotification, CoreSyncConflictNotification } from '../services/NativeCoreService'
import { NotificationRepository } from '../services/NotificationManager'

export function syncConflictRepositoryName(notification: CoreSyncConflictNotification, repositories: NotificationRepository[]): string {
  return repositories.find((repo: NotificationRepository) => repo.coreRepoId === notification.repoId)?.name || localizedText($r('app.string.text_repositories'))
}

export function coreNotificationRenderKey(notification: CoreNotification): string {
  return JSON.stringify(notification)
}
