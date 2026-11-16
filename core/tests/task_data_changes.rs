use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::sync::{Arc, Mutex};

struct Fixture {
    root: std::path::PathBuf,
    workspace: OrgWorkspace,
    events: Arc<Mutex<Vec<DataChangeEvent>>>,
    _subscription: DataChangeSubscription,
}

impl Fixture {
    async fn new(source: &str) -> Self {
        let root = std::env::temp_dir().join(format!("task-data-changes-{}", uuid()));
        tokio::fs::create_dir(&root).await.unwrap();
        tokio::fs::write(root.join("a.org"), source).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let observed = events.clone();
        let _subscription =
            workspace.watch_data_changes(move |event| observed.lock().unwrap().push(event));
        Self {
            root,
            workspace,
            events,
            _subscription,
        }
    }

    fn group(&self, operations: serde_json::Value) -> TaskOperationGroup {
        let text = serde_json::to_string(&operations)
            .unwrap()
            .replace("$repo", &self.workspace.repos()[0].id);
        serde_json::from_str(&format!(
            "{{\"operationId\":\"operation-1\",\"operations\":{text}}}"
        ))
        .unwrap()
    }

    async fn nodes(&self, path: &str) -> Vec<FilterTask> {
        self.workspace.repos()[0]
            .nodes()
            .await
            .unwrap()
            .into_iter()
            .filter(|task| task.path() == path)
            .collect()
    }
}

