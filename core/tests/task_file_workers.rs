//! 文件任务协调、删除副本和恢复依赖的真实仓库验证。
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::fs;

struct Fixture {
    roots: Vec<PathBuf>,
    workspace: OrgWorkspace,
    source: OrgRepo,
    system: OrgRepo,
}
impl Fixture {
    async fn new(source: &str, trash: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let base = std::env::temp_dir().join(format!(
            "org-file-workers-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let source_root = base.join("source");
        let system_root = base.join("system");
        fs::create_dir_all(&source_root).await.unwrap();
        fs::create_dir(&system_root).await.unwrap();
        fs::write(source_root.join("tasks.org"), source)
            .await
            .unwrap();
        fs::write(system_root.join("trash.org"), trash)
            .await
            .unwrap();
        let mut source = OrgRepo::new(source_root.to_string_lossy().into()).unwrap();
        let mut system = OrgRepo::new(system_root.to_string_lossy().into()).unwrap();
        source.load::<WebDavSyncPolicy>().await.unwrap();
        system.load::<WebDavSyncPolicy>().await.unwrap();
        let workspace = OrgWorkspace::start(vec![source.clone(), system.clone()])
            .await
            .unwrap();
        Self {
            roots: vec![base],
            workspace,
            source,
            system,
        }
    }
    async fn nodes(&self, repo: &OrgRepo, path: &str) -> Vec<FilterTask> {
        repo.file(path).await.unwrap().nodes()
    }
    async fn trash(&self, paths: Vec<TaskPath>) -> Result<(), CoreError> {
        self.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: paths
                    .into_iter()
                    .map(|path| {
                        TaskOperation::Trash(TaskTrash {
                            path,
                            target: OrgFileRef {
                                repo_id: self.system.id.clone(),
                                path: "trash.org".into(),
                            },
                        })
                    })
                    .collect(),
                ..Default::default()
            })
            .await
    }
    async fn restore(&self, paths: Vec<TaskPath>) -> Result<(), CoreError> {
        self.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: paths
                    .into_iter()
                    .map(|path| TaskOperation::Restore(TaskRestore { path }))
                    .collect(),
                ..Default::default()
            })
            .await
    }
    async fn bytes(&self, repo: &OrgRepo, path: &str) -> Vec<u8> {
        fs::read(PathBuf::from(&repo.root_directory).join(path))
            .await
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for root in &self.roots {
            let _ = std::fs::remove_dir_all(root);
        }
    }
}

#[tokio::test]
async fn trash_and_restore_preserve_leaf_fields_and_publish_only_after_all_files_are_saved() {
    let original = "#+CATEGORY: 工作\n#+FILETAGS: :project:\n#+PROJECT_NAME: 核心\n* TODO [#A] Leaf :tag:\nSCHEDULED: <2026-11-17 Tue 10:00 +1w> DEADLINE: <2026-11-18 Wed>\n:PROPERTIES:\n:CREATED: [2025-01-02 Thu 09:05]\n:ID: fixed-id\n:CATEGORY: old-reserved\n:END:\nNotes  \n:LOGBOOK:\n- Note [2026-11-17 Tue 09:00]\n:END:\n* TODO Unrelated\nUnchanged\n";
    let f = Fixture::new(original, "#+TITLE: 废纸篓\n").await;
    let source = f.nodes(&f.source, "tasks.org").await[0].clone();
    let events = Arc::new(Mutex::new(Vec::new()));
    let copy = events.clone();
    let source_path = PathBuf::from(&f.source.root_directory).join("tasks.org");
    let trash_path = PathBuf::from(&f.system.root_directory).join("trash.org");
    let _subscription = f.workspace.watch_data_changes(move |event| {
        let source = std::fs::read_to_string(&source_path).unwrap();
        let trash = std::fs::read_to_string(&trash_path).unwrap();
        assert!(!source.contains("fixed-id") && trash.contains("fixed-id"));
        copy.lock().unwrap().push(event);
    });
    f.trash(vec![source.full_path().clone()]).await.unwrap();
    drop(_subscription);
    assert_eq!(events.lock().unwrap().len(), 2);
    let archived = f.nodes(&f.system, "trash.org").await[0].clone();
    assert_eq!(archived.property("SOURCE_REPO"), Some(f.source.id.as_str()));
    assert_eq!(archived.property("SOURCE_CATEGORY"), Some("工作"));
    assert_eq!(archived.property("CATEGORY"), Some("old-reserved"));
    assert_eq!(archived.property("SOURCE_ID"), Some("fixed-id"));
    assert!(archived.property("ID").is_none());
    assert_eq!(archived.property("SOURCE_PROJECT_NAME"), Some("核心"));
    assert!(archived.property("SOURCE_TIME").is_some());
    assert!(archived.property("SOURCE_TRASH_ID").is_some());
    f.restore(vec![archived.full_path().clone()]).await.unwrap();
    let restored = f
        .nodes(&f.source, "tasks.org")
        .await
        .into_iter()
        .find(|task| task.property("ID") == Some("fixed-id"))
        .unwrap();
    assert_eq!(source.created_at(), restored.created_at());
    assert_eq!(source.state(), restored.state());
    assert_eq!(source.priority(), restored.priority());
    assert_eq!(source.scheduled(), restored.scheduled());
    assert!(restored.body().contains("Notes  \n:LOGBOOK:\n- Note"));
    for property in [
        "SOURCE_REPO",
        "SOURCE_POSITION",
        "SOURCE_CATEGORY",
        "SOURCE_PROJECT_NAME",
        "SOURCE_TIME",
        "SOURCE_TRASH_ID",
    ] {
        assert!(restored.property(property).is_none(), "{property}");
    }
    assert!(
        String::from_utf8(f.bytes(&f.source, "tasks.org").await)
            .unwrap()
            .ends_with("* TODO Unrelated\nUnchanged\n")
    );
    assert!(f.nodes(&f.system, "trash.org").await.is_empty());
}

