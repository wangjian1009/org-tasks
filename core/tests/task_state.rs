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
    assert!(!f.source().contains("CLOSED:"));
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
async fn completion_is_blocked_only_by_unfinished_descendants() {
    for child in [
        "** TODO Child\n",
        "** Group\n*** TODO Child\n",
        "** DONE Child\n*** TODO Grandchild\n",
    ] {
        let source = format!("* TODO Parent\nBody\n{child}");
        let mut f = Fixture::new(&source).await;
        let group = f
            .group(
                "Parent",
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
                .contains("未完成子任务")
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
        for state in [Some("TODO".into()), None] {
            let group = f.group("Parent", vec![TaskModification::Todo(state)]).await;
            f.workspace.execute_task_operations(&group).await.unwrap();
        }
    }
    for child in [
        "** DONE Child\n",
        "** Notes\n",
        "** Group\n*** DONE Child\n",
    ] {
        let source = format!("* TODO Parent\n{child}");
        let mut f = Fixture::new(&source).await;
        let group = f
            .group("Parent", vec![TaskModification::Todo(Some("DONE".into()))])
            .await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert_eq!(
            f.source(),
            source.replacen("* TODO Parent", "* DONE Parent", 1)
        );
    }
}

#[tokio::test]
async fn reopening_a_child_restores_completed_ancestors_and_preserves_other_bytes() {
    for state in [Some("OPEN".into()), None] {
        let source = "#+TODO: OPEN WAIT | FINISHED CANCELLED\r\n* CANCELLED Grandparent [1/1]\r\nCLOSED: [2026-11-01 Sun 09:00]\r\n** Group\r\n*** FINISHED Parent [1/1]\r\nCLOSED: [2026-11-01 Sun 09:00]\r\n:LOGBOOK:\r\n- 已有日志\r\n:END:\r\n**** FINISHED Child\r\nCLOSED: [2026-11-01 Sun 09:00]\r\nSCHEDULED: <2026-11-20 Fri +1d>\r\n正文  \r\n**** FINISHED Sibling\r\n* Other\r\n";
        let mut f = Fixture::new(source).await;
        let events = Arc::new(Mutex::new(0));
        let observed = events.clone();
        let _subscription = f
            .workspace
            .watch_data_changes(move |_| *observed.lock().unwrap() += 1);
        let group = f
            .group(
                "Child",
                vec![
                    TaskModification::Todo(state.clone()),
                    TaskModification::Notes(Some("新备注  \r\n".into())),
                ],
            )
            .await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        let saved = f.source();
        assert!(
            saved.contains("* OPEN Grandparent [1/1]\r\n** Group\r\n*** OPEN Parent"),
            "{saved}"
        );
        assert!(
            saved.contains(if state.is_some() {
                "Parent [1/2]"
            } else {
                "Parent [1/1]"
            }),
            "{saved}"
        );
        assert!(
            saved.contains(&format!(
                "**** {}Child\r\nSCHEDULED:",
                if state.is_some() { "OPEN " } else { "" }
            )),
            "{saved}"
        );
        assert!(!saved.contains("CLOSED:"));
        assert!(saved.contains(":LOGBOOK:\r\n- 已有日志\r\n:END:\r\n"));
        assert!(
            saved.ends_with("新备注  \r\n**** FINISHED Sibling\r\n* Other\r\n"),
            "{saved}"
        );
        assert_eq!(*events.lock().unwrap(), 1);
        assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
        assert_eq!(
            f.workspace.repos()[0].pending_writes().await.unwrap().len(),
            1
        );
        assert!(f.workspace.execute_task_operations(&group).await.is_err());
        assert_eq!(f.source(), saved);
    }
}

#[tokio::test]
async fn reopening_uses_each_ancestor_workflow_and_logging_settings() {
    let source = "#+TODO: TODO | DONE\n#+TODO: READY(r!) WAIT | FINISHED\n#+STARTUP: logdrawer\n* FINISHED Parent\nCLOSED: [2026-11-01 Sun 09:00]\n** DONE Child\n* DONE Unrelated\n";
    let mut f = Fixture::new(source).await;
    let group = f
        .group("Child", vec![TaskModification::Todo(Some("TODO".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    let saved = f.source();
    assert!(
        saved.contains("* READY Parent\n:LOGBOOK:\n- State \"READY\"      from \"FINISHED\""),
        "{saved}"
    );
    assert!(saved.ends_with("** TODO Child\n* DONE Unrelated\n"));
    assert!(!saved.contains("CLOSED:"));
}

#[tokio::test]
async fn reopening_crosses_pending_ancestors_and_repeating_completion_restores_parents() {
    for (initial, scheduled, target) in [
        ("DONE", "", "TODO"),
        ("TODO", "SCHEDULED: <2026-11-10 Tue +1d>\n", "DONE"),
    ] {
        let source = format!(
            "* DONE Grandparent [0/1]\n** TODO Parent [0/1]\n*** {initial} Child\n{scheduled}"
        );
        let mut f = Fixture::new(&source).await;
        let group = f
            .group("Child", vec![TaskModification::Todo(Some(target.into()))])
            .await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        assert!(
            f.source()
                .starts_with("* TODO Grandparent [0/1]\n** TODO Parent [0/1]\n*** TODO Child\n"),
            "{}",
            f.source()
        );
        if !scheduled.is_empty() {
            assert!(f.source().contains("SCHEDULED: <2026-11-11 Wed +1d>"));
        }
    }
}

#[tokio::test]
async fn ancestor_logging_failure_rolls_back_child_and_all_ancestor_changes() {
    let source = "* DONE Grandparent\n:PROPERTIES:\n:LOG_INTO_DRAWER: invalid-name\n:END:\n** DONE Parent\nCLOSED: [2026-11-01 Sun 09:00]\n:PROPERTIES:\n:LOG_INTO_DRAWER: LOGBOOK\n:END:\n*** DONE Child\nCLOSED: [2026-11-01 Sun 09:00]\n";
    let mut f = Fixture::new(source).await;
    let events = Arc::new(Mutex::new(0));
    let observed = events.clone();
    let _subscription = f
        .workspace
        .watch_data_changes(move |_| *observed.lock().unwrap() += 1);
    let group = f
        .group("Child", vec![TaskModification::Todo(Some("TODO".into()))])
        .await;
    assert!(
        f.workspace
            .execute_task_operations(&group)
            .await
            .unwrap_err()
            .to_string()
            .contains("drawer")
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

#[tokio::test]
async fn trigger_reopening_a_child_uses_the_same_ancestor_rules() {
    let source = "* TODO Source\n:PROPERTIES:\n:TRIGGER: ids(\"child\") todo!(TODO)\n:END:\n* DONE Parent [1/1]\n** DONE Child\n:PROPERTIES:\n:ID: child\n:END:\n";
    let mut f = Fixture::new(source).await;
    let group = f
        .group("Source", vec![TaskModification::Todo(Some("DONE".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(
        f.source(),
        source
            .replace("* TODO Source", "* DONE Source")
            .replace("* DONE Parent [1/1]", "* TODO Parent [0/1]")
            .replace("** DONE Child", "** TODO Child")
    );
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

#[tokio::test]
async fn state_changes_without_logging_configuration_only_replace_the_state() {
    for prefix in [
        "",
        "#+STARTUP: logdrawer\n",
        "#+PROPERTY: LOG_INTO_DRAWER HISTORY\n",
        "#+TODO: TODO | DONE\n",
        "#+STARTUP: logdone logrepeat logdrawer\n#+PROPERTY: LOGGING nil\n",
        "#+begin_src org\n#+STARTUP: logdone logrepeat logdrawer\n#+TODO: TODO | DONE(!)\n#+end_src\n",
    ] {
        let body = ":LOGBOOK:\r\n- 已有日志\r\n:END:\r\n正文  \r\n";
        let original = format!("{prefix}* TODO Task\r\n{body}");
        let mut f = Fixture::new(&original).await;
        for state in [Some("DONE"), Some("DONE"), Some("TODO"), None] {
            let group = f.group("Task", vec![TaskModification::Todo(state.map(str::to_owned))]).await;
            f.workspace.execute_task_operations(&group).await.unwrap();
            let expected = format!("{prefix}* {}Task\r\n{body}", state.map(|value| format!("{value} ")).unwrap_or_default());
            assert_eq!(f.source(), expected, "{prefix}");
        }
    }
}

#[tokio::test]
async fn reopening_closed_tasks_preserves_history_dates_and_version_guards() {
    for (keywords, initial, logs) in [
        ("#+TODO: READY | FINISHED(f!) STOP(s!)\n#+STARTUP: logdone logdrawer logrepeat\n", "FINISHED", false),
        ("#+TODO: READY | FINISHED STOP(s@/!)\n#+STARTUP: logdone logdrawer\n", "STOP", true),
        ("#+TODO: READY(r@) | FINISHED(f!/!) STOP\n#+STARTUP: logdone logdrawer\n", "FINISHED", true),
        ("#+TODO: READY(r!) | FINISHED(f!/!) STOP\n#+STARTUP: logdone logdrawer\n#+PROPERTY: LOGGING nil\n", "FINISHED", false),
        ("#+TODO: READY | FINISHED STOP\n", "FINISHED", false),
    ] {
        let body = "SCHEDULED: <2026-11-10 Tue +1d> DEADLINE: <2026-11-20 Fri>\r\n:PROPERTIES:\r\n:CREATED: [2026-10-01 Thu 08:00]\r\n:LAST_REPEAT: [2026-10-25 Sun 10:00]\r\n:END:\r\n";
        let history = "- State \"DONE\"       from \"TODO\"       [2026-11-01 Sun 09:00]\r\n  历史说明保留  \r\n:END:\r\n正文  \r\n* Other\r\n不受影响  \r\n";
        let source = format!("{keywords}* {initial} Task\r\nCLOSED: [2026-11-01 Sun 09:00]\r\n{body}:LOGBOOK:\r\n{history}");
        let mut f = Fixture::new(&source).await;
        let events = Arc::new(Mutex::new(0));
        let observed = events.clone();
        let _subscription = f.workspace.watch_data_changes(move |_| *observed.lock().unwrap() += 1);
        let group = f.group("Task", vec![TaskModification::Todo(Some("READY".into()))]).await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        let saved = f.source();
        assert!(saved.starts_with(&format!("{keywords}* READY Task\r\n{body}:LOGBOOK:\r\n")), "{saved}");
        assert!(saved.ends_with(history), "{saved}");
        assert!(!saved.contains("CLOSED:"));
        assert_eq!(saved.matches("- State ").count(), if logs { 2 } else { 1 }, "{saved}");
        if logs {
            assert!(saved.contains(&format!("- State \"READY\"      from \"{initial}\"")), "{saved}");
        }
        assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
        assert_eq!(f.workspace.repos()[0].pending_writes().await.unwrap().len(), 1);
        assert_eq!(*events.lock().unwrap(), 1);
        assert!(f.workspace.execute_task_operations(&group).await.is_err());
        assert_eq!(f.source(), saved);
        assert_eq!(*events.lock().unwrap(), 1);
    }
}

#[tokio::test]
async fn repeated_reopening_and_completion_append_logs_from_local_keyword_markers() {
    let mut f = Fixture::new(
        "#+SETUPFILE: .setup.org\r\n#+TODO: TODO(t!) INPROGRESS(p) WAIT(w) | DONE(d!)\r\n* DONE Task\r\nCLOSED: [2026-11-01 Sun 09:00]\r\n:LOGBOOK:\r\n- State \"DONE\"       from \"TODO\"       [2026-11-01 Sun 09:00]\r\n  历史说明保留  \r\n:END:\r\n正文  \r\n* Other\r\n不受影响  \r\n",
    ).await;
    tokio::fs::write(
        f.root.join(".setup.org"),
        "#+TODO: TODO(t) NEXT(n) INPROGRESS(p) WAIT(w) | DONE(d!)\n#+TODO: | CNCL(c!)\n#+STARTUP: show2levels hidestars indent logdone logdrawer logrepeat hideblocks\n",
    ).await.unwrap();
    let history = "- State \"DONE\"       from \"TODO\"       [2026-11-01 Sun 09:00]\r\n  历史说明保留  \r\n:END:\r\n正文  \r\n* Other\r\n不受影响  \r\n";
    for (index, state) in ["TODO", "DONE", "TODO", "DONE"].iter().enumerate() {
        let group = f
            .group("Task", vec![TaskModification::Todo(Some((*state).into()))])
            .await;
        f.workspace.execute_task_operations(&group).await.unwrap();
        let saved = f.source();
        assert!(saved.contains(&format!("* {state} Task\r\n")), "{saved}");
        assert_eq!(saved.matches("- State ").count(), index + 2, "{saved}");
        assert_eq!(saved.matches(":LOGBOOK:").count(), 1, "{saved}");
        assert!(
            saved.contains(&format!(":LOGBOOK:\r\n- State \"{state}\"")),
            "{saved}"
        );
        assert_eq!(saved.contains("CLOSED:"), *state == "DONE", "{saved}");
        assert!(saved.ends_with(history), "{saved}");
        assert!(!saved.replace("\r\n", "").contains('\n'), "{saved}");
    }
}

#[tokio::test]
async fn created_completed_tasks_record_closing_information_only_when_enabled() {
    for (prefix, closed, note) in [
        ("", false, false),
        ("#+STARTUP: logdrawer\n", false, false),
        ("#+STARTUP: logdone\n", true, false),
        ("#+STARTUP: lognotedone logdrawer\n", true, true),
        ("#+STARTUP: logdone\n#+PROPERTY: LOGGING nil\n", false, false),
    ] {
        let mut f = Fixture::new(&format!("{prefix}* Keep\n")).await;
        let mut creation = TaskCreation::new(TaskPosition {
            parent: TaskPath::file(f.workspace.repos()[0].id.clone(), "tasks.org".into()),
            after: None,
        }, "New".into());
        creation.state = Some("DONE".into());
        f.workspace.execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Creation(creation)],
            ..Default::default()
        }).await.unwrap();
        let source = f.source();
        assert!(source.contains("* DONE New\n"), "{source}");
        assert!(source.contains(":CREATED: ["), "{source}");
        assert_eq!(source.contains("CLOSED: ["), closed, "{source}");
        assert_eq!(source.contains("CLOSING NOTE"), note, "{source}");
        assert_eq!(source.contains(":LOGBOOK:"), note, "{source}");
        assert!(!source.contains("- State"), "创建状态不模拟一次状态切换：{source}");
    }
}

#[tokio::test]
async fn repeating_completion_runs_local_trigger_after_repeat_and_refreshes_the_saved_dates() {
    let original = "#+TODO: NEXT WAIT | FINISHED\r\n#+STARTUP: logrepeat logdrawer\r\n* NEXT Task\r\nSCHEDULED: <2000-01-01 Sat .+1d/3d>\r\n:PROPERTIES:\r\n:TRIGGER: self scheduled!(\"+2d\") next-sibling todo!(WAIT)\r\n:CREATED: [2000-01-01 Sat 09:00]\r\n:END:\r\n备注  \r\n* NEXT Other\r\nBody  \r\n";
    let mut f = Fixture::new(original).await;
    let group = f
        .group(
            "Task",
            vec![TaskModification::Todo(Some("FINISHED".into()))],
        )
        .await;
    let before = chrono::Local::now().date_naive();
    f.workspace.execute_task_operations(&group).await.unwrap();
    let after = chrono::Local::now().date_naive();
    let saved = f.source();
    let expected_date = |day: chrono::NaiveDate| {
        format!(
            "SCHEDULED: <{} .+1d/3d>",
            (day + chrono::Duration::days(3)).format("%Y-%m-%d %a")
        )
    };
    assert!(
        saved.contains(&expected_date(before)) || saved.contains(&expected_date(after)),
        "{saved}"
    );
    assert!(saved.contains("* NEXT Task\r\n"));
    assert!(saved.contains("* WAIT Other\r\nBody  \r\n"));
    assert!(saved.contains(":LAST_REPEAT: ["));
    assert_eq!(saved.matches("- State ").count(), 1);
    assert!(!saved.contains("CLOSED:"));
    assert!(!saved.replace("\r\n", "").contains('\n'));
    let repo = &f.workspace.repos()[0];
    let file = repo.file("tasks.org").await.unwrap();
    let task = file.task_edit_content(&file.node_paths()[0]).unwrap();
    assert_eq!(
        task.scheduled_repeat.unwrap().rule.unwrap().mode,
        TaskRepeatMode::AfterCompletion
    );
    assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
    assert_eq!(f.workspace.task_operation_history.entries.len(), 1);
    assert!(f.workspace.execute_task_operations(&group).await.is_err());
    assert_eq!(f.source(), saved);
}

#[tokio::test]
async fn trigger_targets_stay_local_and_unsupported_actions_do_not_interrupt_supported_ones() {
    let source = "* TODO Task\n:PROPERTIES:\n:TRIGGER: self clock-in! archive! future-action!(anything) scheduled!(\"next week\") if self variable-set?(unknown t) then todo!(INVALID) else todo!(INVALID) endif set-property!(\"LOCAL\" \"yes\") ids(\"outside\") todo!(DONE) file(\"other.org\") todo!(DONE) next-sibling todo!(DONE)\n:END:\n* TODO Other\n";
    let mut f = Fixture::new(source).await;
    let other = "* TODO External\n:PROPERTIES:\n:ID: outside\n:END:\n";
    tokio::fs::write(f.root.join("other.org"), other)
        .await
        .unwrap();
    let group = f
        .group("Task", vec![TaskModification::Todo(Some("DONE".into()))])
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    let saved = f.source();
    assert!(saved.contains("* DONE Task\n"));
    assert!(saved.contains(":LOCAL: yes\n"));
    assert!(saved.ends_with("* DONE Other\n"));
    assert_eq!(
        std::fs::read_to_string(f.root.join("other.org")).unwrap(),
        other
    );
    let fallback = &f.workspace.task_operation_history.entries[0]
        .fallback_group
        .files;
    assert_eq!(fallback.len(), 1);
    assert_eq!(fallback[0].file, "tasks.org");
}

#[tokio::test]
async fn trigger_changes_before_the_source_keep_following_modifications_on_the_source() {
    let source = "* TODO First\n* TODO Task\n:PROPERTIES:\n:TRIGGER: previous-sibling todo!(DONE) set-property!(\"PADDING\" \"some text before source\")\n:END:\nNotes\n";
    let mut f = Fixture::new(source).await;
    let group = f
        .group(
            "Task",
            vec![
                TaskModification::Todo(Some("DONE".into())),
                TaskModification::Notes(Some("新备注\n".into())),
            ],
        )
        .await;
    f.workspace.execute_task_operations(&group).await.unwrap();
    let saved = f.source();
    assert!(
        saved.starts_with(
            "* DONE First\n:PROPERTIES:\n:PADDING: some text before source\n:END:\n* DONE Task\n"
        ),
        "{saved}"
    );
    assert!(saved.ends_with("新备注\n"));
}

#[tokio::test]
async fn malformed_failed_and_recursive_triggers_roll_back_the_entire_operation_group() {
    for trigger in [
        "next-sibling todo!(DONE) self scheduled!(\"+1d\")",
        "self todo!(TODO) todo!(DONE)",
        "if self done? then next-sibling todo!(DONE)",
        "next-sibling todo!(DONE) self set-property!(\"CREATED\" \"changed\")",
    ] {
        let source =
            format!("* TODO Task\n:PROPERTIES:\n:TRIGGER: {trigger}\n:END:\n* TODO Other\n");
        let mut f = Fixture::new(&source).await;
        let group = f
            .group("Task", vec![TaskModification::Todo(Some("DONE".into()))])
            .await;
        assert!(
            f.workspace.execute_task_operations(&group).await.is_err(),
            "{trigger}"
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
    }
}
