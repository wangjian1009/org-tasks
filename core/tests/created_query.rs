use chrono::{Duration, Local, NaiveDate, TimeZone};
use org_tasks_core::*;

fn local(value: &str) -> i64 {
    let naive = chrono::NaiveDateTime::parse_from_str(value, "%Y-%m-%d %H:%M").unwrap();
    Local
        .from_local_datetime(&naive)
        .earliest()
        .unwrap()
        .timestamp_millis()
}
fn repo(id: &str, files: &[(&str, &str)]) -> OrgRepo {
    let mut repo = OrgRepo::new(format!("/unused/{id}")).unwrap();
    repo.id = id.into();
    repo.files = files
        .iter()
        .map(|(path, content)| {
            OrgFile::new(id.into(), (*path).into(), content.as_bytes().to_vec()).unwrap()
        })
        .collect();
    repo
}
#[test]
fn created_properties_project_own_valid_dates_times_and_sort_by_time() {
    let source = "#+PROPERTY: CREATED [2026-11-08 Sun 11:00]\n* Parent\n:PROPERTIES:\n:created: [2026-11-08 Sun 10:00]\n:END:\n** Child\nBody [2026-11-08 Sun 12:00]\n* TODO Morning\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n* DONE Noon\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 12:00]\n:END:\n* Note\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun]\n:END:\n* BadDate\n:PROPERTIES:\n:CREATED: [2026-02-30 Mon 12:00]\n:END:\n* BadTime\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 25:00]\n:END:\n* Text\n:PROPERTIES:\n:CREATED: prefix [2026-11-08 Sun 12:00]\n:END:\n* Fake\n#+begin_src org\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 12:00]\n:END:\n#+end_src\n";
    let w = OrgWorkspace::new(vec![repo("a", &[("inbox.org", source)])]).unwrap();
    let tasks = w.search(&Filter::parse(".o.created"));
    let valid = tasks
        .iter()
        .filter(|task| task.created_at().is_some())
        .collect::<Vec<_>>();
    assert_eq!(
        valid.iter().map(|t| t.title()).collect::<Vec<_>>(),
        ["Noon", "Parent", "Morning", "Note"]
    );
    assert_eq!(valid[0].created_at(), Some(local("2026-11-08 12:00")));
    assert_eq!(valid[3].created_at(), Some(local("2026-11-08 00:00")));
    let filter = Filter::parse("cr.ge.-2d cr.le.today");
    assert!(filter.matches_at(valid[0], NaiveDate::from_ymd_opt(2026, 11, 10).unwrap()));
    assert!(!filter.matches_at(valid[0], NaiveDate::from_ymd_opt(2026, 11, 11).unwrap()));
    for title in ["Child", "BadDate", "BadTime", "Text", "Fake"] {
        assert!(
            tasks
                .iter()
                .find(|t| t.title() == title)
                .unwrap()
                .created_at()
                .is_none(),
            "{title}"
        );
    }
    assert_eq!(w.repos()[0].files()[0].source_bytes(), source.as_bytes());
}
#[test]
fn three_calendar_days_include_full_dates_done_memo_and_cancelled() {
    let today = Local::now().date_naive();
    let source = format!(
        "#+TODO: TODO | DONE CNCL\n{}{}{}{}{}{}* NoCreated\n",
        entry("TODO Before", today - Duration::days(3), "23:59"),
        entry("TODO Boundary", today - Duration::days(2), "00:00"),
        entry("DONE Done", today - Duration::days(1), "11:00"),
        entry("CNCL Cancelled", today, "10:00"),
        entry("Memo", today, "23:59"),
        entry("Future", today + Duration::days(1), "00:00")
    );
    let w = OrgWorkspace::new(vec![repo("a", &[("tasks.org", &source)])]).unwrap();
    let query = TaskQuery {
        expression: "cr.ge.-2d cr.le.today .o.created".into(),
        ..Default::default()
    };
    let tasks = w.query(&query).unwrap().tasks;
    assert_eq!(
        tasks
            .iter()
            .map(|task| task.title())
            .collect::<Vec<_>>(),
        ["Memo", "Cancelled", "Done", "Boundary"]
    );
    assert!(tasks[1].is_cancelled());
    assert!(tasks[2].is_done());
    assert!(tasks[0].state().is_none());
    assert!(!tasks[2].is_cancelled());
    let json = serde_json::to_value(&query).unwrap();
    assert!(json.get("createdRange").is_none());
}

fn entry(title: &str, date: NaiveDate, time: &str) -> String {
    format!("* {title}\n:PROPERTIES:\n:CREATED: [{date} {time}]\n:END:\n")
}

#[test]
fn excluded_files_are_structured_repository_specific_and_legacy_paths_are_rejected() {
    let source = "* Note\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 11:00]\n:END:\n";
    let w = OrgWorkspace::new(vec![
        repo("a", &[("inbox.org", source)]),
        repo("b", &[("inbox.org", source)]),
    ])
    .unwrap();
    let q = TaskQuery {
        excluded_files: vec![OrgFileRef {
            repo_id: "a".into(),
            path: "inbox.org".into(),
        }],
        ..Default::default()
    };
    let tasks = w.query(&q).unwrap().tasks;
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].repo_id(), "b");
    assert!(
        w.query(&TaskQuery {
            excluded_files: vec![
                OrgFileRef {
                    repo_id: "a".into(),
                    path: "inbox.org".into()
                },
                OrgFileRef {
                    repo_id: "b".into(),
                    path: "inbox.org".into()
                }
            ],
            ..Default::default()
        })
        .unwrap()
        .tasks
        .is_empty()
    );
    assert!(serde_json::from_str::<TaskQuery>(r#"{"excludedFiles":["inbox.org"]}"#).is_err());
    assert!(
        serde_json::from_str::<TaskQuery>(r#"{"excludedFiles":[{"path":"inbox.org"}]}"#).is_err()
    );
    assert!(
        w.query(&TaskQuery {
            excluded_files: vec![OrgFileRef {
                repo_id: "".into(),
                path: "inbox.org".into()
            }],
            ..Default::default()
        })
        .is_err()
    );
    assert!(
        w.query(&TaskQuery {
            excluded_files: vec![OrgFileRef {
                repo_id: "a".into(),
                path: "../x.org".into()
            }],
            ..Default::default()
        })
        .is_err()
    );
    let legacy: TaskQuery = serde_json::from_str(r#"{"includeDone":true}"#).unwrap();
    assert!(legacy.excluded_files.is_empty());
}
