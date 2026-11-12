use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    files: BTreeMap<PathBuf, Vec<u8>>,
    directories: BTreeSet<PathBuf>,
}

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
    events: Arc<AtomicUsize>,
    _subscription: DataChangeSubscription,
}
impl Fixture {
    async fn new(files: &[(&str, &str)]) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-trigger-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        for (path, source) in files {
            let path = root.join(path);
            tokio::fs::create_dir_all(path.parent().unwrap())
                .await
                .unwrap();
            tokio::fs::write(path, source).await.unwrap();
        }
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let events = Arc::new(AtomicUsize::new(0));
        let observed = events.clone();
        let subscription = workspace.watch_data_changes(move |_| {
            observed.fetch_add(1, Ordering::Relaxed);
        });
        Self {
            root,
            workspace,
            events,
            _subscription: subscription,
        }
    }
    async fn group(&self) -> TaskOperationGroup {
        let file = self.workspace.repos()[0].file("tasks.org").await.unwrap();
        let path = file
            .node_paths()
            .into_iter()
            .find(|path| path.titles.last().is_some_and(|s| s == "Task"))
            .unwrap();
        TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path,
                modifications: vec![TaskModification::Todo(Some("DONE".into()))],
            })],
            file_versions: vec![TaskFileVersion {
                repo_id: file.repo_id.clone(),
                file: file.path.clone(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
            queue_repo_ids: vec![file.repo_id.clone()],
        }
    }
    fn source(&self) -> String {
        std::fs::read_to_string(self.root.join("tasks.org")).unwrap()
    }
    fn snapshot(&self) -> Snapshot {
        fn collect(root: &Path, at: &Path, snapshot: &mut Snapshot) {
            for entry in std::fs::read_dir(at).unwrap() {
                let entry = entry.unwrap();
                let path = entry.path();
                if path.is_dir() {
                    snapshot
                        .directories
                        .insert(path.strip_prefix(root).unwrap().into());
                    collect(root, &path, snapshot);
                } else if entry.file_name() != ".transaction.lock" {
                    snapshot.files.insert(
                        path.strip_prefix(root).unwrap().into(),
                        std::fs::read(path).unwrap(),
                    );
                }
            }
        }
        let mut snapshot = Snapshot {
            files: BTreeMap::new(),
            directories: BTreeSet::new(),
        };
        collect(&self.root, &self.root, &mut snapshot);
        snapshot
    }
    async fn assert_rollback(&mut self, group: &TaskOperationGroup, fragment: &str) {
        let before = self.snapshot();
        let error = self
            .workspace
            .execute_task_operations(group)
            .await
            .unwrap_err();
        assert!(
            error.to_string().contains(fragment),
            "预期 {fragment:?}，实际 {error}"
        );
        assert_eq!(
            self.snapshot(),
            before,
            "失败时必须保留普通文件、历史及同步控制数据的全部字节"
        );
        assert!(self.workspace.task_operation_history.entries.is_empty());
        assert_eq!(self.events.load(Ordering::Relaxed), 0);
        assert!(
            self.workspace.repos()[0]
                .pending_writes()
                .await
                .unwrap()
                .is_empty()
        );
    }
    async fn assert_one_commit(&self, before: &str) {
        assert_eq!(self.events.load(Ordering::Relaxed), 1);
        let history = &self.workspace.task_operation_history.entries;
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].fallback_group.files.len(), 1);
        let file = &history[0].fallback_group.files[0];
        assert_eq!(file.before.as_deref(), Some(before));
        assert_eq!(file.after, self.source());
        assert_eq!(
            self.workspace.repos()[0]
                .pending_writes()
                .await
                .unwrap()
                .len(),
            1
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test]
async fn invalid_supported_actions_and_syntax_preserve_every_file_and_publish_nothing() {
    for (trigger, expected) in [
        (
            "self set-property!(\"TOUCHED\" \"yes\") todo!(INVALID)",
            "状态",
        ),
        ("self todo!", "缺少参数"),
        ("self tag!(\":bad tag:\")", "标签"),
        ("self set-priority!(\"AA\")", "优先级"),
        ("self scheduled!(\"+1d\")", "不存在"),
        ("self deadline!(copy)", "来源没有"),
        ("self scheduled!(\"++1q\")", "单位"),
        ("self scheduled!(\"++99999999999999999y\")", "范围"),
        ("self set-property!(\"MISSING\" inc)", "未设置"),
        ("self set-property!(\"COUNT\" inc)", "数值"),
        ("self set-property!(\"MISSING\" next)", "未设置"),
        ("self set-property!(\"COUNT\" next)", "允许值"),
        ("self set-property!(\"BAD:NAME\" \"value\")", "属性名称"),
        ("self set-property!(\"TEXT\" \"line1\\nline2\")", "属性名称"),
        ("self set-property!(\"CREATED\" \"changed\")", "时间"),
        ("self set-property!(\"CREATED+\" \"changed\")", "时间"),
        ("self set-property!(\"CLOSED\" \"changed\")", "时间"),
        ("self set-property!(\"CLOSED+\" \"changed\")", "时间"),
        ("self delete-property!(\"created\")", "时间"),
        ("self delete-property!(\"CLOSED+\")", "时间"),
        ("self set-effort!(increment)", "下一个"),
        ("self scheduled!(\"++1d\")", "EDNA_TS_FORMAT"),
        (
            "if self re-search?(\"[\") then self tag!(\":x:\") endif",
            "正则",
        ),
        ("self set-property!(\"TEXT\" \"unfinished)", "字符串"),
        ("self set-property!(\"TEXT\" \"value\"", "括号"),
        ("then self todo!(DONE)", "标记"),
        ("if self done?", "then"),
        ("if self done? self todo!(DONE) endif", "标记"),
        ("if self done? then self todo!(DONE)", "endif"),
        ("if self todo!(DONE) then self todo!(DONE) endif", "上下文"),
        ("self done?", "上下文"),
        ("self todo!(TODO) todo!(DONE)", "循环"),
    ] {
        // 非法格式仅用于对应场景，其他动作不读取它。
        let source = format!(
            "#+TODO: TODO | DONE(!)\n#+STARTUP: logdone logrepeat logdrawer\n* TODO Task\n:PROPERTIES:\n:TRIGGER: {trigger}\n:COUNT: not_a_number\n:EFFORT: 1:00\n:EFFORT_ALL: 0:30 1:00\n:EDNA_TS_FORMAT: invalid\n:CREATED: [2026-01-01 Thu]\n:END:\n正文  \n* Other\n保留\n"
        );
        let mut f =
            Fixture::new(&[("tasks.org", &source), ("other.org", "* TODO External\n")]).await;
        let group = f.group().await;
        f.assert_rollback(&group, expected).await;
    }
}

