use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::sync::{Arc, Mutex};

static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

async fn fixture(source: &str) -> (std::path::PathBuf, OrgWorkspace, OrgFileMetadata) {
    let root = std::env::temp_dir().join(format!(
        "org-header-{}-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    tokio::fs::create_dir(&root).await.unwrap();
    tokio::fs::write(root.join("project.org"), source)
        .await
        .unwrap();
    let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
    let metadata = metadata(&workspace).await;
    (root, workspace, metadata)
}
async fn metadata(w: &OrgWorkspace) -> OrgFileMetadata {
    w.query(&[CoreQuery::File {
        query: FileQuery {
            include_ignored: true,
            ..Default::default()
        },
    }])
    .await
    .unwrap()
    .remove(0)
    .into_files()
    .unwrap()
    .remove(0)
}
fn change(m: &OrgFileMetadata, name: &str, value: FileHeaderValue) -> FileHeaderValueChange {
    FileHeaderValueChange {
        entry_id: m
            .header_entries
            .iter()
            .find(|e| e.name == name)
            .unwrap()
            .id
            .clone(),
        value,
    }
}
fn group(m: &OrgFileMetadata, changes: Vec<FileHeaderValueChange>) -> TaskOperationGroup {
    TaskOperationGroup {
        operation_id: Some("header-test".into()),
        operations: vec![TaskOperation::FileHaderModification(
            FileHaderModification {
                file: OrgFileRef {
                    repo_id: m.repo_id.clone(),
                    path: m.path.clone(),
                },
                changes,
            },
        )],
        file_versions: vec![TaskFileVersion {
            repo_id: m.repo_id.clone(),
            file: m.path.clone(),
            version: m.file_version.clone(),
        }],
    }
}
#[tokio::test]
async fn header_edit_preserves_bytes_and_projects_metadata_and_tasks_in_the_same_event() {
    let source = ":PROPERTIES:\r\n:UNKNOWN: keep\r\n:END:\r\n  #+TITLE:  原名  \r\n#+FILETAGS: :project:todo:work:\r\n#+CATEGORY: 旧分类\r\n#+TAGS: { iOS(i) Android(a) }\r\n#+TAGS: BUG FEAT\r\n说明  \r\n* TODO 任务\r\n正文";
    let (root, w, m) = fixture(source).await;
    let events = Arc::new(Mutex::new(Vec::new()));
    let out = events.clone();
    let _sub = w.watch_data_changes(move |event| out.lock().unwrap().push(event));
    w.execute_task_operations(&group(
        &m,
        vec![
            change(&m, "TITLE", FileHeaderValue::Text("新名".into())),
            change(&m, "CATEGORY", FileHeaderValue::Text("研发".into())),
            change(
                &m,
                "FILETAGS",
                FileHeaderValue::Tags(vec!["project".into(), "todo".into(), "home".into()]),
            ),
        ],
    ))
    .await
    .unwrap();
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        source
            .replace("原名", "新名")
            .replace("旧分类", "研发")
            .replace(":work:", ":home:")
    );
    let next = metadata(&w).await;
    assert_eq!(next.category.as_deref(), Some("研发"));
    assert_ne!(next.file_version, m.file_version);
    assert!(
        next.header_entries
            .iter()
            .find(|e| e.name == "UNKNOWN")
            .unwrap()
            .edit
            .is_none()
    );
    let all = events.lock().unwrap();
    let DataChangeEvent::RepositoryChanged {
        files,
        changes,
        operation_id,
        ..
    } = all.last().unwrap();
    assert_eq!(operation_id.as_deref(), Some("header-test"));
    let file = &files.as_ref().unwrap()[0];
    assert_eq!(file.after_version, next.file_version);
    assert_eq!(file.after, next);
    assert_eq!(changes.len(), 1);
    let after = &changes[0].after.as_ref().unwrap().task;
    assert_eq!(after.category(), Some("研发"));
    assert!(
        after
            .file_metadata()
            .header_entries
            .iter()
            .find(|entry| entry.name == "FILETAGS")
            .unwrap()
            .tags
            .contains(&"home".into())
    );
    drop(all);
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
#[tokio::test]
async fn stale_ids_missing_versions_readonly_and_protected_tags_never_write() {
    let source = "#+TITLE: 原名\n#+FILETAGS: :project:todo:\n#+CUSTOM: readonly\n* TODO 任务\n";
    let (root, w, m) = fixture(source).await;
    let mut missing = group(
        &m,
        vec![change(&m, "TITLE", FileHeaderValue::Text("修改".into()))],
    );
    missing.file_versions.clear();
    assert!(w.execute_task_operations(&missing).await.is_err());
    let readonly = group(
        &m,
        vec![
            change(&m, "TITLE", FileHeaderValue::Text("不能部分保存".into())),
            change(&m, "CUSTOM", FileHeaderValue::Text("x".into())),
        ],
    );
    assert!(w.execute_task_operations(&readonly).await.is_err());
    assert!(
        w.execute_task_operations(&group(
            &m,
            vec![change(
                &m,
                "FILETAGS",
                FileHeaderValue::Tags(vec!["project".into()])
            )]
        ))
        .await
        .is_err()
    );
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        source
    );
    w.execute_task_operations(&group(
        &m,
        vec![change(&m, "TITLE", FileHeaderValue::Text("更新".into()))],
    ))
    .await
    .unwrap();
    let next = metadata(&w).await;
    let mut stale = group(
        &next,
        vec![change(&m, "TITLE", FileHeaderValue::Text("旧ID".into()))],
    );
    assert!(w.execute_task_operations(&stale).await.is_err());
    stale.file_versions[0].version = m.file_version.clone();
    assert!(w.execute_task_operations(&stale).await.is_err());
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
#[tokio::test]
async fn duplicate_declarations_and_empty_values_keep_identity_and_empty_project_notifications() {
    let source = "#+TITLE:\r\n#+TAGS: A B\r\n#+TAGS: C D\r\n";
    let (root, w, m) = fixture(source).await;
    let tags = m
        .header_entries
        .iter()
        .filter(|e| e.name == "TAGS")
        .collect::<Vec<_>>();
    assert_ne!(tags[0].id, tags[1].id);
    w.execute_task_operations(&group(
        &m,
        vec![
            change(&m, "TITLE", FileHeaderValue::Text("空项目".into())),
            FileHeaderValueChange {
                entry_id: tags[1].id.clone(),
                value: FileHeaderValue::Text("{ C(c) D(d) } \\n E".into()),
            },
        ],
    ))
    .await
    .unwrap();
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        "#+TITLE: 空项目\r\n#+TAGS: A B\r\n#+TAGS: { C(c) D(d) } \\n E\r\n"
    );
    assert_eq!(metadata(&w).await.header_entries[2].tags, ["C", "D", "E"]);
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[test]
fn header_merge_keeps_local_fields_remote_body_and_conflict_candidates_are_actionable() {
    let base = b"#+TITLE: Base\n#+CATEGORY: Work\nIntro\n* TODO Task\nBody\n";
    let local = b"#+TITLE: Local\n#+CATEGORY: Work\nIntro\n* TODO Task\nBody\n";
    let remote = b"#+TITLE: Base\n#+CATEGORY: Home\nIntro remote\n* TODO Task\nRemote body\n";
    let output = merge(base, local, remote).unwrap();
    assert_eq!(
        std::str::from_utf8(&output).unwrap(),
        "#+TITLE: Local\n#+CATEGORY: Home\nIntro remote\n* TODO Task\nRemote body\n"
    );
    let competing = b"#+TITLE: Remote\n#+CATEGORY: Home\nIntro remote\n* TODO Task\nRemote body\n";
    let merged = merge(base, local, competing).unwrap();
    let file = OrgFile::new("repo".into(), "p.org".into(), merged).unwrap();
    let point = &file.conflicts().unwrap()[0];
    assert_eq!(point.reason, "header");
    assert!(
        point
            .available_actions
            .contains(&TaskConfilictAction::UseLocal)
    );
    assert!(point.candidate_content.starts_with("#+TITLE: Local"));
    assert!(
        std::str::from_utf8(file.source_bytes())
            .unwrap()
            .starts_with("#+TITLE: Remote\n#+CATEGORY: Home")
    );
}

#[tokio::test]
async fn file_header_conflict_preview_applies_only_the_contested_header_value() {
    let base = b"#+TITLE: Base\n#+CATEGORY: Work\n* TODO Task\nBody\n";
    let local = b"#+TITLE: Local\n#+CATEGORY: Work\n* TODO Task\nBody\n";
    let remote = b"#+TITLE: Remote\n#+CATEGORY: Home\n* TODO Task\nRemote body\n";
    let source = String::from_utf8(merge(base, local, remote).unwrap()).unwrap();
    let (root, w, m) = fixture(&source).await;
    let file = w.repos()[0].file("project.org").await.unwrap();
    let conflict = file.conflicts().unwrap().remove(0);
    w.execute_task_operations(&TaskOperationGroup {
        operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
            path: Some(file.full_path()),
            id: conflict.id,
            action: TaskConfilictAction::UseLocal,
            target: None,
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: m.repo_id,
            file: m.path,
            version: m.file_version,
        }],
        ..Default::default()
    })
    .await
    .unwrap();
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        "#+TITLE: Local\n#+CATEGORY: Home\n* TODO Task\nRemote body\n"
    );
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn header_ids_resolve_against_group_start_and_tag_whitespace_is_preserved() {
    let source =
        "#+TITLE: Original\r\n#+FILETAGS: :project: todo : work :\r\n* TODO Task\r\nBefore\r\n";
    let (root, w, m) = fixture(source).await;
    let mut g = group(
        &m,
        vec![
            change(&m, "TITLE", FileHeaderValue::Text("Updated".into())),
            change(
                &m,
                "FILETAGS",
                FileHeaderValue::Tags(vec![
                    "project".into(),
                    "todo".into(),
                    "work".into(),
                    "new".into(),
                ]),
            ),
        ],
    );
    g.operations.insert(
        0,
        TaskOperation::Modification(TaskModificationOperation {
            path: TaskPath {
                repo_id: m.repo_id.clone(),
                file: Some(m.path.clone()),
                titles: vec!["Task".into()],
                occurrence: 1,
            },
            modifications: vec![TaskModification::Notes(Some("After".into()))],
        }),
    );
    w.execute_task_operations(&g).await.unwrap();
    let actual = tokio::fs::read_to_string(root.join("project.org"))
        .await
        .unwrap();
    assert!(actual.starts_with("#+TITLE: Updated\r\n#+FILETAGS: :project: todo : work :new:\r\n"));
    assert!(actual.contains("After"));
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn tag_groups_can_span_declarations_and_property_append_keeps_its_source() {
    let source = ":PROPERTIES:\n:PROJECT_NAME: Main\n:PROJECT_NAME+: Part\n:END:\n#+FILETAGS: :project:\n#+TAGS: { A B\n#+TAGS: C D }\n";
    let (root, w, m) = fixture(source).await;
    w.execute_task_operations(&group(
        &m,
        vec![
            change(&m, "PROJECT_NAME+", FileHeaderValue::Text("Updated".into())),
            change(&m, "TAGS", FileHeaderValue::Text("{ A X".into())),
        ],
    ))
    .await
    .unwrap();
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        source
            .replace(":PROJECT_NAME+: Part", ":PROJECT_NAME+: Updated")
            .replace("{ A B", "{ A X")
    );
    let next = metadata(&w).await;
    assert_eq!(next.project_name.as_deref(), Some("Main Updated"));
    assert_eq!(next.tag_groups, vec![vec!["A", "X", "C", "D"]]);
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn header_conflict_uses_existing_preview_project_finish_and_operation_submission() {
    let base = b"#+TITLE: Base\n#+CATEGORY: Work\n* TODO Task\nBody\n";
    let local = b"#+TITLE: Local\n#+CATEGORY: Work\n* TODO Task\nBody\n";
    let remote = b"#+TITLE: Remote\n#+CATEGORY: Home\n* TODO Task\nRemote body\n";
    let source = String::from_utf8(merge(base, local, remote).unwrap()).unwrap();
    let (root, w, m) = fixture(&source).await;
    let preview_root = root.with_extension("preview");
    tokio::fs::create_dir(&preview_root).await.unwrap();
    let w = w
        .with_preview_root(tokio::fs::canonicalize(&preview_root).await.unwrap())
        .await
        .unwrap();
    let original = w.repos()[0].file("project.org").await.unwrap();
    let point = original.conflicts().unwrap().remove(0);
    let preview = w
        .create_conflict_preview(ConflictPreviewRequest {
            file: original.full_path(),
            conflict_id: point.id.clone(),
            source_version: m.file_version,
        })
        .await
        .unwrap();
    let working = preview.file().await.unwrap();
    let version = LocalFileVersion::from_bytes(working.source_bytes()).content_hash;
    let projected = preview
        .project(ConflictPreviewProjectionRequest {
            conflict_id: point.id.clone(),
            preview_version: version.clone(),
            target: None,
        })
        .await
        .unwrap();
    assert_eq!(projected.status, "ready");
    assert!(
        projected
            .content
            .starts_with("#+TITLE: Local\n#+CATEGORY: Home")
    );
    assert!(!projected.changes.changes.is_empty());
    w.execute_task_operations(&TaskOperationGroup {
        operations: vec![TaskOperation::ConfilictSelection(TaskConfilictSelection {
            path: Some(working.full_path()),
            id: point.id,
            action: TaskConfilictAction::UseLocal,
            target: None,
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: working.repo_id.clone(),
            file: working.path.clone(),
            version,
        }],
        ..Default::default()
    })
    .await
    .unwrap();
    let changed = preview.file().await.unwrap();
    let group = preview
        .finish(ConflictPreviewFinishOptions {
            preview_version: LocalFileVersion::from_bytes(changed.source_bytes()).content_hash,
        })
        .await
        .unwrap();
    w.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        "#+TITLE: Local\n#+CATEGORY: Home\n* TODO Task\nRemote body\n"
    );
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
    tokio::fs::remove_dir_all(preview_root).await.unwrap();
}

#[test]
fn ambiguous_duplicate_header_changes_preserve_local_candidate_without_guessing_a_target() {
    let base = b"#+TAGS: A B\n#+TAGS: C D\n* Task\n";
    let local = b"#+TAGS: A X\n#+TAGS: C D\n* Task\n";
    let remote = b"#+TAGS: C D\n#+TAGS: A B\n* Task\nRemote\n";
    let bytes = merge(base, local, remote).unwrap();
    let file = OrgFile::new("repo".into(), "x.org".into(), bytes).unwrap();
    let conflict = file.conflicts().unwrap().remove(0);
    assert_eq!(conflict.reason, "header");
    assert_eq!(
        conflict.available_actions,
        vec![TaskConfilictAction::Discard]
    );
    assert!(conflict.candidate_content.contains("A X"));
    assert!(
        std::str::from_utf8(file.source_bytes())
            .unwrap()
            .starts_with(std::str::from_utf8(remote).unwrap())
    );
}

#[tokio::test]
async fn inline_tag_arrays_preserve_config_shortcuts_groups_and_unrelated_bytes() {
    let source = "#+TITLE: 标签验收\r\n#+FILETAGS: :project:todo:work:\r\n#+TAGS: { A(a)  B(b) }\tC(c) \\n D(d)\r\n#+TAGS: { E(e) F(f) }\r\n* TODO 任务 :B:work:\r\n正文";
    let (root, w, m) = fixture(source).await;
    w.execute_task_operations(&group(
        &m,
        vec![
            change(
                &m,
                "FILETAGS",
                FileHeaderValue::Tags(vec!["project".into(), "todo".into(), "home".into()]),
            ),
            change(
                &m,
                "TAGS",
                FileHeaderValue::Tags(vec![
                    "A".into(),
                    "C".into(),
                    "D".into(),
                    "new".into(),
                    "new".into(),
                ]),
            ),
        ],
    ))
    .await
    .unwrap();
    let expected = source
        .replace(":project:todo:work:", ":project:todo:home:")
        .replace("B(b)", "")
        .replace("D(d)\r\n", "D(d) new\r\n");
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        expected
    );
    let next = metadata(&w).await;
    assert_eq!(next.tag_options, ["A", "C", "D", "new", "E", "F"]);
    assert_eq!(next.tag_groups, vec![vec!["A"], vec!["E", "F"]]);
    let invalid = group(
        &next,
        vec![
            change(&next, "TITLE", FileHeaderValue::Text("不能部分保存".into())),
            change(&next, "TAGS", FileHeaderValue::Tags(vec!["bad tag".into()])),
        ],
    );
    assert!(w.execute_task_operations(&invalid).await.is_err());
    assert_eq!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap(),
        expected
    );
    let empty = group(
        &next,
        vec![change(&next, "TAGS", FileHeaderValue::Tags(vec![]))],
    );
    w.execute_task_operations(&empty).await.unwrap();
    let cleared = metadata(&w).await;
    assert_eq!(cleared.tag_options, ["E", "F"]);
    assert!(
        tokio::fs::read_to_string(root.join("project.org"))
            .await
            .unwrap()
            .contains("* TODO 任务 :B:work:")
    );
    w.stop().await.unwrap();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
