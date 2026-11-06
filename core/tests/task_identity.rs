use org_tasks_core::{Filter, FilterTask, OrgFile, OrgRepo, OrgWorkspace, TaskQuery};

fn workspace(root: &str, path: &str, source: &str) -> OrgWorkspace {
    let mut repo = OrgRepo::new(root.into()).unwrap();
    repo.id = "repo".into();
    repo.files =
        vec![OrgFile::new(repo.id.clone(), path.into(), source.as_bytes().to_vec()).unwrap()];
    OrgWorkspace::new(vec![repo]).unwrap()
}

fn tasks(source: &str) -> Vec<FilterTask> {
    workspace("/repo", "inbox.org", source).search(&Filter::parse(""))
}

#[test]
fn md5_has_a_defined_encoding_and_keeps_title_path_boundaries() {
    let records = tasks("* TODO Project\n** TODO Child\n");
    assert_eq!(records[1].id, "c9977ec1396cc0465b20fc09cb18600c");
    assert!(records.iter().all(|task| {
        task.id.len() == 32
            && task
                .id
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    }));
    assert_ne!(
        tasks("* TODO A.B\n** TODO C\n")[1].id,
        tasks("* TODO A\n** TODO B.C\n")[1].id
    );
}

#[test]
fn deleting_earlier_records_cannot_reassign_their_ids_to_survivors() {
    let before = tasks("* TODO Alpha\n* TODO Bravo\n* TODO Charlie\n* TODO Delta\n");
    let after = tasks("* TODO Charlie\n* TODO Delta\n");
    assert_eq!(before[0].byte_offset, after[0].byte_offset);
    assert_ne!(before[0].id, after[0].id);
    assert_eq!(before[2].id, after[0].id);
    assert_eq!(before[3].id, after[1].id);
    assert_eq!(tasks("* TODO Delta\n* TODO Charlie\n")[0].id, after[1].id);
}

#[test]
fn task_state_and_edge_cookies_do_not_change_parent_or_child_identity() {
    let plain = tasks("* TODO Project\n** TODO Child\n");
    for source in [
        "* DONE [1/2] Project [50%]\n** DONE [2/2] Child [100%]\n",
        "* TODO Project [/]\n** DONE [%] Child\n",
        "* DONE [1/2][50%] Project [0/2] [%]\n** TODO Child\n",
    ] {
        let updated = tasks(source);
        assert_eq!(
            plain.iter().map(|t| &t.id).collect::<Vec<_>>(),
            updated.iter().map(|t| &t.id).collect::<Vec<_>>(),
            "{source}"
        );
    }
    assert_eq!(tasks("* DONE [2/2] Report\n")[0].title, "[2/2] Report");
}

#[test]
fn non_task_ancestors_are_skipped_but_the_current_records_title_is_kept() {
    let first = tasks("* Group\n** TODO Project\n*** Notes\n**** TODO Child\n");
    let moved = tasks("* Renamed group\n** TODO Project\n*** Different notes\n**** DONE Child\n");
    let direct = tasks("* TODO Project\n** TODO Child\n");
    assert_eq!(first[3].id, moved[3].id);
    assert_eq!(first[3].id, direct[1].id);
    assert_ne!(
        tasks("* Note one\n* Note two\n")[0].id,
        tasks("* Note one\n* Note two\n")[1].id
    );
    assert_eq!(
        tasks("* TODO Task\n* Group\n** TODO Child\n")[2].id,
        tasks("* TODO Child\n")[0].id
    );
}

#[test]
fn only_edge_progress_is_removed_and_inline_markup_stays_significant() {
    assert_ne!(
        tasks("* TODO Part [1/2] Review\n")[0].id,
        tasks("* TODO Part [2/2] Review\n")[0].id
    );
    for title in [
        "[one/two] Report",
        "Report [1//2]",
        "*[1/2]* Report",
        "[[https://example.org][[1/2]]] Report",
    ] {
        assert_ne!(
            tasks(&format!("* TODO {title}\n"))[0].id,
            tasks("* TODO Report\n")[0].id
        );
    }
    let records = tasks("#+TODO: OPEN | FINISHED\n* OPEN Project\n** OPEN Child\n");
    let changed = tasks("#+TODO: OPEN | FINISHED\n* FINISHED [2/2] Project\n** FINISHED Child\n");
    assert_eq!(records[1].id, changed[1].id);
}

#[test]
fn repo_path_file_path_and_task_ancestors_scope_the_identity() {
    let source = "* TODO Project\n** TODO Child\n";
    let id = tasks(source)[1].id.clone();
    assert_ne!(
        id,
        workspace("/other", "inbox.org", source).search(&Filter::parse(""))[1].id
    );
    assert_ne!(
        id,
        workspace("/repo", "other/inbox.org", source).search(&Filter::parse(""))[1].id
    );
    assert_ne!(id, tasks("* TODO Other project\n** TODO Child\n")[1].id);
    let mut rebuilt = workspace("/repo", "inbox.org", source);
    rebuilt.repos[0].id = "new-repo-id".into();
    assert_eq!(id, rebuilt.search(&Filter::parse(""))[1].id);
}

#[test]
fn duplicate_paths_are_distinct_and_ids_do_not_depend_on_query_filters() {
    let source = "* TODO Project\n** TODO Repeat [0/1]\n** DONE Repeat [1/1]\n";
    let all = tasks(source);
    assert_ne!(all[1].id, all[2].id);
    let ws = workspace("/repo", "inbox.org", source);
    let done = ws
        .query(&TaskQuery {
            expression: "it.done".into(),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(done.tasks[0].id, all[2].id);
    assert_eq!(
        all[2].id,
        tasks(&format!("* TODO Unrelated\n{source}"))[3].id
    );
}

#[test]
fn display_content_changes_keep_identity_without_rewriting_source() {
    let before = tasks("* TODO [#A] Project :old:\nBody\n");
    let source =
        "* DONE [#C] Project [1/1] :new:\r\nSCHEDULED: <2026-11-06 Fri>\r\nChanged body\r\n";
    let ws = workspace("/repo", "inbox.org", source);
    let after = ws.search(&Filter::parse(""));
    assert_eq!(before[0].id, after[0].id);
    assert_ne!(before[0].body, after[0].body);
    assert_eq!(ws.repos()[0].files()[0].source_bytes(), source.as_bytes());
}
