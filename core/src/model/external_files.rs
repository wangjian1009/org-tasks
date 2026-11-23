//! 外部文件变化描述路径与增删改；查询订阅可直接清除已删除文件。
use serde::Serialize;

use crate::{OrgFileRef, OrgWorkspace};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ExternalFileChangeKind {
    Created,
    Deleted,
    Updated,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalFileChange {
    pub file: OrgFileRef,
    pub kind: ExternalFileChangeKind,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename = "externalFileChanged", rename_all = "camelCase")]
pub struct ExternalFileChanged {
    pub change_files: Vec<ExternalFileChange>,
}

pub struct ExternalFileSubscription {
    _subscription: super::notification_center::Subscription,
}

impl OrgWorkspace {
    /// 监听当前 Workspace 的外部文件变化；取消句柄后不再接收后续事件。
    pub fn watch_external_file_changes<F>(&self, callback: F) -> ExternalFileSubscription
    where
        F: Fn(ExternalFileChanged) + Send + Sync + 'static,
    {
        watch(&self.notifications, callback)
    }
}

pub(crate) fn watch<F>(center: &super::NotificationCenter, callback: F) -> ExternalFileSubscription
where
    F: Fn(ExternalFileChanged) + Send + Sync + 'static,
{
    ExternalFileSubscription {
        _subscription: center.subscribe(move |event| {
            if let super::sync_events::SyncCommitted::ExternalFiles(event) = event {
                callback(event.clone());
            }
        }),
    }
}

/// 通知缓存必须先更新，文件监控只在完整业务收尾后收到事件。
pub(crate) async fn publish(
    repo: &super::OrgRepo,
    center: &super::NotificationCenter,
    change_files: Vec<ExternalFileChange>,
    observations: Vec<(String, crate::file_state::CurrentFileState)>,
    reset: bool,
) -> Result<(), crate::CoreError> {
    let (revision, baseline) = crate::file_state::load_baseline(repo, center).await;
    let mut stamp = center.files().stamp(repo, center);
    stamp.set_revision(revision);
    let notification_result = center.files().apply_repository(repo, stamp, baseline, observations, reset);
    center.files().flush().await?;
    if !change_files.is_empty() {
        center.publish(super::sync_events::SyncCommitted::ExternalFiles(
            ExternalFileChanged { change_files },
        ));
    }
    center.flush().await?;
    notification_result
}

