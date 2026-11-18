use crate::CoreError;

use crate::model::{OrgRepo, OrgRepoId, TodoConfig, validate_id};

pub type OrgWorkspaceValidationError = CoreError;

mod process;
use process::{Command, Snapshot};
use std::sync::Arc;
use tokio::sync::{mpsc, watch};

/// 可克隆的命令句柄；可变状态仅由 process 持有。
#[derive(Clone, Debug)]
pub struct OrgWorkspace {
    sender: mpsc::UnboundedSender<Command>,
    snapshot: watch::Receiver<Arc<Snapshot>>,
    completed: watch::Receiver<Option<Result<(), CoreError>>>,
    pub(crate) notifications: crate::model::notification_center::NotificationCenter,
    pub(crate) tasks: crate::workspace_tasks::WorkspaceTasks,
}

impl PartialEq for OrgWorkspace {
    fn eq(&self, other: &Self) -> bool { self.sender.same_channel(&other.sender) }
}
impl Eq for OrgWorkspace {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkspaceState {
    pub repos: Vec<OrgRepo>,
    pub todo_defaults: TodoConfig,
    pub task_operation_history: crate::model::TaskOperationHistory,
    pub(crate) preview: crate::model::conflict_preview::PreviewStore,
    pub(crate) notifications: crate::model::notification_center::NotificationCenter,
    pub(crate) tasks: crate::workspace_tasks::WorkspaceTasks,
}

impl WorkspaceState {
    /// 批量启动独立订阅，只共享一次文件加载；结果顺序与请求一致。
    pub async fn subscribe_query(
        &self,
        requests: Vec<crate::QuerySubscriptionRequest>,
    ) -> Result<Vec<crate::QuerySubscriptionStart>, CoreError> {
        let _activity = self.tasks.enter()?;
        if requests.is_empty() { return Ok(Vec::new()); }
        let queries = requests.iter().map(|request| request.query.clone()).collect::<Vec<_>>();
        let mut subscriptions = Vec::with_capacity(requests.len());
        for request in requests {
            let mut subscription = crate::query_subscription::prepare(request.query, request.callback)?;
            let monitor = subscription.monitor();
            subscription.attach(crate::model::data_changes::watch(&self.notifications, monitor));
            subscription.watch_external_files(&self.notifications);
            subscriptions.push(subscription);
        }
        let mut snapshot = self.query_snapshot(&queries, true).await?;
        self.notifications.flush().await?;
        let repo_order = self.repos.iter().map(|repo| repo.id.clone()).collect::<Vec<_>>();
        let results = std::mem::take(&mut snapshot.results);
        Ok(subscriptions.into_iter().zip(results).map(|(subscription, data)| {
            let data = subscription.initialize(data, &snapshot, &repo_order);
            crate::QuerySubscriptionStart { data, subscription }
        }).collect())
    }

    /// 停止接收内部任务与通知，等待已启动任务和在途回调退出；可重复等待。
    pub async fn stop(&self) -> Result<(), CoreError> {
        let tasks = self.tasks.stop().await;
        self.preview.invalidate();
        tasks
    }

    pub fn set_settings(&mut self, settings: crate::model::CoreSettings) -> Result<(), CoreError> {
        settings.validate()?;
        let mut defaults = self.todo_defaults.clone();
        defaults.core_settings = settings;
        self.set_todo_defaults(defaults)
    }

    pub fn set_todo_defaults(&mut self, defaults: TodoConfig) -> Result<(), CoreError> {
        defaults.validate()?;
        if self.todo_defaults == defaults {
            return Ok(());
        }
        self.preview.invalidate();
        let mut repos = self.repos.clone();
        for repo in &mut repos {
            repo.set_todo_defaults(defaults.clone())?;
        }
        self.repos = repos;
        self.todo_defaults = defaults;
        Ok(())
    }

    pub fn repos(&self) -> &[OrgRepo] {
        &self.repos
    }

    pub fn repo(&self, repo_id: &OrgRepoId) -> Option<&OrgRepo> {
        self.repos.iter().find(|repo| &repo.id == repo_id)
    }

    pub fn repo_by_root_directory(&self, root_directory: &str) -> Option<&OrgRepo> {
        self.repos
            .iter()
            .find(|repo| repo.root_directory == root_directory)
    }

    pub fn repo_mut_by_root_directory(&mut self, root_directory: &str) -> Option<&mut OrgRepo> {
        self.repos
            .iter_mut()
            .find(|repo| repo.root_directory == root_directory)
    }

    pub fn add_repo(&mut self, mut repo: OrgRepo) -> Result<(), OrgWorkspaceValidationError> {
        self.preview.validate_repo(&repo)?;
        repo.set_todo_defaults(self.todo_defaults.clone())?;
        let mut repositories = self.repos.clone();
        repositories.push(repo.clone());
        validate_repositories(&repositories)?;
        self.repos.push(repo);
        Ok(())
    }

