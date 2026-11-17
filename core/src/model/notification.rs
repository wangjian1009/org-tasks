//! 只订阅当前待关注事件；缓存、基线比较和回调均由通知处理任务维护。
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Weak;

use crate::{CoreError, OrgRepo, OrgRepoId, OrgWorkspace};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use tokio::task::JoinSet;

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

pub struct NotificationSubscription {
    _subscription: super::notification_center::Subscription,
}

impl OrgWorkspace {
    /// 注册后默认收到一次完整列表（包括空列表），随后仅在列表变化时回调。
    /// 冷缓存由独立任务加载；回调不能同步等待当前 Workspace 的后续业务命令。
    pub fn watch_notifications<F>(
        &self,
        repo_ids: Option<Vec<OrgRepoId>>,
        callback: F,
    ) -> Result<NotificationSubscription, CoreError>
    where
        F: Fn(Vec<CoreNotification>) + Send + Sync + 'static,
    {
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
                .watch_notifications(repo_ids, Box::new(callback)),
        })
    }
}

pub(crate) type NotificationCallback = Box<dyn Fn(Vec<CoreNotification>) + Send + Sync>;

pub(crate) enum NotificationRequest {
    Subscribe {
        repo_ids: Option<Vec<OrgRepoId>>,
        token: Weak<()>,
        callback: NotificationCallback,
        active: watch::Sender<bool>,
    },
    Unsubscribe(Weak<()>),
    Configure(Vec<OrgRepo>),
    Snapshot {
        repo_id: String,
        data: RepositoryNotifications,
    },
    Files {
        repo_id: String,
        revision: u64,
        files: Vec<super::FileDataChange>,
        conflicts: bool,
    },
}

/// revision 只用于本 Workspace 内排除迟到结果；在仓库锁内分配，不是持久化时间。
#[derive(Clone, Debug)]
pub(crate) struct RepositoryNotifications {
    revision: u64,
    baseline: Option<BTreeMap<String, Option<String>>>,
    current: BTreeMap<String, String>,
    conflicts: BTreeSet<String>,
}

impl RepositoryNotifications {
    pub(crate) async fn load(
        repo: &OrgRepo,
        center: &super::NotificationCenter,
    ) -> Result<Self, CoreError> {
        let root = std::path::Path::new(&repo.root_directory);
        let _guard = crate::webdav::transaction::lock(root).await?;
        Self::load_unlocked(repo, center).await
    }

    pub(crate) async fn publish(
        repo: &OrgRepo,
        center: &super::NotificationCenter,
    ) -> Result<(), CoreError> {
        let _guard =
            crate::webdav::transaction::lock(std::path::Path::new(&repo.root_directory)).await?;
        let data = Self::load_unlocked(repo, center).await?;
        // 在同一仓库锁内分配顺序并入队，避免后续文件事件先应用后丢失新基线。
        center.update_snapshot(repo.id.clone(), data);
        Ok(())
    }

    async fn load_unlocked(
        repo: &OrgRepo,
        center: &super::NotificationCenter,
    ) -> Result<Self, CoreError> {
        let root = std::path::Path::new(&repo.root_directory);
        super::access::recover(root, &repo.id).await?;
        let files = repo.load_files_unlocked(&[]).await?;
        let baseline = crate::webdav::remote_base::notification_baseline(root).await?;
        let mut current = files
            .iter()
            .map(|file| {
                (
                    file.path.clone(),
                    crate::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                )
            })
            .collect::<BTreeMap<_, _>>();
        // 基线中的非 Org 文件（如扫描规则）同样参与本地差异判断。
        for path in baseline
            .iter()
            .flat_map(|entries| entries.keys())
            .filter(|path| !path.ends_with(".org"))
        {
            if let Some(bytes) = crate::webdav::transaction::read(root, path).await? {
                current.insert(
                    path.clone(),
                    crate::LocalFileVersion::from_bytes(&bytes).content_hash,
                );
            }
        }
        Ok(Self {
            revision: center.next_revision(),
            baseline,
            current,
            conflicts: files
                .iter()
                .filter(|file| file.has_conflict())
                .map(|file| file.path.clone())
                .collect(),
        })
    }