#[tokio::test]
async fn duplicate_ids_and_task_dependencies_are_validated_for_trigger_targets() {
    for (trigger, targets, expected) in [
        (
            "ids(\"duplicate\") todo!(DONE)",
            "* TODO A\n:PROPERTIES:\n:ID: duplicate\n:END:\n* TODO B\n:PROPERTIES:\n:ID: duplicate\n:END:\n",
            "不唯一",
        ),
        (
            "ids(\"parent\") todo!(DONE)",
            "* TODO Parent\n:PROPERTIES:\n:ID: parent\n:END:\n** TODO Child\n",
            "子任务",
        ),
    ] {
        let source = format!(
            "* TODO Task\n:PROPERTIES:\n:TRIGGER: self set-property!(\"BEFORE\" \"changed\") {trigger}\n:END:\n{targets}"
        );
        let mut f = Fixture::new(&[("tasks.org", &source)]).await;
        let group = f.group().await;
        f.assert_rollback(&group, expected).await;
    }
}

#[tokio::test]
async fn nested_parameters_conditions_and_instruction_budgets_have_enforced_boundaries() {
    let conditions = |n: usize| {
        format!(
            "{}self tag!(\":leaf:\"){}",
            "if self !done? then ".repeat(n),
            " endif".repeat(n)
        )
    };
    let parameters = |n: usize| {
        format!(
            "self future!({}nil{}) tag!(\":leaf:\")",
            "(".repeat(n - 1),
            ")".repeat(n - 1)
        )
    };
    for (trigger, expected) in [
        (parameters(64), None),
        (parameters(65), Some("嵌套")),
        (conditions(64), None),
        (conditions(65), Some("嵌套")),
        (
            format!("self {}unknown-finder", "future! ".repeat(2047)),
            None,
        ),
        (
            format!("self {}unknown-finder", "future! ".repeat(2048)),
            Some("次数"),
        ),
    ] {
        let source = format!("* TODO Task\n:PROPERTIES:\n:TRIGGER: {trigger}\n:END:\n正文  \n");
        let mut f = Fixture::new(&[("tasks.org", &source)]).await;
        let group = f.group().await;
        if let Some(expected) = expected {
            f.assert_rollback(&group, expected).await;
        } else {
            f.workspace.execute_task_operations(&group).await.unwrap();
            assert!(f.source().starts_with("* DONE Task"));
            if trigger.contains("leaf") {
                assert!(f.source().contains(":leaf:"));
            }
            f.assert_one_commit(&source).await;
        }
    }
}

