//! 验证单文件解决请求、进程级同步提示和跨仓库确认；不访问真实远端。
use org_tasks_core::webdav::*;
use org_tasks_core::*;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct Fixture {
    repo: OrgRepo,
    root: PathBuf,
}
impl Fixture {
    async fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "org-conflict-contract-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self { repo, root }
    }
    async fn conflict(&mut self, path: &str) -> SyncConflictComparison {
        let local = self.root.join(path);
        tokio::fs::create_dir_all(local.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(local, b"* TODO Local\r\n").await.unwrap();
        let folder = self.root.join(format!(".sync/history/1/conflicts/{path}"));
        tokio::fs::create_dir_all(&folder).await.unwrap();
        let bytes = b"* TODO Remote\r\n";
        tokio::fs::write(
            folder.join(std::path::Path::new(path).file_name().unwrap()),
            bytes,
        )
        .await
        .unwrap();
        let mut record = OrgRepoSyncRecord::<WebDavSyncContextDetail, WebDavSyncFileDetail>::new(
            "one".into(),
            1,
        )
        .unwrap()
        .with_kind("webdav");
        record
            .append_file(
                OrgRepoSyncFileRecord::new(
                    path.into(),
                    OrgRepoSyncFileAction::Conflicted,
                    OrgRepoSyncFileState::Conflict,
                )
                .unwrap()
                .with_detail(WebDavSyncFileDetail {
                    etag: Some("\"one\"".into()),
                    archive: Some(WebDavFileArchive {
                        content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
                    }),
                    ..Default::default()
                }),
            )
            .unwrap();
        record.finish(OrgRepoSyncResult::Succeeded, 2).unwrap();
        tokio::fs::write(
            self.root.join(".sync/history/1.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .await
        .unwrap();
        self.repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: "one".into(),
                path: path.into(),
            })
            .await
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn request(comparison: &SyncConflictComparison, side: OrgMergeSide) -> SyncConflictResolution {
    SyncConflictResolution {
        target: comparison.target.clone(),
        expected_local_hash: comparison.local_hash.clone(),
        expected_remote_hash: comparison.remote_hash.clone(),
        expected_local_missing: comparison.local_missing,
        choices: comparison
            .changes
            .iter()
            .map(|c| OrgMergeChoice {
                key: c.key.clone(),
                side,
            })
            .collect(),
    }
}
async fn notices(repos: Vec<OrgRepo>) -> Vec<CoreNotification> {
    OrgWorkspace::new(repos)
        .unwrap()
        .notifications()
        .await
        .unwrap()
}
fn required(notifications: &[CoreNotification]) -> usize {
    notifications
        .iter()
        .filter(|n| matches!(n, CoreNotification::SyncRequired))
        .count()
}

struct Confirmation {
    fail: bool,
}
impl SyncPolicy for Confirmation {
    const KIND: &'static str = "webdav";
    type ContextDetail = WebDavSyncContextDetail;
    type FileDetail = WebDavSyncFileDetail;
    async fn synchronize(
        &self,
        context: &mut SyncContext<'_>,
        _: &SyncCancellation,
        _: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError> {
        let mut record = OrgRepoSyncRecord::new(
            format!("confirm-{}", context.started_at),
            context.started_at,
        )?
        .with_kind("webdav");
        for file in &context.repo.files {
            if context.options.excludes_path(&file.path) {
                continue;
            }
            record.append_file(
                OrgRepoSyncFileRecord::new(
                    file.path.clone(),
                    OrgRepoSyncFileAction::Uploaded,
                    if self.fail {
                        OrgRepoSyncFileState::Failed
                    } else {
                        OrgRepoSyncFileState::Synchronized
                    },
                )?
                .with_local_version(Some(LocalFileVersion::from_bytes(file.source_bytes())))
                .with_detail(WebDavSyncFileDetail {
                    etag: Some("\"two\"".into()),
                    synced_source: Some(std::str::from_utf8(file.source_bytes()).unwrap().into()),
                    ..Default::default()
                }),
            )?;
        }
        record.finish(
            if self.fail {
                OrgRepoSyncResult::Failed
            } else {
                OrgRepoSyncResult::Succeeded
            },
            context.started_at,
        )?;
        Ok(record)
    }
}

#[tokio::test]
async fn singleton_notifications_require_complete_saves_and_all_repositories_to_confirm() {
    let mut a = Fixture::new().await;
    let mut b = Fixture::new().await;
    let mut equal = Fixture::new().await;
    let updates = Arc::new(Mutex::new(Vec::new()));
    let captured = updates.clone();
    let workspace = OrgWorkspace::new(vec![]).unwrap();
    let _subscription =
        workspace.watch_notifications(move |update| captured.lock().unwrap().push(update));
    let ac = a.conflict("path/to/A.org").await;
    assert_eq!(required(&notices(vec![]).await), 0);
    let valid = request(&ac, OrgMergeSide::Local);
    // 不完整、重复、未知 key 或过期版本均不能写入文件或生成结果、意图和提示。
    let mut incomplete = valid.clone();
    incomplete.choices.pop();
    let mut duplicate = valid.clone();
    duplicate.choices.push(duplicate.choices[0].clone());
    let mut unknown = valid.clone();
    unknown.choices[0].key = "unknown".into();
    let mut stale = valid.clone();
    stale.expected_local_hash = "stale".into();
    for invalid in [incomplete, duplicate, unknown, stale] {
        assert!(a.repo.resolve_conflict(&invalid).await.is_err());
        assert_eq!(
            tokio::fs::read(a.root.join("path/to/A.org")).await.unwrap(),
            b"* TODO Local\r\n"
        );
        assert!(
            !a.root
                .join(".sync/history/1/conflicts/path/to/A.org/A.resolved.org")
                .exists()
        );
        assert!(a.repo.pending_writes().await.unwrap().is_empty());
        assert_eq!(required(&notices(vec![]).await), 0);
    }
    let mut forged = serde_json::to_value(&valid).unwrap();
    forged["changes"] = serde_json::json!([]);
    assert!(serde_json::from_value::<SyncConflictResolution>(forged).is_err());
    a.repo.resolve_conflict(&valid).await.unwrap();
    assert_eq!(required(&notices(vec![a.repo.clone()]).await), 1);
    assert_eq!(
        serde_json::to_value(CoreNotification::SyncRequired).unwrap(),
        serde_json::json!({"type":"syncRequired"})
    );
    let bc = b.conflict("path/to/B.org").await;
    b.repo
        .resolve_conflict(&request(&bc, OrgMergeSide::Local))
        .await
        .unwrap();
    assert_eq!(
        required(&notices(vec![a.repo.clone(), b.repo.clone()]).await),
        1
    );
    assert_eq!(
        updates
            .lock()
            .unwrap()
            .iter()
            .filter(|u| matches!(u, NotificationUpdate::GlobalNotificationsChanged))
            .count(),
        1,
        "后来同类提示不再次发布"
    );
    let ec = equal.conflict("equal.org").await;
    equal
        .repo
        .resolve_conflict(&request(&ec, OrgMergeSide::Remote))
        .await
        .unwrap();
    assert!(equal.repo.pending_writes().await.unwrap().is_empty());
    assert_eq!(
        required(&notices(vec![equal.repo.clone()]).await),
        1,
        "另一文件采用远端不能清除已有提示"
    );
    a.repo
        .sync(
            &Confirmation { fail: true },
            3,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
        )
        .await
        .unwrap();
    assert_eq!(required(&notices(vec![]).await), 1);
    a.repo
        .sync(
            &Confirmation { fail: false },
            4,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
        )
        .await
        .unwrap();
    assert_eq!(
        required(&notices(vec![]).await),
        1,
        "其他仓库未确认，保留唯一提示"
    );
    b.repo
        .sync_with_options(
            &Confirmation { fail: false },
            3,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
            SyncOptions {
                excluded_directories: vec!["path".into()],
            },
        )
        .await
        .unwrap();
    assert_eq!(
        required(&notices(vec![]).await),
        1,
        "过滤的待上传文件不能视为确认"
    );
    b.repo
        .sync(
            &Confirmation { fail: false },
            4,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
        )
        .await
        .unwrap();
    assert_eq!(required(&notices(vec![]).await), 0);
    let mut later = Fixture::new().await;
    let comparison = later.conflict("A.resolved.org").await;
    later
        .repo
        .resolve_conflict(&request(&comparison, OrgMergeSide::Local))
        .await
        .unwrap();
    assert!(
        later
            .root
            .join(".sync/history/1/conflicts/A.resolved.org/A.resolved.resolved.org")
            .is_file()
    );
    assert_eq!(required(&notices(vec![]).await), 1);
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "restarted_notification_is_not_recreated",
            "--nocapture",
        ])
        .env("ORG_TASKS_RESTART_FIXTURE", &later.root)
        .status()
        .unwrap();
    assert!(status.success());
    // 完成另一进程的只读查询不会消费本进程通知。
    assert_eq!(required(&notices(vec![]).await), 1);
}

#[tokio::test]
async fn restarted_notification_is_not_recreated() {
    let Some(root) = std::env::var_os("ORG_TASKS_RESTART_FIXTURE") else {
        return;
    };
    let mut repo = OrgRepo::new(PathBuf::from(root).to_string_lossy().into()).unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert!(!repo.pending_writes().await.unwrap().is_empty());
    assert_eq!(
        required(&notices(vec![repo]).await),
        0,
        "新进程不能从 resolved 或 outbox 恢复同步提示"
    );
}
