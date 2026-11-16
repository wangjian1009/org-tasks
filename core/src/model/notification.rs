//! Core 判断的当前待关注事件；查询不消费事件，也不保存通知记录。
use crate::OrgWorkspace;
use serde::{Deserialize, Serialize};

use super::OrgRepoId;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CoreNotification {
    SyncConflict(SyncConflictNotification),
    SyncRequired,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncConflictNotification {
    pub repo_id: OrgRepoId,
    pub path: String,
}

/// 更新事件只表示需要重新查询；注意事项由统一批量查询中的 NotificationQuery 提供。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum NotificationUpdate {
    RepositoryChanged {
        #[serde(rename = "repoId")]
        repo_id: OrgRepoId,
    },
    GlobalNotificationsChanged,
}

pub struct NotificationSubscription {
    _subscription: super::notification_center::Subscription,
}

impl OrgWorkspace {
    /// 通知模块注册同步提交回调，统一转发更新。回调不能同步等待当前 Workspace 的后续业务命令。
    pub fn watch_notifications<F>(&self, callback: F) -> NotificationSubscription
    where
        F: Fn(NotificationUpdate) + Send + Sync + 'static,
    {
        let subscription = self.notifications.subscribe(move |event| {
            let super::sync_events::SyncCommitted::Repository { repo_id, .. } = event;
            callback(NotificationUpdate::RepositoryChanged { repo_id: repo_id.clone() });
        });
        NotificationSubscription {
            _subscription: subscription,
        }
    }

}