#[tokio::test]
async fn one_failure_discards_successful_changes_in_all_other_file_tasks_and_notifications() {
    let f = Fixture::new("* TODO Leaf\nBody\n", "#+TITLE: 废纸篓\n").await;
    fs::write(
        PathBuf::from(&f.source.root_directory).join("other.org"),
        "* TODO Other\n",
    )
    .await
    .unwrap();
    let path = f.nodes(&f.source, "tasks.org").await[0].full_path().clone();
    let events = Arc::new(Mutex::new(Vec::new()));
    let copy = events.clone();
    let _sub = f
        .workspace
        .watch_data_changes(move |event| copy.lock().unwrap().push(event));
    let result = f
        .workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![
                TaskOperation::Modification(TaskModificationOperation {
                    path: f.nodes(&f.source, "other.org").await[0].full_path().clone(),
                    modifications: vec![TaskModification::Title(Some("Changed".into()))],
                }),
                TaskOperation::Trash(TaskTrash {
                    path,
                    target: OrgFileRef {
                        repo_id: f.system.id.clone(),
                        path: "trash.org".into(),
                    },
                }),
                TaskOperation::Deletion(TaskDeletion {
                    path: TaskPath {
                        repo_id: f.source.id.clone(),
                        file: Some("tasks.org".into()),
                        titles: vec!["Missing".into()],
                        occurrence: 1,
                    },
                }),
            ],
            ..Default::default()
        })
        .await;
    assert!(result.is_err());
    assert_eq!(
        f.bytes(&f.source, "tasks.org").await,
        b"* TODO Leaf\nBody\n"
    );
    assert_eq!(f.bytes(&f.source, "other.org").await, b"* TODO Other\n");
    assert_eq!(
        f.bytes(&f.system, "trash.org").await,
        "#+TITLE: 废纸篓\n".as_bytes()
    );
    assert!(events.lock().unwrap().is_empty());
    assert!(f.workspace.task_operation_history().entries.is_empty());
}

