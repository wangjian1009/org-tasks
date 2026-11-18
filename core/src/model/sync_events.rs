//! 提交后的通知分发端口；同时路由精确增量与外部文件变化，不依赖 UI 或宿主运行时。

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SyncCommitted {
    ExternalFiles(super::ExternalFileChanged),
    Repository {
        repo_id: String,
        operation_id: Option<String>,
        files: Option<Vec<super::FileDataChange>>,
        changes: Vec<super::TaskDataChange>,
        notifications: Vec<super::CoreNotification>,
    },
}

pub(crate) fn publish_changes(
    notifications: &super::notification_center::NotificationCenter,
    repo: &super::OrgRepo,
    operation_id: Option<&str>,
    files: Option<Vec<super::FileDataChange>>,
    changes: Vec<super::TaskDataChange>,
) {
    notifications.publish(SyncCommitted::Repository {
        repo_id: repo.id.clone(),
        operation_id: operation_id.map(str::to_owned),
        files,
        changes,
        notifications: Vec::new(),
    });
}
