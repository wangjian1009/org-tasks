//! 通知集合只投影文件服务推送的事实；回调在 NotificationCenter::process 中执行。
use crate::{CoreError, OrgRepo, OrgRepoId, OrgWorkspace};
use crate::repository_errors::{RepositoryError, RepositoryErrorSnapshot};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Weak;
use tokio::sync::watch;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CoreNotification {
    SyncConflict(SyncConflictNotification),
    SyncRequired,
    SyncBaselineUnavailable {
        #[serde(rename = "repoId")]
        repo_id: OrgRepoId,
        reason: SyncBaselineFailure,
    },
    RepositoryRootMissing {
        #[serde(rename = "rootDirectory")]
        root_directory: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NotificationScope {
    pub repository_error_roots: Vec<String>,
    pub sync_roots: Vec<String>,
}

pub(crate) enum NotificationSelection {
    RepoIds(Option<Vec<OrgRepoId>>),
    Roots(NotificationScope),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncBaselineFailure {
    Missing,
    Invalid,
    Inconsistent,
    Io,
}
impl SyncBaselineFailure {
    pub(crate) fn from_error(error: &CoreError) -> Self {
        let message = error.to_string();
        if message.contains("丢失") || message.contains("缺少") {
            Self::Missing
        } else if message.contains("不一致") || message.contains("已改变") {
            Self::Inconsistent
        } else if message.contains("无效") || message.contains("格式") || message.contains("校验")
        {
            Self::Invalid
        } else {
            Self::Io
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncConflictNotification {
    pub repo_id: OrgRepoId,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSnapshot {
    pub revision: u64,
    pub notifications: Vec<CoreNotification>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationDelta {
    pub from_revision: u64,
    pub revision: u64,
    pub changes: Vec<NotificationChange>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum NotificationChange {
    Added {
        notification: CoreNotification,
    },
    Removed {
        notification: CoreNotification,
    },
    Updated {
        before: CoreNotification,
        after: CoreNotification,
    },
}
impl NotificationDelta {
    /// 原子应用完整值的增删改；版本不连续时拒绝，不主动查询。
    pub fn apply(&self, snapshot: &mut NotificationSnapshot) -> Result<(), CoreError> {
        if snapshot.revision != self.from_revision || self.revision <= self.from_revision {
            return Err(CoreError::InvalidState("通知增量版本不连续"));
        }
        let mut values = snapshot.notifications.clone();
        for change in &self.changes {
            let (before, after) = match change {
                NotificationChange::Added { notification } => (None, Some(notification)),
                NotificationChange::Removed { notification } => (Some(notification), None),
                NotificationChange::Updated { before, after } => (Some(before), Some(after)),
            };
            if let Some(before) = before {
                values.retain(|value| value != before);
            }
            if let Some(after) = after
                && !values.contains(after)
            {
                values.push(after.clone());
            }
        }
        order_notifications(&mut values);
        snapshot.notifications = values;
        snapshot.revision = self.revision;
        Ok(())
    }
}

pub trait NotificationMonitor: Send + Sync + 'static {
    fn snapshot(&self, snapshot: NotificationSnapshot);
    fn changed(&self, delta: NotificationDelta);
}
impl<S, C> NotificationMonitor for (S, C)
where
    S: Fn(NotificationSnapshot) + Send + Sync + 'static,
    C: Fn(NotificationDelta) + Send + Sync + 'static,
{
    fn snapshot(&self, value: NotificationSnapshot) {
        self.0(value);
    }
    fn changed(&self, value: NotificationDelta) {
        self.1(value);
    }
}
pub struct NotificationSubscription {
    _subscription: super::notification_center::Subscription,
}
impl OrgWorkspace {
    /// 先发送缓存快照，随后只发送变化；注册不读取文件。
    pub fn watch_notifications<M: NotificationMonitor>(
        &self,
        repo_ids: Option<Vec<OrgRepoId>>,
        monitor: M,
    ) -> Result<NotificationSubscription, CoreError> {
        self.tasks.ensure_running()?;
        if repo_ids
            .iter()
            .flatten()
            .any(|id| !self.repos().iter().any(|repo| &repo.id == id))
        {
            return Err(CoreError::InvalidInput("通知订阅仓库不属于 workspace"));
        }
        Ok(NotificationSubscription {
            _subscription: self
                .notifications
                .watch_notifications(NotificationSelection::RepoIds(repo_ids), Box::new(monitor)),
        })
    }

    pub fn watch_notifications_with_scope<M: NotificationMonitor>(
        &self,
        scope: NotificationScope,
        monitor: M,
    ) -> Result<NotificationSubscription, CoreError> {
        self.tasks.ensure_running()?;
        Ok(NotificationSubscription {
            _subscription: self.notifications
                .watch_notifications(NotificationSelection::Roots(scope), Box::new(monitor)),
        })
    }
}

pub(crate) enum NotificationRequest {
    Subscribe {
        selection: NotificationSelection,
        token: Weak<()>,
        monitor: Box<dyn NotificationMonitor>,
        active: watch::Sender<bool>,
    },
    Unsubscribe(Weak<()>),
    Configure(Vec<OrgRepo>),
    FileStates(crate::file_state::FileStateEvent),
    RepositoryErrors(RepositoryErrorSnapshot),
}
struct Monitor {
    selection: NotificationSelection,
    token: Weak<()>,
    monitor: Box<dyn NotificationMonitor>,
    active: watch::Sender<bool>,
    last: NotificationSnapshot,
}
impl Drop for Monitor {
    fn drop(&mut self) {
        self.active.send_replace(false);
    }
}
#[derive(Default)]
pub(crate) struct NotificationState {
    repos: Vec<OrgRepo>,
    cache: BTreeMap<String, (u64, u64, Vec<CoreNotification>)>,
    repository_errors: Option<(u64, Vec<CoreNotification>)>,
    monitors: Vec<Monitor>,
    revision: u64,
}
impl NotificationState {
    pub(crate) fn handle(
        &mut self,
        request: NotificationRequest,
        center: &super::NotificationCenter,
    ) {
        match request {
            NotificationRequest::Subscribe {
                selection,
                token,
                monitor,
                active,
            } => {
                let last = NotificationSnapshot {
                    revision: self.revision,
                    notifications: self.values(&selection),
                };
                monitor.snapshot(last.clone());
                let repo_ids = match &selection {
                    NotificationSelection::RepoIds(ids) => ids.clone(),
                    NotificationSelection::Roots(scope) => Some(self.repos.iter()
                        .filter(|repo| scope.sync_roots.contains(&repo.root_directory))
                        .map(|repo| repo.id.clone()).collect()),
                };
                center.files().request_snapshot(repo_ids);
                self.monitors.push(Monitor {
                    selection,
                    token,
                    monitor,
                    active,
                    last,
                });
            }
            NotificationRequest::Unsubscribe(token) => self
                .monitors
                .retain(|monitor| !monitor.token.ptr_eq(&token)),
            NotificationRequest::Configure(repos) => {
                self.cache.retain(|id, _| {
                    repos.iter().any(|repo| {
                        &repo.id == id
                            && self.repos.iter().any(|old| {
                                old.id == repo.id && old.root_directory == repo.root_directory
                            })
                    })
                });
                self.repos = repos;
            }
            NotificationRequest::FileStates(event) => {
                let Some(repo) = self.repos.iter().find(|repo| repo.id == event.repo_id) else {
                    return;
                };
                if center.files().epoch(repo) != Some(event.epoch) {
                    return;
                }
                if self
                    .cache
                    .get(&event.repo_id)
                    .is_some_and(|(epoch, revision, _)| {
                        *epoch > event.epoch
                            || (*epoch == event.epoch && *revision >= event.revision)
                    })
                {
                    return;
                }
                let mut values = Vec::new();
                if let crate::file_state::BaselineState::Unavailable(reason) = event.baseline {
                    values.push(CoreNotification::SyncBaselineUnavailable {
                        repo_id: event.repo_id.clone(),
                        reason,
                    });
                }
                for (path, file) in &event.files {
                    if matches!(
                        file.current,
                        crate::file_state::CurrentFileState::Present {
                            has_conflict: true,
                            ..
                        }
                    ) {
                        values.push(CoreNotification::SyncConflict(SyncConflictNotification {
                            repo_id: event.repo_id.clone(),
                            path: path.clone(),
                        }));
                    }
                }
                if event
                    .files
                    .values()
                    .any(|file| file.local_change == Some(true))
                {
                    values.push(CoreNotification::SyncRequired);
                }
                self.cache
                    .insert(event.repo_id, (event.epoch, event.revision, values));
            }
            NotificationRequest::RepositoryErrors(snapshot) => {
                if self.repository_errors.as_ref().is_some_and(|(revision, _)| *revision >= snapshot.revision) {
                    return;
                }
                let values = snapshot.errors.into_iter().map(|entry| match entry.error {
                    RepositoryError::RootMissing => CoreNotification::RepositoryRootMissing {
                        root_directory: entry.root_directory,
                    },
                }).collect();
                self.repository_errors = Some((snapshot.revision, values));
            }
        }
        self.monitors
            .retain(|monitor| monitor.token.strong_count() > 0);
        self.revision += 1;
        let updates = self
            .monitors
            .iter()
            .map(|monitor| self.values(&monitor.selection))
            .collect::<Vec<_>>();
        for (monitor, values) in self.monitors.iter_mut().zip(updates) {
            let removed = monitor
                .last
                .notifications
                .iter()
                .filter(|value| !values.contains(value))
                .cloned()
                .collect::<Vec<_>>();
            let mut added = values
                .iter()
                .filter(|value| !monitor.last.notifications.contains(value))
                .cloned()
                .collect::<Vec<_>>();
            let mut changes = Vec::new();
            for before in removed {
                let replacement = if let CoreNotification::SyncBaselineUnavailable {
                    repo_id, ..
                } = &before
                {
                    added.iter().position(|after| matches!(after, CoreNotification::SyncBaselineUnavailable { repo_id: id, .. } if id == repo_id))
                } else {
                    None
                };
                if let Some(index) = replacement {
                    changes.push(NotificationChange::Updated {
                        before,
                        after: added.remove(index),
                    });
                } else {
                    changes.push(NotificationChange::Removed {
                        notification: before,
                    });
                }
            }
            changes.extend(
                added
                    .into_iter()
                    .map(|notification| NotificationChange::Added { notification }),
            );
            if changes.is_empty() {
                continue;
            }
            let delta = NotificationDelta {
                from_revision: monitor.last.revision,
                revision: self.revision,
                changes,
            };
            monitor.last = NotificationSnapshot {
                revision: self.revision,
                notifications: values,
            };
            monitor.monitor.changed(delta);
        }
    }
    fn values(&self, selection: &NotificationSelection) -> Vec<CoreNotification> {
        let mut values = Vec::new();
        let mut dirty = false;
        if let Some((_, errors)) = &self.repository_errors {
            values.extend(errors.iter().filter(|notification| {
                let CoreNotification::RepositoryRootMissing { root_directory } = notification else { return false };
                match selection {
                    NotificationSelection::RepoIds(None) => true,
                    NotificationSelection::RepoIds(Some(ids)) => self.repos.iter().any(|repo| {
                        repo.root_directory == *root_directory && ids.contains(&repo.id)
                    }),
                    NotificationSelection::Roots(scope) => scope.repository_error_roots.contains(root_directory),
                }
            }).cloned());
        }
        for repo in &self.repos {
            let selected = match selection {
                NotificationSelection::RepoIds(ids) => ids.as_ref().is_none_or(|ids| ids.contains(&repo.id)),
                NotificationSelection::Roots(scope) => scope.sync_roots.contains(&repo.root_directory),
            };
            if !selected {
                continue;
            }
            for notification in self.notifications_for_repo(&repo.id) {
                if notification == CoreNotification::SyncRequired {
                    dirty = true;
                } else if !values.contains(&notification) {
                    values.push(notification);
                }
            }
        }
        if dirty {
            values.push(CoreNotification::SyncRequired);
        }
        order_notifications(&mut values);
        values
    }
    pub(crate) fn notifications_for_repo(&self, repo_id: &str) -> Vec<CoreNotification> {
        self.cache
            .get(repo_id)
            .map(|(_, _, values)| values.clone())
            .unwrap_or_default()
    }
}

// 通知按完整值维护集合，所有消费者使用同一稳定展示顺序。
fn order_notifications(values: &mut [CoreNotification]) {
    fn key(value: &CoreNotification) -> (u8, &str, u8, &str) {
        match value {
            CoreNotification::RepositoryRootMissing { root_directory } => (1, root_directory, 0, ""),
            CoreNotification::SyncRequired => (2, "", 0, ""),
            CoreNotification::SyncConflict(file) => (0, &file.repo_id, 1, &file.path),
            CoreNotification::SyncBaselineUnavailable { repo_id, .. } => (0, repo_id, 0, ""),
        }
    }
    values.sort_by(|left, right| key(left).cmp(&key(right)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::file_state::BaselineState;
    #[tokio::test]
    async fn monitor_snapshots_scopes_updates_and_cancellation_follow_channel_order() {
        let root = std::env::temp_dir().join(format!(
            "notification-monitor-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        tokio::fs::create_dir_all(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        let (send, mut receive) = tokio::sync::mpsc::unbounded_channel();
        let snapshot_send = send.clone();
        let monitor = workspace
            .watch_notifications(
                None,
                (
                    move |snapshot: NotificationSnapshot| {
                        let _ = snapshot_send.send((true, serde_json::to_value(snapshot).unwrap()));
                    },
                    move |delta: NotificationDelta| {
                        let _ = send.send((false, serde_json::to_value(delta).unwrap()));
                    },
                ),
            )
            .unwrap();
        workspace.notifications.flush().await.unwrap();
        let (initial, value) = receive.recv().await.unwrap();
        assert!(initial);
        assert_eq!(value["notifications"], serde_json::json!([]));
        for (index, reason) in [SyncBaselineFailure::Missing, SyncBaselineFailure::Invalid]
            .into_iter()
            .enumerate()
        {
            let files = workspace.notifications.files();
            files
                .apply_repository(
                    &repo,
                    files.stamp(&repo, &workspace.notifications),
                    BaselineState::Unavailable(reason),
                    vec![],
                    false,
                )
                .unwrap();
            workspace.notifications.flush().await.unwrap();
            let (initial, delta) = receive.recv().await.unwrap();
            assert!(!initial);
            assert_eq!(
                delta["changes"][0]["kind"],
                if index == 0 { "added" } else { "updated" }
            );
            if index == 1 {
                assert_eq!(delta["changes"][0]["before"]["reason"], "missing");
                assert_eq!(delta["changes"][0]["after"]["reason"], "invalid");
            } else {
                assert_eq!(delta["changes"][0]["kind"], "added");
            }
        }
        let (empty_send, mut empty) = tokio::sync::mpsc::unbounded_channel();
        let _empty = workspace
            .watch_notifications(
                Some(vec![]),
                (
                    move |snapshot: NotificationSnapshot| {
                        let _ = empty_send.send(snapshot);
                    },
                    |_: NotificationDelta| panic!("空范围不应收到变化"),
                ),
            )
            .unwrap();
        workspace.notifications.flush().await.unwrap();
        assert!(empty.recv().await.unwrap().notifications.is_empty());
        drop(monitor);
        let files = workspace.notifications.files();
        files
            .apply_repository(
                &repo,
                files.stamp(&repo, &workspace.notifications),
                BaselineState::Uninitialized,
                vec![],
                false,
            )
            .unwrap();
        workspace.notifications.flush().await.unwrap();
        assert!(receive.try_recv().is_err());
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
