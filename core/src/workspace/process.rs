//! 通过消息独占 Workspace 状态；读取并发，文件修改按依赖排队，控制命令作为屏障。
use super::*;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use tokio::sync::oneshot;
use tokio::task::JoinSet;

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
type Reply = Box<dyn FnOnce() + Send>;
type Work = Box<dyn FnOnce(WorkspaceState) -> BoxFuture<'static, (WorkspaceState, Reply)> + Send>;

#[derive(Clone, Debug)]
pub(super) struct Snapshot {
    pub(super) repos: Vec<OrgRepo>,
    configured_roots: BTreeSet<String>,
    pub(super) sync_policies: std::collections::BTreeMap<OrgRepoId, SyncBinding>,
    defaults: TodoConfig,
    history: Arc<crate::TaskOperationHistory>,
}
impl Snapshot {
    fn from_state(state: &WorkspaceState) -> Arc<Self> {
        Arc::new(Self {
            repos: state.repos.clone(),
            configured_roots: state.configured_roots.keys().cloned().collect(),
            sync_policies: state.sync_policies.clone(),
            defaults: state.todo_defaults.clone(),
            history: Arc::new(state.task_operation_history.clone()),
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Access {
    Query,
    Files(BTreeSet<(String, String)>),
    Exclusive,
    Stop,
}

pub(super) struct Command {
    access: Access,
    work: Work,
}

impl OrgWorkspace {
    pub async fn start(repos: Vec<OrgRepo>) -> Result<Self, OrgWorkspaceValidationError> {
        validate_repositories(&repos)?;
        tokio::runtime::Handle::try_current()
            .map_err(|_| CoreError::InvalidState("Workspace 必须在 Tokio 运行时中启动"))?;
        let (notifications, requests) =
            crate::model::notification_center::NotificationCenter::new();
        let tasks = crate::workspace_tasks::WorkspaceTasks::new();
        let (stop, stopping) = oneshot::channel();
        tasks.spawn_finalizer(
            stop,
            crate::model::notification_center::NotificationCenter::process(requests, stopping),
        )?;
        let mut state = WorkspaceState {
            repos,
            configured_roots: Default::default(),
            sync_policies: Default::default(),
            todo_defaults: TodoConfig::default(),
            task_operation_history: Default::default(),
            preview: Default::default(),
            notifications: notifications.clone(),
            tasks: tasks.clone(),
        };
        state.configure_roots(state.repos.iter().map(|repo| repo.root_directory.clone()).collect::<Vec<_>>())?;
        notifications.configure(state.repos.clone());
        notifications.files().ready().await;
        notifications.flush().await?;
        let (snapshots, snapshot) = watch::channel(Snapshot::from_state(&state));
        let (completion, completed) = watch::channel(None);
        let (sender, receiver) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let result = process(state, receiver, snapshots).await;
            completion.send_replace(Some(result));
        });
        Ok(Self {
            sender,
            snapshot,
            completed,
            notifications,
            tasks,
        })
    }

    pub(super) async fn request<T, F>(&self, access: Access, work: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: for<'a> FnOnce(&'a mut WorkspaceState) -> BoxFuture<'a, Result<T, CoreError>>
            + Send
            + 'static,
    {
        let (sender, received) = oneshot::channel();
        self.sender
            .send(Command {
                access,
                work: Box::new(move |mut state| {
                    Box::pin(async move {
                        let result = work(&mut state).await;
                        let reply: Reply = Box::new(move || {
                            let _ = sender.send(result);
                        });
                        (state, reply)
                    })
                }),
            })
            .map_err(|_| CoreError::InvalidState("Workspace 已停止"))?;
        received
            .await
            .map_err(|_| CoreError::InvalidState("Workspace 命令未能完成"))?
    }

    /// 配置和历史读取返回已发布的独立快照，不借出 process 内部状态。
    pub fn repos(&self) -> Vec<OrgRepo> {
        self.snapshot.borrow().repos.clone()
    }
    pub fn repo(&self, id: &OrgRepoId) -> Option<OrgRepo> {
        self.snapshot
            .borrow()
            .repos
            .iter()
            .find(|repo| &repo.id == id)
            .cloned()
    }
    pub fn repo_by_root_directory(&self, root: &str) -> Option<OrgRepo> {
        self.snapshot
            .borrow()
            .repos
            .iter()
            .find(|repo| repo.root_directory == root)
            .cloned()
    }
    /// 将配置目录转换为查询选择值，未打开的目录匹配空集合。
    pub fn query_repository_selector(&self, root: &str) -> Option<OrgRepoId> {
        let snapshot = self.snapshot.borrow();
        if let Some(repo) = snapshot.repos.iter().find(|repo| repo.root_directory == root) {
            return Some(repo.id.clone());
        }
        snapshot.configured_roots.contains(root).then(|| format!("{UNLOADED_QUERY_ROOT}{root}"))
    }
    pub fn todo_defaults(&self) -> TodoConfig {
        self.snapshot.borrow().defaults.clone()
    }
    pub fn task_operation_history(&self) -> crate::TaskOperationHistory {
        self.snapshot.borrow().history.as_ref().clone()
    }
    pub fn get_settings(&self) -> crate::CoreSettings {
        self.todo_defaults().core_settings
    }
    pub fn notification_center(&self) -> &crate::NotificationCenter {
        &self.notifications
    }
    pub fn query_ordering(
        &self,
        query: &crate::CoreQuery,
    ) -> Result<crate::QueryOrdering, CoreError> {
        crate::QueryOrdering::new(
            query,
            self.repos().into_iter().map(|repo| repo.id).collect(),
        )
    }

    pub async fn set_settings(&self, settings: crate::CoreSettings) -> Result<(), CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move { state.set_settings(settings) })
        })
        .await
    }
    pub async fn set_todo_defaults(&self, defaults: TodoConfig) -> Result<(), CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move { state.set_todo_defaults(defaults) })
        })
        .await
    }
    /// 更新宿主 TODO 文本时，在命令执行时保留现有附加状态。
    pub async fn set_todo_defaults_text(&self, source: &str) -> Result<(), CoreError> {
        let source = source.to_owned();
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move {
                let mut defaults = TodoConfig::from_settings(&source)?;
                defaults.core_settings = state.todo_defaults.core_settings.clone();
                state.set_todo_defaults(defaults)
            })
        })
        .await
    }
    pub async fn add_repo(&self, repo: OrgRepo) -> Result<(), CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move {
                let mut roots = state.configured_roots.keys().cloned().collect::<BTreeSet<_>>();
                roots.insert(repo.root_directory.clone());
                state.add_repo(repo)?;
                state.configure_roots(roots)
            })
        })
        .await
    }
    pub async fn configure_repository_roots(&self, roots: Vec<String>) -> Result<Vec<RepositoryRootStatus>, CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move { state.configure_repository_roots(roots).await })
        }).await
    }
    pub async fn remove_repo_by_root_directory(&self, root: &str) -> Result<OrgRepo, CoreError> {
        let root = root.to_owned();
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move {
                let repo = state.remove_repo_by_root_directory(&root)?;
                let remaining = state.configured_roots.keys().filter(|path| *path != &root).cloned().collect::<Vec<_>>();
                state.configure_roots(remaining)?;
                state.notifications.errors().flush().await?;
                Ok(repo)
            })
        })
        .await
    }
    pub async fn load_repo<P: crate::SyncPolicy + 'static>(
        &self,
        root: &str,
    ) -> Result<(), CoreError> {
        let root = root.to_owned();
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move {
                state
                    .repo_mut_by_root_directory(&root)
                    .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?
                    .load::<P>()
                    .await?;
                validate_repositories(&state.repos)
            })
        })
        .await
    }
    pub async fn reset_repo(&self, root: &str) -> Result<(), CoreError> {
        let root = root.to_owned();
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move {
                let notifications = state.notifications.clone();
                let repo = state
                    .repo_mut_by_root_directory(&root)
                    .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
                repo.reset(Some(&notifications)).await?;
                let id = repo.id.clone();
                state.task_operation_history.entries.retain(|entry| {
                    !entry
                        .fallback_group
                        .files
                        .iter()
                        .any(|file| file.repo_id == id)
                });
                Ok(())
            })
        })
        .await
    }
    /// 将仓库只读操作纳入查询批次；闭包只取得本次独立的配置快照。
    pub async fn read_repo<T, F, Fut>(&self, root: &str, read: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: FnOnce(OrgRepo) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, CoreError>> + Send + 'static,
    {
        let root = root.to_owned();
        self.request(Access::Query, move |state| {
            Box::pin(async move {
                let repo = state
                    .repo_by_root_directory(&root)
                    .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?
                    .clone();
                let result = crate::file_state::OBSERVER.scope(state.notifications.clone(), read(repo)).await;
                state.notifications.flush().await?;
                result
            })
        })
        .await
    }

    pub async fn query(
        &self,
        queries: &[crate::CoreQuery],
    ) -> Result<Vec<crate::CoreQueryResult>, CoreError> {
        let queries = queries.to_vec();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.query(&queries).await })
        })
        .await
    }
    #[cfg(test)]
    pub(crate) async fn query_snapshot(
        &self,
        queries: &[crate::CoreQuery],
        retain: bool,
    ) -> Result<crate::query::QuerySnapshot, CoreError> {
        let queries = queries.to_vec();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.query_snapshot(&queries, retain).await })
        })
        .await
    }
    #[cfg(test)]
    pub(crate) async fn state_for_test(&self) -> Result<WorkspaceState, CoreError> {
        self.request(Access::Query, |state| {
            Box::pin(async move { Ok(state.clone()) })
        })
        .await
    }
    pub async fn subscribe_query(
        &self,
        requests: Vec<crate::QuerySubscriptionRequest>,
    ) -> Result<Vec<crate::QuerySubscriptionStart>, CoreError> {
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.subscribe_query(requests).await })
        })
        .await
    }
    pub fn query_subscription_status(
        &self,
        subscription: &crate::QuerySubscription,
    ) -> crate::QuerySubscriptionStatus {
        subscription.status()
    }
    pub fn unsubscribe_query(&self, subscription: &mut crate::QuerySubscription) {
        subscription.cancel();
    }
    pub async fn refile_targets(&self) -> Result<Vec<crate::RefileTarget>, CoreError> {
        self.query_refile_targets(&crate::RefileTargetQuery::default())
            .await
    }
    pub async fn query_refile_targets(
        &self,
        query: &crate::RefileTargetQuery,
    ) -> Result<Vec<crate::RefileTarget>, CoreError> {
        let query = query.clone();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.query_refile_targets(&query).await })
        })
        .await
    }
    /// 在冻结的文件版本上解析结构编辑，返回可在原版本上提交的普通操作组。
    pub async fn task_structure_operations(
        &self,
        request: &crate::TaskStructureRequest,
    ) -> Result<crate::TaskOperationGroup, CoreError> {
        let request = request.clone();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.task_structure_operations(&request).await })
        })
        .await
    }
    pub async fn task_merge_operations(
        &self,
        request: &crate::TaskMergeRequest,
    ) -> Result<crate::TaskMergePlan, CoreError> {
        let request = request.clone();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.task_merge_operations(&request).await })
        })
        .await
    }
    pub async fn execute_task_operations(
        &self,
        group: &crate::TaskOperationGroup,
    ) -> Result<(), CoreError> {
        let access = operation_access(group);
        let group = group.clone();
        self.request(access, move |state| {
            Box::pin(async move { state.execute_task_operations(&group).await })
        })
        .await
    }
    pub async fn with_preview_root(self, root: std::path::PathBuf) -> Result<Self, CoreError> {
        self.set_preview_root(root).await?;
        Ok(self)
    }
    pub async fn set_preview_root(&self, root: std::path::PathBuf) -> Result<(), CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move { state.set_preview_root(root) })
        })
        .await
    }
    pub async fn create_conflict_preview(
        &self,
        request: crate::ConflictPreviewRequest,
    ) -> Result<crate::ConflictPreview, CoreError> {
        self.request(Access::Exclusive, move |state| {
            Box::pin(async move { state.create_conflict_preview(request).await })
        })
        .await
    }
    pub async fn file_at(&self, path: &crate::TaskPath) -> Result<crate::OrgFile, CoreError> {
        let path = path.clone();
        self.request(Access::Query, move |state| {
            Box::pin(async move { state.file_at(&path).await })
        })
        .await
    }
    pub async fn start_http_server(
        workspace: Self,
        address: std::net::SocketAddr,
    ) -> Result<crate::http_server::EmbeddedHttpServer, CoreError> {
        crate::http_server::EmbeddedHttpServer::start(workspace, address).await
    }
    pub async fn stop_http_server(
        server: &mut crate::http_server::EmbeddedHttpServer,
    ) -> Result<(), CoreError> {
        server.stop().await
    }
    pub async fn stop(&self) -> Result<(), CoreError> {
        if self.completed.borrow().is_none() {
            // 即使调用方取消等待，已受理的 Stop 仍由 process 排空并完成。
            let _ = self
                .request(Access::Stop, |state| {
                    Box::pin(async move { state.stop().await })
                })
                .await;
        }
        let mut completed = self.completed.clone();
        loop {
            if let Some(result) = completed.borrow().clone() {
                return result;
            }
            completed
                .changed()
                .await
                .map_err(|_| CoreError::InvalidState("Workspace 调度任务提前结束"))?;
        }
    }
}

