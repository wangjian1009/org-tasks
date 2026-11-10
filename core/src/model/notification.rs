//! Core 判断的当前待关注事件；查询不消费事件，也不保存通知记录。
use serde::{Deserialize, Serialize};

use super::{OrgRepo, OrgRepoId, OrgWorkspace};
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

/// 更新事件只表示需要重新查询；注意事项仍由 notifications 接口独立提供。
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

impl OrgRepo {
    /// 每个当前冲突文件生成一条通知；仓库应先加载以取得最新文件与稳定身份。
    pub async fn notifications(&self) -> Result<Vec<CoreNotification>, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        Ok(self
            .load_files(&[]).await?
            .iter()
            .filter(|file| file.has_conflict())
            .map(|file| {
                CoreNotification::SyncConflict(SyncConflictNotification {
                    repo_id: self.id.clone(),
                    path: file.path.clone(),
                })
            })
            .collect())
    }
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

    /// 汇总已加载仓库当前的待关注事件；任一仓库读取失败即返回错误。
    pub async fn notifications(&self) -> Result<Vec<CoreNotification>, CoreError> {
        let mut notifications = Vec::new();
        for repo in self.repos() {
            notifications.extend(repo.notifications().await?);
        }
        let mut changed = false;
        for repo in self.repos() {
            if repo.has_local_changes().await? {
                changed = true;
            }
        }
        if changed {
            notifications.push(CoreNotification::SyncRequired);
        }
        Ok(notifications)
    }
}
