use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

struct Fixture {
    root: std::path::PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(files: &[(&str, &str)]) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "query-subscription-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        for (path, source) in files {
            std::fs::write(root.join(path), source).unwrap();
        }
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self {
            root,
            workspace: OrgWorkspace::start(vec![repo]).await.unwrap(),
        }
    }
    fn group(&self, operations: serde_json::Value) -> TaskOperationGroup {
        serde_json::from_str(
            &serde_json::to_string(&serde_json::json!({
                "operationId":"same-user-operation", "operations":operations
            }))
            .unwrap()
            .replace("$repo", &self.workspace.repos()[0].id),
        )
        .unwrap()
    }
    async fn apply(&mut self, operations: serde_json::Value) {
        let group = self.group(operations);
        self.workspace
            .execute_task_operations(&group)
            .await
            .unwrap();
    }
    async fn subscribe(&self, query: CoreQuery) -> (QuerySubscription, Receiver) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let capture = events.clone();
        let started = self
            .workspace
            .subscribe_query(vec![QuerySubscriptionRequest::new(query, move |event| capture.lock().unwrap().push(event))])
            .await
            .unwrap().remove(0);
        (
            started.subscription,
            Receiver {
                data: started.data,
                events,
            },
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct Receiver {
    data: CoreQueryResult,
    events: Arc<Mutex<Vec<DataChangeEvent>>>,
}
impl Receiver {
    fn consume(&mut self) -> Vec<DataChangeEvent> {
        let events = std::mem::take(&mut *self.events.lock().unwrap());
        for event in &events {
            let DataChangeEvent::RepositoryChanged {
                files,
                changes,
                removed_files,
                categories,
                ..
            } = event;
            match &mut self.data {
                CoreQueryResult::Task(result) => {
                    // 同一文件的重名序号可能互换，批量移除旧身份后再加入新身份。
                    result.tasks.retain(|task| {
                        !changes
                            .iter()
                            .filter_map(|change| change.before.as_ref())
                            .any(|before| {
                                before.task.repo_id() == task.repo_id()
                                    && before.task.id() == task.id()
                            })
                    });
                    result.tasks.extend(
                        changes
                            .iter()
                            .filter_map(|change| change.after.as_ref())
                            .map(|after| after.task.clone()),
                    );
                    if let Some(categories) = categories {
                        result.categories = categories.clone();
                    }
                }
                CoreQueryResult::File(result) => {
                    result.retain(|item| {
                        !files.iter().flatten().any(|file| {
                            item.repo_id == file.after.repo_id && item.path == file.after.path
                        }) && !removed_files
                            .iter()
                            .any(|file| item.repo_id == file.repo_id && item.path == file.path)
                    });
                    result.extend(files.iter().flatten().map(|file| file.after.clone()));
                }
                CoreQueryResult::Notification(_) => unreachable!(),
            }
        }
        events
    }
    async fn assert_matches(&mut self, workspace: &OrgWorkspace, query: &CoreQuery) {
        self.consume();
        // 仅作为测试预期使用普通查询；生产订阅从不执行后续查询。
        let expected = workspace
            .query(std::slice::from_ref(query))
            .await
            .unwrap()
            .remove(0);
        match (&self.data, expected) {
            (CoreQueryResult::Task(actual), CoreQueryResult::Task(expected)) => {
                let as_map = |tasks: &[FilterTask]| {
                    tasks
                        .iter()
                        .map(|task| (task.full_path().clone(), task.clone()))
                        .collect::<BTreeMap<_, _>>()
                };
                assert_eq!(as_map(&actual.tasks), as_map(&expected.tasks));
                assert_eq!(actual.tasks.len(), expected.tasks.len());
                assert_eq!(actual.categories, expected.categories);
            }
            (CoreQueryResult::File(actual), CoreQueryResult::File(expected)) => {
                let as_map = |files: &[OrgFileMetadata]| {
                    files
                        .iter()
                        .map(|file| ((file.repo_id.clone(), file.path.clone()), file.clone()))
                        .collect::<BTreeMap<_, _>>()
                };
                assert_eq!(as_map(actual), as_map(&expected));
            }
            _ => panic!("初始查询和订阅数据类型必须一致"),
        }
    }
}

#[tokio::test]
async fn create_update_query_exit_and_entity_delete_are_filtered_without_operation_id_deduplication()
 {
    let mut f = Fixture::new(&[("a.org", "* TODO Visible :work:\n* TODO Hidden\n")]).await;
    let query: CoreQuery = TaskQuery {
        expression: "it.todo t.work".into(),
        ..Default::default()
    }
    .into();
    let (mut subscription, mut receiver) = f.subscribe(query.clone()).await;
    let CoreQueryResult::Task(initial) = &receiver.data else {
        unreachable!()
    };
    assert_eq!(initial.tasks.len(), 1);
    assert_eq!(initial.tasks[0].title(), "Visible");
    for (title, modifications, kind) in [
        (
            "Hidden",
            serde_json::json!([{"field":"TAGS","value":["work"]}]),
            TaskDataChangeKind::Created,
        ),
        (
            "Visible",
            serde_json::json!([{"field":"TODO","value":"DONE"}]),
            TaskDataChangeKind::Deleted,
        ),
        (
            "Hidden",
            serde_json::json!([{"field":"PRIORITY","value":"A"}]),
            TaskDataChangeKind::Updated,
        ),
    ] {
        f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":[title]},"modifications":modifications}}])).await;
        let events = receiver.consume();
        assert_eq!(events.len(), 1);
        let DataChangeEvent::RepositoryChanged {
            changes,
            operation_id,
            ..
        } = &events[0];
        assert_eq!(operation_id.as_deref(), Some("same-user-operation"));
        assert!(changes.iter().any(|change| {
            change.kind == kind
                && change
                    .after
                    .as_ref()
                    .or(change.before.as_ref())
                    .unwrap()
                    .task
                    .title()
                    == title
        }));
        receiver.assert_matches(&f.workspace, &query).await;
        assert_eq!(
            f.workspace.query_subscription_status(&subscription),
            QuerySubscriptionStatus::Current
        );
    }
    f.apply(serde_json::json!([{"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Hidden"]}}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, TaskDataChangeKind::Deleted);
    assert!(changes[0].after.is_none());
    receiver.assert_matches(&f.workspace, &query).await;
    f.apply(serde_json::json!([{"type":"Creation","data":{"position":{"parent":{"repoId":"$repo","file":"a.org","titles":[]}},"title":"New","state":"TODO","tags":["work"]}}])).await;
    receiver.assert_matches(&f.workspace, &query).await;
    let failed = f.group(serde_json::json!([
        {"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["New"]},"modifications":[{"field":"TITLE","value":"Changed"}]}},
        {"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Missing"]}}}
    ]));
    assert!(f.workspace.execute_task_operations(&failed).await.is_err());
    assert!(receiver.consume().is_empty());
    f.workspace.unsubscribe_query(&mut subscription);
    assert_eq!(
        f.workspace.query_subscription_status(&subscription),
        QuerySubscriptionStatus::Closed
    );
    f.apply(serde_json::json!([{"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["New"]}}}])).await;
    assert!(receiver.consume().is_empty());
}

#[tokio::test]
async fn parent_membership_is_retained_when_children_are_created_and_removed() {
    let mut f = Fixture::new(&[("a.org", "* TODO Parent\n")]).await;
    let query: CoreQuery = TaskQuery {
        expression: "it.todo".into(),
        ..Default::default()
    }
    .into();
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    f.apply(serde_json::json!([{"type":"Creation","data":{"position":{"parent":{"repoId":"$repo","file":"a.org","titles":["Parent"]}},"title":"Child","state":"TODO"}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
    assert!(
        !changes
            .iter()
            .any(|change| change.kind == TaskDataChangeKind::Deleted
                && change.before.as_ref().unwrap().task.title() == "Parent")
    );
    assert!(
        changes
            .iter()
            .any(|change| change.kind == TaskDataChangeKind::Created
                && change.after.as_ref().unwrap().task.title() == "Child")
    );
    receiver.assert_matches(&f.workspace, &query).await;
    f.apply(serde_json::json!([{"type":"Deletion","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Parent","Child"]}}}])).await;
    receiver.assert_matches(&f.workspace, &query).await;
    let CoreQueryResult::Task(result) = &receiver.data else {
        unreachable!()
    };
    assert_eq!(result.tasks[0].title(), "Parent");
}

#[tokio::test]
async fn duplicate_path_reindexing_and_same_file_movement_keep_all_members() {
    let mut f = Fixture::new(&[("a.org", "* TODO Item\n* TODO Item\n* TODO Group\n")]).await;
    let query: CoreQuery = TaskQuery::default().into();
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    f.apply(serde_json::json!([{"type":"Movement","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Item"],"occurrence":1},"position":{"parent":{"repoId":"$repo","file":"a.org","titles":["Group"]}}}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
    assert_eq!(
        changes
            .iter()
            .filter(|change| change.kind == TaskDataChangeKind::Moved)
            .count(),
        1
    );
    receiver.assert_matches(&f.workspace, &query).await;
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Group"]},"modifications":[{"field":"TITLE","value":"Renamed"}]}}])).await;
    receiver.assert_matches(&f.workspace, &query).await;
}

#[tokio::test]
async fn category_summary_tracks_unselected_categories_without_caching_their_records() {
    let mut f = Fixture::new(&[
        ("a.org", "#+CATEGORY: Work\n* TODO A\n"),
        ("b.org", "#+CATEGORY: Personal\n* TODO B\n"),
    ])
    .await;
    let query: CoreQuery = TaskQuery {
        expression: "it.todo".into(),
        categories: vec![Some("Work".into())],
        ..Default::default()
    }
    .into();
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"b.org","titles":["B"]},"modifications":[{"field":"TODO","value":"DONE"}]}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged {
        changes,
        categories,
        ..
    } = &events[0];
    assert!(changes.is_empty());
    assert_eq!(
        categories
            .as_ref()
            .unwrap()
            .iter()
            .map(|category| category.category.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("Work")]
    );
    receiver.assert_matches(&f.workspace, &query).await;
}

#[tokio::test]
async fn file_query_tag_membership_emits_file_insertions_and_removals() {
    let mut f = Fixture::new(&[
        ("a.org", "#+FILETAGS: :project:\n* TODO A\n"),
        ("b.org", "* TODO Other :work:\n"),
    ])
    .await;
    let query = CoreQuery::File {
        query: FileQuery {
            file_tags: vec!["work".into()],
            is_project: Some(true),
            ..Default::default()
        },
    };
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    assert!(matches!(&receiver.data, CoreQueryResult::File(files) if files.is_empty()));
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["A"]},"modifications":[{"field":"TAGS","value":["work"]}]}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged { files, changes, .. } = &events[0];
    assert!(changes.is_empty());
    assert_eq!(files.as_ref().unwrap().len(), 1);
    assert!(files.as_ref().unwrap()[0].before.is_none());
    receiver.assert_matches(&f.workspace, &query).await;
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["A"]},"modifications":[{"field":"TAGS","value":[]}]}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged {
        files,
        removed_files,
        ..
    } = &events[0];
    assert!(files.as_ref().unwrap().is_empty());
    assert_eq!(removed_files[0].path, "a.org");
    assert!(f.root.join("a.org").is_file());
    receiver.assert_matches(&f.workspace, &query).await;
}

