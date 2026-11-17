use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::cmp::Ordering;

fn compare(left: &[QueryOrderPart], right: &[QueryOrderPart]) -> Ordering {
    for (left, right) in left.iter().zip(right) {
        let value = match (&left.value, &right.value) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => {
                if left.missing_last {
                    return Ordering::Greater;
                } else {
                    Ordering::Less
                }
            }
            (Some(_), None) => {
                if left.missing_last {
                    return Ordering::Less;
                } else {
                    Ordering::Greater
                }
            }
            (Some(QueryOrderValue::Number(a)), Some(QueryOrderValue::Number(b))) => a.cmp(b),
            (Some(QueryOrderValue::Text(a)), Some(QueryOrderValue::Text(b))) => a.cmp(b),
            _ => panic!("同一查询同一位置的键必须具有相同类型"),
        };
        if value != Ordering::Equal {
            return if left.descending {
                value.reverse()
            } else {
                value
            };
        }
    }
    Ordering::Equal
}

#[tokio::test]
async fn scalar_order_keys_match_all_core_sort_fields_and_preserve_workspace_ties() {
    let directory = std::env::temp_dir().join(format!(
        "query-ordering-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let source = "* TODO [#A] Alpha\nSCHEDULED: <2026-11-16 Mon> DEADLINE: <2026-11-19 Thu>\n:PROPERTIES:\n:CREATED: [2026-11-01 Sun 09:00]\n:LAST_MODIFIED: [2026-11-02 Mon 10:00]\n:END:\n<2026-11-17 Tue>\n* DONE [#C] 😀\nCLOSED: [2026-11-14 Sat]\n* TODO \u{e000}\n* TODO Tie\n";
    let mut repos = Vec::new();
    for root in ["second", "first"] {
        let root = directory.join(root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("same.org"), source).unwrap();
        std::fs::write(root.join("日程.org"), "* TODO Other\n").unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        repos.push(repo);
    }
    let workspace = OrgWorkspace::start(repos).await.unwrap();
    for field in [
        "",
        "book",
        "title",
        "scheduled",
        "deadline",
        "event",
        "closed",
        "created",
        "modified",
        "priority",
        "state",
        "position",
    ] {
        for direction in ["", "."] {
            let expression = if field.is_empty() {
                String::new()
            } else {
                format!("{direction}o.{field}")
            };
            let query: CoreQuery = TaskQuery {
                expression: expression.clone(),
                ..Default::default()
            }
            .into();
            let expected = workspace
                .query(std::slice::from_ref(&query))
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks;
            let ordering = workspace.query_ordering(&query).unwrap();
            let mut actual = expected.clone();
            actual.reverse();
            actual.sort_by(|a, b| compare(&ordering.task_key(a), &ordering.task_key(b)));
            assert_eq!(actual, expected, "{expression}");
        }
    }
    let query = CoreQuery::File {
        query: FileQuery::default(),
    };
    let expected = workspace
        .query(std::slice::from_ref(&query))
        .await
        .unwrap()
        .remove(0)
        .into_files()
        .unwrap();
    let ordering = workspace.query_ordering(&query).unwrap();
    let mut actual = expected.clone();
    actual.reverse();
    actual.sort_by(|a, b| compare(&ordering.file_key(a), &ordering.file_key(b)));
    assert_eq!(actual, expected);
    assert!(
        workspace
            .query_ordering(&CoreQuery::Notification {
                query: NotificationQuery::default(),
                repo_ids: None,
            })
            .is_err()
    );
    std::fs::remove_dir_all(directory).unwrap();
}
