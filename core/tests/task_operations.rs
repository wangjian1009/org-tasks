use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::path::PathBuf;
use tokio::fs;

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(source: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "org-operations-{}-{}",
            std::process::id(),
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
    fn group(&self, title: &str) -> TaskOperationGroup {
        let path = self.workspace.repos()[0].files()[0].node_paths()[0].clone();
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
async fn successful_groups_accumulate_exact_fallbacks_and_failed_group_does_not_publish() {
    let source = "* TODO Original\r\nBody  \r\n";
    let mut f = Fixture::new(source).await;
    let first = f
        .workspace
        .execute_task_operations(&f.group("One"))
        .await
        .unwrap();
    assert_eq!(first.fallback.files[0].before.as_deref(), Some(source));
    assert_eq!(first.paths[0].as_ref().unwrap().titles, ["One"]);
    f.workspace
        .execute_task_operations(&f.group("Two"))
        .await
        .unwrap();
    let snapshot = f.workspace.clone();
    let mut invalid = f.group("Three");
    invalid
        .operations
        .push(TaskOperation::Deletion(TaskDeletion {
            path: TaskPath {
                titles: vec!["Missing".into()],
                ..first.paths[0].clone().unwrap()
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
    let mut group = f.group("Changed");
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
            .execute_task_operations(&f.group("Changed"))
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
    let tasks = f.workspace.search(&Filter::parse(""));
    assert!(tasks[0].created_at.is_some());
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
        let mut group = f.group("Changed");
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
