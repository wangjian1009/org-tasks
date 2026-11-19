mod support;

use chrono::{Local, TimeZone};
use org_tasks_core::*;
use std::sync::{Arc, Mutex};

async fn workspace(source: &str) -> OrgWorkspace {
    let mut repo = OrgRepo::new("/tmp/org-task-reminders".into()).unwrap();
    repo.id = "reminders".into();
    let file = OrgFile::new(
        repo.id.clone(),
        "tasks.org".into(),
        source.as_bytes().to_vec(),
    )
    .unwrap();
    support::push_file(&mut repo, file);
    OrgWorkspace::start(vec![repo]).await.unwrap()
}

#[tokio::test]
async fn reminder_time_uses_exactly_the_created_property_time_pipeline() {
    for value in [
        "[2026-11-20 Fri 09:00]",
        "[2026-11-20]",
        "<2026-11-20 09:00>",
        "wrong",
        "[2026-02-30 09:00]",
        "[2026-11-20 25:00]",
        "[2026-11-20]--[2026-11-21]",
    ] {
        let source = format!(
            "#+PROPERTY: REMIND_AT [2026-11-21 Sat 10:00]\r\n* TODO Parent\r\n:PROPERTIES:\r\n:CREATED: {value}\r\n:remind_at: {value}\r\n:END:\r\n** TODO Child\r\n"
        );
        let workspace = workspace(&source).await;
        let nodes = workspace.repos()[0]
            .file("tasks.org")
            .await
            .unwrap()
            .nodes();
        assert_eq!(nodes[0].reminder_at(), nodes[0].created_at(), "{value}");
        assert_eq!(nodes[1].reminder_at(), None);
        assert_eq!(nodes[0].property("ID"), None);
        assert_eq!(
            workspace.repos()[0]
                .file("tasks.org")
                .await
                .unwrap()
                .source_bytes(),
            source.as_bytes()
        );
        workspace.stop().await.unwrap();
    }
}

#[tokio::test]
async fn set_reminder_is_typed_preserves_bytes_and_notifies_query_membership() {
    let source = "#+TITLE: 提醒验证\r\n* TODO Target\r\n:PROPERTIES:\r\n:CREATED: [2026-11-18 Wed 09:00]\r\n:KEEP:   value  \r\n:END:\r\n正文  \r\n* TODO Other\r\n未修改  \r\n";
    let workspace = workspace(source).await;
    let events = Arc::new(Mutex::new(Vec::new()));
    let capture = events.clone();
    let mut start = workspace
        .subscribe_query(vec![QuerySubscriptionRequest::new(
            TaskQuery {
                expression: "it.todo has.reminder".into(),
                ..Default::default()
            }
            .into(),
            move |event| capture.lock().unwrap().push(event),
        )])
        .await
        .unwrap()
        .remove(0);
    assert!(start.data.into_task().unwrap().tasks.is_empty());
    let when = Local
        .with_ymd_and_hms(2026, 11, 20, 9, 0, 0)
        .earliest()
        .unwrap()
        .timestamp_millis();
    for value in [Some(when), Some(when + 300_000), None] {
        let node = workspace.repos()[0]
            .file("tasks.org")
            .await
            .unwrap()
            .nodes()
            .remove(0);
        workspace
            .execute_task_operations(&TaskOperationGroup {
                operations: vec![TaskOperation::Modification(TaskModificationOperation {
                    path: node.full_path().clone(),
                    modifications: vec![TaskModification::SetReminder(value)],
                    note: None,
                })],
                file_versions: vec![TaskFileVersion {
                    repo_id: node.repo_id().into(),
                    file: node.path().into(),
                    version: node.file_version().into(),
                }],
                ..Default::default()
            })
            .await
            .unwrap();
        let file = workspace.repos()[0].file("tasks.org").await.unwrap();
        assert_eq!(file.nodes()[0].reminder_at(), value);
        assert_eq!(file.nodes()[0].property("ID"), None);
        let bytes = String::from_utf8(file.source_bytes().to_vec()).unwrap();
        let without_reminder = bytes
            .lines()
            .filter(|line| !line.starts_with(":REMIND_AT:"))
            .collect::<Vec<_>>()
            .join("\r\n")
            + "\r\n";
        assert_eq!(without_reminder, source);
    }
    let events = serde_json::to_string(&*events.lock().unwrap()).unwrap();
    assert!(events.contains("\"reminderAt\":"));
    workspace.unsubscribe_query(&mut start.subscription);
    workspace.stop().await.unwrap();
}

