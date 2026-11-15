//! 提交后的数据变化通知；任务操作携带内存中生成的增量，同步等入口保留仓库失效通知。
use crate::OrgWorkspace;
use serde::Serialize;

use super::{OrgFileMetadata, OrgFileRef, OrgRepoId, TaskCategory, TaskPosition};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskDataChangeKind {
    Created,
    Updated,
    Deleted,
    Moved,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDataSnapshot {
    pub task: crate::FilterTask,
    pub position: TaskPosition,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDataChange {
    pub kind: TaskDataChangeKind,
    pub before: Option<TaskDataSnapshot>,
    pub after: Option<TaskDataSnapshot>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDataChange {
    pub before: Option<OrgFileMetadata>,
    pub after: OrgFileMetadata,
    pub before_version: Option<String>,
    pub after_version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DataChangeEvent {
    RepositoryChanged {
        #[serde(rename = "repoId")]
        repo_id: OrgRepoId,
        #[serde(rename = "operationId")]
        operation_id: Option<String>,
        /// None 表示现有同步、重载等入口的失效通知；Some 表示本次提交的精确文件集合。
        files: Option<Vec<FileDataChange>>,
        changes: Vec<TaskDataChange>,
        /// 文件数据离开接收范围；不代表删除底层文件。
        #[serde(rename = "removedFiles", skip_serializing_if = "Vec::is_empty")]
        removed_files: Vec<OrgFileRef>,
        /// 任务查询的完整分类摘要；普通仓库事件不提供。
        #[serde(skip_serializing_if = "Option::is_none")]
        categories: Option<Vec<TaskCategory>>,
    },
}

pub struct DataChangeSubscription {
    _sync_subscription: super::sync_events::SyncSubscription,
}

impl OrgWorkspace {
    /// 注册独立数据监控；多个订阅同时有效，回调不能重入当前 workspace 锁。
    pub fn watch_data_changes<F>(&self, callback: F) -> DataChangeSubscription
    where
        F: Fn(DataChangeEvent) + Send + Sync + 'static,
    {
        let roots = self
            .repos()
            .iter()
            .map(|repo| repo.root_directory.clone())
            .collect::<Vec<_>>();
        let subscription = super::sync_events::subscribe(std::sync::Arc::new(move |event| {
            let super::sync_events::SyncCommitted::Repository {
                root_directory,
                repo_id,
                operation_id,
                files,
                changes,
            } = event;
            if roots.contains(root_directory) {
                callback(DataChangeEvent::RepositoryChanged {
                    repo_id: repo_id.clone(),
                    operation_id: operation_id.clone(),
                    files: files.clone(),
                    changes: changes.clone(),
                    removed_files: Vec::new(),
                    categories: None,
                });
            }
        }));
        DataChangeSubscription {
            _sync_subscription: subscription,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn multiple_subscriptions_receive_and_can_cancel_repository_changes() {
        let repo = crate::model::test_support::with_files(
            crate::OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp/data-change-test".into(),
                todo_defaults: super::super::TodoConfig::default(),
            },
            Vec::new(),
            Default::default(),
        );
        let workspace = OrgWorkspace::new(vec![repo.clone()]).unwrap();
        let first = Arc::new(Mutex::new(Vec::new()));
        let second = Arc::new(Mutex::new(Vec::new()));
        let first_capture = first.clone();
        let second_capture = second.clone();
        let first_subscription = workspace.watch_data_changes(move |event| {
            first_capture.lock().unwrap().push(event);
        });
        let _second_subscription = workspace.watch_data_changes(move |event| {
            second_capture.lock().unwrap().push(event);
        });
        super::super::sync_events::publish(&repo);
        assert_eq!(first.lock().unwrap().len(), 1);
        assert_eq!(second.lock().unwrap().len(), 1);
        drop(first_subscription);
        super::super::sync_events::publish(&repo);
        assert_eq!(first.lock().unwrap().len(), 1);
        assert_eq!(second.lock().unwrap().len(), 2);
    }
}