#[tokio::test]
async fn cross_repository_movement_updates_each_scope_and_keeps_the_operation_id() {
    let source = Fixture::new(&[("a.org", "* TODO Moving\n** TODO Child\n")]).await;
    let target = Fixture::new(&[("a.org", "* TODO Target\n")]).await;
    let source_id = source.workspace.repos()[0].id.clone();
    let target_id = target.workspace.repos()[0].id.clone();
    source
        .workspace
        .add_repo(target.workspace.repos()[0].clone()).await
        .unwrap();
    let all: CoreQuery = TaskQuery::default().into();
    let only_source = CoreQuery::Task {
        query: TaskQuery::default(),
        repo_ids: vec![source_id.clone()],
    };
    let only_target = CoreQuery::Task {
        query: TaskQuery::default(),
        repo_ids: vec![target_id.clone()],
    };
    let (_a, mut a) = source.subscribe(all.clone()).await;
    let (_s, mut s) = source.subscribe(only_source.clone()).await;
    let (_t, mut t) = source.subscribe(only_target.clone()).await;
    source.workspace.execute_task_operations(&serde_json::from_value(serde_json::json!({"operationId":"cross-repo","operations":[
        {"type":"Movement","data":{"path":{"repoId":source_id,"file":"a.org","titles":["Moving"]},"position":{"parent":{"repoId":target_id,"file":"a.org","titles":["Target"]}}}}
    ]})).unwrap()).await.unwrap();
    assert_eq!(a.events.lock().unwrap().len(), 2);
    for event in a.events.lock().unwrap().iter() {
        let DataChangeEvent::RepositoryChanged { operation_id, .. } = event;
        assert_eq!(operation_id.as_deref(), Some("cross-repo"));
    }
    a.assert_matches(&source.workspace, &all).await;
    s.assert_matches(&source.workspace, &only_source).await;
    t.assert_matches(&source.workspace, &only_target).await;
}