#[tokio::test]
async fn trigger_chain_depth_and_mutual_repeated_cycles_are_bounded() {
    for length in [32, 33] {
        let mut source = String::new();
        for i in 0..length {
            let title = if i == 0 {
                "Task".to_owned()
            } else {
                format!("T{i}")
            };
            let trigger = if i + 1 == length {
                "self tag!(\":leaf:\")"
            } else {
                "next-sibling todo!(DONE)"
            };
            source.push_str(&format!(
                "* TODO {title}\n:PROPERTIES:\n:TRIGGER: {trigger}\n:END:\n"
            ));
        }
        let mut f = Fixture::new(&[("tasks.org", &source)]).await;
        let group = f.group().await;
        if length == 33 {
            f.assert_rollback(&group, "循环").await;
        } else {
            f.workspace.execute_task_operations(&group).await.unwrap();
            assert_eq!(f.source().matches("* DONE ").count(), length);
            assert_eq!(f.source().matches(":leaf:").count(), 2); // 规则原文与执行后的标签。
            f.assert_one_commit(&source).await;
        }
    }
    let source = "* TODO Task\nSCHEDULED: <2026-01-01 Thu +1d>\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Other\nSCHEDULED: <2026-01-01 Thu +1d>\n:PROPERTIES:\n:TRIGGER: previous-sibling todo!(DONE)\n:END:\n";
    let mut f = Fixture::new(&[("tasks.org", source)]).await;
    let group = f.group().await;
    f.assert_rollback(&group, "循环").await;
}

#[tokio::test]
async fn every_unsupported_action_and_cross_file_finder_is_a_silent_noop() {
    for unsupported in [
        "clock-in!",
        "clock-out!",
        "archive!",
        "future-action!((arbitrary Lisp))",
        "scheduled!(\"next week\")",
        "deadline!(\"next week\")",
        "set-effort!(1.5)",
        "file(\"other.org\") todo!(INVALID)",
        "org-file(\"other.org\") todo!(INVALID)",
        "olp(\"other.org\" \"External\") todo!(INVALID)",
        "ids(\"external\") todo!(INVALID)",
        "match(\"work\" agenda) todo!(INVALID)",
        "match(\"work\" buffer custom-skip) todo!(INVALID)",
        "unknown-finder todo!(INVALID)",
        "if self variable-set?(anything t) then todo!(INVALID) else todo!(INVALID) endif",
        "if self future-condition? then todo!(INVALID) else todo!(INVALID) endif",
    ] {
        let source = format!(
            "* TODO Task\n:PROPERTIES:\n:TRIGGER: self future-start! {unsupported} self tag!(\":after:\")\n:END:\n备注  \n"
        );
        let external = "* TODO External :work:\n:PROPERTIES:\n:ID: external\n:END:\n";
        let mut f = Fixture::new(&[("tasks.org", &source), ("other.org", external)]).await;
        let group = f.group().await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert!(
            f.source().starts_with("* DONE Task :after:\n"),
            "{unsupported}"
        );
        assert!(f.source().ends_with("备注  \n"));
        assert_eq!(
            std::fs::read_to_string(f.root.join("other.org")).unwrap(),
            external
        );
        f.assert_one_commit(&source).await;
    }
}

