use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

struct Fixture {
    root: PathBuf,
    workspace: OrgWorkspace,
}
impl Fixture {
    async fn new(source: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-state-{}-{}-{}",
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
async fn repeating_completion_uses_setup_logs_and_commits_one_versioned_change() {
    let source = "#+SETUPFILE: \"settings/outer file.org\"\r\n* NEXT Task\r\nSCHEDULED: <2000-01-01 Sat .+1d/3d> DEADLINE: <2030-01-01 Tue>\r\n:PROPERTIES:\r\n:CREATED: [2000-01-01 Sat 09:00]\r\n:ID: stable\r\n:END:\r\n备注  \r\n- [ ] Item\r\n#+begin_src org\r\n<2000-01-01 Sat +1d>\r\n#+end_src\r\n* Other\r\n";
    let mut f = Fixture::new(source).await;
    tokio::fs::create_dir(f.root.join("settings"))
        .await
        .unwrap();
    tokio::fs::write(
        f.root.join("settings/outer file.org"),
        "#+SETUPFILE: inner.org\n",
    )
    .await
    .unwrap();
    tokio::fs::write(
        f.root.join("settings/inner.org"),
        "#+TODO: NEXT WAIT | FINISHED\n#+STARTUP: logrepeat logdrawer\n",
    )
    .await
    .unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let observed = events.clone();
    let disk = f.root.join("tasks.org");
    let _subscription = f.workspace.watch_data_changes(move |event| {
        observed
            .lock()
            .unwrap()
            .push((event, std::fs::read_to_string(&disk).unwrap()));
    });
    let group = f
        .group(
            "Task",
            vec![TaskModification::Todo(Some("FINISHED".into()))],
        )
        .await;
    let before = chrono::Local::now().date_naive();
    f.workspace.execute_task_operations(&group).await.unwrap();
    let after = chrono::Local::now().date_naive();
    let result = f.source();
    assert!(result.contains("* NEXT Task\r\n"));
    assert!(!result.contains("CLOSED:"));
    assert!(result.contains(":LAST_REPEAT: ["));
    assert!(result.contains(":CREATED: [2000-01-01 Sat 09:00]\r\n:ID: stable\r\n"));
    assert!(result.contains(":LOGBOOK:\r\n- State \"FINISHED\"   from \"NEXT\""));
    assert!(result.ends_with("备注  \r\n- [ ] Item\r\n#+begin_src org\r\n<2000-01-01 Sat +1d>\r\n#+end_src\r\n* Other\r\n"));
    assert!(!result.replace("\r\n", "").contains('\n'));
    let day = |day: chrono::NaiveDate| {
        format!(
            "SCHEDULED: <{} .+1d/3d>",
            day.succ_opt().unwrap().format("%Y-%m-%d %a")
        )
    };
    assert!(result.contains(&day(before)) || result.contains(&day(after)));
    assert_eq!(events.lock().unwrap().len(), 1);
    assert_eq!(events.lock().unwrap()[0].1, result);
    assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
    let fallback = &f.workspace.task_operation_history.entries[0]
        .fallback_group
        .files[0];
    assert_eq!(fallback.before.as_deref(), Some(source));
    assert_eq!(fallback.after, result);
    assert_eq!(
        f.workspace.repos()[0].pending_writes().await.unwrap().len(),
        1
    );
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(f.source(), result);
    assert_eq!(events.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn logs_are_opt_in_and_setup_without_todo_keeps_default_states() {
    let mut f = Fixture::new("#+SETUPFILE: defaults.org\n* TODO Task\nBody\n").await;
    tokio::fs::write(f.root.join("defaults.org"), "#+STARTUP: logdrawer\n")
        .await
        .unwrap();
    let group = f
        .group("Task", vec![TaskModification::Todo(Some("DONE".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert!(f.source().contains("CLOSED: ["));
    assert!(!f.source().contains("LOGBOOK"));
    // 配置修改不依赖仓库缓存；下一次写入立即按新配置记录日志。
    tokio::fs::write(
        f.root.join("defaults.org"),
        "#+TODO: TODO(!) | DONE(!)\n#+STARTUP: logdrawer\n",
    )
    .await
    .unwrap();
    let group = f
        .group("Task", vec![TaskModification::Todo(Some("TODO".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert!(!f.source().contains("CLOSED:"));
    assert!(
        f.source()
            .contains(":LOGBOOK:\n- State \"TODO\"       from \"DONE\"")
    );
}

#[tokio::test]
async fn parent_state_changes_are_blocked_for_pending_and_completed_descendants() {
    for child in [
        "** TODO Child\n",
        "** DONE Child\n",
        "** Group\n*** TODO Child\n",
    ] {
        let source = format!("* TODO Parent\nBody\n{child}");
        let mut f = Fixture::new(&source).await;
        for state in [Some("DONE".to_owned()), None] {
            let group = f
                .group(
                    "Parent",
                    vec![
                        TaskModification::Title(Some("Changed".into())),
                        TaskModification::Todo(state),
                    ],
                )
                .await;
            let result = f.workspace.execute_task_operations(&group).await;
            assert!(result.unwrap_err().to_string().contains("子任务"));
            assert_eq!(f.source(), source);
            assert!(f.workspace.task_operation_history.entries.is_empty());
            assert!(
                f.workspace.repos()[0]
                    .pending_writes()
                    .await
                    .unwrap()
                    .is_empty()
            );
        }
        let group = f
            .group(
                "Parent",
                vec![TaskModification::Title(Some("Renamed".into()))],
            )
            .await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert_eq!(f.source(), source.replace("Parent", "Renamed"));
    }
    let mut f = Fixture::new("* TODO Parent\n** Notes\n").await;
    let group = f
        .group("Parent", vec![TaskModification::Todo(Some("DONE".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert!(f.source().starts_with("* DONE Parent\nCLOSED:"));
}

#[tokio::test]
async fn invalid_repeater_rolls_back_title_state_logs_and_upload_intents() {
    for (stamp, error) in [
        ("<2026-11-10 Tue +1h>", "时刻"),
        ("<9999-12-31 Fri +1y>", "范围"),
    ] {
        let source = format!(
            "#+TODO: TODO | DONE(!)\n#+STARTUP: logdrawer logrepeat\n* TODO Task\nSCHEDULED: {stamp}\nBody\n"
        );
        let mut f = Fixture::new(&source).await;
        let events = Arc::new(Mutex::new(0));
        let observed = events.clone();
        let _subscription = f
            .workspace
            .watch_data_changes(move |_| *observed.lock().unwrap() += 1);
        let group = f
            .group(
                "Task",
                vec![
                    TaskModification::Title(Some("Changed".into())),
                    TaskModification::Todo(Some("DONE".into())),
                ],
            )
            .await;
        assert!(
            f.workspace
                .execute_task_operations(&group)
                .await
                .unwrap_err()
                .to_string()
                .contains(error)
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
        assert_eq!(*events.lock().unwrap(), 0);
    }
}

#[tokio::test]
async fn completion_repeats_real_timestamps_in_the_title_through_the_public_executor() {
    let mut f = Fixture::new("* TODO Task <2026-11-10 Tue +1w>\nBody\n").await;
    let group = f
        .group(
            "Task <2026-11-10 Tue +1w>",
            vec![TaskModification::Todo(Some("DONE".into()))],
        )
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(f.source(), "* TODO Task <2026-11-17 Tue +1w>\nBody\n");
    assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
}
