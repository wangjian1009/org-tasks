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
async fn read_only_projection_matches_adoption_without_consuming_or_recording_the_choice() {
    let mut f = Fixture::new().await;
    let p = f.preview().await;
    let original = p.file().await.unwrap();
    let current_version = LocalFileVersion::from_bytes(original.source_bytes()).content_hash;
    let projected = p
        .project(ConflictPreviewProjectionRequest {
            conflict_id: p.conflict_id().into(),
            preview_version: current_version.clone(),
            target: None,
        })
        .await
        .unwrap();
    assert_eq!(projected.status, "ready");
    assert_eq!(projected.before_text, "remote\n");
    assert_eq!(projected.after_text, "local\n");
    assert_eq!(projected.working_version, current_version);
    assert_ne!(projected.changes.preview_version, current_version);
    let change = &projected.changes.changes[0];
    let range = change.after.as_ref().unwrap();
    assert_eq!(
        &projected.content.as_bytes()
            [range.start.byte_offset as usize..range.end.byte_offset as usize],
        b"local\n"
    );
    assert!(projected.rendered_html.contains("local"));
    assert!(!projected.content.contains("CONFILICT_ID"));
    assert_eq!(
        p.file().await.unwrap().source_bytes(),
        original.source_bytes()
    );
    assert_eq!(p.conflicts().await.unwrap().len(), 1);
    assert!(p.changes().await.unwrap().changes.is_empty());
    assert!(matches!(
        p.finish(ConflictPreviewFinishOptions {
            preview_version: current_version
        })
        .await,
        Err(CoreError::Preview {
            code: "conflictDecisionRequired",
            ..
        })
    ));
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
    assert!(f.workspace.task_operation_history.entries.is_empty());
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    assert_eq!(
        p.file().await.unwrap().source_bytes(),
        projected.content.as_bytes()
    );
    assert!(
        p.project(ConflictPreviewProjectionRequest {
            conflict_id: p.conflict_id().into(),
            preview_version: projected.working_version,
            target: None,
        })
        .await
        .is_err()
    );
}

#[tokio::test]
async fn switching_projected_points_does_not_accumulate_other_candidates() {
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
    let p = f.preview().await;
    let file = p.file().await.unwrap();
    let points = p.conflicts().await.unwrap();
    assert_eq!(points.len(), 2);
    let version = LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
    let mut projections = Vec::new();
    for point in &points {
        projections.push(
            p.project(ConflictPreviewProjectionRequest {
                conflict_id: point.id.clone(),
                preview_version: version.clone(),
                target: None,
            })
            .await
            .unwrap(),
        );
    }
    assert!(projections[0].content.contains("local a"));
    assert!(projections[0].content.contains("remote b"));
    assert!(projections[1].content.contains("remote a"));
    assert!(projections[1].content.contains("local b"));
    assert_eq!(p.file().await.unwrap().source_bytes(), file.source_bytes());
    assert_eq!(p.conflicts().await.unwrap().len(), 2);
    assert!(matches!(
        p.project(ConflictPreviewProjectionRequest {
            conflict_id: points[0].id.clone(),
            preview_version: "stale".into(),
            target: None,
        })
        .await,
        Err(CoreError::Preview {
            code: "previewVersionMismatch",
            ..
        })
    ));
    assert!(
        p.project(ConflictPreviewProjectionRequest {
            conflict_id: "missing".into(),
            preview_version: version.clone(),
            target: None,
        })
        .await
        .is_err()
    );
    let old_id = points[0].id.clone();
    let _new = f.preview().await;
    assert!(matches!(
        p.project(ConflictPreviewProjectionRequest {
            conflict_id: old_id,
            preview_version: version,
            target: None,
        })
        .await,
        Err(CoreError::Preview {
            code: "previewExpired",
            ..
        })
    ));
}

