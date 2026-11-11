//! 每文件冲突通知与基线 hash 比较产生的全局同步提示。
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
struct Fixture {
    root: PathBuf,
    repo: OrgRepo,
}
impl Fixture {
    async fn new(files: &[(&str, &str)]) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "org-notices-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        for (path, source) in files {
            std::fs::write(root.join(path), source).unwrap();
        }
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self { root, repo }
    }
    fn baseline(&self, files: &[(&str, Option<&str>)]) {
        let entries=files.iter().map(|(path,source)|((*path).into(),serde_json::json!({"revision":"a1","version":{"etag":"\"a\"","modified_at":null,"size":source.map(|v|v.len())},
            "hash":source.map(|v|LocalFileVersion::from_bytes(v.as_bytes()).content_hash),"sync_id":"old"}))).collect::<serde_json::Map<String,serde_json::Value>>();
        std::fs::create_dir_all(self.root.join(".sync/remote_base")).unwrap();
        std::fs::write(
            self.root.join(".sync/remote_base/current.json"),
            serde_json::to_vec(&serde_json::json!({"version":1,"origin":"a1","entries":entries}))
                .unwrap(),
        )
        .unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn required(notices: &[CoreNotification]) -> usize {
    notices
        .iter()
        .filter(|n| matches!(n, CoreNotification::SyncRequired))
        .count()
}

#[tokio::test]
async fn one_conflict_notice_per_current_file_and_one_global_dirty_notice() {
    let a = Fixture::new(&[
        ("a.org", "* 同步冲突 :CONFLICT:\n** Point\n"),
        ("b.org", "* 同步冲突 :CONFLICT:\n** Point\n"),
    ])
    .await;
    let b = Fixture::new(&[("a.org", "* TODO Normal\n")]).await;
    let workspace = OrgWorkspace::new(vec![a.repo.clone(), b.repo.clone()]).unwrap();
    let notices = workspace.query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap();
    assert_eq!(required(&notices), 1);
    let conflicts = notices
        .iter()
        .filter_map(|n| {
            if let CoreNotification::SyncConflict(v) = n {
                Some(v)
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(conflicts.len(), 2);
    assert_eq!(conflicts[0].path, "a.org");
    assert_eq!(conflicts[1].path, "b.org");
    assert!(conflicts.iter().all(|v| v.repo_id == a.repo.id));
    let value = serde_json::to_value(&conflicts[0]).unwrap();
    assert!(value.get("syncId").is_none());
    assert!(value.get("paths").is_none());
    assert_eq!(workspace.query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap(), notices);
}

#[tokio::test]
async fn baseline_comparison_detects_edit_creation_deletion_and_survives_workspace_reopen() {
    let mut f = Fixture::new(&[("a.org", "* A\n"), ("empty.org", "")]).await;
    f.baseline(&[
        ("a.org", Some("* A\n")),
        ("empty.org", Some("")),
        ("gone.org", None),
    ]);
    assert!(!OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
    assert!(
        OrgWorkspace::new(vec![f.repo.clone()])
            .unwrap()
            .query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap()
            .is_empty()
    );
    for changed in ["* Changed\n", ""] {
        std::fs::write(f.root.join("a.org"), changed).unwrap();
        assert!(OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
    }
    std::fs::remove_file(f.root.join("a.org")).unwrap();
    assert!(OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
    std::fs::write(f.root.join("a.org"), "* A\n").unwrap();
    assert!(!OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
    std::fs::write(f.root.join("new.org"), "* New\n").unwrap();
    f.repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert!(OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
    let mut reopened = OrgRepo::new(f.root.to_string_lossy().into()).unwrap();
    reopened.load::<WebDavSyncPolicy>().await.unwrap();
    assert_eq!(
        required(
            &OrgWorkspace::new(vec![reopened])
                .unwrap()
                .query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap()
        ),
        1
    );
    std::fs::remove_file(f.root.join("new.org")).unwrap();
    f.repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert!(!OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired)));
}

#[tokio::test]
async fn corrupt_baseline_is_an_error_and_query_does_not_write_history_or_outbox() {
    let f = Fixture::new(&[("a.org", "* A\n")]).await;
    f.baseline(&[("a.org", Some("* A\n"))]);
    let before = std::fs::read(f.root.join(".sync/remote_base/current.json")).unwrap();
    OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[org_tasks_core::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, org_tasks_core::CoreNotification::SyncRequired));
    assert_eq!(
        std::fs::read(f.root.join(".sync/remote_base/current.json")).unwrap(),
        before
    );
    assert!(f.repo.pending_writes().await.unwrap().is_empty());
    std::fs::write(f.root.join(".sync/remote_base/current.json"), b"broken").unwrap();
    assert!(OrgWorkspace::new(vec![f.repo.clone()]).unwrap().query(&[CoreQuery::Notification { query: Default::default() }]).await.is_err());
}
