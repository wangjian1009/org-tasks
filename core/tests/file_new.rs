use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::fs;

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
    id: String,
}
impl Fixture {
    async fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "file-new-{}-{}",
            std::process::id(),
            FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let id = repo.id.clone();
        Self {
            root,
            workspace: OrgWorkspace::start(vec![repo]).await.unwrap(),
            id,
        }
    }
    fn operation(
        &self,
        file: &str,
        template: &str,
        tasks: Vec<TaskFileInitialTask>,
    ) -> TaskOperation {
        TaskOperation::FileNew(TaskFileNew {
            path: TaskPath::file(self.id.clone(), file.into()),
            template_path: String::new(),
            template_content: template.into(),
            arguments: BTreeMap::new(),
            init_tasks: tasks,
        })
    }
    async fn execute(&self, operations: Vec<TaskOperation>) -> Result<(), CoreError> {
        self.workspace
            .execute_task_operations(&TaskOperationGroup {
                operations,
                ..Default::default()
            })
            .await
    }
    async fn file(&self, name: &str) -> OrgFile {
        self.workspace.repos()[0].file(name).await.unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn task(title: &str) -> TaskFileInitialTask {
    TaskFileInitialTask {
        title: title.into(),
        state: Some("TODO".into()),
        ..Default::default()
    }
}

#[tokio::test]
async fn file_new_places_initial_tasks_using_the_first_root_and_preserves_order() {
    for (template, expected) in [
        ("#+TITLE: 项目\r\n", vec![(1, "甲"), (1, "乙")]),
        (
            "* 分组\n原正文\n** 原子项\n* 另一组\n",
            vec![
                (1, "分组"),
                (2, "甲"),
                (2, "乙"),
                (2, "原子项"),
                (1, "另一组"),
            ],
        ),
        (
            "* TODO 原任务\n** 子任务\n* 另一项\n",
            vec![
                (1, "原任务"),
                (2, "子任务"),
                (1, "甲"),
                (1, "乙"),
                (1, "另一项"),
            ],
        ),
    ] {
        let f = Fixture::new().await;
        f.execute(vec![f.operation(
            "project.org",
            template,
            vec![task("甲"), task("乙")],
        )])
        .await
        .unwrap();
        let file = f.file("project.org").await;
        let actual = file
            .node_paths()
            .into_iter()
            .map(|p| (p.titles.len(), p.titles.last().unwrap().clone()))
            .collect::<Vec<_>>();
        assert_eq!(
            actual,
            expected
                .into_iter()
                .map(|(n, t)| (n, t.to_owned()))
                .collect::<Vec<_>>()
        );
        let bytes = fs::read(f.root.join("project.org")).await.unwrap();
        assert!(String::from_utf8_lossy(&bytes).contains(":CREATED:"));
        assert_eq!(
            f.workspace.task_operation_history().entries[0]
                .fallback_group
                .files
                .len(),
            1
        );
    }
}

#[tokio::test]
async fn file_new_reads_template_arguments_and_root_setup_including_nested_targets() {
    let f = Fixture::new().await;
    fs::create_dir(f.root.join("projects")).await.unwrap();
    fs::write(
        f.root.join("template.org"),
        "#+TITLE: {{项目}}\n#+SETUPFILE:\n#+FILETAGS: :project:\n",
    )
    .await
    .unwrap();
    fs::write(f.root.join(".setup.org"), "#+TODO: READY | FINISHED\n")
        .await
        .unwrap();
    let mut op = f.operation(
        "projects/project.org",
        "",
        vec![TaskFileInitialTask {
            title: "初始任务".into(),
            state: Some("READY".into()),
            ..Default::default()
        }],
    );
    let TaskOperation::FileNew(data) = &mut op else {
        unreachable!()
    };
    data.template_path = "template.org".into();
    data.arguments.insert("项目".into(), "中文项目".into());
    f.execute(vec![op]).await.unwrap();
    let source = fs::read_to_string(f.root.join("projects/project.org"))
        .await
        .unwrap();
    assert!(source.contains("#+TITLE: 中文项目\n#+SETUPFILE: ../.setup.org\n"));
    let file = f.file("projects/project.org").await;
    assert_eq!(file.project().as_deref(), Some("中文项目"));
    assert_eq!(file.todo.pending_keywords, vec!["READY"]);
    assert_eq!(file.node_paths()[0].titles, vec!["初始任务"]);
}

#[tokio::test]
async fn file_new_inline_content_wins_and_missing_setup_keeps_an_empty_declaration() {
    let f = Fixture::new().await;
    let mut op = f.operation(
        "project.org",
        "#+TITLE: {{name}}\r\n#+SETUPFILE:\r\n",
        vec![],
    );
    let TaskOperation::FileNew(data) = &mut op else {
        unreachable!()
    };
    data.template_path = "missing.org".into();
    data.arguments.insert("name".into(), "项目".into());
    f.execute(vec![op]).await.unwrap();
    assert_eq!(
        fs::read(f.root.join("project.org")).await.unwrap(),
        "#+TITLE: 项目\r\n#+SETUPFILE:\r\n".as_bytes()
    );
    f.execute(vec![f.operation("empty.org", "", vec![])])
        .await
        .unwrap();
    assert_eq!(fs::read(f.root.join("empty.org")).await.unwrap(), b"");
}

#[tokio::test]
async fn file_new_rejects_existing_paths_missing_fields_invalid_tasks_and_duplicate_targets_atomically()
 {
    let f = Fixture::new().await;
    fs::write(f.root.join("exists.org"), b"").await.unwrap();
    assert!(
        f.execute(vec![f.operation("exists.org", "#+TITLE: 覆盖\n", vec![])])
            .await
            .is_err()
    );
    assert_eq!(fs::read(f.root.join("exists.org")).await.unwrap(), b"");
    for op in [
        f.operation("missing.org", "{{missing}}", vec![]),
        f.operation(
            "invalid.org",
            "",
            vec![TaskFileInitialTask {
                title: "任务".into(),
                state: Some("INVALID".into()),
                ..Default::default()
            }],
        ),
    ] {
        assert!(f.execute(vec![op]).await.is_err());
    }
    assert!(
        f.execute(vec![
            f.operation("duplicate.org", "一", vec![]),
            f.operation("duplicate.org", "二", vec![])
        ])
        .await
        .is_err()
    );
    for name in ["missing.org", "invalid.org", "duplicate.org"] {
        assert!(!f.root.join(name).exists());
    }
    assert!(f.workspace.task_operation_history().entries.is_empty());
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn file_new_and_movement_preserve_the_original_subtree_and_publish_both_file_changes() {
    let f = Fixture::new().await;
    let source = "前言\r\n* TODO 草稿 :work:\r\n:PROPERTIES:\r\n:CREATED: [2026-11-16 Mon 09:00]\r\n:END:\r\n正文  \r\n** TODO 子任务\r\n子正文\r\n* 保留\r\n";
    fs::write(f.root.join("inbox.org"), source).await.unwrap();
    let file = f.file("inbox.org").await;
    let path = file.node_paths()[0].clone();
    let changes = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let received = changes.clone();
    let _watch = f
        .workspace
        .watch_data_changes(move |event| received.lock().unwrap().push(event));
    let op = f.operation(
        "project.org",
        "#+TITLE: 项目\r\n#+FILETAGS: :project:\r\n",
        vec![],
    );
    let group = TaskOperationGroup {
        operations: vec![
            op,
            TaskOperation::Movement(TaskMovement {
                path,
                position: TaskPosition {
                    parent: TaskPath::file(f.id.clone(), "project.org".into()),
                    after: None,
                },
            }),
        ],
        file_versions: vec![TaskFileVersion {
            repo_id: f.id.clone(),
            file: "inbox.org".into(),
            version: LocalFileVersion::from_bytes(source.as_bytes()).content_hash,
        }],
        ..Default::default()
    };
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        fs::read_to_string(f.root.join("inbox.org")).await.unwrap(),
        "前言\r\n* 保留\r\n"
    );
    assert!(
        fs::read_to_string(f.root.join("project.org"))
            .await
            .unwrap()
            .ends_with(
                source
                    .split_once("前言\r\n")
                    .unwrap()
                    .1
                    .split_once("* 保留\r\n")
                    .unwrap()
                    .0
            )
    );
    assert_eq!(
        f.workspace.task_operation_history().entries[0]
            .fallback_group
            .files
            .len(),
        2
    );
    let events = serde_json::to_value(&*changes.lock().unwrap()).unwrap();
    assert_eq!(events[0]["files"].as_array().unwrap().len(), 2);
    assert!(
        events[0]["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["kind"] == "moved")
    );
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
}

#[tokio::test]
async fn failed_movement_after_file_new_leaves_source_new_file_and_outbox_unchanged() {
    let f = Fixture::new().await;
    fs::write(f.root.join("inbox.org"), "* TODO 原记录\n")
        .await
        .unwrap();
    let invalid = TaskPath {
        repo_id: f.id.clone(),
        file: Some("inbox.org".into()),
        titles: vec!["不存在".into()],
        occurrence: 1,
    };
    let ops = vec![
        f.operation("project.org", "#+TITLE: 项目\n", vec![task("初始化")]),
        TaskOperation::Movement(TaskMovement {
            path: invalid,
            position: TaskPosition {
                parent: TaskPath::file(f.id.clone(), "project.org".into()),
                after: None,
            },
        }),
    ];
    assert!(f.execute(ops).await.is_err());
    assert!(!f.root.join("project.org").exists());
    assert_eq!(
        fs::read_to_string(f.root.join("inbox.org")).await.unwrap(),
        "* TODO 原记录\n"
    );
    assert!(
        f.workspace.repos()[0]
            .pending_writes()
            .await
            .unwrap()
            .is_empty()
    );
}

#[test]
fn file_new_initial_tasks_are_creation_data_and_reject_source_paths() {
    let base = serde_json::json!({"type":"FileNew","data":{"path":{"repoId":"repo","file":"new.org","titles":[]},
        "initTasks":[{"title":"新任务","body":"正文","state":"TODO"}]}});
    assert!(serde_json::from_value::<TaskOperation>(base.clone()).is_ok());
    let mut invalid = base;
    invalid["data"]["initTasks"] =
        serde_json::json!([{"repoId":"repo","file":"inbox.org","titles":["旧任务"]}]);
    assert!(serde_json::from_value::<TaskOperation>(invalid).is_err());
}

#[tokio::test]
async fn project_template_assigns_unique_persistent_ids_and_resolves_optional_setup() {
    for has_setup in [false, true] {
        let f = Fixture::new().await;
        if has_setup {
            fs::write(f.root.join(".setup.org"), "#+TODO: READY | FINISHED\n")
                .await
                .unwrap();
        }
        let mut ids = Vec::new();
        for name in ["first.org", "second.org"] {
            let mut op = f.operation(name,
                ":PROPERTIES:\n:ID:\n:END:\n#+TITLE: {{name}}\n#+FILETAGS: :project:todo:\n#+SETUPFILE:\n",
                vec![TaskFileInitialTask { title: "初始任务".into(),
                    state: Some(if has_setup { "READY" } else { "TODO" }.into()), ..Default::default() }]);
            let TaskOperation::FileNew(data) = &mut op else {
                unreachable!()
            };
            data.arguments.insert("name".into(), "项目".into());
            f.execute(vec![op]).await.unwrap();
            let source = fs::read_to_string(f.root.join(name)).await.unwrap();
            let id = source
                .lines()
                .find_map(|line| line.strip_prefix(":ID: "))
                .unwrap();
            assert!(
                regex::Regex::new(
                    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
                )
                .unwrap()
                .is_match(id)
            );
            ids.push(id.to_owned());
            assert!(source.contains(if has_setup {
                "#+SETUPFILE: .setup.org\n"
            } else {
                "#+SETUPFILE:\n"
            }));
            let file = f.file(name).await;
            assert_eq!(file.project().as_deref(), Some("项目"));
            assert_eq!(file.file_tags(), vec!["project", "todo"]);
            assert_eq!(file.node_paths()[0].titles, vec!["初始任务"]);
            assert_eq!(fs::read_to_string(f.root.join(name)).await.unwrap(), source);
        }
        assert_ne!(ids[0], ids[1]);
    }
}
