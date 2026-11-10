use org_tasks_core::TaskQuery;
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
use tokio::fs;

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(source: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-operations-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).await.unwrap();
        fs::write(root.join("tasks.org"), source).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self {
            root,
            workspace: OrgWorkspace::new(vec![repo]).unwrap(),
        }
    }
    async fn group(&self, title: &str) -> TaskOperationGroup {
        let path = self.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[0].clone();
        TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path,
                modifications: vec![TaskModification::Title(Some(title.into()))],
            })],
            queue_repo_ids: vec![self.workspace.repos()[0].id.clone()],
            ..Default::default()
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn progress_changes_keep_nested_write_paths_but_do_not_bypass_file_versions() {
    let source = "* TODO Parent [/]\n** TODO Child [0/2]\nOld notes\n";
    let mut fixture = Fixture::new(source).await;
    let file = &fixture.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
    let path = file.node_paths()[1].clone();
    assert_eq!(path.titles, ["Parent", "Child"]);
    let mut group = TaskOperationGroup {
        operations: vec![TaskOperation::Modification(TaskModificationOperation {
            path: path.clone(),
            modifications: vec![TaskModification::Notes(Some("New notes\n".into()))],
        })],
        file_versions: vec![TaskFileVersion {
            repo_id: path.repo_id.clone(), file: "tasks.org".into(),
            version: LocalFileVersion::from_bytes(source.as_bytes()).content_hash,
        }],
        ..Default::default()
    };
    let updated = source.replace("Parent [/]", "Parent [1/2]").replace("Child [0/2]", "Child [1/2]");
    fs::write(fixture.root.join("tasks.org"), &updated).await.unwrap();
    assert!(fixture.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(fs::read_to_string(fixture.root.join("tasks.org")).await.unwrap(), updated);
    group.file_versions[0].version = LocalFileVersion::from_bytes(updated.as_bytes()).content_hash;
    fixture.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(fs::read_to_string(fixture.root.join("tasks.org")).await.unwrap(), updated.replace("Old notes", "New notes"));
    assert_eq!(fixture.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[1], path);
}

async fn merge_request(f: &Fixture, selected: &[usize]) -> TaskMergeRequest {
    let file = &f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];

    let paths = file.node_paths();
    TaskMergeRequest { paths: selected.iter().map(|i| paths[*i].clone()).collect(),
        file_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash }
}

#[tokio::test]
async fn merging_plans_only_deletions_and_modifications_in_selection_order() {
    let source = "#+TITLE: Inbox\r\n前言  \r\n* DONE First :old:\r\nCLOSED: [2026-11-01 Sun]\r\n:LOGBOOK:\r\n- Old log\r\n:END:\r\nFirst body  \r\n** TODO Child\r\nchild body\r\n* TODO Main :keep:\r\nSCHEDULED: <2026-11-14 Sat>\r\n:PROPERTIES:\r\n:ID: keep-main\r\n:END:\r\nMain body\r\n** Existing\r\noriginal child\r\n* Last\r\n- [ ] tent\r\n#+begin_src org\r\n,* literal heading\r\n#+end_src\r\n* Unrelated  \r\nDo not touch\r\n";
    let mut f = Fixture::new(source).await;
    let request = merge_request(&f, &[2,4,0]).await;
    let snapshot = f.workspace.clone();
    let mut plan = f.workspace.task_merge_operations(&request).await.unwrap();
    assert_eq!(f.workspace, snapshot);
    assert_eq!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap(), source);
    assert!(f.workspace.repos()[0].pending_writes().await.unwrap().is_empty());
    assert!(plan.operation_group.operations.iter().all(|op| matches!(op,TaskOperation::Deletion(_)|TaskOperation::Modification(_))));
    assert_eq!(plan.operation_group.operations.len(),4);
    plan.operation_group.queue_repo_ids.push(request.paths[0].repo_id.clone());
    f.workspace.execute_task_operations(&plan.operation_group).await.unwrap();
    let result = fs::read_to_string(f.root.join("tasks.org")).await.unwrap();
    assert!(result.starts_with("#+TITLE: Inbox\r\n前言  \r\n* TODO 合并: Main :keep:\r\nSCHEDULED: <2026-11-14 Sat>\r\n:PROPERTIES:\r\n:ID: keep-main\r\n:END:\r\n- Main\r\n"),"{result}");
    assert!(result.ends_with("* Unrelated  \r\nDo not touch\r\n"));
    let file=&f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
    assert_eq!(file.node_paths().iter().map(|p|p.titles.clone()).collect::<Vec<_>>(),vec![vec!["合并: Main"],vec!["Unrelated"]]);
    assert_eq!(file.node_paths()[0],plan.main_path);
    let body=file.nodes()[0].render_content().body_html.clone();
    assert!(body.find("Main").unwrap()<body.find("Last").unwrap());
    assert!(body.find("Last").unwrap()<body.find("First").unwrap());
    assert!(body.contains("Child") && body.contains("Existing") && body.contains("tent"));
    assert!(!body.contains("合并前元数据") && !body.contains("Old log") && !body.contains("org_tasks_merge_original"),"{body}");
    assert!(result.contains("CLOSED: [2026-11-01 Sun]"));
    assert!(result.contains("- Old log"));
    assert_eq!(f.workspace.repos()[0].pending_writes().await.unwrap().len(),1);
    assert_eq!(f.workspace.task_operation_history.entries.len(),1);
    assert_eq!(f.workspace.task_operation_history.entries[0].fallback_group.files[0].before.as_deref(),Some(source));
}

