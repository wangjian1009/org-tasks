//! 普通操作组提交后的精确增量及通知列表；外部文件变化使用独立监控。
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
    NotificationEvent {
        #[serde(rename = "repoId")]
        repo_id: OrgRepoId,
        #[serde(rename = "operationId")]
        operation_id: Option<String>,
        /// None 表示载荷不可用，不能视为空变化；普通操作组提供 Some 的精确文件集合。
        files: Option<Vec<FileDataChange>>,
        changes: Vec<TaskDataChange>,
        notifications: Vec<super::CoreNotification>,
        /// 文件数据离开接收范围；不代表删除底层文件。
        #[serde(rename = "removedFiles", skip_serializing_if = "Vec::is_empty")]
        removed_files: Vec<OrgFileRef>,
        /// 任务查询的完整分类摘要；普通仓库事件不提供。
        #[serde(skip_serializing_if = "Option::is_none")]
        categories: Option<Vec<TaskCategory>>,
    },
}

pub struct DataChangeSubscription {
    pub(crate) subscription: super::notification_center::Subscription,
}

impl OrgWorkspace {
    /// 注册独立数据监控；多个订阅同时有效，回调不能同步等待当前 Workspace 的后续业务命令。
    pub fn watch_data_changes<F>(&self, callback: F) -> DataChangeSubscription
    where
        F: Fn(DataChangeEvent) + Send + Sync + 'static,
    {
        watch(&self.notifications, callback)
    }
}

pub(crate) fn watch<F>(center: &super::notification_center::NotificationCenter, callback: F) -> DataChangeSubscription
where F: Fn(DataChangeEvent) + Send + Sync + 'static {
        let subscription = center.subscribe(move |event| {
            let super::sync_events::SyncCommitted::Repository {
                repo_id,
                operation_id,
                files,
                changes,
                notifications,
            } = event else { return; };
                callback(DataChangeEvent::NotificationEvent {
                    repo_id: repo_id.clone(),
                    operation_id: operation_id.clone(),
                    files: files.clone(),
                    changes: changes.clone(),
                    notifications: notifications.clone(),
                    removed_files: Vec::new(),
                    categories: None,
                });
        });
        DataChangeSubscription {
            subscription,
        }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn multiple_subscriptions_receive_and_can_cancel_notification_events() {
        let repo = crate::model::test_support::with_files(
            crate::OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp/data-change-test".into(),
                todo_defaults: super::super::TodoConfig::default(),
            },
            Vec::new(),
            Default::default(),
        );
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
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
        let after = crate::OrgFile::new(repo.id.clone(), "a.org".into(), b"* TODO A\n".to_vec())
            .unwrap().metadata(false);
        let change = FileDataChange {
            before: None,
            before_version: None,
            after_version: after.file_version.clone(),
            after,
        };
        super::super::sync_events::publish_changes(
            &workspace.notifications, &repo, None, Some(vec![change.clone()]), Vec::new(),
        );
        workspace.notifications.flush().await.unwrap();
        assert_eq!(first.lock().unwrap().len(), 1);
        assert_eq!(second.lock().unwrap().len(), 1);
        drop(first_subscription);
        super::super::sync_events::publish_changes(
            &workspace.notifications, &repo, None, Some(vec![change]), Vec::new(),
        );
        workspace.notifications.flush().await.unwrap();
        assert_eq!(first.lock().unwrap().len(), 1);
        assert_eq!(second.lock().unwrap().len(), 2);
    }
}
