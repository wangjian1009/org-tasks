//! 仓库策略绑定与多仓库检查、同步；只读检查使用已发布快照，不进入命令屏障。
use super::{OrgWorkspace, WorkspaceState, process::Access};
use crate::{CoreError, LocalFileVersion, OrgFileRef, OrgRepo, OrgRepoId, OrgRepoSyncRecord, RemoteCheckContext,
    RemoteChangeState, RepoRemoteChange, RepoSyncResult, SyncCancellation, SyncOptions,
    SyncPolicy, SyncProgressReporter, SyncTriggerReason, TaskFileVersion, TaskOperation,
    TaskOperationGroup, TaskPath};
use std::{future::Future, path::Path, pin::Pin, sync::Arc};

type Pending<'a, T> = Pin<Box<dyn Future<Output = Result<T, CoreError>> + Send + 'a>>;

trait BoundPolicy: Send + Sync {
    fn check<'a>(&'a self, repo: &'a OrgRepo) -> Pending<'a, RemoteChangeState>;
    fn sync<'a>(&'a self, repo: &'a mut OrgRepo, reason: SyncTriggerReason,
        cancellation: &'a SyncCancellation, progress: &'a SyncProgressReporter,
        notifications: &'a crate::NotificationCenter) -> Pending<'a, OrgRepoSyncRecord>;
}

struct Policy<P> { policy: P, options: SyncOptions }

impl<P: SyncPolicy> BoundPolicy for Policy<P> {
    fn check<'a>(&'a self, repo: &'a OrgRepo) -> Pending<'a, RemoteChangeState> {
        Box::pin(async move {
            self.policy.check_remote_changes(&RemoteCheckContext {
                repo, excluded_directories: &self.options.excluded_directories,
            }).await
        })
    }

    fn sync<'a>(&'a self, repo: &'a mut OrgRepo, reason: SyncTriggerReason,
        cancellation: &'a SyncCancellation, progress: &'a SyncProgressReporter,
        notifications: &'a crate::NotificationCenter) -> Pending<'a, OrgRepoSyncRecord> {
        Box::pin(async move {
            let mut options = self.options.clone();
            options.trigger_reason = reason;
            let record = repo.sync_with_options(&self.policy, cancellation, progress,
                options, Some(notifications)).await?;
            // 策略的专属字段仅在组合边界转成 JSON，持久化和策略内部仍保持原类型。
            let value = serde_json::to_value(record)
                .map_err(|_| CoreError::InvalidState("无法编码同步结果"))?;
            serde_json::from_value(value).map_err(|_| CoreError::InvalidState("无法转换同步结果"))
        })
    }
}

#[derive(Clone)]
pub(super) struct SyncBinding(Arc<dyn BoundPolicy>);
impl std::fmt::Debug for SyncBinding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("SyncBinding") }
}
impl PartialEq for SyncBinding {
    fn eq(&self, other: &Self) -> bool { Arc::ptr_eq(&self.0, &other.0) }
}
impl Eq for SyncBinding {}