#[tokio::test]
async fn one_successful_cascade_has_one_event_and_stale_retry_has_no_side_effects() {
    let source = "* TODO Task\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Other\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Last\n";
    let mut f = Fixture::new(&[("tasks.org", source)]).await;
    let group = f.group().await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(f.source().matches("* DONE ").count(), 3);
    f.assert_one_commit(source).await;
    let after = f.snapshot();
    assert!(
        f.workspace
            .execute_task_operations(&group)
            .await
            .unwrap_err()
            .to_string()
            .contains("版本")
    );
    assert_eq!(f.snapshot(), after);
    f.assert_one_commit(source).await;
}

#[tokio::test]
async fn random_target_selection_preserves_membership_and_never_selects_the_source() {
    for _ in 0..8 {
        let source = "* TODO Task\n:PROPERTIES:\n:TRIGGER: relatives(forward-no-wrap random-sort 1) tag!(\":chosen:\")\n:END:\n* TODO A\n* TODO B\n* TODO C\n";
        let mut f = Fixture::new(&[("tasks.org", source)]).await;
        let group = f.group().await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        let saved = f.source();
        assert!(saved.starts_with("* DONE Task\n"));
        let chosen = saved
            .lines()
            .filter(|line| line.starts_with("* TODO ") && line.ends_with(":chosen:"))
            .collect::<Vec<_>>();
        assert_eq!(chosen.len(), 1);
        assert!(
            [
                "* TODO A :chosen:",
                "* TODO B :chosen:",
                "* TODO C :chosen:"
            ]
            .contains(&chosen[0])
        );
        assert_eq!(
            saved.lines().filter(|line| line.starts_with("* ")).count(),
            4
        );
        f.assert_one_commit(source).await;
    }
}

#[tokio::test]
async fn failed_disk_commit_rolls_back_a_completed_cascade_without_publishing() {
    let source =
        "* TODO Task\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Other\n";
    let mut f = Fixture::new(&[("tasks.org", source)]).await;
    let group = f.group().await;
    std::fs::write(f.root.join(".sync/outbox"), "不能替换的原始控制数据").unwrap();
    let before = f.snapshot();
    let error = f
        .workspace
        .execute_task_operations(&group)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("同步控制路径"), "{error}");
    assert_eq!(f.snapshot(), before);
    assert_eq!(f.events.load(Ordering::Relaxed), 0);
    assert!(f.workspace.task_operation_history.entries.is_empty());
}

#[tokio::test]
async fn creation_in_a_completed_state_does_not_run_its_own_trigger() {
    let source = "* TODO Task\n原有正文\n";
    let mut f = Fixture::new(&[("tasks.org", source)]).await;
    let mut group = f.group().await;
    let mut creation = TaskCreation::new(
        TaskPosition {
            parent: TaskPath::file(f.workspace.repos()[0].id.clone(), "tasks.org".into()),
            after: None,
        },
        "Created".into(),
    );
    creation.state = Some("DONE".into());
    creation.body = ":PROPERTIES:\n:TRIGGER: self todo!(INVALID)\n:END:\n新正文\n".into();
    group.operations = vec![TaskOperation::Creation(creation)];
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert!(f.source().contains("* DONE Created\n"));
    assert!(f.source().contains(":TRIGGER: self todo!(INVALID)\n"));
    assert!(f.source().contains(":CREATED: ["));
    assert!(f.source().ends_with(source));
    f.assert_one_commit(source).await;
}