#[tokio::test]
async fn unresolved_target_exposes_candidate_and_only_explicit_target_produces_file_projection() {
    let mut f = Fixture::new().await;
    f.source = merge(b"* Work\nbase\n", b"* Work\nlocal\n", b"* Work\nremote\n").unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    let p = f.preview().await;
    let file = p.file().await.unwrap();
    let version = LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
    let request = ConflictPreviewProjectionRequest {
        conflict_id: p.conflict_id().into(),
        preview_version: version,
        target: None,
    };
    let pending = p.project(request.clone()).await.unwrap();
    assert_eq!(pending.status, "targetRequired");
    assert!(pending.after_text.contains("local"));
    assert!(pending.before_text.is_empty());
    assert!(pending.changes.changes.is_empty());
    assert_eq!(pending.content.as_bytes(), file.source_bytes());
    let mut targeted = request.clone();
    targeted.target = Some(ConflictTarget::Existing(
        file.editable_node_paths()[0].clone(),
    ));
    let ready = p.project(targeted).await.unwrap();
    assert_eq!(ready.status, "ready");
    assert_eq!(ready.before_text, "remote\n");
    assert_eq!(ready.after_text, "local\n");
    let mut invalid = request;
    invalid.target = Some(ConflictTarget::Existing(TaskPath::file(
        "real".into(),
        "a.org".into(),
    )));
    assert!(p.project(invalid).await.is_err());
    assert_eq!(p.file().await.unwrap().source_bytes(), file.source_bytes());
    assert_eq!(p.conflicts().await.unwrap().len(), 1);
}
#[tokio::test]
async fn copy_uses_reserved_repo_and_uuid_and_never_enters_queries_or_events() {
    let mut f = Fixture::new().await;
    let before = f
        .workspace
        .query(&[(TaskQuery::default()).into()])
        .await
        .unwrap()
        .remove(0)
        .into_task()
        .unwrap();
    let p = f.preview().await;
    assert_eq!(p.full_path().repo_id, "<preview>");
    assert_eq!(p.full_path().file.as_deref(), Some(p.id()));
    assert_eq!(
        p.file().await.unwrap().source_bytes(),
        b"* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nremote\n"
    );
    assert!(!p.file().await.unwrap().has_conflict());
    assert_eq!(p.conflicts().await.unwrap().len(), 1);
    assert_eq!(
        f.workspace
            .query(&[(TaskQuery::default()).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
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
    let other = p.conflicts().await.unwrap()[1].id.clone();
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
        f.workspace.repos()[0]
            .file("a.org")
            .await
            .unwrap()
            .conflict_ids(),
        vec![other]
    );
    assert!(
        std::fs::read(f.root.join("repo/a.org"))
            .unwrap()
            .starts_with(copied.source_bytes())
    );
    assert!(!copied.has_conflict());
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
    let conflict = p.conflicts().await.unwrap().remove(0);
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
async fn task_without_stable_id_finds_unique_task_with_same_title() {
    let mut f = Fixture::new().await;
    f.source = merge(
        b"* TODO Work\nbase\n",
        b"* TODO Work\nlocal\n",
        b"* TODO Work\nremote\n",
    )
    .unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let p = f.preview().await;
    let conflict = p.conflicts().await.unwrap().remove(0);
    assert!(!conflict.requires_target);
    assert!(matches!(conflict.suggested_target, Some(ConflictTarget::Existing(_))));
    f.choose(&p, TaskConfilictAction::UseLocal).await;
    assert_eq!(p.file().await.unwrap().source_bytes(), b"* TODO Work\nlocal\n");
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
    let operations = p
        .conflicts()
        .await
        .unwrap()
        .into_iter()
        .map(|point| {
            TaskOperation::ConfilictSelection(TaskConfilictSelection {
                path: Some(file.full_path()),
                id: point.id,
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
    assert!(
        !f.workspace.repos()[0]
            .file("a.org")
            .await
            .unwrap()
            .has_conflict()
    );
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

#[tokio::test]
async fn preview_keeps_main_documents_and_candidate_materials_separate_from_creation() {
    let mut f = Fixture::new().await;
    let preview = f.preview().await;
    let original = preview.source_file().await.unwrap();
    let working = preview.file().await.unwrap();
    let by_path = f.workspace.file_at(&preview.full_path()).await.unwrap();
    let expected = b"* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nremote\n";
    for file in [&original, &working, &by_path] {
        assert_eq!(file.source_bytes(), expected);
        assert!(!file.has_conflict());
        assert!(file.conflict_ids().is_empty());
        assert!(file.conflicts().unwrap().is_empty());
        assert_eq!(file.node_paths().len(), 1);
        assert!(!file.render_html().contains("同步冲突"));
    }
    assert_eq!(preview.conflicts().await.unwrap().len(), 1);
    assert_eq!(
        preview.source_version(),
        LocalFileVersion::from_bytes(&f.source).content_hash
    );
    assert!(preview.changes().await.unwrap().changes.is_empty());
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
}

#[tokio::test]
async fn keeping_current_changes_only_the_independent_choice_set() {
    let mut f = Fixture::new().await;
    let preview = f.preview().await;
    let before = preview.file().await.unwrap();
    f.choose(&preview, TaskConfilictAction::Discard).await;
    assert_eq!(
        preview.file().await.unwrap().source_bytes(),
        before.source_bytes()
    );
    assert!(preview.conflicts().await.unwrap().is_empty());
    assert!(preview.changes().await.unwrap().changes.is_empty());
    let file = preview.file().await.unwrap();
    let duplicate = TaskOperationGroup {
        operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
            path: Some(file.full_path()),
            id: preview.conflict_id().into(),
            action: TaskConfilictAction::Discard,
            target: None,
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: file.repo_id.clone(),
            file: file.path.clone(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(
        f.workspace
            .execute_task_operations(&duplicate)
            .await
            .is_err()
    );
    let group = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    assert_eq!(group.operations.len(), 1);
    assert_eq!(std::fs::read(f.root.join("repo/a.org")).unwrap(), f.source);
}

#[tokio::test]
async fn failed_group_rolls_back_both_main_edits_and_separate_conflict_choices() {
    let mut f = Fixture::new().await;
    let preview = f.preview().await;
    let before = preview.file().await.unwrap();
    let initial_id = preview.conflicts().await.unwrap()[0].id.clone();
    let mut missing = before.full_path();
    missing.titles = vec!["不存在".into()];
    let group = TaskOperationGroup {
        operations: vec![
            TaskOperation::ConfilictSelection(TaskConfilictSelection {
                path: Some(before.full_path()),
                id: initial_id.clone(),
                action: TaskConfilictAction::UseLocal,
                target: None,
            }),
            TaskOperation::Deletion(TaskDeletion { path: missing }),
        ],
        file_versions: vec![TaskFileVersion {
            repo_id: before.repo_id.clone(),
            file: before.path.clone(),
            version: LocalFileVersion::from_bytes(before.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(
        preview.file().await.unwrap().source_bytes(),
        before.source_bytes()
    );
    assert_eq!(preview.conflicts().await.unwrap()[0].id, initial_id);
    assert!(matches!(
        preview
            .finish(ConflictPreviewFinishOptions {
                preview_version: LocalFileVersion::from_bytes(before.source_bytes()).content_hash
            })
            .await,
        Err(CoreError::Preview {
            code: "conflictDecisionRequired",
            ..
        })
    ));
}

#[tokio::test]
async fn ordinary_preview_operations_cannot_insert_new_conflict_nodes() {
    let mut f = Fixture::new().await;
    let preview = f.preview().await;
    let before = preview.file().await.unwrap();
    let mut creation = TaskCreation::new(
        TaskPosition {
            parent: before.full_path(),
            after: None,
        },
        "不允许的容器".into(),
    );
    creation.tags = vec!["CONFLICT".into(), "ARCHIVE".into()];
    let group = TaskOperationGroup {
        operations: vec![TaskOperation::Creation(creation)],
        file_versions: vec![TaskFileVersion {
            repo_id: before.repo_id.clone(),
            file: before.path.clone(),
            version: LocalFileVersion::from_bytes(before.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(
        preview.file().await.unwrap().source_bytes(),
        before.source_bytes()
    );
    assert_eq!(preview.conflicts().await.unwrap().len(), 1);
}

#[tokio::test]
async fn empty_main_remains_empty_until_a_separate_candidate_is_inserted() {
    let mut f = Fixture::new().await;
    // 空远端与本地新增通常可直接合并，使用现有容器格式构造离线候选。
    f.source = "\n* 同步冲突 :CONFLICT:ARCHIVE:\n** Local\n:PROPERTIES:\n:CONFILICT_ID: local\n:END:\n#+CONFLICT_REASON: create\n*** TODO Local\nbody\n".as_bytes().to_vec();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let preview = f.preview().await;
    let file = preview.file().await.unwrap();
    assert!(file.source_bytes().is_empty());
    assert!(
        preview
            .source_file()
            .await
            .unwrap()
            .source_bytes()
            .is_empty()
    );
    let selection = TaskConfilictSelection {
        path: Some(file.full_path()),
        id: preview.conflict_id().into(),
        action: TaskConfilictAction::UseLocal,
        target: Some(ConflictTarget::Insert(TaskPosition {
            parent: file.full_path(),
            after: None,
        })),
    };
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::ConfilictSelection(selection)],
            file_versions: vec![TaskFileVersion {
                repo_id: file.repo_id.clone(),
                file: file.path.clone(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![],
        })
        .await
        .unwrap();
    let edited = preview.file().await.unwrap();
    assert_eq!(edited.source_bytes(), b"* TODO Local\nbody\n");
    let group = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(edited.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        edited.source_bytes()
    );
}

#[tokio::test]
async fn legacy_conflict_footer_is_separated_and_archive_never_leaks_to_adopted_tasks() {
    let mut f = Fixture::new().await;
    f.source = std::str::from_utf8(&f.source)
        .unwrap()
        .replace(":CONFLICT:ARCHIVE:", ":CONFLICT:")
        .into_bytes();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let preview = f.preview().await;
    assert!(!preview.source_file().await.unwrap().has_conflict());
    f.choose(&preview, TaskConfilictAction::UseLocal).await;
    let file = preview.file().await.unwrap();
    let nodes = file.nodes();
    assert!(!nodes[0].own_tags().iter().any(|tag| tag == "ARCHIVE"));
    assert!(!nodes[0].inherited_tags().iter().any(|tag| tag == "ARCHIVE"));
    let group = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        file.source_bytes()
    );
}

#[tokio::test]
async fn full_file_candidate_replaces_only_the_separated_main_document() {
    let mut f = Fixture::new().await;
    f.source = "#+TITLE: Remote\n* Remote\nremote body\n\n* 同步冲突 :CONFLICT:ARCHIVE:\n** 文件结构\n:PROPERTIES:\n:CONFILICT_ID: whole\n:END:\n#+CONFLICT_REASON: structure\n#+begin_example\n,#+TITLE: Local\n,* TODO Local\nlocal body\n#+end_example\n".as_bytes().to_vec();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let preview = f.preview().await;
    let file = preview.file().await.unwrap();
    assert_eq!(
        file.source_bytes(),
        b"#+TITLE: Remote\n* Remote\nremote body\n"
    );
    let projected = preview
        .project(ConflictPreviewProjectionRequest {
            conflict_id: "whole".into(),
            preview_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            target: None,
        })
        .await
        .unwrap();
    assert_eq!(projected.status, "ready");
    assert_eq!(
        projected.content,
        "#+TITLE: Local\n* TODO Local\nlocal body\n"
    );
    assert_eq!(
        preview.file().await.unwrap().source_bytes(),
        file.source_bytes()
    );
    assert_eq!(preview.conflicts().await.unwrap().len(), 1);
    let group = TaskOperationGroup {
        operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
            path: Some(file.full_path()),
            id: "whole".into(),
            action: TaskConfilictAction::UseLocal,
            target: Some(ConflictTarget::ReplaceMain),
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: file.repo_id.clone(),
            file: file.path.clone(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        }],
        queue_repo_ids: vec![],
    };
    f.workspace.execute_task_operations(&group).await.unwrap();
    let edited = preview.file().await.unwrap();
    assert_eq!(
        edited.source_bytes(),
        b"#+TITLE: Local\n* TODO Local\nlocal body\n"
    );
    assert!(!edited.has_conflict());
    assert!(preview.conflicts().await.unwrap().is_empty());
    let operations = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(edited.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    f.workspace
        .execute_task_operations(&operations)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        edited.source_bytes()
    );
}

#[tokio::test]
async fn separated_preview_preserves_setupfile_context_when_adopting_a_candidate() {
    let mut f = Fixture::new().await;
    let base = "#+SETUPFILE: workflow.setup\n* OPEN Work\n:PROPERTIES:\n:ID: work\n:END:\nbase\n";
    f.source = merge(
        base.as_bytes(),
        base.replace("base", "local").as_bytes(),
        base.replace("base", "remote").as_bytes(),
    )
    .unwrap();
    std::fs::write(
        f.root.join("repo/workflow.setup"),
        "#+TODO: OPEN | CLOSED\n",
    )
    .unwrap();
    std::fs::write(f.root.join("repo/a.org"), &f.source).unwrap();
    let preview = f.preview().await;
    let baseline = preview.source_file().await.unwrap();
    assert_eq!(baseline.todo.initial_state.as_deref(), Some("OPEN"));
    assert_eq!(baseline.node_paths()[0].titles, vec!["Work"]);
    assert!(!baseline.has_conflict());
    f.choose(&preview, TaskConfilictAction::UseLocal).await;
    let edited = preview.file().await.unwrap();
    assert_eq!(
        edited.nodes()[0].state().map(|state| state.name.as_str()),
        Some("OPEN")
    );
    assert_eq!(edited.node_paths()[0].titles, vec!["Work"]);
    let operations = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(edited.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    f.workspace
        .execute_task_operations(&operations)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(f.root.join("repo/a.org")).unwrap(),
        edited.source_bytes()
    );
}