#[tokio::test]
async fn merging_rejects_overlapping_selection_identity_targets_and_conflicts_without_writes() {
    for (source, selected) in [
        ("* Main\n* Other\n", vec![0,0]),
        ("* Main\n* Other\n", vec![0,1,1]),
        ("* Main\n** Child\n", vec![0,1]),
        ("* Main\n** Child\n", vec![1,0]),
        ("* Main\n* Other\n:PROPERTIES:\n:ID: stable\n:END:\n", vec![0,1]),
        ("* Main\n** Child\n:PROPERTIES:\n:CUSTOM_ID: stable\n:END:\n* Other\n", vec![0,2]),
        ("* Main\n[[*Other]]\n* Other\n", vec![0,1]),
        ("* Main\n* Other\n** Candidate :CONFLICT:\n", vec![0,1]),
        ("* Main\n* Other\n", vec![0]),
    ] {
        let f=Fixture::new(source).await;
        let request=merge_request(&f,&selected).await;
        let snapshot=f.workspace.clone();
        assert!(f.workspace.task_merge_operations(&request).await.is_err(),"{source}");
        assert_eq!(f.workspace,snapshot);
        assert_eq!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap(),source);
        assert!(f.workspace.repos()[0].pending_writes().await.unwrap().is_empty());
    }
}

#[tokio::test]
async fn merging_keeps_first_selected_duplicate_and_converts_children_to_nested_lists() {
    let mut f=Fixture::new("* Same\nfirst\n* Same\nsecond\n* Parent\n** Source\nbody\n**** TODO Nested\n#+begin_src org\n,**** literal\n#+end_src\n").await;
    let request=merge_request(&f,&[1,3,0]).await;
    let plan=f.workspace.task_merge_operations(&request).await.unwrap();
    f.workspace.execute_task_operations(&plan.operation_group).await.unwrap();
    let result=fs::read_to_string(f.root.join("tasks.org")).await.unwrap();
    assert!(result.starts_with("* 合并: Same\n- Same\n  second\n"),"{result}");
    assert!(result.contains("  - Nested\n"));
    assert!(result.contains(",**** literal"));
    assert!(result.ends_with("* Parent\n"));
    assert_eq!(f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[0],plan.main_path);
}

#[tokio::test]
async fn merging_group_version_prevents_partial_deletion_and_archives_cannot_end_early() {
    let source="* Main\n* Source\n:LOGBOOK:\n#+end_comment\nlog\n:END:\n";
    let mut f=Fixture::new(source).await;
    let request=merge_request(&f,&[0,1]).await;
    let plan=f.workspace.task_merge_operations(&request).await.unwrap();
    let newer=source.replace("* Main","* Main changed");
    fs::write(f.root.join("tasks.org"),&newer).await.unwrap();
    assert!(f.workspace.execute_task_operations(&plan.operation_group).await.is_err());
    assert!(f.workspace.task_merge_operations(&request).await.is_err());
    assert_eq!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap(),newer);
    assert!(f.workspace.task_operation_history.entries.is_empty());
    fs::write(f.root.join("tasks.org"),source).await.unwrap();
    f.workspace.execute_task_operations(&plan.operation_group).await.unwrap();
    assert!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap().contains(",#+end_comment"));
}