#[tokio::test]
async fn batch_trash_of_duplicate_titles_uses_bound_nodes_and_restores_each_once() {
    let f = Fixture::new(
        "* TODO Same\nfirst\n* TODO Same\nsecond\n* TODO Same\nthird\n",
        "#+TITLE: 废纸篓\n",
    )
    .await;
    let nodes = f.nodes(&f.source, "tasks.org").await;
    f.trash(vec![
        nodes[0].full_path().clone(),
        nodes[1].full_path().clone(),
    ])
    .await
    .unwrap();
    assert_eq!(
        f.bytes(&f.source, "tasks.org").await,
        b"* TODO Same\nthird\n"
    );
    let trashed = f.nodes(&f.system, "trash.org").await;
    assert_eq!(trashed.len(), 2);
    f.restore(
        trashed
            .into_iter()
            .map(|task| task.full_path().clone())
            .collect(),
    )
    .await
    .unwrap();
    let text = String::from_utf8(f.bytes(&f.source, "tasks.org").await).unwrap();
    assert_eq!(text.matches("first").count(), 1);
    assert_eq!(text.matches("second").count(), 1);
    assert_eq!(text.matches("third").count(), 1);
    assert!(f.nodes(&f.system, "trash.org").await.is_empty());
}

#[tokio::test]
async fn restore_insertion_failure_keeps_source_but_other_restores_and_modifications_commit() {
    let f = Fixture::new(
        "* TODO Other\n* Parent\n** TODO Child\n:PROPERTIES:\n:ID: child\n:END:\nchild body\n",
        "#+TITLE: 废纸篓\n",
    )
    .await;
    let nodes = f.nodes(&f.source, "tasks.org").await;
    f.trash(vec![
        nodes[2].full_path().clone(),
        nodes[0].full_path().clone(),
    ])
    .await
    .unwrap();
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Deletion(TaskDeletion {
                path: nodes[1].full_path().clone(),
            })],
            ..Default::default()
        })
        .await
        .unwrap();
    let archived = f.nodes(&f.system, "trash.org").await;
    f.restore(
        archived
            .into_iter()
            .map(|task| task.full_path().clone())
            .collect(),
    )
    .await
    .unwrap();
    assert!(
        f.nodes(&f.source, "tasks.org")
            .await
            .iter()
            .any(|task| task.title() == "Other")
    );
    let remaining = f.nodes(&f.system, "trash.org").await;
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].property("SOURCE_ID"), Some("child"));
    assert!(
        !String::from_utf8(f.bytes(&f.source, "tasks.org").await)
            .unwrap()
            .contains("child body")
    );
}

#[tokio::test]
async fn restore_to_missing_file_or_repository_keeps_archive_and_does_not_create_empty_files() {
    let f = Fixture::new("* TODO Leaf\nBody\n", "#+TITLE: 废纸篓\n").await;
    f.trash(vec![
        f.nodes(&f.source, "tasks.org").await[0].full_path().clone(),
    ])
    .await
    .unwrap();
    fs::remove_file(PathBuf::from(&f.source.root_directory).join("tasks.org"))
        .await
        .unwrap();
    let archive = f.nodes(&f.system, "trash.org").await[0].full_path().clone();
    let original = f.bytes(&f.system, "trash.org").await;
    f.restore(vec![archive.clone()]).await.unwrap();
    assert_eq!(f.bytes(&f.system, "trash.org").await, original);
    assert!(
        !PathBuf::from(&f.source.root_directory)
            .join("tasks.org")
            .exists()
    );
    f.workspace
        .remove_repo_by_root_directory(&f.source.root_directory)
        .await
        .unwrap();
    f.restore(vec![archive]).await.unwrap();
    assert_eq!(f.bytes(&f.system, "trash.org").await, original);
}

#[tokio::test]
async fn trash_rejects_non_leaf_and_original_version_conflicts_without_side_effects() {
    let f = Fixture::new("* TODO Parent\n** TODO Child\n", "#+TITLE: 废纸篓\n").await;
    let original = f.bytes(&f.source, "tasks.org").await;
    assert!(
        f.trash(vec![
            f.nodes(&f.source, "tasks.org").await[0].full_path().clone()
        ])
        .await
        .is_err()
    );
    let node = f.nodes(&f.source, "tasks.org").await[1].clone();
    let result = f
        .workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Trash(TaskTrash {
                path: node.full_path().clone(),
                target: OrgFileRef {
                    repo_id: f.system.id.clone(),
                    path: "trash.org".into(),
                },
            })],
            file_versions: vec![TaskFileVersion {
                repo_id: f.source.id.clone(),
                file: "tasks.org".into(),
                version: "stale".into(),
            }],
            ..Default::default()
        })
        .await;
    assert!(result.is_err());
    assert_eq!(f.bytes(&f.source, "tasks.org").await, original);
    assert!(f.nodes(&f.system, "trash.org").await.is_empty());
}