fn uuid() -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    format!(
        "{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    )
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn same_file_move_keeps_explicit_mapping_for_duplicate_paths_subtree_and_siblings() {
    let f = Fixture::new(
        "* TODO Group :old:\n** TODO Item\n*** TODO Child\n** TODO Item\n* TODO Target :new:\n",
    )
    .await;
    let before = f.nodes("a.org").await;
    let group = f.group(serde_json::json!([{"type":"Movement","data":{
        "path":{"repoId":"$repo","file":"a.org","titles":["Group","Item"],"occurrence":1},
        "position":{"parent":{"repoId":"$repo","file":"a.org","titles":["Target"]}}
    }}]));
    f.workspace.execute_task_operations(&group).await.unwrap();
    let after = f.nodes("a.org").await;
    let events = f.events.lock().unwrap();
    assert_eq!(events.len(), 1);
    let DataChangeEvent::RepositoryChanged {
        operation_id,
        files,
        changes,
        ..
    } = &events[0];
    assert_eq!(operation_id.as_deref(), Some("operation-1"));
    assert_eq!(files.as_ref().unwrap().len(), 1);
    let moved = changes
        .iter()
        .filter(|change| change.kind == TaskDataChangeKind::Moved)
        .collect::<Vec<_>>();
    assert_eq!(moved.len(), 2);
    for change in moved {
        let old = &change.before.as_ref().unwrap().task;
        let new = &change.after.as_ref().unwrap().task;
        assert!(
            before
                .iter()
                .any(|task| task.full_path() == old.full_path() && task.id() == old.id())
        );
        assert!(
            after
                .iter()
                .any(|task| task.full_path() == new.full_path() && task.id() == new.id())
        );
        assert_eq!(old.full_path().titles[0], "Group");
        assert_eq!(new.full_path().titles[0], "Target");
        assert_ne!(old.id(), new.id());
        assert!(new.inherited_tags().contains(&"new".into()));
        assert!(!new.inherited_tags().contains(&"old".into()));
    }
    let sibling = changes
        .iter()
        .find(|change| {
            change.before.as_ref().is_some_and(|snapshot| {
                snapshot.task.full_path().titles == ["Group", "Item"]
                    && snapshot.task.full_path().occurrence == 2
            })
        })
        .unwrap();
    assert_eq!(sibling.kind, TaskDataChangeKind::Updated);
    assert_eq!(
        sibling.after.as_ref().unwrap().task.full_path().occurrence,
        1
    );
    for change in changes {
        if let Some(snapshot) = &change.after {
            let task = after
                .iter()
                .find(|task| task.full_path() == snapshot.task.full_path())
                .unwrap();
            assert_eq!(task.file_version(), snapshot.task.file_version());
            assert_eq!(task.byte_offset(), snapshot.task.byte_offset());
        }
    }
}

#[tokio::test]
async fn reordering_with_unchanged_path_and_id_is_still_an_explicit_move() {
    for (title, after, expected, old_after, new_after) in [
        ("C", None, "* TODO C\n* TODO A\n* TODO B\n", Some("B"), None),
        (
            "A",
            Some("C"),
            "* TODO B\n* TODO C\n* TODO A\n",
            None,
            Some("C"),
        ),
    ] {
        let f = Fixture::new("* TODO A\n* TODO B\n* TODO C\n").await;
        let after = after
            .map(|title| serde_json::json!({"repoId":"$repo","file":"a.org","titles":[title]}));
        let group = f.group(serde_json::json!([{"type":"Movement","data":{
            "path":{"repoId":"$repo","file":"a.org","titles":[title]},
            "position":{"parent":{"repoId":"$repo","file":"a.org","titles":[]},"after":after}
        }}]));
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert_eq!(
            std::fs::read_to_string(f.root.join("a.org")).unwrap(),
            expected
        );
        let events = f.events.lock().unwrap();
        let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
        let moved = changes
            .iter()
            .filter(|change| change.kind == TaskDataChangeKind::Moved)
            .collect::<Vec<_>>();
        assert_eq!(moved.len(), 1);
        let before = moved[0].before.as_ref().unwrap();
        let after = moved[0].after.as_ref().unwrap();
        assert_eq!(before.task.id(), after.task.id());
        assert_eq!(before.task.full_path(), after.task.full_path());
        assert_eq!(
            before
                .position
                .after
                .as_ref()
                .map(|path| path.titles[0].as_str()),
            old_after
        );
        assert_eq!(
            after
                .position
                .after
                .as_ref()
                .map(|path| path.titles[0].as_str()),
            new_after
        );
    }
}

#[tokio::test]
async fn cross_repository_move_routes_the_same_mapping_to_both_repositories_after_commit() {
    let mut source = Fixture::new("* TODO Moving\n** TODO Child\n").await;
    let target = Fixture::new("* TODO Target\n").await;
    let source_id = source.workspace.repos()[0].id.clone();
    let target_id = target.workspace.repos()[0].id.clone();
    source
        .workspace
        .add_repo(target.workspace.repos()[0].clone()).await
        .unwrap();
    // 订阅范围在创建时固定，新增仓库后重新建立本次监控。
    let observed = source.events.clone();
    source._subscription = source
        .workspace
        .watch_data_changes(move |event| observed.lock().unwrap().push(event));
    let group: TaskOperationGroup = serde_json::from_value(serde_json::json!({"operationId":"cross-repo","operations":[
        {"type":"Movement","data":{"path":{"repoId":source_id,"file":"a.org","titles":["Moving"]},
        "position":{"parent":{"repoId":target_id,"file":"a.org","titles":["Target"]}}}}
    ]})).unwrap();
    source
        .workspace
        .execute_task_operations(&group)
        .await
        .unwrap();
    let events = source.events.lock().unwrap();
    assert_eq!(events.len(), 2);
    for event in events.iter() {
        let DataChangeEvent::RepositoryChanged {
            repo_id,
            operation_id,
            files,
            changes,
            ..
        } = event;
        assert!([&source_id, &target_id].contains(&repo_id));
        assert_eq!(operation_id.as_deref(), Some("cross-repo"));
        assert_eq!(files.as_ref().unwrap().len(), 1);
        let moved = changes
            .iter()
            .filter(|change| change.kind == TaskDataChangeKind::Moved)
            .collect::<Vec<_>>();
        assert_eq!(moved.len(), 2);
        for change in moved {
            assert_eq!(change.before.as_ref().unwrap().task.repo_id(), source_id);
            assert_eq!(change.after.as_ref().unwrap().task.repo_id(), target_id);
        }
    }
    assert_eq!(std::fs::read(source.root.join("a.org")).unwrap(), b"");
    assert!(
        std::fs::read_to_string(target.root.join("a.org"))
            .unwrap()
            .contains("** TODO Moving\n*** TODO Child")
    );
}

#[tokio::test]
async fn repeated_moves_and_renames_in_one_group_keep_original_identity_and_final_position() {
    let f = Fixture::new("* TODO A\n* TODO B\n* TODO C\n").await;
    let group = f.group(serde_json::json!([
        {"type":"Movement","data":{"path":{"repoId":"$repo","file":"a.org","titles":["A"]},"position":{"parent":{"repoId":"$repo","file":"a.org","titles":["B"]}}}},
        {"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["B","A"]},"modifications":[{"field":"TITLE","value":"Renamed"}]}},
        {"type":"Movement","data":{"path":{"repoId":"$repo","file":"a.org","titles":["B","Renamed"]},"position":{"parent":{"repoId":"$repo","file":"a.org","titles":[]},"after":{"repoId":"$repo","file":"a.org","titles":["C"]}}}}
    ]));
    f.workspace.execute_task_operations(&group).await.unwrap();
    let events = f.events.lock().unwrap();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
    let moved = changes
        .iter()
        .find(|change| change.kind == TaskDataChangeKind::Moved)
        .unwrap();
    assert_eq!(
        moved.before.as_ref().unwrap().task.full_path().titles,
        ["A"]
    );
    assert_eq!(
        moved.after.as_ref().unwrap().task.full_path().titles,
        ["Renamed"]
    );
    assert_eq!(
        moved
            .after
            .as_ref()
            .unwrap()
            .position
            .after
            .as_ref()
            .unwrap()
            .titles,
        ["C"]
    );
    assert_eq!(
        changes
            .iter()
            .filter(|change| change.kind == TaskDataChangeKind::Moved)
            .count(),
        1
    );
}

#[tokio::test]
async fn trigger_cascade_properties_and_ancestor_statistics_publish_final_data_with_same_operation_id()
 {
    let source = "* TODO Parent [0/3]\n** TODO Source\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n** TODO Middle\n:PROPERTIES:\n:TRIGGER: next-sibling set-property!(\"STYLE\" \"habit\") todo!(DONE)\n:END:\n** TODO Last\n";
    let f = Fixture::new(source).await;
    let group = f.group(serde_json::json!([{"type":"Modification","data":{
        "path":{"repoId":"$repo","file":"a.org","titles":["Parent","Source"]},
        "modifications":[{"field":"TODO","value":"DONE"}]
    }}]));
    f.workspace.execute_task_operations(&group).await.unwrap();
    let events = f.events.lock().unwrap();
    assert_eq!(events.len(), 1);
    let DataChangeEvent::RepositoryChanged {
        changes,
        operation_id,
        ..
    } = &events[0];
    assert_eq!(operation_id.as_deref(), Some("operation-1"));
    for name in ["Source", "Middle", "Last"] {
        let change = changes
            .iter()
            .find(|change| {
                change.after.as_ref().is_some_and(|snapshot| {
                    snapshot
                        .task
                        .full_path()
                        .titles
                        .last()
                        .is_some_and(|title| title == name)
                })
            })
            .unwrap();
        assert_eq!(change.kind, TaskDataChangeKind::Updated);
        assert_eq!(
            change.before.as_ref().unwrap().task.state().unwrap().name,
            "TODO"
        );
        assert_eq!(
            change.after.as_ref().unwrap().task.state().unwrap().name,
            "DONE"
        );
    }
    let last = changes
        .iter()
        .find_map(|change| {
            change
                .after
                .as_ref()
                .filter(|snapshot| snapshot.task.title() == "Last")
        })
        .unwrap();
    assert!(last.task.is_habit());
    assert!(
        std::fs::read_to_string(f.root.join("a.org"))
            .unwrap()
            .contains(":STYLE: habit")
    );
    assert!(changes.iter().any(|change| {
        change
            .after
            .as_ref()
            .is_some_and(|snapshot| snapshot.task.title() == "Parent [3/3]")
    }));
    assert!(!f.root.join(".sync/outbox").exists());
}

#[tokio::test]
async fn failed_operation_after_trigger_discards_all_data_events_and_noop_is_silent() {
    let source =
        "* TODO Source\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Other\n";
    let f = Fixture::new(source).await;
    let failed = f.group(serde_json::json!([
        {"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Source"]},"modifications":[{"field":"TODO","value":"DONE"}]}},
        {"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Missing"]}}}
    ]));
    assert!(f.workspace.execute_task_operations(&failed).await.is_err());
    assert_eq!(
        std::fs::read_to_string(f.root.join("a.org")).unwrap(),
        source
    );
    assert!(f.events.lock().unwrap().is_empty());
    assert!(f.workspace.task_operation_history().entries.is_empty());
    let noop = f.group(serde_json::json!([{"type":"Modification","data":{
        "path":{"repoId":"$repo","file":"a.org","titles":["Source"]},
        "modifications":[{"field":"TITLE","value":"Source"}]
    }}]));
    f.workspace.execute_task_operations(&noop).await.unwrap();
    assert!(f.events.lock().unwrap().is_empty());
}