fn operation_access(group: &crate::TaskOperationGroup) -> Access {
    use crate::TaskOperation::*;
    let mut files = BTreeSet::new();
    let mut insert = |path: &crate::TaskPath| -> Option<()> {
        if path.repo_id == "<preview>" {
            return None;
        }
        let file = path.file.as_ref()?;
        files.insert((path.repo_id.clone(), file.clone()));
        Some(())
    };
    for operation in &group.operations {
        let known = match operation {
            FileNew(data) => insert(&data.path)
                .and_then(|_| {
                    insert(&crate::TaskPath::file(
                        data.path.repo_id.clone(),
                        ".setup.org".into(),
                    ))
                })
                .and_then(|_| {
                    if data.template_content.is_empty() && !data.template_path.is_empty() {
                        insert(&crate::TaskPath::file(
                            data.path.repo_id.clone(),
                            data.template_path.clone(),
                        ))
                    } else {
                        Some(())
                    }
                }),
            FileHaderModification(data) => insert(&crate::TaskPath::file(
                data.file.repo_id.clone(),
                data.file.path.clone(),
            )),
            FileDeletion(data) => insert(&data.path),
            Creation(data) => insert(&data.position.parent),
            Modification(data) => insert(&data.path),
            Note(data) => insert(&data.path),
            Deletion(data) => insert(&data.path),
            Trash(data) => insert(&data.path).and_then(|_| insert(&crate::TaskPath::file(data.target.repo_id.clone(), data.target.path.clone()))),
            Restore(_) => return Access::Exclusive,
            Movement(data) => insert(&data.path)
                .and_then(|_| insert(&data.position.parent))
                .and_then(|_| data.position.after.as_ref().map_or(Some(()), &mut insert)),
            ConfilictSelection(data) => data.path.as_ref().and_then(&mut insert),
        };
        if known.is_none() {
            return Access::Exclusive;
        }
    }
    for version in &group.file_versions {
        if version.repo_id == "<preview>" {
            return Access::Exclusive;
        }
        files.insert((version.repo_id.clone(), version.file.clone()));
    }
    Access::Files(files)
}