impl OrgWorkspace {
    pub async fn set_sync_policy<P: SyncPolicy + 'static>(
        &self, repo_id: &OrgRepoId, policy: P, excluded_directories: Vec<String>,
    ) -> Result<(), CoreError> {
        if repo_id.is_empty() { return Err(CoreError::InvalidInput("同步策略需要稳定的仓库 ID")); }
        let options = SyncOptions { excluded_directories, ..Default::default() }.normalized()?;
        let id = repo_id.clone();
        let binding = SyncBinding(Arc::new(Policy { policy, options }));
        self.request(Access::Exclusive, move |state| Box::pin(async move {
            if state.repo(&id).is_none() { return Err(CoreError::InvalidInput("仓库不属于 Workspace")); }
            state.sync_policies.insert(id, binding);
            Ok(())
        })).await
    }

    pub async fn remove_sync_policy(&self, repo_id: &OrgRepoId) -> Result<(), CoreError> {
        let id = repo_id.clone();
        self.request(Access::Exclusive, move |state| Box::pin(async move {
            let repo = state.repo(&id).ok_or(CoreError::InvalidInput("仓库不属于 Workspace"))?;
            repo.clear_sync_metadata().await?;
            crate::model::external_files::publish(repo, &state.notifications, vec![], vec![], false).await?;
            state.sync_policies.remove(&id);
            Ok(())
        })).await
    }

    pub async fn check_remote_changes(&self) -> Result<Vec<RepoRemoteChange>, CoreError> {
        let _activity = self.tasks.enter()?;
        // 克隆后立即释放 watch 借用，网络期间不阻塞配置快照发布。
        let snapshot = self.snapshot.borrow().clone();
        let mut results = Vec::new();
        for repo in &snapshot.repos {
            if let Some(binding) = snapshot.sync_policies.get(&repo.id) {
                results.push(RepoRemoteChange { repo_id: repo.id.clone(), result: binding.0.check(repo).await });
            }
        }
        Ok(results)
    }

    pub async fn sync_repos(
        &self, repo_ids: &[OrgRepoId], trigger_reason: SyncTriggerReason,
        cancellation: Option<SyncCancellation>, progress: Option<SyncProgressReporter>,
        trash_file: Option<OrgFileRef>,
    ) -> Result<Vec<RepoSyncResult>, CoreError> {
        if repo_ids.iter().collect::<std::collections::BTreeSet<_>>().len() != repo_ids.len() {
            return Err(CoreError::InvalidInput("同步仓库列表不能重复"));
        }
        let ids = repo_ids.to_vec();
        let cancellation = cancellation.unwrap_or_default();
        let progress = progress.unwrap_or_default();
        self.request(Access::Exclusive, move |state| Box::pin(async move {
            if let Some(trash) = &trash_file {
                TaskPath::file(trash.repo_id.clone(), trash.path.clone()).validate()?;
                if state.repo(&trash.repo_id).is_none() {
                    return Err(CoreError::InvalidInput("废纸篓仓库不属于 Workspace"));
                }
            }
            let mut results = Vec::with_capacity(ids.len());
            for id in ids {
                let result = sync_one(state, &id, trigger_reason, &cancellation, &progress, trash_file.as_ref()).await;
                results.push(RepoSyncResult { repo_id: id, result });
            }
            Ok(results)
        })).await
    }
}

