//! Core 判断的当前待关注事件；查询不消费事件，也不保存通知记录。
use serde::{Deserialize, Serialize};

use super::{OrgRepo, OrgRepoId, OrgRepoSyncRecordId, OrgWorkspace};
use crate::CoreError;
use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

/// 单一通知之外仅跟踪仓库确认代次，防止多仓库或并发解决提前清除提示；不保存路径或正文。
#[derive(Default)]
struct RequiredSyncState {
    generation: u64,
    repositories: BTreeMap<String, u64>,
}
impl RequiredSyncState {
    fn insert(&mut self, repo_id: &str) -> bool {
        let first = self.repositories.is_empty();
        self.generation += 1;
        self.repositories.insert(repo_id.into(), self.generation);
        first
    }
    fn confirm(&mut self, repo_id: &str, version: Option<u64>) -> bool {
        if version.is_none() || self.repositories.get(repo_id).copied() != version {
            return false;
        }
        self.repositories.remove(repo_id);
        self.repositories.is_empty()
    }
}
fn required_state() -> &'static Mutex<RequiredSyncState> {
    static STATE: OnceLock<Mutex<RequiredSyncState>> = OnceLock::new();
    STATE.get_or_init(Default::default)
}
pub(crate) fn require_sync(repo_id: &str) {
    let changed = required_state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(repo_id);
    if changed {
        super::sync_events::publish_global();
    }
}
pub(crate) fn sync_required_version(repo_id: &str) -> Option<u64> {
    required_state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .repositories
        .get(repo_id)
        .copied()
}
pub(crate) fn confirm_required_sync(repo_id: &str, version: Option<u64>) {
    let changed = required_state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .confirm(repo_id, version);
    if changed {
        super::sync_events::publish_global();
    }
}

