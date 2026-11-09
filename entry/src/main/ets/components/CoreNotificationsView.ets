import { CoreNotification } from '../services/NativeCoreService'
import { CoreNotificationsState, emptyCoreNotificationsState } from '../services/CoreNotificationService'
import { coreNotificationRenderKey } from '../ui/CoreNotificationPresentation'
import { SyncConflictNotificationView } from './SyncConflictNotificationView'
import { SyncRequiredNotificationView } from './SyncRequiredNotificationView'
import { UiColor } from '../ui/Theme'

// 通用入口只分发枚举变体，各通知的内容和操作由其专属组件实现。
@Component
export struct CoreNotificationsView {
  @Prop disabled: boolean = false
  @Prop horizontalInset: number = 12
  @StorageLink('coreNotifications') notificationState: CoreNotificationsState = emptyCoreNotificationsState()

  build() {
    if (this.notificationState.notifications.length > 0) {
      Column() {
        Column() {
          ForEach(this.notificationState.notifications, (notification: CoreNotification) => {
            if (notification.type === 'syncConflict') {
              SyncConflictNotificationView({ notification, repositories: this.notificationState.repositories, disabled: this.disabled })
            } else if (notification.type === 'syncRequired') {
              SyncRequiredNotificationView({ disabled: this.disabled })
            }
          }, (notification: CoreNotification) => coreNotificationRenderKey(notification))
        }.width('100%').padding({ top: 4, bottom: 4 }).borderRadius(12)
          .backgroundColor(UiColor.notificationCard).clip(true)
      }.width('100%').padding({ left: this.horizontalInset, right: this.horizontalInset, top: 8 }).flexShrink(0)
    }
  }
}