#[tokio::test]
async fn trigger_cascade_and_system_tag_expressions_use_raw_events_but_return_display_tags() {
    let mut f = Fixture::new(&[("a.org", "* TODO Source :REFILE:\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Target :REFILE:\n")]).await;
    let query: CoreQuery = TaskQuery {
        expression: "it.todo tn.REFILE".into(),
        ..Default::default()
    }
    .into();
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["Source"]},"modifications":[{"field":"TODO","value":"DONE"}]}}])).await;
    let events = receiver.consume();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &events[0];
    assert_eq!(changes.len(), 2);
    assert!(
        changes
            .iter()
            .all(|change| change.kind == TaskDataChangeKind::Deleted
                && change.before.as_ref().unwrap().task.own_tags().is_empty())
    );
    receiver.assert_matches(&f.workspace, &query).await;
}

#[tokio::test]
async fn unsupported_and_invalid_queries_fail_without_affecting_other_subscriptions() {
    let f = Fixture::new(&[("a.org", "* TODO A\n")]).await;
    assert!(
        f.workspace
            .subscribe_query(vec![QuerySubscriptionRequest::new(
                CoreQuery::Notification {
                    query: Default::default()
                },
                |_| panic!("不应发布事件")
            )])
            .await
            .is_err()
    );
    assert!(
        f.workspace
            .subscribe_query(vec![QuerySubscriptionRequest::new(
                CoreQuery::Task {
                    query: TaskQuery::default(),
                    repo_ids: vec!["missing".into()]
                },
                |_| panic!("不应发布事件")
            )])
            .await
            .is_err()
    );
    let (subscription, _) = f.subscribe(TaskQuery::default().into()).await;
    assert_eq!(
        f.workspace.query_subscription_status(&subscription),
        QuerySubscriptionStatus::Current
    );
}