#[tokio::test]
async fn custom_todo_keywords_survive_trash_and_restore_without_changing_original_workflow() {
    let f=Fixture::new("#+TODO: OPEN REVIEW | FINISHED\n* REVIEW Custom\n:PROPERTIES:\n:CREATED: [2020-01-01 Wed]\n:END:\nbody\n","#+TITLE: 废纸篓\n").await;
    f.trash(vec![
        f.nodes(&f.source, "tasks.org").await[0].full_path().clone(),
    ])
    .await
    .unwrap();
    f.restore(vec![
        f.nodes(&f.system, "trash.org").await[0].full_path().clone(),
    ])
    .await
    .unwrap();
    let restored = f.nodes(&f.source, "tasks.org").await;
    assert_eq!(
        restored[0].state().map(|state| state.name.as_str()),
        Some("REVIEW")
    );
    assert_eq!(restored[0].title(), "Custom");
    assert!(restored[0].created_at().is_some());
}

#[tokio::test]
async fn system_properties_are_overwritten_and_removed_instead_of_restoring_old_values() {
    let f = Fixture::new("* TODO Leaf\n:PROPERTIES:\n:SOURCE_TRASH_ID: invalid-old\n:SOURCE_FILE: old.org\n:SOURCE_FUTURE: reserved\n:CATEGORY: old\n:PROJECT_NAME: old-project\n:ID: business-id\n:END:\nbody\n", "#+TITLE: 废纸篓\n").await;
    f.trash(vec![
        f.nodes(&f.source, "tasks.org").await[0].full_path().clone(),
    ])
    .await
    .unwrap();
    let archived = f.nodes(&f.system, "trash.org").await[0].clone();
    assert_ne!(archived.property("SOURCE_TRASH_ID"), Some("invalid-old"));
    assert_eq!(archived.property("SOURCE_FILE"), Some("tasks.org"));
    f.restore(vec![archived.full_path().clone()]).await.unwrap();
    let restored = f.nodes(&f.source, "tasks.org").await[0].clone();
    assert_eq!(restored.property("ID"), Some("business-id"));
    assert_eq!(restored.property("CATEGORY"), Some("old"));
    assert_eq!(restored.property("PROJECT_NAME"), Some("old-project"));
    for name in ["SOURCE_TRASH_ID", "SOURCE_FILE", "SOURCE_FUTURE"] {
        assert!(restored.property(name).is_none());
    }
}

#[tokio::test]
async fn cross_file_move_then_delete_emits_one_final_deletion_without_a_stale_move() {
    let f = Fixture::new("* TODO Leaf\nbody\n* TODO Other\n", "#+TITLE: 目标\n").await;
    let source = f.nodes(&f.source, "tasks.org").await[0].clone();
    let target = TaskPath::file(f.system.id.clone(), "trash.org".into());
    let moved = TaskPath {
        repo_id: f.system.id.clone(),
        file: Some("trash.org".into()),
        titles: vec!["Leaf".into()],
        occurrence: 1,
    };
    let events = Arc::new(Mutex::new(Vec::new()));
    let capture = events.clone();
    let _subscription = f
        .workspace
        .watch_data_changes(move |event| capture.lock().unwrap().push(event));
    f.workspace
        .execute_task_operations(&TaskOperationGroup {
            operations: vec![
                TaskOperation::Movement(TaskMovement {
                    path: source.full_path().clone(),
                    position: TaskPosition {
                        parent: target,
                        after: None,
                    },
                }),
                TaskOperation::Deletion(TaskDeletion { path: moved }),
            ],
            ..Default::default()
        })
        .await
        .unwrap();
    let events = events.lock().unwrap();
    let changes = events
        .iter()
        .flat_map(|event| {
            let DataChangeEvent::NotificationEvent { changes, .. } = event;
            changes
        })
        .filter(|change| {
            change
                .before
                .as_ref()
                .is_some_and(|before| before.task.full_path() == source.full_path())
        })
        .collect::<Vec<_>>();
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, TaskDataChangeKind::Deleted);
    assert!(changes[0].after.is_none());
    drop(changes);
    drop(events);
    assert!(f.nodes(&f.system, "trash.org").await.is_empty());
}