async fn process(
    mut state: WorkspaceState,
    mut receiver: mpsc::UnboundedReceiver<Command>,
    snapshots: watch::Sender<Arc<Snapshot>>,
) -> Result<(), CoreError> {
    let mut queue = VecDeque::<Command>::new();
    let mut jobs = JoinSet::new();
    let mut active = HashMap::<tokio::task::Id, Access>::new();
    let mut closed = false;
    loop {
        // 只推进同一批次；较早的阻塞修改仍保留其全部文件依赖。
        let mut reserved = BTreeSet::new();
        let mut index = 0;
        while let Some(command) = queue.get(index) {
            let runnable = match &command.access {
                Access::Query => active.values().all(|access| *access == Access::Query),
                Access::Files(files) => {
                    if active
                        .values()
                        .any(|access| !matches!(access, Access::Files(_)))
                    {
                        break;
                    }
                    let free = files.is_disjoint(&reserved)
                        && active.values().all(|access| match access {
                            Access::Files(other) => files.is_disjoint(other),
                            _ => false,
                        });
                    reserved.extend(files.iter().cloned());
                    free
                }
                Access::Exclusive | Access::Stop => active.is_empty() && index == 0,
            };
            if !runnable {
                if matches!(command.access, Access::Files(_)) {
                    index += 1;
                    continue;
                }
                break;
            }
            let command = queue.remove(index).expect("待执行命令存在");
            let barrier = matches!(command.access, Access::Exclusive | Access::Stop);
            let snapshot = match command.access {
                Access::Query | Access::Files(_) => WorkspaceState {
                    sync_policies: state.sync_policies.clone(),
                    repos: state.repos.clone(),
                    configured_roots: state.configured_roots.clone(),
                    todo_defaults: state.todo_defaults.clone(),
                    task_operation_history: Default::default(),
                    preview: state.preview.clone(),
                    notifications: state.notifications.clone(),
                    tasks: state.tasks.clone(),
                },
                Access::Exclusive | Access::Stop => state.clone(),
            };
            let task = jobs.spawn((command.work)(snapshot));
            active.insert(task.id(), command.access);
            if barrier {
                break;
            }
            // 查询与修改不能在同一轮越过批次边界。
            if queue.get(index).is_some_and(|next| {
                active.values().any(|current| {
                    matches!(
                        (current, &next.access),
                        (Access::Query, Access::Files(_)) | (Access::Files(_), Access::Query)
                    )
                })
            }) {
                break;
            }
        }
        if closed && queue.is_empty() && jobs.is_empty() {
            return state.stop().await;
        }
        tokio::select! {
            command = receiver.recv(), if !closed => {
                match command {
                    Some(command) => {
                        if command.access == Access::Stop {
                            receiver.close();
                            while let Ok(rejected) = receiver.try_recv() { drop(rejected); }
                            closed = true;
                        }
                        queue.push_back(command);
                    }
                    None => closed = true,
                }
            }
            finished = jobs.join_next_with_id(), if !jobs.is_empty() => {
                match finished.expect("运行中的任务存在") {
                    Ok((id, (finished, reply))) => {
                        let access = active.remove(&id).expect("运行命令已登记");
                        match access {
                            Access::Query => {},
                            Access::Files(_) => state.task_operation_history.entries.extend(finished.task_operation_history.entries),
                            Access::Exclusive | Access::Stop => state = finished,
                        }
                        if access != Access::Query {
                            snapshots.send_replace(Snapshot::from_state(&state));
                            state.notifications.configure(state.repos.clone());
                        }
                        reply();
                        if access == Access::Stop {
                            // 停止后的请求不执行，丢弃 reply 使等待方收到明确失败。
                            receiver.close();
                            return state.stop().await;
                        }
                    }
                    Err(error) => { active.remove(&error.id()); }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Controlled {
        started: oneshot::Receiver<()>,
        release: oneshot::Sender<()>,
        finished: oneshot::Receiver<()>,
    }
    fn enqueue(workspace: &OrgWorkspace, access: Access) -> Controlled {
        let (started, entering) = oneshot::channel();
        let (release, released) = oneshot::channel();
        let (finished, finishing) = oneshot::channel();
        workspace
            .sender
            .send(Command {
                access,
                work: Box::new(move |state| {
                    Box::pin(async move {
                        let _ = started.send(());
                        let _ = released.await;
                        let reply: Reply = Box::new(move || {
                            let _ = finished.send(());
                        });
                        (state, reply)
                    })
                }),
            })
            .unwrap();
        Controlled {
            started: entering,
            release,
            finished: finishing,
        }
    }
    fn files(paths: &[&str]) -> Access {
        Access::Files(
            paths
                .iter()
                .map(|path| ("repo".into(), (*path).into()))
                .collect(),
        )
    }

    #[tokio::test]
    async fn query_batches_file_writes_and_exclusive_commands_preserve_barriers() {
        let workspace = OrgWorkspace::start(vec![]).await.unwrap();
        let mut first = enqueue(&workspace, Access::Query);
        let second = enqueue(&workspace, Access::Query);
        (&mut first.started).await.unwrap();
        second.started.await.unwrap();
        let mut write_a = enqueue(&workspace, files(&["a.org"]));
        let write_b = enqueue(&workspace, files(&["b.org"]));
        let mut later_read = enqueue(&workspace, Access::Query);
        let mut exclusive = enqueue(&workspace, Access::Exclusive);
        let mut last_read = enqueue(&workspace, Access::Query);
        first.release.send(()).unwrap();
        first.finished.await.unwrap();
        assert!(matches!(
            write_a.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        second.release.send(()).unwrap();
        (&mut write_a.started).await.unwrap();
        write_b.started.await.unwrap();
        write_a.release.send(()).unwrap();
        write_a.finished.await.unwrap();
        assert!(matches!(
            later_read.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        write_b.release.send(()).unwrap();
        (&mut later_read.started).await.unwrap();
        assert!(matches!(
            exclusive.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        later_read.release.send(()).unwrap();
        (&mut exclusive.started).await.unwrap();
        assert!(matches!(
            last_read.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        exclusive.release.send(()).unwrap();
        last_read.started.await.unwrap();
        last_read.release.send(()).unwrap();
        workspace.stop().await.unwrap();
    }

    #[tokio::test]
    async fn multi_file_waiter_reserves_its_dependencies_without_blocking_unrelated_files() {
        let workspace = OrgWorkspace::start(vec![]).await.unwrap();
        let first = enqueue(&workspace, files(&["a.org"]));
        first.started.await.unwrap();
        let mut movement = enqueue(&workspace, files(&["a.org", "b.org"]));
        let mut later_b = enqueue(&workspace, files(&["b.org"]));
        let independent = enqueue(&workspace, files(&["c.org"]));
        independent.started.await.unwrap();
        assert!(matches!(
            movement.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert!(matches!(
            later_b.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        first.release.send(()).unwrap();
        movement.started.await.unwrap();
        independent.release.send(()).unwrap();
        independent.finished.await.unwrap();
        assert!(matches!(
            later_b.started.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        movement.release.send(()).unwrap();
        later_b.started.await.unwrap();
        later_b.release.send(()).unwrap();
        workspace.stop().await.unwrap();
    }

    #[tokio::test]
    async fn stop_drains_accepted_work_even_if_caller_cancels_waiting() {
        let workspace = OrgWorkspace::start(vec![]).await.unwrap();
        let work = enqueue(&workspace, Access::Query);
        work.started.await.unwrap();
        let owner = workspace.clone();
        let stopping = tokio::spawn(async move { owner.stop().await });
        while !workspace.sender.is_closed() {
            tokio::task::yield_now().await;
        }
        assert!(!stopping.is_finished());
        stopping.abort();
        assert!(workspace.query(&[]).await.is_err());
        work.release.send(()).unwrap();
        workspace.stop().await.unwrap();
        workspace.stop().await.unwrap();
    }

    #[tokio::test]
    async fn todo_text_update_preserves_additional_states_from_the_same_command_state() {
        let workspace = OrgWorkspace::start(vec![]).await.unwrap();
        let configured = crate::CoreSettings {
            addition_states: vec![crate::TaskState {
                name: "RUN".into(),
                category: Some(crate::TaskStateCategory::Doing),
            }],
        };
        workspace.set_settings(configured.clone()).await.unwrap();
        workspace
            .set_todo_defaults_text("#+TODO: OPEN | END")
            .await
            .unwrap();
        assert_eq!(workspace.get_settings(), configured);
        assert!(workspace.set_todo_defaults_text("invalid").await.is_err());
        assert_eq!(workspace.get_settings(), configured);
        workspace.stop().await.unwrap();
    }

    #[tokio::test]
    async fn failed_command_does_not_skip_later_work_and_clones_share_settings() {
        let workspace = OrgWorkspace::start(vec![]).await.unwrap();
        let sibling = workspace.clone();
        let before = workspace.get_settings();
        assert!(
            workspace
                .request::<(), _>(Access::Exclusive, |_| Box::pin(async {
                    Err(CoreError::InvalidInput("注入失败"))
                }))
                .await
                .is_err()
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let capture = calls.clone();
        sibling
            .request(Access::Query, move |_| {
                Box::pin(async move {
                    capture.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                })
            })
            .await
            .unwrap();
        workspace.set_settings(before.clone()).await.unwrap();
        assert_eq!(sibling.get_settings(), before);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        sibling.stop().await.unwrap();
    }
}
