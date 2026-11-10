//! 验证冲突子树在查询前排除，所有普通节点和原文编辑入口均不能改写其内容。
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;

const SOURCE: &str = "#+CATEGORY: Work\n* TODO Normal :REFILE:\nbody\n* Parent\n** Hidden :CONFLICT:REFILE:\n[[geo:1,2][place]]\n*** TODO Child :REFILE:\nsecret\n* TODO Visible\n";
struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "org-conflict-boundary-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), SOURCE).unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self {
            root,
            workspace: OrgWorkspace::new(vec![repo]).unwrap(),
        }
    }
    fn path(&self, titles: &[&str]) -> TaskPath {
        TaskPath {
            repo_id: self.workspace.repos()[0].id.clone(),
            file: Some("a.org".into()),
            titles: titles.iter().map(|v| (*v).into()).collect(),
            occurrence: 1,
        }
    }
    async fn reject(&mut self, operation: TaskOperation) {
        let group = TaskOperationGroup {
            operations: vec![operation],
            queue_repo_ids: vec![self.workspace.repos()[0].id.clone()],
            ..Default::default()
        };
        assert!(
            self.workspace
                .execute_task_operations(&group)
                .await
                .is_err()
        );
        assert_eq!(
            std::fs::read(self.root.join("a.org")).unwrap(),
            SOURCE.as_bytes()
        );
        assert!(self.workspace.task_operation_history.entries.is_empty());
        assert!(
            self.workspace.repos()[0]
                .pending_writes()
                .await
                .unwrap()
                .is_empty()
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn every_query_excludes_conflict_roots_descendants_counts_and_refile_targets() {
    let f = Fixture::new().await;
    let result = f.workspace.query(&TaskQuery::default()).await.unwrap();
    assert_eq!(
        result.tasks.iter().map(|t| t.title()).collect::<Vec<_>>(),
        vec!["Normal", "Parent", "Visible"]
    );
    assert_eq!(result.categories.iter().map(|v| v.count).sum::<usize>(), 3);
    for expression in [
        "t.CONFLICT",
        "tn.CONFLICT",
        "secret",
        "has.address",
        "it.done",
        "it.none t.CONFLICT",
    ] {
        assert!(
            f.workspace
                .query(&TaskQuery {
                    expression: expression.into(),
                    include_done: true,
                    include_compose_tasks: true,
                    ..Default::default()
                }).await
                .unwrap()
                .tasks
                .is_empty(),
            "{expression}"
        );
    }
    let targets = f
        .workspace
        .query_refile_targets(&RefileTargetQuery::default()).await
        .unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].heading_path, vec!["Normal"]);
    assert_eq!(f.workspace.repos()[0].file_metadata().await.unwrap()[0].task_count, 3);
    assert_eq!(f.workspace.repos()[0].nodes().await.unwrap().len(), 3);
}

#[tokio::test]
async fn node_operations_cannot_edit_conflicts_directly_or_through_ancestors() {
    let mut f = Fixture::new().await;
    for titles in [
        &["Parent", "Hidden"][..],
        &["Parent", "Hidden", "Child"][..],
    ] {
        let path = f.path(titles);
        f.reject(TaskOperation::Modification(TaskModificationOperation {
            path: path.clone(),
            modifications: vec![TaskModification::Title(Some("Changed".into()))],
        }))
        .await;
        f.reject(TaskOperation::Modification(TaskModificationOperation {
            path: path.clone(),
            modifications: vec![TaskModification::Tags(None)],
        }))
        .await;
        f.reject(TaskOperation::Deletion(TaskDeletion { path: path.clone() }))
            .await;
        f.reject(TaskOperation::Movement(TaskMovement {
            path: path.clone(),
            position: TaskPosition {
                parent: f.path(&[]),
                after: None,
            },
        }))
        .await;
        f.reject(TaskOperation::Creation(TaskCreation::new(
            TaskPosition {
                parent: path.clone(),
                after: None,
            },
            "New".into(),
        )))
        .await;
    }
    f.reject(TaskOperation::Deletion(TaskDeletion {
        path: f.path(&["Parent"]),
    }))
    .await;
    f.reject(TaskOperation::Movement(TaskMovement {
        path: f.path(&["Parent"]),
        position: TaskPosition {
            parent: f.path(&[]),
            after: None,
        },
    }))
    .await;
    f.reject(TaskOperation::Modification(TaskModificationOperation {
        path: f.path(&["Parent"]),
        modifications: vec![TaskModification::AddressLink(Some(TaskAddressChange {
            old_uri: "geo:1,2".into(),
            new_uri: "geo:3,4".into(),
        }))],
    }))
    .await;
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path: f.path(&["Normal"]),
                modifications: vec![TaskModification::Body(Some("Updated".into()))],
            })],
            ..Default::default()
        })
        .await
        .unwrap();
    let file = std::fs::read_to_string(f.root.join("a.org")).unwrap();
    assert!(file.contains(
        "** Hidden :CONFLICT:REFILE:\n[[geo:1,2][place]]\n*** TODO Child :REFILE:\nsecret\n"
    ));
}

#[test]
fn raw_editor_cannot_overwrite_delete_or_insert_inside_conflict_subtrees() {
    let make = || OrgFile::new("r".into(), "a.org".into(), SOURCE.as_bytes().to_vec()).unwrap();
    let at = SOURCE.find("secret").unwrap();
    let pos = |offset| {
        let prefix = &SOURCE.as_bytes()[..offset];
        SourcePosition::new(
            1 + prefix.iter().filter(|&&b| b == b'\n').count() as u32,
            prefix.iter().rev().take_while(|&&b| b != b'\n').count() as u32,
            offset as u64,
        )
        .unwrap()
    };
    let range = SourceRange::new(pos(at), pos(at + 6)).unwrap();
    for edit in [
        OrgFileEdit::ReplaceRange {
            target: range,
            content: b"new".to_vec(),
        },
        OrgFileEdit::DeleteRange { target: range },
        OrgFileEdit::InsertAt {
            anchor: pos(at),
            content: b"new".to_vec(),
        },
    ] {
        let mut file = make();
        assert!(apply_edit(&mut file, edit).is_err());
        assert_eq!(file.source_bytes(), SOURCE.as_bytes());
    }
}
