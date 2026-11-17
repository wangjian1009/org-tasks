//! 同步提交后的回调端口；通知模块订阅它，不依赖 UI 或宿主运行时。

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SyncCommitted {
    Repository {
        repo_id: String,
        operation_id: Option<String>,
        files: Option<Vec<super::FileDataChange>>,
        changes: Vec<super::TaskDataChange>,
    },
}

// 基线可能先于工作文件发布；错误返回同样需要触发仓库数据订阅更新。
// 注意事项列表由业务另行投递带 checksum 的状态，不消费本失效事件。
pub(crate) struct CompletionNotice {
    repo_id: String,
    notifications: Option<super::notification_center::NotificationCenter>,
}
impl CompletionNotice {
    pub(crate) fn new(
        repo: &super::OrgRepo,
        notifications: Option<&super::notification_center::NotificationCenter>,
    ) -> Self {
        Self {
            repo_id: repo.id.clone(),
            notifications: notifications.cloned(),
        }
    }
}
impl Drop for CompletionNotice {
    fn drop(&mut self) {
        if let Some(notifications) = &self.notifications {
            notifications.publish(SyncCommitted::Repository {
                repo_id: self.repo_id.clone(),
                operation_id: None,
                files: None,
                changes: Vec::new(),
            });
        }
    }
}
pub(crate) fn publish(
    notifications: &super::notification_center::NotificationCenter,
    repo: &super::OrgRepo,
) {
    publish_operation(notifications, repo, None);
}
pub(crate) fn publish_operation(
    notifications: &super::notification_center::NotificationCenter,
    repo: &super::OrgRepo,
    operation_id: Option<&str>,
) {
    publish_changes(notifications, repo, operation_id, None, Vec::new());
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
    });
}