#[tokio::test]
async fn excluded_ignored_and_unchanged_records_do_not_produce_member_events() {
    let mut f = Fixture::new(&[
        ("a.org", "* TODO A\n"),
        ("b.org", "* TODO B\n"),
        ("c.org", "* TODO C\n"),
        (".orgzlyignore", "c.org\n"),
    ])
    .await;
    let query: CoreQuery = TaskQuery {
        exclude_files: vec![OrgFileRef {
            repo_id: f.workspace.repos()[0].id.clone(),
            path: "b.org".into(),
        }],
        ..Default::default()
    }
    .into();
    let (subscription, mut receiver) = f.subscribe(query.clone()).await;
    for (file, title, new_title) in [
        ("b.org", "B", "Changed B"),
        ("c.org", "C", "Changed C"),
        ("a.org", "A", "A"),
    ] {
        f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":file,"titles":[title]},"modifications":[{"field":"TITLE","value":new_title}]}}])).await;
        assert!(receiver.consume().is_empty());
    }
    assert_eq!(
        f.workspace.query_subscription_status(&subscription),
        QuerySubscriptionStatus::Current
    );
    receiver.assert_matches(&f.workspace, &query).await;
}

#[tokio::test]
async fn new_files_enter_empty_task_and_file_subscriptions_from_the_same_creation_event() {
    let mut f = Fixture::new(&[]).await;
    let tasks: CoreQuery = TaskQuery::default().into();
    let files = CoreQuery::File {
        query: FileQuery::default(),
    };
    let (_task_sub, mut task_data) = f.subscribe(tasks.clone()).await;
    let (_file_sub, mut file_data) = f.subscribe(files.clone()).await;
    f.apply(serde_json::json!([{"type":"Creation","data":{"position":{"parent":{"repoId":"$repo","file":"a.org","titles":[]}},"title":"First","state":"TODO"}}])).await;
    let task_events = task_data.consume();
    let DataChangeEvent::RepositoryChanged { changes, .. } = &task_events[0];
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, TaskDataChangeKind::Created);
    task_data.assert_matches(&f.workspace, &tasks).await;
    file_data.assert_matches(&f.workspace, &files).await;
}

#[tokio::test]
async fn included_file_subscription_ignores_other_files_and_tracks_membership_changes() {
    let mut f = Fixture::new(&[("a.org", "* TODO A\n"), ("b.org", "* TODO B\n")]).await;
    let reference = |path: &str| OrgFileRef { repo_id: f.workspace.repos()[0].id.clone(), path: path.into() };
    let query: CoreQuery = TaskQuery {
        expression: "it.todo".into(),
        include_files: vec![reference("a.org"), reference("b.org")],
        exclude_files: vec![reference("b.org")],
        ..Default::default()
    }.into();
    let (_subscription, mut receiver) = f.subscribe(query.clone()).await;
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"b.org","titles":["B"]},"modifications":[{"field":"TITLE","value":"Other"}]}}])).await;
    assert!(receiver.consume().is_empty());
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["A"]},"modifications":[{"field":"TODO","value":"DONE"}]}}])).await;
    receiver.assert_matches(&f.workspace, &query).await;
    assert!(receiver.data.clone().into_task().unwrap().tasks.is_empty());
    f.apply(serde_json::json!([{"type":"Modification","data":{"path":{"repoId":"$repo","file":"a.org","titles":["A"]},"modifications":[{"field":"TODO","value":"TODO"}]}}])).await;
    receiver.assert_matches(&f.workspace, &query).await;
    assert_eq!(receiver.data.clone().into_task().unwrap().tasks.len(), 1);
}
