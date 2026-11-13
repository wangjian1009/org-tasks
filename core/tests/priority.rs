use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(source: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-priority-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        tokio::fs::write(root.join("tasks.org"), source)
            .await
            .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self {
            root,
            workspace: OrgWorkspace::new(vec![repo]).unwrap(),
        }
    }
    async fn group(&self, title: &str, modifications: Vec<TaskModification>) -> TaskOperationGroup {
        let file = self.workspace.repos()[0].file("tasks.org").await.unwrap();
        let path = file
            .node_paths()
            .into_iter()
            .find(|path| path.titles.last().is_some_and(|value| value == title))
            .unwrap();
        TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path,
                modifications,
            })],
            queue_repo_ids: vec![file.repo_id.clone()],
            file_versions: vec![TaskFileVersion {
                repo_id: file.repo_id.clone(),
                file: file.path.clone(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
        }
    }
    fn source(&self) -> String {
        std::fs::read_to_string(self.root.join("tasks.org")).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn setup_configuration_snapshots_and_priority_writes_are_atomic_and_lossless() {
    let source = "#+SETUPFILE: .setup.org\r\n* TODO Task\r\n正文  \r\n* TODO [#Z] Legacy\r\n";
    let mut f = Fixture::new(source).await;
    std::fs::write(f.root.join(".setup.org"), "#+SETUPFILE: inner.org\n").unwrap();
    std::fs::write(f.root.join("inner.org"), "#+PRIORITIES: B D C\n").unwrap();
    let file = f.workspace.repos()[0].file("tasks.org").await.unwrap();
    let old = file.nodes();
    assert!(old[0].priority().is_none());
    assert_eq!(
        old[0].task_priority_of(PeriodCategory::Hight).unwrap().name,
        "B"
    );
    assert_eq!(old[1].priority().unwrap().category, None);
    let metadata = f
        .workspace
        .query(&[CoreQuery::File {
            query: FileQuery::default(),
        }])
        .await
        .unwrap()
        .remove(0)
        .into_files()
        .unwrap()
        .into_iter()
        .find(|item| item.path == "tasks.org")
        .unwrap();
    assert_eq!(metadata.priority_options(), old[0].priority_options());
    assert_eq!(&metadata.default_priority, old[0].default_priority());
    assert_eq!(old[0].default_priority().name, "C");
    assert_eq!(
        metadata.task_priority_of(PeriodCategory::Low).unwrap().name,
        "D"
    );
    let bad = f
        .group(
            "Task",
            vec![
                TaskModification::Title(Some("Changed".into())),
                TaskModification::Priority(Some("A".into())),
            ],
        )
        .await;
    assert!(
        f.workspace
            .execute_task_operations(&bad)
            .await
            .unwrap_err()
            .to_string()
            .contains("优先级不属于")
    );
    assert_eq!(f.source(), source);
    assert!(f.workspace.task_operation_history.entries.is_empty());
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
    let good = f
        .group("Task", vec![TaskModification::Priority(Some("B".into()))])
        .await;
    f.workspace.execute_task_operations(&good).await.unwrap();
    assert_eq!(
        f.source(),
        source.replacen("* TODO Task", "* TODO [#B] Task", 1)
    );
    assert!(f.workspace.execute_task_operations(&good).await.is_err());
    let stale_config = f
        .group(
            "Task",
            vec![
                TaskModification::Notes(Some("new".into())),
                TaskModification::Priority(Some("B".into())),
            ],
        )
        .await;
    std::fs::write(f.root.join("inner.org"), "#+PRIORITIES: C E D\n").unwrap();
    let saved = f.source();
    assert!(
        f.workspace
            .execute_task_operations(&stale_config)
            .await
            .is_err()
    );
    assert_eq!(f.source(), saved);
    let current = f.workspace.repos()[0]
        .file("tasks.org")
        .await
        .unwrap()
        .nodes();
    assert_eq!(current[0].priority().unwrap().name, "B");
    assert_eq!(current[0].priority().unwrap().category, None);
    assert_eq!(
        current[0]
            .task_priority_of(PeriodCategory::Hight)
            .unwrap()
            .name,
        "C"
    );
    assert_eq!(old[0].default_priority().name, "C");
    assert_eq!(current[0].default_priority().name, "D");
    assert_eq!(
        old[0].task_priority_of(PeriodCategory::Hight).unwrap().name,
        "B"
    );
    let clear = f
        .group("Task", vec![TaskModification::Priority(None)])
        .await;
    f.workspace.execute_task_operations(&clear).await.unwrap();
    assert_eq!(f.source(), source);
}

#[tokio::test]
async fn repository_loader_ignores_body_and_source_block_priority_keywords() {
    let source =
        "#+begin_src org\n#+PRIORITIES: A C B\n#+end_src\n* TODO Task\n#+PRIORITIES: B D C\n";
    let mut f = Fixture::new(source).await;
    let file = f.workspace.repos()[0].file("tasks.org").await.unwrap();
    assert!(file.nodes()[0].priority_options().is_empty());
    let group = f
        .group("Task", vec![TaskModification::Priority(Some("A".into()))])
        .await;
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(f.source(), source);
}

#[tokio::test]
async fn priority_sort_and_queries_use_each_files_default_without_writing_cookies() {
    let source = "#+PRIORITIES: A F D\n* TODO Unset D\n* TODO [#A] High\n* TODO [#D] Explicit D\n* TODO [#F] Low\n";
    let f = Fixture::new(source).await;
    std::fs::write(f.root.join("setup.org"), "#+PRIORITIES: A F C\n").unwrap();
    std::fs::write(
        f.root.join("inherited.org"),
        "#+SETUPFILE: setup.org\n* TODO Unset C\n",
    )
    .unwrap();
    std::fs::write(f.root.join("plain.org"), "* TODO Unset B\n").unwrap();
    let queries = ["o.priority", ".o.priority", "p.D", "ps.D", "p.C", "p.B"].map(|expression| {
        CoreQuery::from(TaskQuery {
            expression: expression.into(),
            ..Default::default()
        })
    });
    let results = f.workspace.query(&queries).await.unwrap();
    for (result, expected) in results.into_iter().zip([
        vec!["High", "Unset B", "Unset C", "Unset D", "Explicit D", "Low"],
        vec!["Low", "Unset D", "Explicit D", "Unset C", "Unset B", "High"],
        vec!["Unset D", "Explicit D"],
        vec!["Explicit D"],
        vec!["Unset C"],
        vec!["Unset B"],
    ]) {
        let tasks = result.into_task().unwrap().tasks;
        assert_eq!(
            tasks.iter().map(FilterTask::title).collect::<Vec<_>>(),
            expected
        );
        for task in tasks
            .iter()
            .filter(|task| task.title().starts_with("Unset"))
        {
            assert!(task.priority().is_none());
            assert_eq!(task.effective_priority(), task.default_priority());
        }
    }
    assert_eq!(f.source(), source);
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
}