#[tokio::test]
async fn repeated_merging_keeps_archives_out_of_notes_and_notes_edits_preserve_metadata() {
    let mut f = Fixture::new("* Main\nnotes\n* Source\n:PROPERTIES:\n:CREATED: [2026-11-10 Tue]\n:END:\nextra\n").await;
    let first = f.workspace.task_merge_operations(&merge_request(&f,&[0,1]).await).await.unwrap();
    f.workspace.execute_task_operations(&first.operation_group).await.unwrap();
    let mut content=fs::read_to_string(f.root.join("tasks.org")).await.unwrap();
    content.push_str("* Third\nmore\n");
    fs::write(f.root.join("tasks.org"),&content).await.unwrap();
    f.workspace.repos[0].load::<WebDavSyncPolicy>().await.unwrap();
    let second=f.workspace.task_merge_operations(&merge_request(&f,&[0,1]).await).await.unwrap();
    f.workspace.execute_task_operations(&second.operation_group).await.unwrap();
    let file=&f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
    let notes=file.task_edit_content(&second.main_path).unwrap().notes;
    assert!(notes.contains("- 合并: Main") && notes.contains("- Source") && notes.contains("- Third"),"{notes}");
    assert!(!notes.contains("org_tasks_merge_original") && !notes.contains("CREATED"),"{notes}");
    let source=std::str::from_utf8(file.source_bytes()).unwrap();
    assert_eq!(source.matches("#+begin_comment org_tasks_merge_original").count(),4);
    let group=TaskOperationGroup { operations:vec![TaskOperation::Modification(TaskModificationOperation {
        path:second.main_path, modifications:vec![TaskModification::Notes(Some("edited\n".into()))]
    })], ..Default::default() };
    f.workspace.execute_task_operations(&group).await.unwrap();
    let updated=fs::read_to_string(f.root.join("tasks.org")).await.unwrap();
    assert!(updated.contains(":CREATED: [2026-11-10 Tue]"));
    assert!(updated.contains("edited\n"));
}

#[tokio::test]
async fn task_operations_notify_only_after_changed_files_are_committed() {
    let mut f = Fixture::new("* TODO Original\n").await;
    let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let events = observed.clone();
    let file = f.root.join("tasks.org");
    let repo_id = f.workspace.repos()[0].id.clone();
    let _subscription = f.workspace.watch_notifications(move |update| {
        if let org_tasks_core::NotificationUpdate::RepositoryChanged { repo_id } = update {
            events.lock().unwrap().push((repo_id, std::fs::read_to_string(&file).unwrap()));
        }
    });

    let changed = f.group("Updated").await;
    f.workspace.execute_task_operations(&changed).await.unwrap();
    assert_eq!(
        *observed.lock().unwrap(),
        vec![(repo_id, "* TODO Updated\n".into())]
    );

    let unchanged = f.group("Updated").await;
    f.workspace.execute_task_operations(&unchanged).await.unwrap();
    let invalid = f.group("Invalid\nHeading").await;
    assert!(f.workspace.execute_task_operations(&invalid).await.is_err());
    assert_eq!(observed.lock().unwrap().len(), 1);
    assert_eq!(
        std::fs::read_to_string(f.root.join("tasks.org")).unwrap(),
        "* TODO Updated\n"
    );
}

