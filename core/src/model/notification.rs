//! Core 判断的当前待关注事件；查询不消费事件，也不保存通知记录。
use serde::{Deserialize, Serialize};

use super::{OrgRepoId, OrgWorkspace};
use crate::CoreError;
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
    _sync_subscription: super::sync_events::SyncSubscription,
}

impl OrgWorkspace {
    /// 通知模块注册同步提交回调，统一转发更新。回调不能重入当前仓库锁。
    pub fn watch_notifications<F>(&self, callback: F) -> NotificationSubscription
    where
        F: Fn(NotificationUpdate) + Send + Sync + 'static,
    {
        let roots = self
            .repos()
            .iter()
            .map(|repo| repo.root_directory.clone())
            .collect::<Vec<_>>();
        let subscription =
            super::sync_events::subscribe(std::sync::Arc::new(move |event| match event {
                super::sync_events::SyncCommitted::Repository {
                    root_directory,
                    repo_id,
                } if roots.contains(root_directory) => {
                    callback(NotificationUpdate::RepositoryChanged {
                        repo_id: repo_id.clone(),
                    })
                }
                _ => {}
            }));
        NotificationSubscription {
            _sync_subscription: subscription,
        }
    }

    /// 本地重新加载也是数据提交入口，普通只读查询不广播更新。
    pub async fn reload(&mut self) -> Result<(), CoreError> {
        for repo in &mut self.repos {
            repo.load::<crate::webdav::WebDavSyncPolicy>().await?;
            super::sync_events::publish(repo);
        }
        Ok(())
    }

}