#[tokio::test]
async fn trash_copies_only_missing_ancestor_tags_and_restores_id_and_file_metadata() {
    let f = Fixture::new(":PROPERTIES:\n:ID: file-id\n:END:\n#+TITLE: 来源文件\n#+FILETAGS: :file_tag:\n* Grand :grand:shared:\n** Parent :parent:shared:\n*** TODO Previous\n*** TODO Leaf :own:shared:\n:PROPERTIES:\n:ID: leaf-id\n:CREATED: [2020-01-01 Wed]\n:SOURCE_ID: stale\n:SOURCE_FUTURE: stale\n:END:\nnotes\n*** TODO Next\n", "#+TITLE: 废纸篓\n").await;
    let original = f.nodes(&f.source, "tasks.org").await;
    let source = original.iter().find(|task| task.title() == "Leaf").unwrap();
    f.trash(vec![source.full_path().clone()]).await.unwrap();
    let archived = f.nodes(&f.system, "trash.org").await.remove(0);
    assert_eq!(archived.own_tags(), ["own", "shared", "grand", "parent"]);
    assert_eq!(
        archived.property("SOURCE_PARENT_TAGS"),
        Some("[\"grand\",\"parent\"]")
    );
    assert_eq!(archived.property("SOURCE_FILE_TITLE"), Some("来源文件"));
    assert_eq!(archived.property("SOURCE_FILE_ID"), Some("file-id"));
    assert_eq!(archived.property("SOURCE_ID"), Some("leaf-id"));
    assert!(archived.property("ID").is_none());
    assert!(archived.property("SOURCE_FUTURE").is_none());
    let brother: TaskPath =
        serde_json::from_str(archived.property("SOURCE_BROTHER").unwrap()).unwrap();
    assert_eq!(brother.titles.last().unwrap(), "Previous");
    // 恢复必须按前缀清除后续扩展字段，也保留废纸篓中新加的自有标签。
    f.workspace
        .execute_task_operations(
            &serde_json::from_value(serde_json::json!({"operations":[{
                "type":"Modification", "data":{"path":archived.full_path(), "modifications":[
                    {"field":"PROPERTY","value":{"name":"SOURCE_FUTURE","value":"future"}},
                    {"field":"TAGS","value":["own","shared","grand","parent","added"]}
                ]}
            }]}))
            .unwrap(),
        )
        .await
        .unwrap();
    f.restore(vec![archived.full_path().clone()]).await.unwrap();
    let restored = f
        .nodes(&f.source, "tasks.org")
        .await
        .into_iter()
        .find(|task| task.title() == "Leaf")
        .unwrap();
    assert_eq!(restored.own_tags(), ["own", "shared", "added"]);
    assert_eq!(restored.property("ID"), Some("leaf-id"));
    assert_eq!(restored.created_at(), source.created_at());
    assert!(
        restored
            .properties()
            .keys()
            .all(|name| !name.starts_with("SOURCE_"))
    );
    let text = String::from_utf8(f.bytes(&f.source, "tasks.org").await).unwrap();
    assert!(text.find("Previous").unwrap() < text.find("Leaf").unwrap());
    assert!(text.find("Leaf").unwrap() < text.find("Next").unwrap());
}

#[tokio::test]
async fn restore_missing_or_unrelated_brother_falls_back_to_first_child() {
    for unrelated in [false, true] {
        let f = Fixture::new(
            "* Parent\n** TODO Previous\n** TODO Leaf\n** TODO Next\n* Other\n** TODO Unrelated\n",
            "#+TITLE: 废纸篓\n",
        )
        .await;
        let original = f.nodes(&f.source, "tasks.org").await;
        f.trash(vec![original[2].full_path().clone()])
            .await
            .unwrap();
        let archived = f.nodes(&f.system, "trash.org").await.remove(0);
        if unrelated {
            let value = serde_json::to_string(original[5].full_path()).unwrap();
            f.workspace
                .execute_task_operations(&TaskOperationGroup {
                    operations: vec![TaskOperation::Modification(TaskModificationOperation {
                        path: archived.full_path().clone(),
                        modifications: vec![TaskModification::Property {
                            name: "SOURCE_BROTHER".into(),
                            value: Some(value),
                        }],
                    })],
                    ..Default::default()
                })
                .await
                .unwrap();
        } else {
            f.workspace
                .execute_task_operations(&TaskOperationGroup {
                    operations: vec![TaskOperation::Deletion(TaskDeletion {
                        path: original[1].full_path().clone(),
                    })],
                    ..Default::default()
                })
                .await
                .unwrap();
        }
        f.restore(vec![archived.full_path().clone()]).await.unwrap();
        let nodes = f.nodes(&f.source, "tasks.org").await;
        assert_eq!(nodes[1].title(), "Leaf");
        assert!(f.nodes(&f.system, "trash.org").await.is_empty());
    }
}