async fn sync_one(state: &mut WorkspaceState, id: &OrgRepoId, reason: SyncTriggerReason,
    cancellation: &SyncCancellation, progress: &SyncProgressReporter,
    trash_file: Option<&OrgFileRef>,
) -> Result<OrgRepoSyncRecord, CoreError> {
    use crate::webdav::{SYNC_TRASH, TRASH_PENDING, transaction};
    let binding = state.sync_policies.get(id).cloned()
        .ok_or(CoreError::InvalidInput("仓库未配置同步策略"))?;
    let notifications = state.notifications.clone();
    let repo = state.repos.iter_mut().find(|repo| &repo.id == id)
        .ok_or(CoreError::InvalidInput("仓库不属于 Workspace"))?;
    let sync = binding.0.sync(repo, reason, cancellation, progress, &notifications);
    let Some(trash) = trash_file else { return sync.await; };
    let result = SYNC_TRASH.scope(trash.clone(), sync).await;
    let source = state.repo(id).expect("同步仓库仍在当前命令中").clone();
    let root = Path::new(&source.root_directory);
    let guard = crate::model::access::enter(root, id).await?;
    let pending = transaction::read(root, TRASH_PENDING).await?;
    drop(guard);
    let Some(pending) = pending else { return result; };
    let target = state.repo(&trash.repo_id).expect("已验证废纸篓仓库");
    let file = target.file(&trash.path).await?;
    let archived = file.path_headlines().into_iter().filter_map(|(_, headline)|
        crate::model::properties::own(&headline, "SOURCE_TRASH_ID")).collect::<std::collections::BTreeSet<_>>();
    let mut group: TaskOperationGroup = serde_json::from_slice(&pending)
        .map_err(|_| CoreError::InvalidState("待转入废纸篓的操作无效"))?;
    let parent = TaskPath::file(trash.repo_id.clone(), trash.path.clone());
    for operation in &group.operations {
        if !matches!(operation, TaskOperation::Creation(task) if task.position.parent == parent) {
            return Err(CoreError::InvalidState("待转入废纸篓的操作与目标文件不一致"));
        }
    }
    // 操作组已提交但待处理文件尚未清理时，按保留下来的来源 ID 跳过已写入的记录。
    group.operations.retain(|operation| match operation {
        TaskOperation::Creation(task) => !task.properties.iter().any(|property|
            property.name == "SOURCE_TRASH_ID" && archived.contains(&property.value)),
        _ => false,
    });
    if !group.operations.is_empty() {
        group.file_versions = vec![TaskFileVersion {
            repo_id: trash.repo_id.clone(), file: trash.path.clone(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        }];
        state.execute_task_operations(&group).await?;
    }
    let _guard = crate::model::access::enter(root, id).await?;
    let mut plan = transaction::Plan::default();
    plan.guards.push((TRASH_PENDING.into(), Some(pending)));
    plan.set(root, TRASH_PENDING.into(), None).await?;
    plan.commit(root).await?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OrgRepoSyncResult, SyncContext};
    use std::sync::Mutex;

    struct Probe {
        state: Result<RemoteChangeState, CoreError>,
        fail_sync: bool,
        calls: Arc<Mutex<Vec<String>>>,
    }
    impl SyncPolicy for Probe {
        const KIND: &'static str = "probe";
        type ContextDetail = String;
        type FileDetail = serde_json::Value;

        async fn check_remote_changes(&self, context: &RemoteCheckContext<'_>) -> Result<RemoteChangeState, CoreError> {
            self.calls.lock().unwrap().push(format!("check:{}:{:?}", context.repo.id, context.excluded_directories));
            self.state.clone()
        }

        async fn synchronize(&self, context: &mut SyncContext<'_>, cancellation: &SyncCancellation,
            _: &SyncProgressReporter,
        ) -> Result<OrgRepoSyncRecord<String>, CoreError> {
            self.calls.lock().unwrap().push(format!("sync:{}:{}", context.repo.id, context.started_at));
            if self.fail_sync { return Err(CoreError::InvalidState("模拟同步失败")); }
            let mut record = OrgRepoSyncRecord::new(format!("probe-{}", context.started_at), context.started_at)?
                .with_context_detail("策略专属字段".to_owned());
            record.finish(if cancellation.is_cancelled() { OrgRepoSyncResult::Cancelled } else { OrgRepoSyncResult::Succeeded },
                chrono::Utc::now().timestamp_millis().max(context.started_at))?;
            Ok(record)
        }
    }

    async fn workspace() -> (OrgWorkspace, std::path::PathBuf, Vec<OrgRepoId>) {
        let root = std::env::temp_dir().join(format!("org-workspace-sync-{}", crate::model::service::generate_repo_id().unwrap()));
        let mut repos = Vec::new();
        for name in ["a", "b", "local"] {
            let path = root.join(name);
            tokio::fs::create_dir_all(&path).await.unwrap();
            let mut repo = OrgRepo::new(path.to_string_lossy().into()).unwrap();
            repo.load::<Probe>().await.unwrap();
            repos.push(repo);
        }
        let ids = repos.iter().map(|repo| repo.id.clone()).collect();
        (OrgWorkspace::start(repos).await.unwrap(), root, ids)
    }

    fn policy(state: Result<RemoteChangeState, CoreError>, fail_sync: bool, calls: &Arc<Mutex<Vec<String>>>) -> Probe {
        Probe { state, fail_sync, calls: calls.clone() }
    }

    #[tokio::test]
    async fn check_returns_each_configured_repository_and_does_not_sync_or_touch_files() {
        let (workspace, root, ids) = workspace().await;
        let calls = Arc::new(Mutex::new(Vec::new()));
        workspace.set_sync_policy(&ids[0], policy(Err(CoreError::InvalidState("检查失败")), false, &calls), vec![" private ".into()]).await.unwrap();
        workspace.set_sync_policy(&ids[1], policy(Ok(RemoteChangeState::Changed), false, &calls), vec![]).await.unwrap();
        let accesses = workspace.repos().iter().map(|repo| crate::model::test_support::repository_accesses(&repo.root_directory)).collect::<Vec<_>>();
        let result = workspace.check_remote_changes().await.unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].repo_id, ids[0]);
        assert!(result[0].result.is_err());
        assert_eq!(result[1].result, Ok(RemoteChangeState::Changed));
        assert_eq!(*calls.lock().unwrap(), vec![format!("check:{}:[\"private\"]", ids[0]), format!("check:{}:[]", ids[1])]);
        for (repo, before) in workspace.repos().iter().zip(accesses) {
            assert_eq!(crate::model::test_support::repository_accesses(&repo.root_directory), before);
            assert!(!std::path::Path::new(&repo.root_directory).join(".sync/history").exists());
        }
        workspace.remove_sync_policy(&ids[0]).await.unwrap();
        assert_eq!(workspace.check_remote_changes().await.unwrap().len(), 1);
        workspace.remove_repo_by_root_directory(&root.join("b").to_string_lossy()).await.unwrap();
        assert!(workspace.check_remote_changes().await.unwrap().is_empty());
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn sync_selected_repositories_preserves_order_failures_and_generated_timestamps() {
        let (workspace, root, ids) = workspace().await;
        let calls = Arc::new(Mutex::new(Vec::new()));
        workspace.set_sync_policy(&ids[0], policy(Ok(RemoteChangeState::Unchanged), true, &calls), vec![]).await.unwrap();
        workspace.set_sync_policy(&ids[1], policy(Ok(RemoteChangeState::Unknown), false, &calls), vec![]).await.unwrap();
        assert!(workspace.sync_repos(&[], SyncTriggerReason::Manual, None, None, None).await.unwrap().is_empty());
        assert!(workspace.sync_repos(&[ids[0].clone(), ids[0].clone()], SyncTriggerReason::Manual, None, None, None).await.is_err());
        assert!(calls.lock().unwrap().is_empty());
        let before = chrono::Utc::now().timestamp_millis();
        let result = workspace.sync_repos(&[ids[0].clone(), ids[1].clone(), ids[2].clone()], SyncTriggerReason::RemoteChanged, None, None, None).await.unwrap();
        assert_eq!(result.iter().map(|item| &item.repo_id).collect::<Vec<_>>(), ids.iter().collect::<Vec<_>>());
        assert!(result[0].result.is_err());
        assert!(result[2].result.is_err());
        let record = result[1].result.as_ref().unwrap();
        assert!(record.started_at >= before);
        assert!(record.started_at <= chrono::Utc::now().timestamp_millis());
        assert_eq!(record.trigger_reason, Some(SyncTriggerReason::RemoteChanged));
        assert_eq!(record.context_detail, "策略专属字段");
        assert_eq!(calls.lock().unwrap().len(), 2);
        assert!(!root.join("local/.sync/history").exists());
        let next = workspace.sync_repos(&[ids[1].clone()], SyncTriggerReason::Manual, None, None, None).await.unwrap();
        assert!(next[0].result.as_ref().unwrap().started_at > record.started_at);
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn generated_time_advances_past_existing_history_and_shared_cancellation_is_honored() {
        let (workspace, root, ids) = workspace().await;
        let calls = Arc::new(Mutex::new(Vec::new()));
        let mut repo = workspace.repo(&ids[0]).unwrap();
        let future = chrono::Utc::now().timestamp_millis() + 60_000;
        let probe = policy(Ok(RemoteChangeState::Unknown), false, &calls);
        repo.sync_at(&probe, future, &SyncCancellation::default(), &SyncProgressReporter::default()).await.unwrap();
        workspace.set_sync_policy(&ids[0], probe, vec![]).await.unwrap();
        let token = SyncCancellation::default(); token.cancel();
        let result = workspace.sync_repos(&[ids[0].clone()], SyncTriggerReason::LocalChanged, Some(token), None, None).await.unwrap();
        let record = result[0].result.as_ref().unwrap();
        assert_eq!(record.started_at, future + 1);
        assert_eq!(record.result, Some(OrgRepoSyncResult::Cancelled));
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