#[tokio::test]
async fn invalid_reminder_rolls_back_the_whole_group_and_property_cannot_bypass_it() {
    let source = "* TODO Target\n原文\n";
    let workspace = workspace(source).await;
    let task = workspace.repos()[0]
        .file("tasks.org")
        .await
        .unwrap()
        .nodes()
        .remove(0);
    for invalid in [
        TaskModification::SetReminder(Some(i64::MAX)),
        TaskModification::Property {
            name: "REMIND_AT".into(),
            value: Some("wrong".into()),
        },
    ] {
        assert!(
            workspace
                .execute_task_operations(&TaskOperationGroup {
                    operations: vec![TaskOperation::Modification(TaskModificationOperation {
                        path: task.full_path().clone(),
                        modifications: vec![TaskModification::Title(Some("改名".into())), invalid],
                        note: None
                    })],
                    ..Default::default()
                })
                .await
                .is_err()
        );
        assert_eq!(
            workspace.repos()[0]
                .file("tasks.org")
                .await
                .unwrap()
                .source_bytes(),
            source.as_bytes()
        );
    }
    let set = serde_json::to_value(TaskModification::SetReminder(Some(42))).unwrap();
    assert_eq!(set, serde_json::json!({"field":"SET_REMINDER","value":42}));
    workspace.stop().await.unwrap();
}