    fn apply(&mut self, revision: u64, files: &[super::FileDataChange], conflicts: bool) {
        if revision <= self.revision {
            return;
        }
        for file in files {
            self.current
                .insert(file.after.path.clone(), file.after_version.clone());
            // 普通任务修改不生成冲突通知；只有解决冲突业务可以变更冲突集合。
            if conflicts {
                if file.after.has_conflict {
                    self.conflicts.insert(file.after.path.clone());
                } else {
                    self.conflicts.remove(&file.after.path);
                }
            }
        }
        self.revision = revision;
    }

    fn dirty(&self) -> bool {
        let Some(baseline) = &self.baseline else {
            return false;
        };
        self.current
            .iter()
            .any(|(path, hash)| baseline.get(path).and_then(Option::as_ref) != Some(hash))
            || baseline
                .iter()
                .any(|(path, hash)| hash.as_ref() != self.current.get(path))
    }
}

struct Monitor {
    repo_ids: Option<Vec<OrgRepoId>>,
    token: Weak<()>,
    callback: NotificationCallback,
    active: watch::Sender<bool>,
    last: Option<Vec<CoreNotification>>,
}
impl Drop for Monitor {
    fn drop(&mut self) {
        self.active.send_replace(false);
    }
}

#[derive(Default)]
pub(crate) struct NotificationState {
    repos: Vec<OrgRepo>,
    cache: BTreeMap<String, RepositoryNotifications>,
    monitors: Vec<Monitor>,
    pending: BTreeMap<String, Vec<(u64, Vec<super::FileDataChange>, bool)>>,
    generation: u64,
    loading: BTreeSet<String>,
}

pub(crate) type NotificationLoads =
    JoinSet<(u64, String, Result<RepositoryNotifications, CoreError>)>;

impl NotificationState {
    pub(crate) fn handle(
        &mut self,
        request: NotificationRequest,
        loads: &mut NotificationLoads,
        center: &super::NotificationCenter,
    ) {
        match request {
            NotificationRequest::Subscribe {
                repo_ids,
                token,
                callback,
                active,
            } => {
                self.monitors.push(Monitor {
                    repo_ids,
                    token,
                    callback,
                    active,
                    last: None,
                });
            }
            NotificationRequest::Unsubscribe(token) => self
                .monitors
                .retain(|monitor| !monitor.token.ptr_eq(&token)),
            NotificationRequest::Configure(repos) => {
                if self.repos == repos {
                    return;
                }
                self.generation += 1;
                loads.abort_all();
                self.loading.clear();
                self.cache.retain(|id, _| {
                    repos.iter().any(|repo| {
                        &repo.id == id
                            && self.repos.iter().any(|old| {
                                old.id == repo.id && old.root_directory == repo.root_directory
                            })
                    })
                });
                self.pending.clear();
                self.repos = repos;
            }
            NotificationRequest::Snapshot { repo_id, data } => self.install(repo_id, data),
            NotificationRequest::Files {
                repo_id,
                revision,
                files,
                conflicts,
            } => {
                if let Some(cache) = self.cache.get_mut(&repo_id) {
                    cache.apply(revision, &files, conflicts);
                } else if self.loading.contains(&repo_id) {
                    self.pending
                        .entry(repo_id)
                        .or_default()
                        .push((revision, files, conflicts));
                }
            }
        }
        self.monitors
            .retain(|monitor| monitor.token.strong_count() > 0);
        self.notify();
        if !self.monitors.is_empty() {
            for repo in &self.repos {
                if !self.monitors.iter().any(|monitor| {
                    monitor
                        .repo_ids
                        .as_ref()
                        .is_none_or(|ids| ids.contains(&repo.id))
                }) || self.cache.contains_key(&repo.id)
                    || !self.loading.insert(repo.id.clone())
                {
                    continue;
                }
                let repo = repo.clone();
                let generation = self.generation;
                let center = center.clone();
                loads.spawn(async move {
                    let data = RepositoryNotifications::load(&repo, &center).await;
                    (generation, repo.id, data)
                });
            }
        }
    }

