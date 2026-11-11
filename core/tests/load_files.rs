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
    let workspace = OrgWorkspace::new(vec![a.repo.clone(), b.repo.clone()]).unwrap();
    let result = workspace
        .query(&[TaskQuery {
            excluded_files: vec![OrgFileRef {
                repo_id: a.repo.id.clone(),
                path: "same.org".into(),
            }],
            ..Default::default()
        }])
        .await
        .unwrap().remove(0);
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
    assert!(workspace.query(&[TaskQuery::default()]).await.is_err());
}

#[tokio::test]
async fn scan_rules_are_read_per_operation_and_do_not_hide_files_from_load_files() {
    let f = Fixture::new().await;
    f.write("a.org", b"* TODO A\n").await;
    f.write("b.org", b"* TODO B\n").await;
    f.write(".orgzlyignore", b"a.org\n").await;
    assert_eq!(f.repo.load_files(&[]).await.unwrap().len(), 2);
    let workspace = OrgWorkspace::new(vec![f.repo.clone()]).unwrap();
    let first = workspace.query(&[TaskQuery::default()]).await.unwrap().remove(0);
    assert_eq!(first.tasks[0].path(), "b.org");
    f.write(".orgzlyignore", b"b.org\n").await;
    let second = workspace.query(&[TaskQuery::default()]).await.unwrap().remove(0);
    assert_eq!(second.tasks[0].path(), "a.org");
    assert_eq!(first.tasks[0].path(), "b.org");
    assert!(f.repo.file_metadata().await.unwrap()[1].is_ignore);
}
