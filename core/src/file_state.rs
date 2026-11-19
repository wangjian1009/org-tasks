//! 已观察文件的状态服务；只加载基线元数据，不为通知读取业务文件。
use crate::model::NotificationCenter;
use crate::{CoreError, LocalFileVersion, OrgFile, OrgRepo, SyncBaselineFailure};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, RwLock};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;

tokio::task_local! { pub(crate) static OBSERVER: NotificationCenter; }
tokio::task_local! { pub(crate) static CAPTURE: Arc<std::sync::Mutex<BTreeMap<String, CurrentFileState>>>; }

pub(crate) fn observe(repo: &OrgRepo, files: Vec<(String, CurrentFileState)>) {
    if CAPTURE
        .try_with(|capture| capture.lock().unwrap().extend(files.clone()))
        .is_ok()
    {
        return;
    }
    let _ = OBSERVER.try_with(|center| {
        let stamp = center.files().stamp(repo, center);
        let _ = center.files().update_files(repo, stamp, files);
    });
}

#[derive(Clone, Debug)]
pub(crate) struct FileStateManager {
    sender: mpsc::UnboundedSender<Command>,
    epochs: Arc<RwLock<BTreeMap<String, (String, u64)>>>,
}
impl PartialEq for FileStateManager {
    fn eq(&self, other: &Self) -> bool {
        self.sender.same_channel(&other.sender)
    }
}
impl Eq for FileStateManager {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum BaselineState {
    Loading,
    Uninitialized,
    Ready(BTreeMap<String, Option<String>>),
    Unavailable(SyncBaselineFailure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum CurrentFileState {
    Present { version: String, has_conflict: bool },
    Missing,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileState {
    pub current: CurrentFileState,
    pub local_change: Option<bool>,
}
#[derive(Clone, Debug)]
pub(crate) struct FileStateEvent {
    pub repo_id: String,
    pub epoch: u64,
    pub revision: u64,
    pub baseline: BaselineState,
    pub files: BTreeMap<String, FileState>,
}
#[derive(Clone)]
pub(crate) struct Stamp {
    epoch: u64,
    revision: u64,
}
impl Stamp {
    pub(crate) fn set_revision(&mut self, revision: u64) {
        self.revision = revision;
    }
}

pub(crate) enum Command {
    Configure(Vec<(OrgRepo, u64)>),
    UpdateFiles {
        repo: OrgRepo,
        stamp: Stamp,
        files: Vec<(String, CurrentFileState)>,
    },
    DeleteFiles {
        repo: OrgRepo,
        stamp: Stamp,
        paths: Vec<String>,
    },
    ApplyRepository {
        repo: OrgRepo,
        stamp: Stamp,
        baseline: BaselineState,
        files: Vec<(String, CurrentFileState)>,
        reset: bool,
    },
    Snapshot(Option<Vec<String>>),
    Query {
        repo_id: String,
        reply: oneshot::Sender<BTreeMap<String, FileState>>,
    },
    Flush(oneshot::Sender<()>),
    Ready(oneshot::Sender<()>),
    Stop(oneshot::Sender<()>),
}

struct Repository {
    repo: OrgRepo,
    epoch: u64,
    baseline_revision: u64,
    minimum_revision: u64,
    baseline: BaselineState,
    files: BTreeMap<String, (u64, CurrentFileState)>,
}
impl Repository {
    fn event(&self, revision: u64) -> FileStateEvent {
        let files = self
            .files
            .iter()
            .map(|(path, (_, current))| {
                let local_change = match &self.baseline {
                    BaselineState::Ready(base) => {
                        let hash = match current {
                            CurrentFileState::Present { version, .. } => Some(version),
                            CurrentFileState::Missing => None,
                        };
                        Some(base.get(path).and_then(Option::as_ref) != hash)
                    }
                    _ => None,
                };
                (
                    path.clone(),
                    FileState {
                        current: current.clone(),
                        local_change,
                    },
                )
            })
            .collect();
        FileStateEvent {
            repo_id: self.repo.id.clone(),
            epoch: self.epoch,
            revision,
            baseline: self.baseline.clone(),
            files,
        }
    }
    fn apply(&mut self, stamp: &Stamp, files: Vec<(String, CurrentFileState)>) {
        if stamp.epoch != self.epoch || stamp.revision <= self.minimum_revision {
            return;
        }
        for (path, current) in files {
            if self
                .files
                .get(&path)
                .is_none_or(|(revision, _)| *revision < stamp.revision)
            {
                self.files.insert(path, (stamp.revision, current));
            }
        }
    }
}

impl FileStateManager {
    pub(crate) fn new() -> (Self, mpsc::UnboundedReceiver<Command>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (
            Self {
                sender,
                epochs: Default::default(),
            },
            receiver,
        )
    }
    fn send(&self, command: Command) -> Result<(), CoreError> {
        self.sender
            .send(command)
            .map_err(|_| CoreError::InvalidState("文件状态服务已停止"))
    }
    pub(crate) fn configure(&self, repos: Vec<OrgRepo>, center: &NotificationCenter) {
        let mut epochs = self.epochs.write().unwrap();
        let mut configured = Vec::new();
        for repo in repos {
            let epoch = epochs
                .get(&repo.id)
                .filter(|(root, _)| root == &repo.root_directory)
                .map(|(_, epoch)| *epoch)
                .unwrap_or_else(|| center.next_revision());
            configured.push((repo.clone(), epoch));
        }
        *epochs = configured
            .iter()
            .map(|(repo, epoch)| (repo.id.clone(), (repo.root_directory.clone(), *epoch)))
            .collect();
        let _ = self.send(Command::Configure(configured));
    }
    pub(crate) fn epoch(&self, repo: &OrgRepo) -> Option<u64> {
        self.epochs
            .read()
            .unwrap()
            .get(&repo.id)
            .filter(|(root, _)| root == &repo.root_directory)
            .map(|(_, epoch)| *epoch)
    }
    pub(crate) fn stamp(&self, repo: &OrgRepo, center: &NotificationCenter) -> Stamp {
        let epoch = self
            .epochs
            .read()
            .unwrap()
            .get(&repo.id)
            .filter(|(root, _)| root == &repo.root_directory)
            .map(|(_, epoch)| *epoch)
            .unwrap_or(0);
        Stamp {
            epoch,
            revision: center.next_revision(),
        }
    }
    pub(crate) fn update_files(
        &self,
        repo: &OrgRepo,
        stamp: Stamp,
        files: Vec<(String, CurrentFileState)>,
    ) -> Result<(), CoreError> {
        self.send(Command::UpdateFiles {
            repo: repo.clone(),
            stamp,
            files,
        })
    }
    pub(crate) fn delete_files(
        &self,
        repo: &OrgRepo,
        stamp: Stamp,
        paths: Vec<String>,
    ) -> Result<(), CoreError> {
        self.send(Command::DeleteFiles {
            repo: repo.clone(),
            stamp,
            paths,
        })
    }
    pub(crate) fn apply_repository(
        &self,
        repo: &OrgRepo,
        stamp: Stamp,
        baseline: BaselineState,
        files: Vec<(String, CurrentFileState)>,
        reset: bool,
    ) -> Result<(), CoreError> {
        self.send(Command::ApplyRepository {
            repo: repo.clone(),
            stamp,
            baseline,
            files,
            reset,
        })
    }
    pub(crate) fn request_snapshot(&self, scope: Option<Vec<String>>) {
        let _ = self.send(Command::Snapshot(scope));
    }
    pub(crate) async fn query(
        &self,
        repo_id: &str,
    ) -> Result<BTreeMap<String, FileState>, CoreError> {
        let (reply, received) = oneshot::channel();
        self.send(Command::Query {
            repo_id: repo_id.into(),
            reply,
        })?;
        received
            .await
            .map_err(|_| CoreError::InvalidState("文件状态服务已停止"))
    }
    pub(crate) async fn flush(&self) -> Result<(), CoreError> {
        let (done, received) = oneshot::channel();
        self.send(Command::Flush(done))?;
        received
            .await
            .map_err(|_| CoreError::InvalidState("文件状态服务已停止"))
    }
    pub(crate) async fn ready(&self) {
        let (done, received) = oneshot::channel();
        let _ = self.send(Command::Ready(done));
        let _ = received.await;
    }
    pub(crate) async fn stop(&self) {
        let (done, received) = oneshot::channel();
        let _ = self.send(Command::Stop(done));
        let _ = received.await;
    }
    pub(crate) async fn process(
        mut commands: mpsc::UnboundedReceiver<Command>,
        center: NotificationCenter,
    ) {
        let mut repos = BTreeMap::<String, Repository>::new();
        let mut loads = JoinSet::<(String, u64, u64, BaselineState)>::new();
        let mut ready = Vec::<oneshot::Sender<()>>::new();
        let mut loading = BTreeSet::<(String, u64)>::new();
        loop {
            let command = tokio::select! {
                command = commands.recv() => command,
                loaded = loads.join_next(), if !loads.is_empty() => {
                    if let Some(Ok((id, epoch, revision, baseline))) = loaded {
                        loading.remove(&(id.clone(), epoch));
                        if let Some(repo) = repos.get_mut(&id).filter(|repo| repo.epoch == epoch)
                            && repo.baseline_revision == 0 {
                            repo.baseline = baseline;
                            repo.baseline_revision = revision;
                            center.file_states(repo.event(center.next_revision()));
                        }
                    }
                    if loading.is_empty() { for reply in ready.drain(..) { let _ = reply.send(()); } }
                    continue;
                }
            };
            let Some(command) = command else {
                break;
            };
            match command {
                Command::Configure(configured) => {
                    repos.retain(|id, state| {
                        configured
                            .iter()
                            .any(|(repo, epoch)| &repo.id == id && state.epoch == *epoch)
                    });
                    for (repo, epoch) in configured {
                        if repos.contains_key(&repo.id) {
                            continue;
                        }
                        let id = repo.id.clone();
                        repos.insert(
                            id.clone(),
                            Repository {
                                repo: repo.clone(),
                                epoch,
                                baseline_revision: 0,
                                minimum_revision: 0,
                                baseline: BaselineState::Loading,
                                files: BTreeMap::new(),
                            },
                        );
                        loading.insert((id.clone(), epoch));
                        let center = center.clone();
                        loads.spawn(async move {
                            let (revision, baseline) = load_baseline(&repo, &center).await;
                            (id, epoch, revision, baseline)
                        });
                    }
                }
                Command::UpdateFiles { repo, stamp, files } => {
                    if let Some(state) = repos.get_mut(&repo.id) {
                        state.apply(&stamp, files);
                        center.file_states(state.event(center.next_revision()));
                    }
                }
                Command::DeleteFiles { repo, stamp, paths } => {
                    if let Some(state) = repos.get_mut(&repo.id) {
                        state.apply(
                            &stamp,
                            paths
                                .into_iter()
                                .map(|path| (path, CurrentFileState::Missing))
                                .collect(),
                        );
                        center.file_states(state.event(center.next_revision()));
                    }
                }
                Command::ApplyRepository {
                    repo,
                    stamp,
                    baseline,
                    files,
                    reset,
                } => {
                    if let Some(state) = repos
                        .get_mut(&repo.id)
                        .filter(|state| state.epoch == stamp.epoch)
                    {
                        if reset && stamp.revision > state.minimum_revision {
                            state.files.clear();
                            state.minimum_revision = stamp.revision.saturating_sub(1);
                        }
                        if stamp.revision > state.baseline_revision {
                            state.baseline = baseline;
                            state.baseline_revision = stamp.revision;
                        }
                        state.apply(&stamp, files);
                        center.file_states(state.event(center.next_revision()));
                    }
                }
                Command::Snapshot(scope) => {
                    for (id, state) in &repos {
                        if scope.as_ref().is_none_or(|ids| ids.contains(id)) {
                            center.file_states(state.event(center.next_revision()));
                        }
                    }
                }
                Command::Query { repo_id, reply } => {
                    let _ = reply.send(
                        repos
                            .get(&repo_id)
                            .map(|state| state.event(0).files)
                            .unwrap_or_default(),
                    );
                }
                Command::Flush(reply) => {
                    let _ = reply.send(());
                }
                Command::Ready(reply) => {
                    if loading.is_empty() {
                        let _ = reply.send(());
                    } else {
                        ready.push(reply);
                    }
                }
                Command::Stop(reply) => {
                    loads.abort_all();
                    while loads.join_next().await.is_some() {}
                    let _ = reply.send(());
                    break;
                }
            }
        }
    }
}

pub(crate) fn observation(file: &OrgFile) -> (String, CurrentFileState) {
    (
        file.path.clone(),
        CurrentFileState::Present {
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            has_conflict: file.has_conflict(),
        },
    )
}
pub(crate) async fn load_baseline(
    repo: &OrgRepo,
    center: &NotificationCenter,
) -> (u64, BaselineState) {
    let root = std::path::Path::new(&repo.root_directory);
    let loaded = async {
        let _guard = crate::webdav::transaction::lock(root).await?;
        crate::model::access::recover(root, &repo.id).await?;
        let baseline = crate::webdav::remote_base::notification_baseline(root).await;
        Ok::<_, CoreError>((center.next_revision(), baseline))
    }
    .await;
    match loaded {
        Ok((revision, Ok(Some(base)))) => (revision, BaselineState::Ready(base)),
        Ok((revision, Ok(None))) => (revision, BaselineState::Uninitialized),
        Ok((revision, Err(error))) => (
            revision,
            BaselineState::Unavailable(SyncBaselineFailure::from_error(&error)),
        ),
        Err(error) => (
            center.next_revision(),
            BaselineState::Unavailable(SyncBaselineFailure::from_error(&error)),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreNotification, CoreQuery, FileQuery, OrgFileRef, OrgWorkspace};
    async fn fixture() -> (OrgRepo, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "file-state-{}",
            crate::model::service::generate_repo_id().unwrap()
        ));
        tokio::fs::create_dir_all(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        (repo, root)
    }
    fn present(value: &str, conflict: bool) -> CurrentFileState {
        CurrentFileState::Present {
            version: value.into(),
            has_conflict: conflict,
        }
    }
    #[tokio::test]
    async fn startup_and_monitor_never_scan_unobserved_files() {
        let (repo, root) = fixture().await;
        tokio::fs::write(root.join("a.org"), "* TODO A\n")
            .await
            .unwrap();
        tokio::fs::write(root.join("unseen.org"), "* Conflict :CONFLICT:\n")
            .await
            .unwrap();
        let before = crate::model::test_support::repository_accesses(&repo.root_directory)[1];
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        let (send, mut receive) = mpsc::unbounded_channel();
        let _monitor = workspace
            .watch_notifications(
                None,
                crate::model::test_support::notification_monitor(move |values| {
                    let _ = send.send(values);
                }),
            )
            .unwrap();
        workspace.notifications.flush().await.unwrap();
        assert!(receive.recv().await.unwrap().is_empty());
        assert_eq!(
            crate::model::test_support::repository_accesses(&repo.root_directory)[1],
            before
        );
        workspace
            .query(&[CoreQuery::File {
                query: FileQuery {
                    include_files: vec![OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: "a.org".into(),
                    }],
                    ..Default::default()
                },
            }])
            .await
            .unwrap();
        assert!(receive.try_recv().is_err());
        assert!(
            !workspace
                .notifications
                .files()
                .query(&repo.id)
                .await
                .unwrap()
                .contains_key("unseen.org")
        );
        workspace
            .query(&[CoreQuery::File {
                query: FileQuery {
                    include_files: vec![OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: "unseen.org".into(),
                    }],
                    ..Default::default()
                },
            }])
            .await
            .unwrap();
        assert!(matches!(
            receive.recv().await.unwrap().as_slice(),
            [CoreNotification::SyncConflict(_)]
        ));
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn file_revisions_and_deletions_do_not_discard_other_file_observations() {
        let (repo, root) = fixture().await;
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        let center = &workspace.notifications;
        let files = center.files();
        let first = files.stamp(&repo, center);
        let second = files.stamp(&repo, center);
        files
            .update_files(&repo, second, vec![("a.org".into(), present("new", false))])
            .unwrap();
        files
            .update_files(
                &repo,
                first.clone(),
                vec![
                    ("a.org".into(), present("old", true)),
                    ("b.org".into(), present("b", false)),
                ],
            )
            .unwrap();
        let deleted = files.stamp(&repo, center);
        files
            .delete_files(&repo, deleted, vec!["b.org".into()])
            .unwrap();
        files
            .update_files(&repo, first, vec![("b.org".into(), present("stale", true))])
            .unwrap();
        let result = files.query(&repo.id).await.unwrap();
        assert_eq!(result["a.org"].current, present("new", false));
        assert_eq!(result["b.org"].current, CurrentFileState::Missing);
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn baseline_changes_recompare_known_files_and_deduplicate_notification_sources() {
        let (repo, root) = fixture().await;
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        let center = &workspace.notifications;
        let files = center.files();
        let stamp = files.stamp(&repo, center);
        files
            .apply_repository(
                &repo,
                stamp,
                BaselineState::Ready(BTreeMap::from([
                    ("a.org".into(), Some("base".into())),
                    ("b.org".into(), Some("base".into())),
                ])),
                vec![
                    ("a.org".into(), present("a", false)),
                    ("b.org".into(), present("b", false)),
                ],
                false,
            )
            .unwrap();
        center.flush().await.unwrap();
        let (send, mut receive) = mpsc::unbounded_channel();
        let _monitor = workspace
            .watch_notifications(
                None,
                crate::model::test_support::notification_monitor(move |values| {
                    let _ = send.send(values);
                }),
            )
            .unwrap();
        center.flush().await.unwrap();
        assert_eq!(
            receive.recv().await.unwrap(),
            vec![CoreNotification::SyncRequired]
        );
        files
            .update_files(
                &repo,
                files.stamp(&repo, center),
                vec![("a.org".into(), present("base", false))],
            )
            .unwrap();
        center.flush().await.unwrap();
        assert!(receive.try_recv().is_err());
        files
            .update_files(
                &repo,
                files.stamp(&repo, center),
                vec![("b.org".into(), present("base", false))],
            )
            .unwrap();
        center.flush().await.unwrap();
        assert!(receive.recv().await.unwrap().is_empty());
        files
            .apply_repository(
                &repo,
                files.stamp(&repo, center),
                BaselineState::Ready(BTreeMap::new()),
                vec![],
                false,
            )
            .unwrap();
        center.flush().await.unwrap();
        assert_eq!(
            receive.recv().await.unwrap(),
            vec![CoreNotification::SyncRequired]
        );
        files
            .apply_repository(
                &repo,
                files.stamp(&repo, center),
                BaselineState::Uninitialized,
                vec![],
                true,
            )
            .unwrap();
        center.flush().await.unwrap();
        assert!(receive.recv().await.unwrap().is_empty());
        assert!(files.query(&repo.id).await.unwrap().is_empty());
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