    pub(crate) fn loaded(
        &mut self,
        generation: u64,
        repo_id: String,
        data: Result<RepositoryNotifications, CoreError>,
    ) {
        if generation != self.generation {
            return;
        }
        self.loading.remove(&repo_id);
        match data {
            Ok(data) => self.install(repo_id, data),
            Err(error) => {
                eprintln!("加载通知失败: {error}");
            }
        }
        self.notify();
    }

    fn install(&mut self, repo_id: String, mut data: RepositoryNotifications) {
        if !self.repos.iter().any(|repo| repo.id == repo_id) {
            return;
        }
        if self
            .cache
            .get(&repo_id)
            .is_some_and(|old| old.revision >= data.revision)
        {
            return;
        }
        if let Some(mut pending) = self.pending.remove(&repo_id) {
            pending.sort_by_key(|(revision, _, _)| *revision);
            for (revision, files, conflicts) in pending {
                data.apply(revision, &files, conflicts);
            }
        }
        self.cache.insert(repo_id, data);
    }

    fn notify(&mut self) {
        for monitor in &mut self.monitors {
            if monitor.token.strong_count() == 0 {
                continue;
            }
            let repos = self
                .repos
                .iter()
                .filter(|repo| {
                    monitor
                        .repo_ids
                        .as_ref()
                        .is_none_or(|ids| ids.contains(&repo.id))
                })
                .collect::<Vec<_>>();
            if repos.iter().any(|repo| !self.cache.contains_key(&repo.id)) {
                continue;
            }
            let mut notifications = Vec::new();
            for repo in &repos {
                for path in &self.cache[&repo.id].conflicts {
                    notifications.push(CoreNotification::SyncConflict(SyncConflictNotification {
                        repo_id: repo.id.clone(),
                        path: path.clone(),
                    }));
                }
            }
            if repos.iter().any(|repo| self.cache[&repo.id].dirty()) {
                notifications.push(CoreNotification::SyncRequired);
            }
            if monitor.last.as_ref() != Some(&notifications) {
                monitor.last = Some(notifications.clone());
                (monitor.callback)(notifications);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn snapshot(revision: u64, source: &str) -> RepositoryNotifications {
        RepositoryNotifications {
            revision,
            baseline: Some(BTreeMap::from([("a.org".into(), Some("base".into()))])),
            current: BTreeMap::from([("a.org".into(), source.into())]),
            conflicts: BTreeSet::new(),
        }
    }
    fn changed(source: &str, conflict: bool) -> super::super::FileDataChange {
        let text = if conflict {
            "* Conflict :CONFLICT:\n"
        } else {
            "* Normal\n"
        };
        let file =
            crate::OrgFile::new("repo".into(), "a.org".into(), text.as_bytes().to_vec()).unwrap();
        super::super::FileDataChange {
            before: None,
            after: file.metadata(false),
            before_version: None,
            after_version: source.into(),
        }
    }
    fn state() -> NotificationState {
        NotificationState {
            repos: vec![OrgRepo {
                id: "repo".into(),
                root_directory: "/unused".into(),
                todo_defaults: Default::default(),
            }],
            ..Default::default()
        }
    }
    fn monitor(
        state: &mut NotificationState,
        scope: Option<Vec<String>>,
    ) -> (Arc<()>, Arc<Mutex<Vec<Vec<CoreNotification>>>>) {
        let token = Arc::new(());
        let received = Arc::new(Mutex::new(Vec::new()));
        let sending = received.clone();
        let (active, _) = watch::channel(true);
        state.monitors.push(Monitor {
            repo_ids: scope,
            token: Arc::downgrade(&token),
            callback: Box::new(move |list| sending.lock().unwrap().push(list)),
            active,
            last: None,
        });
        (token, received)
    }

    #[test]
    fn initial_empty_list_and_cached_subscribers_receive_once_and_only_changes_follow() {
        let mut state = state();
        state.install("repo".into(), snapshot(1, "base"));
        let (_token, received) = monitor(&mut state, None);
        state.notify();
        state.notify();
        assert_eq!(
            *received.lock().unwrap(),
            vec![Vec::<CoreNotification>::new()]
        );
        let (_other, cached) = monitor(&mut state, None);
        state.notify();
        assert_eq!(cached.lock().unwrap().len(), 1);
        state
            .cache
            .get_mut("repo")
            .unwrap()
            .apply(2, &[changed("new", false)], false);
        state.notify();
        state
            .cache
            .get_mut("repo")
            .unwrap()
            .apply(3, &[changed("another", false)], false);
        state.notify();
        assert_eq!(received.lock().unwrap().len(), 2);
        state
            .cache
            .get_mut("repo")
            .unwrap()
            .apply(4, &[changed("base", false)], false);
        state.notify();
        assert_eq!(received.lock().unwrap().last().unwrap(), &[]);
    }

    #[test]
    fn cold_load_replays_newer_checksums_and_rejects_late_snapshots() {
        let mut state = state();
        state.loading.insert("repo".into());
        let (_token, received) = monitor(&mut state, None);
        let (center, _) = super::super::NotificationCenter::new();
        state.handle(
            NotificationRequest::Files {
                repo_id: "repo".into(),
                revision: 2,
                files: vec![changed("edited", false)],
                conflicts: false,
            },
            &mut NotificationLoads::new(),
            &center,
        );
        assert!(received.lock().unwrap().is_empty());
        state.loaded(0, "repo".into(), Ok(snapshot(1, "base")));
        assert_eq!(
            *received.lock().unwrap(),
            vec![vec![CoreNotification::SyncRequired]]
        );
        state.install("repo".into(), snapshot(4, "base"));
        state.install("repo".into(), snapshot(3, "edited"));
        state
            .cache
            .get_mut("repo")
            .unwrap()
            .apply(2, &[changed("edited", false)], false);
        state.notify();
        assert_eq!(received.lock().unwrap().last().unwrap(), &[]);
    }

    #[test]
    fn conflicts_and_dirty_files_use_separate_baselines_and_scopes() {
        let mut state = state();
        let mut data = snapshot(1, "base");
        data.conflicts.insert("a.org".into());
        data.apply(2, &[changed("base", false)], false);
        assert_eq!(data.conflicts.len(), 1);
        data.apply(3, &[changed("edited", false)], true);
        assert!(data.conflicts.is_empty());
        assert!(data.dirty());
        data.baseline = None;
        assert!(!data.dirty());
        state.install("repo".into(), data);
        let (_empty, received) = monitor(&mut state, Some(vec![]));
        state.notify();
        assert_eq!(
            *received.lock().unwrap(),
            vec![Vec::<CoreNotification>::new()]
        );
        let mut deleted = snapshot(1, "base");
        deleted.current.clear();
        assert!(deleted.dirty());
        deleted.baseline = Some(BTreeMap::from([("a.org".into(), None)]));
        assert!(!deleted.dirty());
        deleted.current.insert(
            "a.org".into(),
            crate::LocalFileVersion::from_bytes(b"").content_hash,
        );
        assert!(deleted.dirty());
    }

    #[tokio::test]
    async fn cold_search_does_not_block_channel_or_unsubscription() {
        let root = std::env::temp_dir().join(format!(
            "notification-cold-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        tokio::fs::create_dir_all(&root).await.unwrap();
        tokio::fs::write(root.join("a.org"), b"* A\n")
            .await
            .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        let guard = crate::webdav::transaction::lock(&root).await.unwrap();
        let (send, mut received) = tokio::sync::mpsc::unbounded_channel();
        let subscription = workspace
            .watch_notifications(None, move |list| {
                let _ = send.send(list);
            })
            .unwrap();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            workspace.notifications.flush(),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(received.try_recv().is_err());
        drop(subscription);
        workspace.notifications.flush().await.unwrap();
        let (send, mut current) = tokio::sync::mpsc::unbounded_channel();
        let _subscription = workspace
            .watch_notifications(None, move |list| {
                let _ = send.send(list);
            })
            .unwrap();
        drop(guard);
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(2), current.recv())
                .await
                .unwrap()
                .unwrap()
                .is_empty()
        );
        assert!(received.try_recv().is_err());
        assert!(
            workspace
                .watch_notifications(Some(vec!["missing".into()]), |_| {})
                .is_err()
        );
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