#[tokio::test]
async fn restore_without_brother_or_original_id_inserts_first_and_removes_source_fields() {
    let f = Fixture::new("* TODO First\n* TODO Next\n", "#+TITLE: 废纸篓\n").await;
    f.trash(vec![
        f.nodes(&f.source, "tasks.org").await[0].full_path().clone(),
    ])
    .await
    .unwrap();
    let archived = f.nodes(&f.system, "trash.org").await.remove(0);
    assert!(archived.property("SOURCE_BROTHER").is_none());
    assert_eq!(archived.property("SOURCE_FILE_ID"), Some(""));
    assert_eq!(archived.property("SOURCE_FILE_TITLE"), Some(""));
    f.restore(vec![archived.full_path().clone()]).await.unwrap();
    let restored = f.nodes(&f.source, "tasks.org").await.remove(0);
    assert_eq!(restored.title(), "First");
    assert!(restored.property("ID").is_none());
    assert!(
        restored
            .properties()
            .keys()
            .all(|name| !name.starts_with("SOURCE_"))
    );
}

#[tokio::test]
async fn restore_rejects_legacy_metadata_without_modifying_either_file() {
    let f = Fixture::new("* TODO Existing\n", "#+TITLE: 废纸篓\n* TODO Legacy\n:PROPERTIES:\n:TRASH_ID: old\n:ARCHIVE_POSITION: invalid\n:ARCHIVE_TIME: [2026-11-17 Tue 09:00]\n:END:\n").await;
    let source = f.bytes(&f.source, "tasks.org").await;
    let trash = f.bytes(&f.system, "trash.org").await;
    let archived = f.nodes(&f.system, "trash.org").await.remove(0);
    assert!(archived.deleted_at().is_none());
    assert!(f.restore(vec![archived.full_path().clone()]).await.is_err());
    assert_eq!(f.bytes(&f.source, "tasks.org").await, source);
    assert_eq!(f.bytes(&f.system, "trash.org").await, trash);
}

#[tokio::test]
async fn creation_uses_after_only_as_a_hint_without_loading_its_file_or_repository() {
    for hint in [
        "missing",
        "other_parent",
        "other_file",
        "other_repo",
        "valid",
    ] {
        let f = Fixture::new(
            "* Parent\n** TODO Previous\n** TODO Next\n* Other\n** TODO Unrelated\n",
            "#+TITLE: 废纸篓\n",
        )
        .await;
        let nodes = f.nodes(&f.source, "tasks.org").await;
        let mut after = nodes[1].full_path().clone();
        match hint {
            "missing" => *after.titles.last_mut().unwrap() = "Missing".into(),
            "other_parent" => after = nodes[4].full_path().clone(),
            "other_file" => after.file = Some("missing.org".into()),
            "other_repo" => after.repo_id = "unregistered".into(),
            _ => (),
        }
        f.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: vec![TaskOperation::Creation(TaskCreation::new(
                    TaskPosition {
                        parent: nodes[0].full_path().clone(),
                        after: Some(after),
                    },
                    "Created".into(),
                ))],
                ..Default::default()
            })
            .await
            .unwrap();
        let result = f.nodes(&f.source, "tasks.org").await;
        assert_eq!(
            result[if hint == "valid" { 2 } else { 1 }].title(),
            "Created",
            "{hint}"
        );
        assert!(
            !PathBuf::from(&f.source.root_directory)
                .join("missing.org")
                .exists()
        );
    }
}