#[tokio::test]
async fn create_move_delete_coalesces_by_execution_identity_without_ghost_nodes() {
    let f = Fixture::new("* TODO Existing\n").await;
    tokio::fs::write(f.root.join("b.org"), "* TODO Target\n")
        .await
        .unwrap();
    let group = f.group(serde_json::json!([
        {"type":"Creation","data":{"position":{"parent":{"repoId":"$repo","file":"a.org","titles":[]}},"title":"New","state":"TODO"}},
        {"type":"Movement","data":{"path":{"repoId":"$repo","file":"a.org","titles":["New"]},"position":{"parent":{"repoId":"$repo","file":"b.org","titles":["Target"]}}}},
        {"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Existing"]}}}
    ]));
    f.workspace.execute_task_operations(&group).await.unwrap();
    let events = f.events.lock().unwrap();
    let DataChangeEvent::RepositoryChanged { changes, files, .. } = &events[0];
    assert_eq!(files.as_ref().unwrap().len(), 2);
    let created = changes
        .iter()
        .find(|change| change.kind == TaskDataChangeKind::Created)
        .unwrap();
    assert!(created.before.is_none());
    assert_eq!(
        created.after.as_ref().unwrap().task.full_path().titles,
        ["Target", "New"]
    );
    assert_eq!(created.after.as_ref().unwrap().task.path(), "b.org");
    let deleted = changes
        .iter()
        .find(|change| change.kind == TaskDataChangeKind::Deleted)
        .unwrap();
    assert_eq!(deleted.before.as_ref().unwrap().task.title(), "Existing");
    assert!(deleted.after.is_none());
    assert!(
        changes
            .iter()
            .all(|change| change.kind != TaskDataChangeKind::Moved)
    );
    assert_eq!(std::fs::read(f.root.join("a.org")).unwrap(), b"");
}
