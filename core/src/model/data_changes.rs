//! 仓库数据失效通知；不携带快照，调用方收到后重新查询当前数据。
use serde::Serialize;

use super::{OrgRepoId, OrgWorkspace};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DataChangeEvent {
    RepositoryChanged {
        #[serde(rename = "repoId")]
        repo_id: OrgRepoId,
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
            } = event;
            if roots.contains(root_directory) {
                callback(DataChangeEvent::RepositoryChanged {
                    repo_id: repo_id.clone(),
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
        let repo = super::super::OrgRepo {
            id: "repo".into(),
            root_directory: "/tmp/data-change-test".into(),
            files: Vec::new(),
            todo_defaults: super::super::TodoConfig::default(),
            task_scan_rules: Default::default(),
        };
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