#[tokio::test]
async fn reminder_expressions_share_created_date_rules_and_sort_by_full_time() {
    let today = Local::now().date_naive();
    let yesterday = today - chrono::Duration::days(1);
    let tomorrow = today + chrono::Duration::days(1);
    let mut source = String::new();
    for (title, date, time) in [
        ("late", today, "18:00"),
        ("tomorrow", tomorrow, "10:00"),
        ("early", today, "09:00"),
        ("yesterday", yesterday, "15:00"),
    ] {
        source.push_str(&format!("* TODO {title}\n:PROPERTIES:\n:CREATED: [{date} {time}]\n:REMIND_AT: [{date} {time}]\n:END:\n"));
    }
    source.push_str("* TODO missing\n* TODO invalid\n:PROPERTIES:\n:CREATED: wrong\n:REMIND_AT: wrong\n:END:\n* TODO legacy\n:PROPERTIES:\n:REMIND_COUNT: 3\n:REMIND_INTERVAL: 5m\n:REMIND_ENABLED: true\n:END:\n");
    let workspace = workspace(&source).await;
    async fn titles(workspace: &OrgWorkspace, expression: &str) -> Vec<String> {
        workspace
            .query(&[TaskQuery {
                expression: expression.into(),
                ..Default::default()
            }
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap()
            .tasks
            .iter()
            .map(|task| task.title().to_owned())
            .collect()
    }
    for interval in [
        "none",
        "le.today",
        "lt.tomorrow",
        "ge.today",
        "gt.yesterday",
        "ne.today",
        "eq.now",
        "le.2d",
        "ge.-1w",
        "ge.-1m",
    ] {
        let expected = titles(&workspace, &format!("it.todo cr.{interval}")).await;
        for prefix in ["r", "reminder"] {
            assert_eq!(
                titles(&workspace, &format!("it.todo {prefix}.{interval}")).await,
                expected,
                "{prefix}.{interval}"
            );
        }
    }
    assert_eq!(
        titles(&workspace, "it.todo has.reminder o.reminder").await,
        ["yesterday", "early", "late", "tomorrow"]
    );
    assert_eq!(
        titles(&workspace, "it.todo has.reminder .o.r").await,
        ["tomorrow", "late", "early", "yesterday"]
    );
    assert_eq!(
        titles(&workspace, "it.todo (r.lt.today or reminder.gt.today)").await,
        ["tomorrow", "yesterday"]
    );
    assert_eq!(
        titles(&workspace, "it.todo .has.reminder").await,
        ["missing", "invalid", "legacy"]
    );
    workspace.stop().await.unwrap();
}

#[tokio::test]
async fn repeat_completion_updates_reminder_in_the_same_notification_and_rolls_back_with_triggers() {
    let source = "* TODO Target\r\nSCHEDULED: <2026-11-10 Tue 10:00 +1d> DEADLINE: <2026-11-10 Tue 10:00 +1w>\r\n:PROPERTIES:\r\n:REMIND_AT: [2026-11-10 Tue 09:00]\r\n:KEEP:   unchanged  \r\n:END:\r\nBody  \r\n";
    let workspace = workspace(source).await;
    let events = Arc::new(Mutex::new(Vec::new()));
    let capture = events.clone();
    let mut subscription = workspace.subscribe_query(vec![QuerySubscriptionRequest::new(
        TaskQuery { expression: "it.todo has.reminder".into(), ..Default::default() }.into(),
        move |event| capture.lock().unwrap().push(event),
    )]).await.unwrap().remove(0);
    let original = workspace.repos()[0].file("tasks.org").await.unwrap().nodes().remove(0);
    workspace.execute_task_operations(&TaskOperationGroup {
        operations: vec![TaskOperation::Modification(TaskModificationOperation {
            path: original.full_path().clone(), modifications: vec![TaskModification::Todo(Some("DONE".into()))], note: None,
        })],
        file_versions: vec![TaskFileVersion { repo_id: original.repo_id().into(), file: original.path().into(), version: original.file_version().into() }],
        ..Default::default()
    }).await.unwrap();
    let next = workspace.query(&[TaskQuery { expression: "it.todo has.reminder".into(), ..Default::default() }.into()])
        .await.unwrap().remove(0).into_task().unwrap().tasks.remove(0);
    let expected = Local.with_ymd_and_hms(2026, 11, 17, 9, 0, 0).earliest().unwrap().timestamp_millis();
    assert_eq!(next.reminder_at(), Some(expected));
    assert_eq!(next.state().unwrap().name, "TODO");
    assert_ne!(next.file_version(), original.file_version());
    assert!(serde_json::to_string(&*events.lock().unwrap()).unwrap().contains(&format!("\"reminderAt\":{expected}")));
    let bytes = workspace.repos()[0].file("tasks.org").await.unwrap();
    assert!(String::from_utf8_lossy(bytes.source_bytes()).ends_with(":KEEP:   unchanged  \r\n:END:\r\nBody  \r\n"));
    workspace.unsubscribe_query(&mut subscription.subscription);
    workspace.stop().await.unwrap();

    for source in [
        "* TODO Target\nSCHEDULED: <2026-11-10 Tue 10:00 +1d>\n:PROPERTIES:\n:REMIND_AT: [2026-11-10 Tue 09:00]\n:TRIGGER: self todo!(INVALID)\n:END:\nBody\n",
        "* TODO Target\nSCHEDULED: <9999-12-30 Thu 10:00 +1d>\n:PROPERTIES:\n:REMIND_AT: [9999-12-31 Fri 10:00]\n:END:\nBody\n",
    ] {
        let workspace = self::workspace(source).await;
        let task = workspace.repos()[0].file("tasks.org").await.unwrap().nodes().remove(0);
        assert!(workspace.execute_task_operations(&TaskOperationGroup {
            operations: vec![TaskOperation::Modification(TaskModificationOperation {
                path: task.full_path().clone(), modifications: vec![TaskModification::Todo(Some("DONE".into()))], note: None,
            })], ..Default::default()
        }).await.is_err());
        assert_eq!(workspace.repos()[0].file("tasks.org").await.unwrap().source_bytes(), source.as_bytes());
        workspace.stop().await.unwrap();
    }
}