#[tokio::test]
async fn checklist_counts_commit_with_checkbox_before_data_change_events() {
    let source = "* TODO Task [0/2]\r\n- [ ] First\r\n- [ ] Second\r\n";
    let mut f = Fixture::new(source).await;
    let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let events = observed.clone();
    let disk = f.root.join("tasks.org");
    let repo_id = f.workspace.repos()[0].id.clone();
    let _subscription = f.workspace.watch_data_changes(move |event| {
        events
            .lock()
            .unwrap()
            .push((event, std::fs::read_to_string(&disk).unwrap()));
    });
    let initial = f
        .workspace
        .query(&TaskQuery::default()).await
        .unwrap()
        .tasks
        .remove(0);
    for (checked, title, event_count) in [
        (true, "Task [1/2]", 1),
        (true, "Task [1/2]", 1),
        (false, "Task [0/2]", 2),
    ] {
        let file = &f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
        let path = file.node_paths()[0].clone();
        let id = file.task_edit_content(&path).unwrap().checklist[0]
            .id
            .clone();
        let group = TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path,
                modifications: vec![TaskModification::Checklist(
                    TaskChecklistChange::SetChecked { id, checked },
                )],
            })],
            file_versions: vec![TaskFileVersion {
                repo_id: repo_id.clone(),
                file: "tasks.org".into(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            ..Default::default()
        };
        f.workspace.execute_task_operations(&group).await.unwrap();
        let current = f
            .workspace
            .query(&TaskQuery::default()).await
            .unwrap()
            .tasks
            .remove(0);
        assert_eq!(current.title(), title);
        assert_eq!(current.id(), initial.id());
        assert_eq!(current.state(), Some("TODO"));
        let events = observed.lock().unwrap();
        assert_eq!(events.len(), event_count);
        assert_eq!(
            events.last().unwrap().0,
            DataChangeEvent::RepositoryChanged {
                repo_id: repo_id.clone()
            }
        );
        assert_eq!(
            events.last().unwrap().1.as_bytes(),
            f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes()
        );
    }
    let before = f.workspace.clone();
    let file = &f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
    let path = file.node_paths()[0].clone();
    let id = file.task_edit_content(&path).unwrap().checklist[0]
        .id
        .clone();
    let invalid = TaskOperationGroup {
        operations: vec![TaskOperation::Modification(TaskModificationOperation {
            path,
            modifications: vec![
                TaskModification::Checklist(TaskChecklistChange::SetChecked { id, checked: true }),
                TaskModification::Title(Some("Invalid\nHeading".into())),
            ],
        })],
        ..Default::default()
    };
    assert!(f.workspace.execute_task_operations(&invalid).await.is_err());
    assert_eq!(f.workspace, before);
    assert_eq!(
        std::fs::read(f.root.join("tasks.org")).unwrap(),
        source.as_bytes()
    );
    assert_eq!(observed.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn title_statistics_match_emacs_for_title_checkbox_todo_and_recursive_updates() {
    let reference: serde_json::Value =
        serde_json::from_str(include_str!("data/title_statistics_emacs.json")).unwrap();
    for case in reference["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut f = Fixture::new(case["source"].as_str().unwrap()).await;
        let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let events = observed.clone();
        let disk = f.root.join("tasks.org");
        let repo_id = f.workspace.repos()[0].id.clone();
        let _subscription = f.workspace.watch_data_changes(move |event| {
            events
                .lock()
                .unwrap()
                .push((event, std::fs::read_to_string(&disk).unwrap()));
        });
        let mut expected_events = 0;
        for action in case["actions"].as_array().unwrap() {
            let file = &f.workspace.repos()[0].load_files(&[]).await.unwrap()[0];
            let before = file.source_bytes().to_vec();
            let path = file.node_paths()[action["index"].as_u64().unwrap() as usize].clone();
            let modification = match action["type"].as_str().unwrap() {
                "title" => TaskModification::Title(Some(action["value"].as_str().unwrap().into())),
                "todo" => TaskModification::Todo(action["value"].as_str().map(str::to_owned)),
                "checkbox" => {
                    let item = &file.task_edit_content(&path).unwrap().checklist[0];
                    TaskModification::Checklist(TaskChecklistChange::SetChecked {
                        id: item.id.clone(),
                        checked: !item.checked,
                    })
                }
                _ => unreachable!(),
            };
            let group = TaskOperationGroup {
                operations: vec![TaskOperation::Modification(TaskModificationOperation {
                    path,
                    modifications: vec![modification],
                })],
                file_versions: vec![TaskFileVersion {
                    repo_id: repo_id.clone(),
                    file: "tasks.org".into(),
                    version: LocalFileVersion::from_bytes(&before).content_hash,
                }],
                ..Default::default()
            };
            f.workspace
                .execute_task_operations(&group)
                .await
                .unwrap_or_else(|error| panic!("{name}: {error}"));
            let expected = action["expected"].as_str().unwrap();
            assert_eq!(
                f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(),
                expected.as_bytes(),
                "{name}: {action}"
            );
            assert_eq!(
                std::fs::read(f.root.join("tasks.org")).unwrap(),
                expected.as_bytes(),
                "{name}"
            );
            if before != expected.as_bytes() {
                expected_events += 1;
                let events = observed.lock().unwrap();
                assert_eq!(
                    events.last().unwrap(),
                    &(
                        DataChangeEvent::RepositoryChanged {
                            repo_id: repo_id.clone()
                        },
                        expected.into()
                    ),
                    "{name}"
                );
                let history = &f
                    .workspace
                    .task_operation_history
                    .entries
                    .last()
                    .unwrap()
                    .fallback_group
                    .files[0];
                assert_eq!(history.before.as_deref().unwrap().as_bytes(), before);
                assert_eq!(history.after, expected);
            }
            assert_eq!(observed.lock().unwrap().len(), expected_events, "{name}");
        }
    }
}

#[tokio::test]
async fn recursive_statistics_share_field_edits_versions_rollback_and_one_event() {
    let source = "* TODO Root [/] [%]\r\n:PROPERTIES:\r\n:COOKIE_DATA: todo recursive\r\n:END:\r\n** TODO Parent [/]\r\n*** TODO Child\r\nOld notes  \r\n";
    let mut f = Fixture::new(source).await;
    let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let events = observed.clone();
    let _subscription = f
        .workspace
        .watch_data_changes(move |event| events.lock().unwrap().push(event));
    let child = f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[2].clone();
    let group = TaskOperationGroup {
        operations: vec![TaskOperation::Modification(TaskModificationOperation {
            path: child,
            modifications: vec![
                TaskModification::Todo(Some("DONE".into())),
                TaskModification::Priority(Some("A".into())),
                TaskModification::Notes(Some("New notes\n".into())),
            ],
        })],
        ..Default::default()
    };
    f.workspace.execute_task_operations(&group).await.unwrap();
    let expected = source
        .replace("Root [/] [%]", "Root [1/2] [50%]")
        .replace("Parent [/]", "Parent [1/1]")
        .replace("TODO Child", "DONE [#A] Child")
        .replace("Old notes  ", "New notes");
    assert_eq!(
        f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(),
        expected.as_bytes()
    );
    assert_eq!(observed.lock().unwrap().len(), 1);
    let snapshot = f.workspace.clone();
    let child = f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[2].clone();
    let mut invalid = TaskOperationGroup {
        operations: vec![
            TaskOperation::Modification(TaskModificationOperation {
                path: child.clone(),
                modifications: vec![TaskModification::Todo(Some("TODO".into()))],
            }),
            TaskOperation::Deletion(TaskDeletion {
                path: TaskPath {
                    titles: vec!["Missing".into()],
                    ..child
                },
            }),
        ],
        ..Default::default()
    };
    assert!(f.workspace.execute_task_operations(&invalid).await.is_err());
    assert_eq!(f.workspace, snapshot);
    invalid.operations.pop();
    invalid.file_versions.push(TaskFileVersion {
        repo_id: f.workspace.repos()[0].id.clone(),
        file: "tasks.org".into(),
        version: LocalFileVersion::from_bytes(source.as_bytes()).content_hash,
    });
    assert!(f.workspace.execute_task_operations(&invalid).await.is_err());
    assert_eq!(f.workspace, snapshot);
    assert_eq!(
        std::fs::read(f.root.join("tasks.org")).unwrap(),
        expected.as_bytes()
    );
    assert_eq!(observed.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn title_statistics_never_allow_field_injection_or_publish_failed_edits() {
    let source = "* Note\n- [X] First\n- [ ] Second\n";
    let mut f = Fixture::new(source).await;
    let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let events = observed.clone();
    let _subscription = f
        .workspace
        .watch_data_changes(move |event| events.lock().unwrap().push(event));
    let snapshot = f.workspace.clone();
    for title in [
        "TODO Other [/]",
        "[#A] Other [/]",
        "Other [/] :work:",
        "Broken\nHeadline",
    ] {
        assert!(
            f.workspace
                .execute_task_operations(&f.group(title).await)
                .await
                .is_err(),
            "{title}"
        );
        assert_eq!(f.workspace, snapshot);
        assert_eq!(
            std::fs::read(f.root.join("tasks.org")).unwrap(),
            source.as_bytes()
        );
        assert!(observed.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn successful_groups_accumulate_history_and_failed_group_does_not_publish() {
    let source = "* TODO Original\r\nBody  \r\n";
    let mut f = Fixture::new(source).await;
    f.workspace
        .execute_task_operations(&f.group("One").await)
        .await
        .unwrap();
    assert_eq!(
        f.workspace.task_operation_history.entries[0].fallback_group.files[0]
            .before
            .as_deref(),
        Some(source)
    );
    f.workspace
        .execute_task_operations(&f.group("Two").await)
        .await
        .unwrap();
    let snapshot = f.workspace.clone();
    let mut invalid = f.group("Three").await;
    invalid
        .operations
        .push(TaskOperation::Deletion(TaskDeletion {
            path: TaskPath {
                titles: vec!["Missing".into()],
                ..f.workspace.repos()[0].load_files(&[]).await.unwrap()[0].node_paths()[0].clone()
            },
        }));
    assert!(f.workspace.execute_task_operations(&invalid).await.is_err());
    assert_eq!(f.workspace, snapshot);
    assert_eq!(f.workspace.task_operation_history.entries.len(), 2);
    assert_eq!(
        fs::read(f.root.join("tasks.org")).await.unwrap(),
        b"* TODO Two\r\nBody  \r\n"
    );
    assert_eq!(
        f.workspace.repos()[0].pending_writes().await.unwrap().len(),
        2
    );
}

#[tokio::test]
async fn file_version_and_history_serialization_preserve_the_public_contract() {
    let mut f = Fixture::new("* Original\n").await;
    let mut group = f.group("Changed").await;
    group.file_versions.push(TaskFileVersion {
        repo_id: f.workspace.repos()[0].id.clone(),
        file: "tasks.org".into(),
        version: "wrong".into(),
    });
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    group.file_versions[0].version = LocalFileVersion::from_bytes(b"* Original\n").content_hash;
    f.workspace.execute_task_operations(&group).await.unwrap();
    let history = &f.workspace.task_operation_history;
    let decoded: TaskOperationHistory =
        serde_json::from_str(&serde_json::to_string(history).unwrap()).unwrap();
    assert_eq!(*history, decoded);
}

#[tokio::test]
async fn commit_preparation_error_keeps_files_memory_and_history_unchanged() {
    let mut f = Fixture::new("* Original\n").await;
    fs::write(f.root.join(".sync/outbox"), b"blocked")
        .await
        .unwrap();
    let snapshot = f.workspace.clone();
    assert!(
        f.workspace
            .execute_task_operations(&f.group("Changed").await)
            .await
            .is_err()
    );
    assert_eq!(f.workspace, snapshot);
    assert_eq!(
        fs::read(f.root.join("tasks.org")).await.unwrap(),
        b"* Original\n"
    );
    assert_eq!(
        fs::read(f.root.join(".sync/outbox")).await.unwrap(),
        b"blocked"
    );
    assert_eq!(std::fs::read_dir(&f.root).unwrap().count(), 2);
}

#[tokio::test]
async fn record_created_is_generated_by_core_and_survives_reload() {
    let mut f = Fixture::new("* Existing\n").await;
    let id = f.workspace.repos()[0].id.clone();
    let group:TaskOperationGroup=serde_json::from_value(serde_json::json!({"operations":[{"type":"Creation","data":{
        "position":{"parent":{"repoId":id,"file":"tasks.org"}},"title":"Captured","state":"TODO","recordCreated":true}}]})).unwrap();
    f.workspace.execute_task_operations(&group).await.unwrap();
    f.workspace.repos[0]
        .load::<WebDavSyncPolicy>()
        .await
        .unwrap();
    let tasks = f.workspace.query(&TaskQuery::default()).await.unwrap().tasks;
    assert!(tasks[0].created_at().is_some());
    assert!(
        std::fs::read_to_string(f.root.join("tasks.org"))
            .unwrap()
            .contains(":CREATED: [")
    );
    assert!(tasks[0].render_content().body_html.is_empty());
    assert!(tasks[0].task_id().is_some());
    assert!(tasks[1].task_id().is_none());
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_and_missing_parent_directories_never_escape_or_create_directories() {
    let mut f = Fixture::new("* Original\n").await;
    std::os::unix::fs::symlink(f.root.join("tasks.org"), f.root.join("linked.org")).unwrap();
    for file in ["linked.org", "missing/tasks.org"] {
        let mut group = f.group("Changed").await;
        let TaskOperation::Modification(data) = &mut group.operations[0] else {
            unreachable!()
        };
        data.path.file = Some(file.into());
        assert!(f.workspace.execute_task_operations(&group).await.is_err());
    }
    assert!(!f.root.join("missing").exists());
    assert_eq!(
        fs::read(f.root.join("tasks.org")).await.unwrap(),
        b"* Original\n"
    );
}

async fn someday_group(workspace: &OrgWorkspace) -> TaskOperationGroup {
    let source = workspace.repos()[0].file("tasks.org").await.unwrap();
    let target = workspace.refile_targets().await.unwrap()[0].clone();
    let path = source.node_paths()[0].clone();
    TaskOperationGroup {
        operations: vec![
            TaskOperation::Modification(TaskModificationOperation {
                path: path.clone(),
                modifications: vec![
                    TaskModification::Todo(Some("TODO".into())),
                    TaskModification::Schedule(None),
                    TaskModification::Deadline(None),
                    TaskModification::Closed(None),
                ],
            }),
            TaskOperation::Movement(TaskMovement {
                path,
                position: TaskPosition { parent: target.full_path, after: None },
            }),
        ],
        queue_repo_ids: vec![source.repo_id.clone()],
        file_versions: vec![
            TaskFileVersion {
                repo_id: source.repo_id.clone(), file: source.path.clone(),
                version: LocalFileVersion::from_bytes(source.source_bytes()).content_hash,
            },
            TaskFileVersion { repo_id: target.repo_id, file: target.path, version: target.file_version },
        ],
    }
}

#[tokio::test]
async fn someday_group_cleans_only_root_planning_and_preserves_properties_children_and_priority() {
    for state in ["DONE ", "", "TODO "] {
        let original = format!("* {state}[#A] Item :work:\nSCHEDULED: <2026-11-08 Sun +1w> DEADLINE: <2026-11-09 Mon> CLOSED: [2026-11-07 Sat]\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\nBody  \n** TODO Child\nSCHEDULED: <2026-11-10 Tue>\n");
        let mut f = Fixture::new(&original).await;
        fs::write(f.root.join("someday.org"), "* Later :REFILE:\nParent body\n** Existing\n* Other :REFILE:\n").await.unwrap();
        f.workspace.repos[0].load::<WebDavSyncPolicy>().await.unwrap();
        let group = someday_group(&f.workspace).await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert_eq!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap(), "");
        assert_eq!(fs::read_to_string(f.root.join("someday.org")).await.unwrap(),
            "* Later :REFILE:\nParent body\n** TODO [#A] Item :work:\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\nBody  \n*** TODO Child\nSCHEDULED: <2026-11-10 Tue>\n** Existing\n* Other :REFILE:\n");
    }
}

#[tokio::test]
async fn someday_group_rejects_target_todo_mismatch_without_publishing_modifications() {
    let original = "* DONE Item\nSCHEDULED: <2026-11-08 Sun +1w>\n";
    let target = "#+TODO: NEXT | FINISHED\n* Later :REFILE:\n";
    let mut f = Fixture::new(original).await;
    fs::write(f.root.join("someday.org"), target).await.unwrap();
    f.workspace.repos[0].load::<WebDavSyncPolicy>().await.unwrap();
    let snapshot = f.workspace.clone();
    let group = someday_group(&f.workspace).await;
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(f.workspace, snapshot);
    assert_eq!(fs::read_to_string(f.root.join("tasks.org")).await.unwrap(), original);
    assert_eq!(fs::read_to_string(f.root.join("someday.org")).await.unwrap(), target);
    assert!(f.workspace.repos()[0].pending_writes().await.unwrap().is_empty());
}