    pub fn remove_repo_by_root_directory(
        &mut self,
        root_directory: &str,
    ) -> Result<OrgRepo, OrgWorkspaceValidationError> {
        let index = self
            .repos
            .iter()
            .position(|repo| repo.root_directory == root_directory)
            .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
        self.preview.invalidate();
        Ok(self.repos.remove(index))
    }
}

fn validate_repositories(repos: &[OrgRepo]) -> Result<(), CoreError> {
    for (index, repo) in repos.iter().enumerate() {
        if repos[..index]
            .iter()
            .any(|other| other.root_directory == repo.root_directory)
        {
            return Err(CoreError::InvalidInput("仓库根目录必须唯一"));
        }
        if !repo.id.is_empty() {
            if repo.id == "<preview>" {
                return Err(CoreError::InvalidInput(
                    "仓库 ID 不能使用 <preview> 保留身份",
                ));
            }
            validate_id(&repo.id, "仓库 ID 不能为空")?;
            if repos[..index]
                .iter()
                .any(|other| !other.id.is_empty() && other.id == repo.id)
            {
                return Err(CoreError::InvalidInput("仓库 ID 必须唯一"));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OrgFile;

    #[tokio::test]
    async fn query_combines_repositories_and_keeps_repository_identity() {
        let first = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo-1".into(),
                root_directory: "/tmp/one".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![
                OrgFile::new(
                    "repo-1".into(),
                    "tasks.org".into(),
                    b"* TODO First\n".to_vec(),
                )
                .unwrap(),
            ],
            Default::default(),
        );
        let second = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo-2".into(),
                root_directory: "/tmp/two".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![
                OrgFile::new(
                    "repo-2".into(),
                    "tasks.org".into(),
                    b"* TODO Second\n".to_vec(),
                )
                .unwrap(),
            ],
            Default::default(),
        );
        let workspace = OrgWorkspace::start(vec![first, second]).await.unwrap();
        let tasks = workspace
            .query(&[(crate::TaskQuery {
                expression: "i.todo".into(),
                ..Default::default()
            })
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap()
            .tasks;

        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].repo_id(), crate::model::test_support::id("repo-1"));
        assert_eq!(tasks[1].repo_id(), crate::model::test_support::id("repo-2"));
    }

    #[tokio::test]
    async fn repository_snapshot_does_not_mutate_workspace() {
        let repo = crate::model::test_support::with_files(
            OrgRepo { id: "repo-1".into(), root_directory: "/tmp/one".into(), todo_defaults: Default::default() },
            Vec::new(), Default::default());
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        let original = workspace.repo(&crate::model::test_support::id("repo-1")).unwrap();
        let mut snapshot = original.clone();
        snapshot.root_directory = "/tmp/updated".into();
        assert_eq!(workspace.repo(&crate::model::test_support::id("repo-1")).unwrap(), original);
        assert!(workspace.repo(&"unknown".into()).is_none());
        workspace.stop().await.unwrap();
    }

    #[tokio::test]
    async fn add_repo_rejects_duplicate_repository_identity() {
        let repo = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo-1".into(),
                root_directory: "/tmp/one".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            Vec::new(),
            Default::default(),
        );
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();

        assert!(workspace.add_repo(repo).await.is_err());
        assert_eq!(workspace.repos().len(), 1);
    }

    #[tokio::test]
    async fn workspace_accepts_unloaded_repository_until_load_assigns_its_identity() {
        let repo = OrgRepo::new("/tmp/one".into()).unwrap();
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();

        assert!(workspace.repos()[0].id.is_empty());
    }

    #[tokio::test]
    async fn removes_repository_by_root_directory() {
        let workspace =
            OrgWorkspace::start(vec![OrgRepo::new("/tmp/one".into()).unwrap()]).await.unwrap();

        let removed = workspace.remove_repo_by_root_directory("/tmp/one").await.unwrap();

        assert_eq!(removed.root_directory, "/tmp/one");
        assert!(workspace.repos().is_empty());
    }
    #[tokio::test]
    async fn workspace_updates_external_defaults_for_loaded_and_new_repos() {
        let mut repo = OrgRepo::new("/tmp/one".into()).unwrap();
        repo.id = "repo".into();
        {
            let value =
                OrgFile::new("repo".into(), "default.org".into(), b"* OPEN A\n".to_vec()).unwrap();
            crate::model::test_support::push_file(&mut repo, value);
        };
        {
            let value = OrgFile::new(
                "repo".into(),
                "override.org".into(),
                b"#+TODO: OWN | CLOSED\n* OWN B\n".to_vec(),
            )
            .unwrap();
            crate::model::test_support::push_file(&mut repo, value);
        };
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        workspace
            .set_todo_defaults(crate::TodoConfig::from_settings("#+TODO: OPEN | END").unwrap()).await
            .unwrap();
        assert_eq!(
            workspace
                .query(&[(crate::TaskQuery {
                    expression: "it.todo".into(),
                    ..Default::default()
                })
                .into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            2
        );
        workspace
            .set_todo_defaults(crate::TodoConfig::from_settings("#+TODO: OTHER | END").unwrap()).await
            .unwrap();
        assert_eq!(
            workspace
                .query(&[(crate::TaskQuery {
                    expression: "it.todo".into(),
                    ..Default::default()
                })
                .into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            1
        );
        workspace
            .add_repo(OrgRepo::new("/tmp/two".into()).unwrap()).await
            .unwrap();
        assert_eq!(workspace.repos()[1].todo_defaults, workspace.todo_defaults());
        assert_eq!(
            workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(),
            b"* OPEN A\n"
        );
    }
}
