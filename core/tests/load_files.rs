mod support;
use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;

struct Fixture {
    root: PathBuf,
    repo: OrgRepo,
}
impl Fixture {
    async fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-load-files-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        Self { root, repo }
    }
    async fn write(&self, path: &str, bytes: &[u8]) {
        let path = self.root.join(path);
        tokio::fs::create_dir_all(path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(path, bytes).await.unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn identity_loading_does_not_scan_parse_or_recover_business_state() {
    let mut f = Fixture::new().await;
    let id = f.repo.id.clone();
    f.write("invalid.org", &[0xff, 0xfe]).await;
    f.write("reset", b"unfinished or invalid business marker")
        .await;
    f.write("sync", b"unknown sync").await;
    f.write(".sync/history/broken.json", b"{").await;
    f.write(".sync/outbox/broken.json", b"{").await;
    assert!(f.repo.load::<WebDavSyncPolicy>().await.unwrap().is_empty());
    assert_eq!(f.repo.id, id);
    assert!(f.root.join("invalid.org").exists());
    assert!(f.root.join("reset").exists());
    assert!(f.repo.load_files(&[]).await.is_err());
}

#[tokio::test]
async fn each_load_reads_current_disk_and_previous_owned_results_stay_independent() {
    let f = Fixture::new().await;
    f.write("a.org", b"* Original\r\n").await;
    let configuration = f.repo.clone();
    let first = f.repo.load_files(&[]).await.unwrap();
    f.write("a.org", b"* Changed\n").await;
    f.write("nested/b.org", b"* Added\n").await;
    let second = f.repo.load_files(&[]).await.unwrap();
    assert_eq!(first[0].source_bytes(), b"* Original\r\n");
    assert_eq!(second[0].source_bytes(), b"* Changed\n");
    assert_eq!(
        second
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>(),
        ["a.org", "nested/b.org"]
    );
    tokio::fs::remove_file(f.root.join("a.org")).await.unwrap();
    assert_eq!(
        f.repo.load_files(&[]).await.unwrap()[0].path,
        "nested/b.org"
    );
    assert_eq!(f.repo, configuration);
}

#[tokio::test]
async fn relative_exclusions_apply_before_reading_and_parsing_and_do_not_become_patterns() {
    let f = Fixture::new().await;
    f.write("a.org", b"* A\n").await;
    f.write("nested/a.org", &[0xff]).await;
    f.write(".sync/private.org", &[0xff]).await;
    let files = f
        .repo
        .load_files(&["nested/a.org".into(), "*.org".into()])
        .await
        .unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "a.org");
    assert!(f.repo.load_files(&[]).await.is_err());
    for path in ["../a.org", "/a.org", "nested/../a.org", "nested\\a.org", ""] {
        assert!(f.repo.load_files(&[path.into()]).await.is_err(), "{path}");
    }
}

#[tokio::test]
async fn query_extracts_relative_exclusions_for_each_repository_before_file_loading() {
    let a = Fixture::new().await;
    let b = Fixture::new().await;
    a.write("same.org", &[0xff]).await;
    b.write(
        "same.org",
        b"#+CATEGORY: Work\n* TODO Visible\n- [ ] Item\n",
    )
    .await;
    let workspace = OrgWorkspace::start(vec![a.repo.clone(), b.repo.clone()]).await.unwrap();
    let result = workspace
        .query(&[(TaskQuery {
            exclude_files: vec![OrgFileRef {
                repo_id: a.repo.id.clone(),
                path: "same.org".into(),
            }],
            ..Default::default()
        }).into()])
        .await
        .unwrap().remove(0).into_task().unwrap();
    assert_eq!(result.tasks.len(), 1);
    assert_eq!(result.tasks[0].repo_id(), b.repo.id);
    assert_eq!(result.tasks[0].path(), "same.org");
    assert_eq!(result.categories[0].category.as_deref(), Some("Work"));
    let version = result.tasks[0].file_version().to_owned();
    let edit = result.tasks[0].edit_content().clone();
    b.write("same.org", b"* Entirely different\n").await;
    assert_eq!(result.tasks[0].file_version(), version);
    assert_eq!(result.tasks[0].edit_content(), &edit);
    assert_eq!(edit.checklist.len(), 1);
    assert_ne!(
        b.repo.file("same.org").await.unwrap().source_bytes(),
        b"#+CATEGORY: Work\n* TODO Visible\n- [ ] Item\n"
    );
    assert!(workspace.query(&[(TaskQuery::default()).into()]).await.is_err());
}

#[tokio::test]
async fn scan_rules_are_read_per_operation_and_do_not_hide_files_from_load_files() {
    let f = Fixture::new().await;
    f.write("a.org", b"* TODO A\n").await;
    f.write("b.org", b"* TODO B\n").await;
    f.write(".orgzlyignore", b"a.org\n").await;
    assert_eq!(f.repo.load_files(&[]).await.unwrap().len(), 2);
    let workspace = OrgWorkspace::start(vec![f.repo.clone()]).await.unwrap();
    let first = workspace.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap();
    assert_eq!(first.tasks[0].path(), "b.org");
    f.write(".orgzlyignore", b"b.org\n").await;
    let second = workspace.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap();
    assert_eq!(second.tasks[0].path(), "a.org");
    assert_eq!(first.tasks[0].path(), "b.org");
    assert!(support::query_files(&f.repo).await.unwrap()[1].is_ignore);
}

#[tokio::test]
async fn task_includes_skip_other_files_and_repositories_before_reading() {
    let a = Fixture::new().await;
    let b = Fixture::new().await;
    a.write("nested/selected.org", b"* TODO Selected\n").await;
    a.write("broken.org", &[0xff]).await;
    a.write("unrelated/broken.org", &[0xff]).await;
    b.write("nested/selected.org", &[0xff]).await;
    let reference = OrgFileRef { repo_id: a.repo.id.clone(), path: "nested/selected.org".into() };
    let workspace = OrgWorkspace::start(vec![a.repo.clone(), b.repo.clone()]).await.unwrap();
    let result = workspace.query(&[TaskQuery {
        include_files: vec![reference.clone(), reference],
        expression: "it.todo".into(),
        ..Default::default()
    }.into()]).await.unwrap().remove(0).into_task().unwrap();
    assert_eq!(result.tasks.len(), 1);
    assert_eq!(result.tasks[0].title(), "Selected");
    assert_eq!(result.tasks[0].repo_id(), a.repo.id);
}

#[tokio::test]
async fn task_and_file_ranges_subtract_exclusions_from_includes_before_reading() {
    let f = Fixture::new().await;
    f.write("selected.org", b"* TODO Selected\n").await;
    f.write("broken.org", &[0xff]).await;
    let selected = OrgFileRef { repo_id: f.repo.id.clone(), path: "selected.org".into() };
    let broken = OrgFileRef { repo_id: f.repo.id.clone(), path: "broken.org".into() };
    let workspace = OrgWorkspace::start(vec![f.repo.clone()]).await.unwrap();
    for include_files in [vec![], vec![selected.clone(), broken.clone()], vec![broken.clone()]] {
        let expected = usize::from(include_files.is_empty() || include_files.contains(&selected));
        let results = workspace.query(&[
            TaskQuery { include_files: include_files.clone(), exclude_files: vec![broken.clone()], ..Default::default() }.into(),
            CoreQuery::File { query: FileQuery { include_files, exclude_files: vec![broken.clone()], ..Default::default() } },
        ]).await.unwrap();
        assert_eq!(results[0].clone().into_task().unwrap().tasks.len(), expected);
        assert_eq!(results[1].clone().into_files().unwrap().len(), expected);
    }
}

#[tokio::test]
async fn mixed_query_ranges_load_the_union_and_do_not_hide_files_needed_by_other_queries() {
    let f = Fixture::new().await;
    f.write("a.org", b"* TODO A\n").await;
    f.write("b.org", b"* TODO B\n").await;
    f.write("broken.org", &[0xff]).await;
    let reference = |path: &str| OrgFileRef { repo_id: f.repo.id.clone(), path: path.into() };
    let workspace = OrgWorkspace::start(vec![f.repo.clone()]).await.unwrap();
    let a: CoreQuery = TaskQuery { include_files: vec![reference("a.org")], exclude_files: vec![reference("b.org")], ..Default::default() }.into();
    let b = CoreQuery::File { query: FileQuery { include_files: vec![reference("b.org")], ..Default::default() } };
    let results = workspace.query(&[a.clone(), b]).await.unwrap();
    assert_eq!(results[0].clone().into_task().unwrap().tasks[0].title(), "A");
    assert_eq!(results[1].clone().into_files().unwrap()[0].path, "b.org");
    for other in [
        TaskQuery { include_files: vec![reference("broken.org")], ..Default::default() }.into(),
        CoreQuery::File { query: FileQuery { include_files: vec![reference("broken.org")], ..Default::default() } },
        CoreQuery::Notification { query: NotificationQuery {}, repo_ids: None },
    ] {
        assert!(workspace.query(&[a.clone(), other]).await.is_err());
    }
}

#[tokio::test]
async fn removed_book_conditions_and_invalid_file_scopes_are_rejected() {
    let f = Fixture::new().await;
    f.write("selected.org", b"* TODO b.selected.org\n").await;
    let workspace = OrgWorkspace::start(vec![f.repo.clone()]).await.unwrap();
    for expression in ["b.selected.org", ".b.selected.org", "it.todo (b.\"selected.org\")"] {
        assert!(matches!(workspace.query(&[TaskQuery { expression: expression.into(), ..Default::default() }.into()]).await,
            Err(CoreError::InvalidInput(_))));
    }
    let result = workspace.query(&[TaskQuery { expression: "\"b.selected.org\"".into(), ..Default::default() }.into()]).await.unwrap();
    assert_eq!(result[0].clone().into_task().unwrap().tasks.len(), 1);
    for path in ["", "../selected.org", "/selected.org", "a\\selected.org"] {
        assert!(workspace.query(&[TaskQuery { include_files: vec![OrgFileRef { repo_id: f.repo.id.clone(), path: path.into() }], ..Default::default() }.into()]).await.is_err());
    }
    assert!(workspace.query(&[TaskQuery { include_files: vec![OrgFileRef { repo_id: "unknown".into(), path: "selected.org".into() }], ..Default::default() }.into()]).await.is_err());
    assert!(serde_json::from_value::<TaskQuery>(serde_json::json!({"excludedFiles":[]})).is_err());
}