/// reset 只收集将删除的相对路径，不读取或解析文件正文。
pub(crate) async fn deleted_files(
    repo: &super::OrgRepo,
) -> Result<Vec<ExternalFileChange>, crate::CoreError> {
    let root = std::path::Path::new(&repo.root_directory);
    let mut directories = vec![std::path::PathBuf::new()];
    let mut files = Vec::new();
    while let Some(relative) = directories.pop() {
        let mut entries = tokio::fs::read_dir(root.join(&relative))
            .await
            .map_err(|error| crate::CoreError::Store(format!("无法读取重置文件范围: {error}")))?;
        while let Some(entry) = entries
            .next_entry()
            .await
            .map_err(|error| crate::CoreError::Store(format!("无法读取重置文件路径: {error}")))?
        {
            if relative.as_os_str().is_empty()
                && (entry.file_name() == ".sync" || entry.file_name() == "reset")
            {
                continue;
            }
            let path = relative.join(entry.file_name());
            let metadata = tokio::fs::symlink_metadata(entry.path())
                .await
                .map_err(|error| {
                    crate::CoreError::Store(format!("无法读取重置文件属性: {error}"))
                })?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                directories.push(path);
            } else if metadata.is_file() {
                files.push(ExternalFileChange {
                    file: OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: path
                            .to_str()
                            .ok_or(crate::CoreError::InvalidInput("文件路径必须是 UTF-8"))?
                            .replace(std::path::MAIN_SEPARATOR, "/"),
                    },
                    kind: ExternalFileChangeKind::Deleted,
                });
            }
        }
    }
    files.sort_by(|left, right| left.file.path.cmp(&right.file.path));
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn file_event_serializes_typed_paths_and_change_kinds() {
        let event = ExternalFileChanged {
            change_files: vec![ExternalFileChange {
                file: OrgFileRef {
                    repo_id: "repo".into(),
                    path: "dir/a.org".into(),
                },
                kind: ExternalFileChangeKind::Deleted,
            }],
        };
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            serde_json::json!({
                "type":"externalFileChanged", "changeFiles":[{"file":{"repoId":"repo","path":"dir/a.org"},"kind":"deleted"}]
            })
        );
    }

    #[tokio::test]
    async fn reset_clears_core_notifications_before_publishing_precise_deleted_paths() {
        let root = std::env::temp_dir().join(format!(
            "external-reset-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        tokio::fs::create_dir_all(root.join("dir")).await.unwrap();
        tokio::fs::write(root.join("dir/a.org"), "* Conflict :CONFLICT:\n")
            .await
            .unwrap();
        tokio::fs::write(root.join("empty.org"), "").await.unwrap();
        let mut repo = crate::OrgRepo::new(root.to_str().unwrap().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        workspace.query(&[crate::CoreQuery::File { query: crate::FileQuery::default() }]).await.unwrap();
        workspace.notifications.flush().await.unwrap();
        let ordering = Arc::new(Mutex::new(Vec::new()));
        let observed = ordering.clone();
        let (initial, mut received) = tokio::sync::mpsc::unbounded_channel();
        let _notices = workspace
            .watch_notifications(None, super::super::test_support::notification_monitor(move |list| {
                observed
                    .lock()
                    .unwrap()
                    .push(if list.is_empty() { "empty" } else { "conflict" });
                let _ = initial.send(list);
            }))
            .unwrap();
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(5), received.recv())
                .await
                .unwrap()
                .unwrap()
                .len(),
            1
        );
        let (send, mut data_events) = tokio::sync::mpsc::unbounded_channel();
        let starts = workspace
            .subscribe_query(vec![
                crate::QuerySubscriptionRequest::new(
                    crate::TaskQuery {
                        include_files: vec![OrgFileRef {
                            repo_id: repo.id.clone(),
                            path: "dir/a.org".into(),
                        }],
                        ..Default::default()
                    }
                    .into(),
                    move |event| { send.send(event).unwrap(); },
                ),
                crate::QuerySubscriptionRequest::new(
                    crate::TaskQuery {
                        include_files: vec![OrgFileRef {
                            repo_id: repo.id.clone(),
                            path: "unrelated.org".into(),
                        }],
                        ..Default::default()
                    }
                    .into(),
                    |_| {},
                ),
            ])
            .await
            .unwrap();
        let observed = ordering.clone();
        let events = Arc::new(Mutex::new(Vec::new()));
        let captured = events.clone();
        let watch = workspace.watch_external_file_changes(move |event| {
            observed.lock().unwrap().push("files");
            captured.lock().unwrap().push(event);
        });
        workspace.reset_repo(root.to_str().unwrap()).await.unwrap();
        assert_eq!(*ordering.lock().unwrap(), ["conflict", "empty", "files"]);
        assert_eq!(
            workspace.query_subscription_status(&starts[0].subscription),
            crate::QuerySubscriptionStatus::Current
        );
        assert_eq!(
            workspace.query_subscription_status(&starts[1].subscription),
            crate::QuerySubscriptionStatus::Current
        );
        let events = events.lock().unwrap().clone();
        let crate::DataChangeEvent::NotificationEvent { removed_files, .. } = data_events.try_recv().unwrap();
        assert_eq!(removed_files.len(), 1);
        assert_eq!(removed_files[0].path, "dir/a.org");
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0]
                .change_files
                .iter()
                .map(|change| change.file.path.as_str())
                .collect::<Vec<_>>(),
            ["dir/a.org", "empty.org"]
        );
        assert!(
            events[0]
                .change_files
                .iter()
                .all(|change| change.file.repo_id == repo.id
                    && change.kind == ExternalFileChangeKind::Deleted)
        );
        drop(watch);
        workspace.stop().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
