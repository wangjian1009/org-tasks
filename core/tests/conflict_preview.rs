//! 临时副本隔离、地址代次、既有操作复用及最终应用的版本保护。
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
struct Fixture {
    root: PathBuf,
    source: Vec<u8>,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let base = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "org-preview-test-{}-{}-{}",
                std::process::id(),
                serial,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
        std::fs::create_dir_all(base.join("repo")).unwrap();
        let source = merge(
            b"* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nold\n",
            b"* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nlocal\n",
            b"* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nremote\n",
        )
        .unwrap();
        std::fs::write(base.join("repo/a.org"), &source).unwrap();
        let mut repo = OrgRepo::new(base.join("repo").to_str().unwrap().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let workspace = OrgWorkspace::new(vec![repo])
            .unwrap()
            .with_preview_root(base.join("previews"))
            .unwrap();
        Self {
            root: base,
            source,
            workspace,
        }
    }
    async fn preview(&mut self) -> ConflictPreview {
        let file = self.workspace.repos()[0].file("a.org").await.unwrap();
        self.workspace
            .create_conflict_preview(ConflictPreviewRequest {
                file: file.full_path(),
                conflict_id: file.conflict_ids()[0].clone(),
                source_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            })
            .await
            .unwrap()
    }
    async fn choose(&mut self, p: &ConflictPreview, action: TaskConfilictAction) {
        let file = p.file().await.unwrap();
        self.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
                    path: Some(file.full_path()),
                    id: p.conflict_id().into(),
                    action,
                    target: None,
                })],
                queue_repo_ids: vec![],
                file_versions: vec![TaskFileVersion {
                    repo_id: file.repo_id.clone(),
                    file: file.path.clone(),
                    version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                }],
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
#[tokio::test]
async fn copy_uses_reserved_repo_and_uuid_and_never_enters_queries_or_events() {
    let mut f = Fixture::new().await;
    let before = f.workspace.query(&TaskQuery::default()).await.unwrap();
    let p = f.preview().await;
    assert_eq!(p.full_path().repo_id, "<preview>");
    assert_eq!(p.full_path().file.as_deref(), Some(p.id()));
    assert_eq!(p.file().await.unwrap().source_bytes(), f.source);
    assert_eq!(
        f.workspace
            .query(&TaskQuery::default()).await
            .unwrap()
            .tasks
            .len(),
        before.tasks.len()
    );
    assert_eq!(f.workspace.repos().len(), 1);
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
    assert!(f.workspace.task_operation_history.entries.is_empty());
    assert!(
        p.changes()
            .await
            .unwrap()
            .changes
            .iter()
            .any(|c| c.area == "main")
    );
    assert!(String::from_utf8_lossy(p.file().await.unwrap().source_bytes()).contains("local"));
}
#[tokio::test]
async fn finish_returns_source_operations_without_writing_and_host_uses_unified_interface() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    let file = p.file().await.unwrap();
    let opts = ConflictPreviewFinishOptions {
        preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
    };
    let mut group = p.finish(opts.clone()).await.unwrap();
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    assert!(f.workspace.task_operation_history.entries.is_empty());
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
    assert_eq!(group.file_versions[0].repo_id, f.workspace.repos()[0].id);
    assert_eq!(group.file_versions[0].file, "a.org");
    let TaskOperation::ConfilictSelection(selection) = &group.operations[0] else {
        panic!("缺少冲突操作")
    };
    assert_eq!(
        selection.path.as_ref().unwrap().repo_id,
        f.workspace.repos()[0].id
    );
    assert_eq!(
        selection.path.as_ref().unwrap().file.as_deref(),
        Some("a.org")
    );
    assert_eq!(p.finish(opts).await.unwrap(), group);
    assert!(p.file().await.is_err());
    group.queue_repo_ids = vec![f.workspace.repos()[0].id.clone()];
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        file.source_bytes()
    );
    assert_eq!(
        f.workspace.repos()[0].pending_writes().await.unwrap().len(),
        1
    );
    assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
}
#[tokio::test]
async fn finishing_preserves_source_version_and_later_submission_rejects_external_changes() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    f.choose(&p, TaskConfilictAction::Discard).await;
    assert!(matches!(
        p.finish(ConflictPreviewFinishOptions {
            preview_version: "stale".into()
        })
        .await,
        Err(CoreError::Preview {
            code: "previewVersionMismatch",
            ..
        })
    ));
    let file = p.file().await.unwrap();
    std::fs::write(f.root.join("repo/a.org"), b"* New\n").unwrap();
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        b"* New\n"
    );
    p.discard().await.unwrap();
    p.discard().await.unwrap();
}
#[tokio::test]
async fn new_copy_invalidates_old_paths_and_mixed_operations_fail_before_writing() {
    let mut f = Fixture::new().await;
    let old = f.preview().await;
    let current = f.preview().await;
    assert_ne!(old.id(), current.id());
    assert!(old.file().await.is_err());
    assert!(f.workspace.file_at(&old.full_path()).await.is_err());
    let file = current.file().await.unwrap();
    let real = f.workspace.repos()[0].file("a.org").await.unwrap();
    let group = TaskOperationGroup {
        operations: vec![TaskOperation::Deletion(TaskDeletion {
            path: real.node_paths()[0].clone(),
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: "<preview>".into(),
            file: current.id().into(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    old.discard().await.unwrap();
    assert!(current.file().await.is_ok());
}
#[tokio::test]
async fn ordinary_modifications_use_preview_full_paths_and_keep_other_candidates() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    let file = p.file().await.unwrap();
    let path = file.editable_node_paths()[0].clone();
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path,
                modifications: vec![TaskModification::Title(Some("Adjusted".into()))],
            })],
            file_versions: vec![TaskFileVersion {
                repo_id: "<preview>".into(),
                file: p.id().into(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![],
        })
        .await
        .unwrap();
    let edited = p.file().await.unwrap();
    assert!(String::from_utf8_lossy(edited.source_bytes()).contains("Adjusted"));
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(edited.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(group.operations.len(), 2);
    assert!(!serde_json::to_string(&group).unwrap().contains("<preview>"));
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        edited.source_bytes()
    );
}
#[tokio::test]
async fn preview_root_inside_repository_is_rejected() {
    let f = Fixture::new().await;
    assert!(
        f.workspace
            .clone()
            .with_preview_root(f.root.join("repo/previews"))
            .is_err()
    );
}

#[tokio::test]
async fn failed_temporary_group_is_not_recorded_and_original_other_candidates_remain() {
    let mut f = Fixture::new().await;
    let base =
        "* A\n:PROPERTIES:\n:ID: a\n:END:\nbase a\n* B\n:PROPERTIES:\n:ID: b\n:END:\nbase b\n";
    f.source = merge(
        base.as_bytes(),
        base.replace("base", "local").as_bytes(),
        base.replace("base", "remote").as_bytes(),
    )
    .unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let p = f.preview().await;
    let initial = p.file().await.unwrap();
    let other = initial.conflict_ids()[1].clone();
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    let copied = p.file().await.unwrap();
    let mut missing = copied.editable_node_paths()[0].clone();
    missing.titles = vec!["不存在".into()];
    let group = TaskOperationGroup {
        operations: vec![
            TaskOperation::Modification(TaskModificationOperation {
                path: copied.editable_node_paths()[0].clone(),
                modifications: vec![TaskModification::Title(Some("ShouldRollback".into()))],
            }),
            TaskOperation::Deletion(TaskDeletion { path: missing }),
        ],
        file_versions: vec![TaskFileVersion {
            repo_id: "<preview>".into(),
            file: p.id().into(),
            version: LocalFileVersion::from_bytes(copied.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(
        p.file().await.unwrap().source_bytes(),
        copied.source_bytes()
    );
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(copied.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(group.operations.len(), 1);
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        f.workspace.repos()[0].file("a.org").await.unwrap().conflict_ids(),
        vec![other]
    );
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        copied.source_bytes()
    );
}

#[tokio::test]
async fn missing_stable_id_requires_explicit_target_and_finish_remaps_it() {
    let mut f = Fixture::new().await;
    f.source = merge(b"* Work\nbase\n", b"* Work\nlocal\n", b"* Work\nremote\n").unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let p = f.preview().await;
    let file = p.file().await.unwrap();
    let conflict = file.conflicts().unwrap().remove(0);
    assert!(conflict.requires_target);
    assert!(conflict.suggested_target.is_none());
    let mut group = TaskOperationGroup {
        operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
            path: Some(file.full_path()),
            id: conflict.id,
            action: TaskConfilictAction::UseLocal,
            target: None,
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: file.repo_id.clone(),
            file: file.path.clone(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(matches!(
        f.workspace.execute_task_operations(&group).await,
        Err(CoreError::Preview {
            code: "conflictTargetRequired",
            ..
        })
    ));
    let TaskOperation::ConfilictSelection(v) = &mut group.operations[0] else {
        unreachable!()
    };
    v.target = Some(ConflictTarget::Existing(
        file.editable_node_paths()[0].clone(),
    ));
    f.workspace.execute_task_operations(&group).await.unwrap();
    let file = p.file().await.unwrap();
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert!(!serde_json::to_string(&group).unwrap().contains("<preview>"));
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        file.source_bytes()
    );
}

#[tokio::test]
async fn creation_movement_and_deletion_are_recorded_in_order_with_all_paths_remapped() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    let file = p.file().await.unwrap();
    let creation = TaskCreation::new(
        TaskPosition {
            parent: file.full_path(),
            after: None,
        },
        "New".into(),
    );
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Creation(creation)],
            file_versions: vec![TaskFileVersion {
                repo_id: "<preview>".into(),
                file: p.id().into(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![],
        })
        .await
        .unwrap();
    let file = p.file().await.unwrap();
    let paths = file.editable_node_paths();
    let movement = TaskMovement {
        path: paths[0].clone(),
        position: TaskPosition {
            parent: paths[1].clone(),
            after: None,
        },
    };
    let mut moved = paths[0].clone();
    moved.titles = vec!["Work".into(), "New".into()];
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![
                TaskOperation::Movement(movement),
                TaskOperation::Deletion(TaskDeletion { path: moved }),
            ],
            file_versions: vec![TaskFileVersion {
                repo_id: "<preview>".into(),
                file: p.id().into(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![],
        })
        .await
        .unwrap();
    let file = p.file().await.unwrap();
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(group.operations.len(), 4);
    assert!(!serde_json::to_string(&group).unwrap().contains("<preview>"));
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        file.source_bytes()
    );
}

#[tokio::test]
async fn discard_preserves_crlf_bom_and_missing_final_newline_and_anchors_are_byte_based() {
    let mut f = Fixture::new().await;
    let remote = "\u{feff}#+TITLE: 中文\r\n* 任务\r\n远端";
    let base = "\u{feff}#+TITLE: 中文\r\n* 任务\r\n原始";
    let local = "\u{feff}#+TITLE: 中文\r\n* 任务\r\n本地";
    f.source = merge(base.as_bytes(), local.as_bytes(), remote.as_bytes()).unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let p = f.preview().await;
    let source = p.source_file().await.unwrap();
    let offset = remote.find("* 任务").unwrap();
    assert!(
        source
            .render_html()
            .contains(&format!("data-org-start=\"{offset}\""))
    );
    f.choose(&p, TaskConfilictAction::Discard).await;
    let file = p.file().await.unwrap();
    assert_eq!(file.source_bytes(), remote.as_bytes());
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        remote.as_bytes()
    );
}

#[tokio::test]
async fn another_workspace_does_not_clean_a_live_preview_lease() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    let mut independent = OrgWorkspace::new(vec![f.workspace.repos()[0].clone()])
        .unwrap()
        .with_preview_root(f.root.join("previews"))
        .unwrap();
    let file = independent.repos()[0].file("a.org").await.unwrap();
    let second = independent
        .create_conflict_preview(ConflictPreviewRequest {
            file: file.full_path(),
            conflict_id: file.conflict_ids()[0].clone(),
            source_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert!(p.file().await.is_ok());
    assert!(second.file().await.is_ok());
    drop(independent);
    assert!(p.file().await.is_ok());
}

#[tokio::test]
async fn every_conflict_choice_in_one_preview_is_returned_in_order() {
    let mut f = Fixture::new().await;
    let base =
        "* A\n:PROPERTIES:\n:ID: a\n:END:\nbase a\n* B\n:PROPERTIES:\n:ID: b\n:END:\nbase b\n";
    f.source = merge(
        base.as_bytes(),
        base.replace("base", "local").as_bytes(),
        base.replace("base", "remote").as_bytes(),
    )
    .unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let p = f.preview().await;
    let file = p.file().await.unwrap();
    let operations = file
        .conflict_ids()
        .into_iter()
        .map(|id| {
            TaskOperation::ConfilictSelection(TaskConfilictSelection {
                path: Some(file.full_path()),
                id,
                action: TaskConfilictAction::Discard,
                target: None,
            })
        })
        .collect();
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations,
            file_versions: vec![TaskFileVersion {
                repo_id: file.repo_id.clone(),
                file: file.path.clone(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![],
        })
        .await
        .unwrap();
    let edited = p.file().await.unwrap();
    let group = p
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(edited.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(group.operations.len(), 2);
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        edited.source_bytes()
    );
    assert!(!f.workspace.repos()[0].file("a.org").await.unwrap().has_conflict());
}

#[tokio::test]
async fn preview_stays_silent_and_real_submission_notifies_each_data_subscriber_once() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    let mut f = Fixture::new().await;
    let first = Arc::new(AtomicUsize::new(0));
    let second = Arc::new(AtomicUsize::new(0));
    let capture = first.clone();
    let _first_subscription = f.workspace.watch_data_changes(move |_| {
        capture.fetch_add(1, Ordering::SeqCst);
    });
    let capture = second.clone();
    let _second_subscription = f.workspace.watch_data_changes(move |_| {
        capture.fetch_add(1, Ordering::SeqCst);
    });
    let preview = f.preview().await;
    f.choose(&preview, TaskConfilictAction::UseLocal).await;
    let file = preview.file().await.unwrap();
    let group = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(first.load(Ordering::SeqCst), 0);
    assert_eq!(second.load(Ordering::SeqCst), 0);
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(first.load(Ordering::SeqCst), 1);
    assert_eq!(second.load(Ordering::SeqCst), 1);
}
