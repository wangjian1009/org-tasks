//! 冲突容器、普通操作组丢弃和基线通知的完整边界验证。
use org_tasks_core::{webdav::WebDavSyncPolicy, *};

use std::path::PathBuf;

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(bytes: &[u8]) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "org-container-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), bytes).unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self {
            root,
            workspace: OrgWorkspace::new(vec![repo]).unwrap(),
        }
    }
    async fn file(&self) -> OrgFile {
        self.workspace.repos()[0].file("a.org").await.unwrap()
    }
    async fn group(&self, ids: &[String]) -> TaskOperationGroup {
        let file = self.file().await;
        TaskOperationGroup {
            operations: ids
                .iter()
                .map(|id| {
                    TaskOperation::ConfilictSelection(TaskConfilictSelection { path:None, target:None,
                        id: id.clone(),
                        action: TaskConfilictAction::Discard,
                    })
                })
                .collect(),
            file_versions: vec![TaskFileVersion {
                repo_id: file.repo_id.clone(),
                file: file.path.clone(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![file.repo_id.clone()],
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn one_footer_keeps_remote_bytes_and_discard_all_uses_task_operations() {
    for nl in ["\n", "\r\n"] {
        for final_newline in [false, true] {
            let base = format!(
                "#+TITLE: Remote{nl}* TODO A{nl}:PROPERTIES:{nl}:ID: a{nl}:END:{nl}base{nl}* B{nl}base{nl}"
            );
            let local = base.replace("base", "local");
            let mut remote = base.replacen("base", "remote", 1);
            if !final_newline {
                remote.truncate(remote.len() - nl.len());
            }
            let merged = merge(base.as_bytes(), local.as_bytes(), remote.as_bytes()).unwrap();
            assert!(merged.starts_with(remote.as_bytes()));
            assert_eq!(
                merge(base.as_bytes(), local.as_bytes(), &merged).unwrap(),
                merged
            );
            let mut f = Fixture::new(&merged).await;
            let file = f.file().await;
            assert!(file.has_conflict());
            assert_eq!(file.conflict_ids().len(), 2);
            let roots = file
                .syntax()
                .document()
                .headlines()
                .filter(|h| h.tags().any(|t| t == "CONFLICT"))
                .collect::<Vec<_>>();
            assert_eq!(roots.len(), 1);
            assert_eq!(usize::from(roots[0].end()), merged.len());
            for point in roots[0].headlines() {
                assert!(point.properties().unwrap().get("CONFILICT_ID").is_some());
                assert_eq!(point.properties().unwrap().iter().count(), 1);
                assert!(point.headlines().next().is_some());
            }
            for legacy in [
                ":CONFLICT_ID:",
                ":CONFLICT_SOURCE:",
                ":CONFLICT_ORIGIN:",
                ":CONFLICT_PARENT:",
                ":CONFLICT_PATH:",
                ":CONFLICT_OPERATION:",
                "#+CONFLICT:",
            ] {
                assert!(
                    !String::from_utf8_lossy(&merged).contains(legacy),
                    "{legacy}"
                );
            }
            let query = f.workspace.query(&TaskQuery::default()).await.unwrap();
            assert_eq!(query.tasks.len(), 2);
            assert!(
                query
                    .tasks
                    .iter()
                    .all(|task| !task.body().contains("local"))
            );
            let ids = file.conflict_ids();
            let first = f.group(&ids[..1]).await;
            f.workspace.execute_task_operations(&first).await.unwrap();
            assert!(f.file().await.has_conflict());
            assert_eq!(f.file().await.conflict_ids().len(), 1);
            let last = f.group(&ids[1..]).await;
            f.workspace.execute_task_operations(&last).await.unwrap();
            assert!(!f.file().await.has_conflict());
            assert!(f.file().await.conflict_ids().is_empty());
            assert_eq!(
                std::fs::read(f.root.join("a.org")).unwrap(),
                remote.as_bytes()
            );
            assert_eq!(f.workspace.task_operation_history.entries.len(), 2);
            assert_eq!(
                f.workspace.repos()[0].pending_writes().await.unwrap().len(),
                2
            );
        }
    }
}

#[tokio::test]
async fn invalid_stale_or_duplicate_selections_leave_the_entire_group_unwritten() {
    let base = b"* A\nbase\n";
    let merged = merge(base, b"* A\nlocal\n", b"* A\nremote\n").unwrap();
    let mut f = Fixture::new(&merged).await;
    let ids = f.file().await.conflict_ids();
    let mut stale = f.group(&ids).await;
    stale.file_versions[0].version = "stale".into();
    let mut duplicate = f.group(&ids).await;
    duplicate.operations.push(duplicate.operations[0].clone());
    let mut unknown = f.group(&ids).await;
    unknown
        .operations
        .push(TaskOperation::ConfilictSelection(TaskConfilictSelection { path:None, target:None,
            id: "missing".into(),
            action: TaskConfilictAction::Discard,
        }));
    for group in [stale, duplicate, unknown] {
        assert!(f.workspace.execute_task_operations(&group).await.is_err());
        assert_eq!(std::fs::read(f.root.join("a.org")).unwrap(), merged);
        assert!(f.workspace.task_operation_history.entries.is_empty());
        assert!(
            f.workspace.repos()[0]
                .pending_writes()
                .await
                .unwrap()
                .is_empty()
        );
    }
    let json = serde_json::json!({"operations":[{"type":"ConfilictSelection","data":{"id":ids[0],"action":"replace"}}]});
    assert!(serde_json::from_value::<TaskOperationGroup>(json).is_err());
}

#[test]
fn conflict_points_keep_user_properties_and_code_literals_visible() {
    let base = b"* A\nbase\n";
    let local=b"* A\n:PROPERTIES:\n:ID: user\n:CONFLICT_COMMENT: keep\n:END:\n#+begin_src text\n:CONFLICT_SOURCE: literal\n#+end_src\nlocal\n";
    let remote = b"* A\nremote\n";
    let merged = merge(base, local, remote).unwrap();
    let text = String::from_utf8(merged).unwrap();
    assert!(text.contains(":CONFLICT_COMMENT: keep"));
    assert!(text.contains(":CONFLICT_SOURCE: literal"));
}

#[tokio::test]
async fn ordinary_edits_keep_the_footer_and_its_separator_independent_from_normal_content() {
    for remote in ["* A\nremote", "* A\nremote\n"] {
        let merged = merge(b"* A\nbase\n", b"* A\nlocal\n", remote.as_bytes()).unwrap();
        let mut f = Fixture::new(&merged).await;
        let original_ids = f.file().await.conflict_ids();
        let normal = f.file().await.node_paths()[0].clone();
        f.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: vec![
                    TaskOperation::Modification(TaskModificationOperation {
                        path: normal.clone(),
                        modifications: vec![TaskModification::Body(Some("Updated".into()))],
                    }),
                    TaskOperation::Creation(TaskCreation::new(
                        TaskPosition {
                            parent: f.file().await.full_path(),
                            after: Some(normal),
                        },
                        "New".into(),
                    )),
                ],
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(f.file().await.conflict_ids(), original_ids);
        let clean = OrgFile::new(
            f.file().await.repo_id.clone(),
            "a.org".into(),
            remote.as_bytes().to_vec(),
        )
        .unwrap();
        let mut plain = Fixture::new(clean.source_bytes()).await;
        let plain_path = plain.file().await.node_paths()[0].clone();
        plain
            .workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: vec![
                    TaskOperation::Modification(TaskModificationOperation {
                        path: plain_path.clone(),
                        modifications: vec![TaskModification::Body(Some("Updated".into()))],
                    }),
                    TaskOperation::Creation(TaskCreation::new(
                        TaskPosition {
                            parent: plain.file().await.full_path(),
                            after: Some(plain_path),
                        },
                        "New".into(),
                    )),
                ],
                ..Default::default()
            })
            .await
            .unwrap();
        let group = f.group(&original_ids).await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert_eq!(f.file().await.source_bytes(), plain.file().await.source_bytes());
    }
}
