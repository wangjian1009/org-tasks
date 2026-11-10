mod support;
use org_tasks_core::{FilterTask, OrgFile, OrgRepo, OrgWorkspace, TaskQuery};

fn workspace(root: &str, path: &str, source: &str) -> OrgWorkspace {
    let mut repo = OrgRepo::new(root.into()).unwrap();
    repo.id = "repo".into();
    { let value = vec![OrgFile::new(repo.id.clone(), path.into(), source.as_bytes().to_vec()).unwrap()]; support::write_files(&mut repo, value); }
    OrgWorkspace::new(vec![repo]).unwrap()
}

async fn tasks(source: &str) -> Vec<FilterTask> {
    workspace("/repo", "inbox.org", source).query(&TaskQuery::default()).await.unwrap().tasks
}

#[tokio::test]
async fn plaintext_has_a_defined_encoding_and_keeps_title_path_boundaries() {
    let records = tasks("* TODO Project\n** TODO Child\n").await;
    let identity: serde_json::Value = serde_json::from_str(records[1].task_id().unwrap()).unwrap();
    assert_eq!(identity[1], "inbox.org");
    assert_eq!(identity[2], serde_json::json!(["Project", "Child"]));
    assert!(std::path::Path::new(identity[0].as_str().unwrap()).is_dir());
    assert!(records.iter().all(|task| task.id().starts_with('[')));
    assert_ne!(
        tasks("* TODO A.B\n** TODO C\n").await[1].id(),
        tasks("* TODO A\n** TODO B.C\n").await[1].id()
    );
}

#[tokio::test]
async fn deleting_earlier_records_cannot_reassign_their_ids_to_survivors() {
    let before = tasks("* TODO Alpha\n* TODO Bravo\n* TODO Charlie\n* TODO Delta\n").await;
    let after = tasks("* TODO Charlie\n* TODO Delta\n").await;
    assert_eq!(before[0].byte_offset(), after[0].byte_offset());
    assert_ne!(before[0].id(), after[0].id());
    assert_eq!(before[2].id(), after[0].id());
    assert_eq!(before[3].id(), after[1].id());
    assert_eq!(tasks("* TODO Delta\n* TODO Charlie\n").await[0].id(), after[1].id());
}

#[tokio::test]
async fn task_state_and_edge_cookies_do_not_change_parent_or_child_identity() {
    let plain = tasks("* TODO Project\n** TODO Child\n").await;
    for source in [
        "* DONE [1/2] Project [50%]\n** DONE [2/2] Child [100%]\n",
        "* TODO Project [/]\n** DONE [%] Child\n",
        "* DONE [1/2][50%] Project [0/2] [%]\n** TODO Child\n",
    ] {
        let updated = tasks(source).await;
        assert_eq!(
            plain.iter().map(|t| t.id()).collect::<Vec<_>>(),
            updated.iter().map(|t| t.id()).collect::<Vec<_>>(),
            "{source}"
        );
        assert_eq!(
            plain.iter().map(|task| task.full_path()).collect::<Vec<_>>(),
            updated.iter().map(|task| task.full_path()).collect::<Vec<_>>(),
            "{source}"
        );
    }
    assert_eq!(tasks("* DONE [2/2] Report\n").await[0].title(), "[2/2] Report");
}

#[tokio::test]
async fn non_task_ancestors_are_skipped_but_the_current_records_title_is_kept() {
    let first = tasks("* Group\n** TODO Project\n*** Notes\n**** TODO Child\n").await;
    let moved = tasks("* Renamed group\n** TODO Project\n*** Different notes\n**** DONE Child\n").await;
    let direct = tasks("* TODO Project\n** TODO Child\n").await;
    assert_eq!(first[3].id(), moved[3].id());
    assert_eq!(first[3].id(), direct[1].id());
    assert_ne!(
        tasks("* Note one\n* Note two\n").await[0].id(),
        tasks("* Note one\n* Note two\n").await[1].id()
    );
    assert_eq!(
        tasks("* TODO Task\n* Group\n** TODO Child\n").await[2].id(),
        tasks("* TODO Child\n").await[0].id()
    );
}

#[tokio::test]
async fn only_edge_progress_is_removed_and_inline_markup_stays_significant() {
    assert_ne!(
        tasks("* TODO Part [1/2] Review\n").await[0].id(),
        tasks("* TODO Part [2/2] Review\n").await[0].id()
    );
    for title in [
        "[one/two] Report",
        "Report [1//2]",
        "*[1/2]* Report",
        "[[https://example.org][[1/2]]] Report",
    ] {
        assert_ne!(
            tasks(&format!("* TODO {title}\n")).await[0].id(),
            tasks("* TODO Report\n").await[0].id()
        );
    }
    let records = tasks("#+TODO: OPEN | FINISHED\n* OPEN Project\n** OPEN Child\n").await;
    let changed = tasks("#+TODO: OPEN | FINISHED\n* FINISHED [2/2] Project\n** FINISHED Child\n").await;
    assert_eq!(records[1].id(), changed[1].id());
}

#[tokio::test]
async fn repo_path_file_path_and_task_ancestors_scope_the_identity() {
    let source = "* TODO Project\n** TODO Child\n";
    let id = tasks(source).await[1].id().to_owned();
    assert_ne!(
        id,
        workspace("/other", "inbox.org", source).query(&TaskQuery::default()).await.unwrap().tasks[1].id()
    );
    assert_ne!(
        id,
        workspace("/repo", "other/inbox.org", source).query(&TaskQuery::default()).await.unwrap().tasks[1].id()
    );
    assert_ne!(id, tasks("* TODO Other project\n** TODO Child\n").await[1].id());
    let mut rebuilt = workspace("/repo", "inbox.org", source);
    rebuilt.repos[0].id = support::id("new-repo-id");
    std::fs::write(std::path::Path::new(&rebuilt.repos[0].root_directory).join(".sync/id"), format!("{}\n", rebuilt.repos[0].id)).unwrap();
    assert_eq!(id, rebuilt.query(&TaskQuery::default()).await.unwrap().tasks[1].id());
}

#[tokio::test]
async fn duplicate_paths_are_distinct_and_ids_do_not_depend_on_query_filters() {
    let source = "* TODO Project\n** TODO Repeat [0/1]\n** DONE Repeat [1/1]\n";
    let all = tasks(source).await;
    assert_ne!(all[1].id(), all[2].id());
    let ws = workspace("/repo", "inbox.org", source);
    let done = ws
        .query(&TaskQuery {
            expression: "it.done".into(),
            ..Default::default()
        }).await
        .unwrap();
    assert_eq!(done.tasks[0].id(), all[2].id());
    assert_eq!(
        all[2].id(),
        tasks(&format!("* TODO Unrelated\n{source}")).await[3].id()
    );
}

#[tokio::test]
async fn display_content_changes_keep_identity_without_rewriting_source() {
    let before = tasks("* TODO [#A] Project :old:\nBody\n").await;
    let source =
        "* DONE [#C] Project [1/1] :new:\r\nSCHEDULED: <2026-11-06 Fri>\r\nChanged body\r\n";
    let ws = workspace("/repo", "inbox.org", source);
    let after = ws.query(&TaskQuery::default()).await.unwrap().tasks;
    assert_eq!(before[0].id(), after[0].id());
    assert_ne!(before[0].body(), after[0].body());
    assert_eq!(ws.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(), source.as_bytes());
}