#[cfg(test)]
use crate::webdav::WebDavSyncPolicy;

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
    pub sync_id: OrgRepoSyncRecordId,
    pub paths: Vec<String>,
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
    /// 从当前本地历史恢复待处理事件；仓库应先加载以取得稳定 Core ID。
    pub async fn notifications(&self) -> Result<Vec<CoreNotification>, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        let Some(record) = self.last_effect_sync().await? else {
            return Ok(Vec::new());
        };
        let paths = record
            .files
            .iter()
            .filter(|file| crate::webdav::history_is_conflict(file) && !file.detail.resolved)
            .map(|file| file.relative_path.clone())
            .collect::<Vec<_>>();
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![CoreNotification::SyncConflict(
            SyncConflictNotification {
                repo_id: self.id.clone(),
                sync_id: record.id,
                paths,
            },
        )])
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
                super::sync_events::SyncCommitted::GlobalNotificationsChanged => {
                    callback(NotificationUpdate::GlobalNotificationsChanged)
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
        if !required_state()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .repositories
            .is_empty()
        {
            notifications.push(CoreNotification::SyncRequired);
        }
        Ok(notifications)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::webdav::{WebDavSyncContextDetail, WebDavSyncFileDetail};
    use crate::{
        OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState, OrgRepoSyncRecord,
        OrgRepoSyncResult,
    };
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[test]
    fn duplicate_notifications_and_stale_sync_confirmations_do_not_lose_new_resolutions() {
        let mut state = RequiredSyncState::default();
        assert!(state.insert("a"));
        let first = state.repositories.get("a").copied();
        assert!(!state.insert("a"));
        assert!(!state.confirm("a", first));
        assert!(state.repositories.contains_key("a"));
        assert!(!state.insert("b"));
        assert!(!state.confirm("a", state.repositories.get("a").copied()));
        assert!(state.confirm("b", state.repositories.get("b").copied()));
        assert!(state.repositories.is_empty());
        assert!(state.insert("c"));
    }

    struct Fixture {
        repo: OrgRepo,
        root: PathBuf,
    }

    impl Fixture {
        async fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!(
                "org-tasks-notifications-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            tokio::fs::create_dir(&root).await.unwrap();
            let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            repo.load::<WebDavSyncPolicy>().await.unwrap();
            Self { repo, root }
        }

        async fn append(
            &self,
            id: &str,
            time: i64,
            states: &[(&str, OrgRepoSyncFileState)],
            result: OrgRepoSyncResult,
        ) {
            let mut record =
                OrgRepoSyncRecord::<WebDavSyncContextDetail, WebDavSyncFileDetail>::new(
                    id.into(),
                    time,
                )
                .unwrap()
                .with_kind("webdav")
                .with_context_detail(WebDavSyncContextDetail { format_version: 1 });
            for (path, state) in states {
                let action = match state {
                    OrgRepoSyncFileState::Synchronized => OrgRepoSyncFileAction::Uploaded,
                    OrgRepoSyncFileState::Conflict => OrgRepoSyncFileAction::Conflicted,
                    _ => OrgRepoSyncFileAction::Skipped,
                };
                let mut file: OrgRepoSyncFileRecord<WebDavSyncFileDetail> =
                    OrgRepoSyncFileRecord::new((*path).into(), action, *state).unwrap();
                if matches!(
                    state,
                    OrgRepoSyncFileState::Conflict | OrgRepoSyncFileState::RemoteDeleted
                ) {
                    let bytes = b"* TODO Backup\n";
                    let folder = self.root.join(format!(".sync/history/{time}/files/{path}"));
                    tokio::fs::create_dir_all(&folder).await.unwrap();
                    tokio::fs::write(folder.join(path), bytes).await.unwrap();
                    file.detail.archive = Some(crate::webdav::WebDavFileArchive {
                        content_hash: crate::LocalFileVersion::from_bytes(bytes).content_hash,
                    });
                }
                record.append_file(file).unwrap();
            }
            let result = if states.iter().any(|(_, s)| {
                matches!(
                    s,
                    OrgRepoSyncFileState::Conflict | OrgRepoSyncFileState::RemoteDeleted
                )
            }) {
                OrgRepoSyncResult::Succeeded
            } else {
                result
            };
            record.finish(result, time + 1).unwrap();
            tokio::fs::write(
                self.root.join(format!(".sync/history/{time}.json")),
                serde_json::to_vec(&record).unwrap(),
            )
            .await
            .unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[tokio::test]
    async fn empty_and_execution_failure_only_histories_have_no_notifications() {
        assert!(
            OrgWorkspace::new(vec![])
                .unwrap()
                .notifications()
                .await
                .unwrap()
                .iter()
                .all(|n| !matches!(n, CoreNotification::SyncConflict(_)))
        );
        let fixture = Fixture::new().await;
        assert!(fixture.repo.notifications().await.unwrap().is_empty());
        fixture
            .append(
                "failed",
                1,
                &[("a.org", OrgRepoSyncFileState::Failed)],
                OrgRepoSyncResult::Failed,
            )
            .await;
        fixture
            .append("cancelled", 3, &[], OrgRepoSyncResult::Cancelled)
            .await;
        assert!(fixture.repo.notifications().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn conflict_events_repeat_until_each_path_is_resolved_without_rewriting_history() {
        use OrgRepoSyncFileState::{Conflict, Failed as FileFailed, RemoteDeleted, Synchronized};
        use OrgRepoSyncResult::Failed;
        let fixture = Fixture::new().await;
        fixture
            .append(
                "first",
                1,
                &[("a.org", Conflict), ("b.org", RemoteDeleted)],
                Failed,
            )
            .await;
        let original = tokio::fs::read(fixture.root.join(".sync/history/1.json"))
            .await
            .unwrap();
        let first = fixture.repo.notifications().await.unwrap();
        assert_eq!(
            first,
            vec![CoreNotification::SyncConflict(SyncConflictNotification {
                repo_id: fixture.repo.id.clone(),
                sync_id: "first".into(),
                paths: vec!["a.org".into(), "b.org".into()]
            })]
        );
        assert_eq!(fixture.repo.notifications().await.unwrap(), first);
        fixture
            .append("failed", 3, &[("a.org", FileFailed)], Failed)
            .await;
        assert_eq!(fixture.repo.notifications().await.unwrap(), first);
        fixture
            .append("second", 5, &[("a.org", Conflict)], Failed)
            .await;
        let notifications = fixture.repo.notifications().await.unwrap();
        assert_eq!(notifications.len(), 1);
        let CoreNotification::SyncConflict(notification) = &notifications[0] else {
            panic!("应为冲突通知")
        };
        assert_eq!(notification.sync_id, "second");
        assert_eq!(notification.paths, vec!["a.org"]);
        fixture
            .append(
                "partial",
                7,
                &[("a.org", Synchronized), ("b.org", FileFailed)],
                Failed,
            )
            .await;
        assert_eq!(fixture.repo.notifications().await.unwrap(), notifications);
        let folder = fixture.root.join(".sync/history/5/files/a.org");
        tokio::fs::write(folder.join("a.resolved.org"), "* TODO Result\n")
            .await
            .unwrap();
        assert!(fixture.repo.notifications().await.unwrap().is_empty());
        assert_eq!(
            fixture.repo.last_effect_sync().await.unwrap().unwrap().id,
            "second"
        );
        // 旧日志自己的未解决状态保留，但不会在最新冲突已解决后恢复旧通知。
        assert!(
            fixture
                .repo
                .pending_sync_conflicts()
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            tokio::fs::read(fixture.root.join(".sync/history/1.json"))
                .await
                .unwrap(),
            original
        );
    }

    #[tokio::test]
    async fn workspace_preserves_core_repository_identity_and_serializes_a_discriminated_event() {
        let first = Fixture::new().await;
        let second = Fixture::new().await;
        for fixture in [&first, &second] {
            fixture
                .append(
                    "same-sync",
                    1,
                    &[("same.org", OrgRepoSyncFileState::Conflict)],
                    OrgRepoSyncResult::Failed,
                )
                .await;
        }
        let workspace = OrgWorkspace::new(vec![first.repo.clone(), second.repo.clone()]).unwrap();
        let events = workspace
            .notifications()
            .await
            .unwrap()
            .into_iter()
            .filter(|e| matches!(e, CoreNotification::SyncConflict(_)))
            .collect::<Vec<_>>();
        assert_eq!(events.len(), 2);
        let value = serde_json::to_value(&events).unwrap();
        assert_eq!(value[0]["type"], "syncConflict");
        assert_eq!(value[0]["repoId"], first.repo.id);
        assert_eq!(value[1]["repoId"], second.repo.id);
        assert_eq!(value[0]["syncId"], "same-sync");
        assert_eq!(value[0]["paths"][0], "same.org");
        let round_trip: Vec<CoreNotification> = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(round_trip, events);
        let CoreNotification::SyncConflict(conflict) = &events[0] else {
            panic!("应为冲突通知")
        };
        assert_eq!(conflict.repo_id, first.repo.id);
        assert_eq!(value[0].as_object().unwrap().len(), 4);
        assert!(!value.to_string().contains(first.root.to_str().unwrap()));
    }

    #[tokio::test]
    async fn unloaded_or_unreadable_repositories_do_not_silently_hide_notifications() {
        let fixture = Fixture::new().await;
        let unloaded = OrgRepo::new(fixture.root.to_string_lossy().into()).unwrap();
        assert!(matches!(
            unloaded.notifications().await,
            Err(CoreError::InvalidState(_))
        ));
        tokio::fs::write(fixture.root.join(".sync/history/1.json"), b"broken history")
            .await
            .unwrap();
        let workspace = OrgWorkspace::new(vec![fixture.repo.clone()]).unwrap();
        assert!(matches!(
            workspace.notifications().await,
            Err(CoreError::Store(_))
        ));
    }
    #[tokio::test]
    async fn notification_watch_filters_repositories_and_unsubscribes() {
        let first = Fixture::new().await;
        let second = Fixture::new().await;
        let mut watched = OrgWorkspace::new(vec![first.repo.clone()]).unwrap();
        let mut unrelated = OrgWorkspace::new(vec![second.repo.clone()]).unwrap();
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = events.clone();
        let subscription = watched.watch_notifications(move |event| {
            if matches!(event, NotificationUpdate::RepositoryChanged { .. }) {
                captured.lock().unwrap().push(event);
            }
        });
        unrelated.reload().await.unwrap();
        assert!(events.lock().unwrap().is_empty());
        watched.reload().await.unwrap();
        assert_eq!(events.lock().unwrap().len(), 1);
        assert_eq!(
            events.lock().unwrap()[0],
            NotificationUpdate::RepositoryChanged {
                repo_id: first.repo.id.clone()
            }
        );
        drop(subscription);
        watched.reload().await.unwrap();
        assert_eq!(events.lock().unwrap().len(), 1);
        // 普通快照查询不广播，避免通知刷新递归产生更新。
        watched.notifications().await.unwrap();
        assert_eq!(events.lock().unwrap().len(), 1);
    }
}