#[tokio::test]
async fn local_match_defaults_and_missing_target_conditions_do_not_escape_the_file() {
    for (finder, expected_tag) in [
        ("match(\"work\") tag!(\":local:\")", ":local:"),
        ("match(\"work\" nil) tag!(\":local:\")", ":local:"),
        ("match(\"work\" file) tag!(\":local:\")", ":local:"),
        (
            "if ids(\"missing\") done? then next-sibling tag!(\":empty:\") else todo!(INVALID) endif",
            ":empty:",
        ),
        (
            "if ids(\"missing\") !done? then next-sibling tag!(\":empty:\") else todo!(INVALID) endif",
            ":empty:",
        ),
    ] {
        let source =
            format!("* TODO Task\n:PROPERTIES:\n:TRIGGER: {finder}\n:END:\n* TODO Target :work:\n");
        let external = "* TODO External :work:\n";
        let mut f = Fixture::new(&[("tasks.org", &source), ("other.org", external)]).await;
        let group = f.group().await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert!(
            f.source()
                .ends_with(&format!("* TODO Target {expected_tag}\n"))
        );
        assert_eq!(
            std::fs::read_to_string(f.root.join("other.org")).unwrap(),
            external
        );
        f.assert_one_commit(&source).await;
    }
}

#[tokio::test]
async fn linked_change_event_observes_all_committed_nodes_and_is_not_emitted_for_noop_or_failure() {
    let source = "#+TODO: TODO NEXT | DONE\n* TODO Task\nSCHEDULED: <2026-11-01 Sun +1d>\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(DONE)\n:END:\n* TODO Other\n:PROPERTIES:\n:TRIGGER: next-sibling todo!(NEXT)\n:END:\n* TODO Last\n";
    let mut f = Fixture::new(&[("tasks.org", source)]).await;
    let observations = Arc::new(std::sync::Mutex::new(Vec::new()));
    let observed = observations.clone();
    let disk = f.root.join("tasks.org");
    let _watcher = f.workspace.watch_data_changes(move |event| {
        observed
            .lock()
            .unwrap()
            .push((event, std::fs::read_to_string(&disk).unwrap()));
    });
    let group = f.group().await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    let committed = f.source();
    assert!(committed.contains("* TODO Task\nSCHEDULED: <2026-11-02 Mon +1d>\n"));
    assert!(committed.contains("* DONE Other\n"));
    assert!(committed.ends_with("* NEXT Last\n"));
    assert_eq!(
        *observations.lock().unwrap(),
        vec![(
            DataChangeEvent::RepositoryChanged {
                repo_id: f.workspace.repos()[0].id.clone(),
            },
            committed
        )]
    );
    f.assert_one_commit(source).await;
    let snapshot = f.snapshot();
    let mut noop = f.group().await;
    let TaskOperation::Modification(change) = &mut noop.operations[0] else {
        unreachable!()
    };
    change.modifications = vec![TaskModification::Priority(None)];
    f.workspace.execute_task_operations(&noop).await.unwrap();
    assert_eq!(f.snapshot(), snapshot);
    assert_eq!(observations.lock().unwrap().len(), 1);
    let mut failed = f.group().await;
    let TaskOperation::Modification(change) = &mut failed.operations[0] else {
        unreachable!()
    };
    change.modifications = vec![TaskModification::Todo(Some("INVALID".into()))];
    assert!(f.workspace.execute_task_operations(&failed).await.is_err());
    assert_eq!(f.snapshot(), snapshot);
    assert_eq!(observations.lock().unwrap().len(), 1);
    assert_eq!(f.events.load(Ordering::Relaxed), 1);
}
