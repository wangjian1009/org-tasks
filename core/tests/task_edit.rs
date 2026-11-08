use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::fs;

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

async fn fixture(files: &[(&str, &str)]) -> OrgWorkspace {
    let root = std::env::temp_dir().join(format!(
        "org-edit-{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
        FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&root).await.unwrap();
    for (path, text) in files {
        fs::write(root.join(path), text).await.unwrap();
    }
    let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    OrgWorkspace::new(vec![repo]).unwrap()
}
fn request(w: &OrgWorkspace, title: &str, parent: Option<&RefileTarget>) -> TaskEdit {
    let task = w
        .search(&Filter::parse(""))
        .into_iter()
        .find(|task| task.title == title)
        .unwrap();
    TaskEdit {
        source: w.task_source(&task.id).unwrap(),
        destination: parent.map(|target| TaskDestination {
            repo_id: target.repo_id.clone(),
            path: target.path.clone(),
            file_version: target.file_version.clone(),
            parent: Some(target.position),
            clear_todo: false,
        }),
        queue_repo_ids: w.repos().iter().map(|repo| repo.id.clone()).collect(),
    }
}
async fn text(w: &OrgWorkspace, path: &str) -> String {
    fs::read_to_string(std::path::Path::new(&w.repos()[0].root_directory).join(path))
        .await
        .unwrap()
}
async fn clean(w: OrgWorkspace) {
    for repo in w.repos() {
        fs::remove_dir_all(&repo.root_directory).await.unwrap();
    }
}

#[tokio::test]
async fn move_preserves_subtree_and_places_before_first_child_with_category() {
    let original = "#+TITLE: Inbox\r\n* TODO Item\r\n:PROPERTIES:\r\n:CREATED: [2026-11-08 Sun 09:00]\r\n:END:\r\nBody  \r\n#+begin_src org\r\n,** Literal heading\r\n#+end_src\r\n*** TODO Child\r\nchild body\r\n* TODO Keep\r\nunchanged  \r\n";
    let destination = "#+CATEGORY: Work\r\n* Projects :REFILE:\r\nParent body  \r\n** TODO Existing\r\nold body\r\n* Other\r\n";
    let mut w = fixture(&[("inbox.org", original), ("projects.org", destination)]).await;
    let target = w.refile_targets().remove(0);
    assert_eq!(target.category.as_deref(), Some("Work"));
    let edit = request(&w, "Item", Some(&target));
    w.edit_task(&edit).await.unwrap();
    assert_eq!(
        text(&w, "inbox.org").await,
        "#+TITLE: Inbox\r\n* TODO Keep\r\nunchanged  \r\n"
    );
    let moved = text(&w, "projects.org").await;
    assert!(moved.starts_with(
        "#+CATEGORY: Work\r\n* Projects :REFILE:\r\nParent body  \r\n** TODO Item\r\n"
    ));
    assert!(moved.contains(":CREATED: [2026-11-08 Sun 09:00]\r\n"));
    assert!(
        moved
            .contains("#+begin_src org\r\n,** Literal heading\r\n#+end_src\r\n**** TODO Child\r\n")
    );
    assert!(moved.ends_with("** TODO Existing\r\nold body\r\n* Other\r\n"));
    assert_eq!(w.repos()[0].pending_writes().await.unwrap().len(), 2);
    clean(w).await;
}

#[tokio::test]
async fn same_file_moves_work_in_both_directions_and_reject_self_or_descendants() {
    for source_first in [true, false] {
        let item = "* TODO Item\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n** Descendant :REFILE:\n";
        let parent = "* Parent :REFILE:\nbody\n** Existing\n";
        let original = if source_first {
            format!("{item}{parent}")
        } else {
            format!("{parent}{item}")
        };
        let mut w = fixture(&[("inbox.org", &original)]).await;
        let targets = w.refile_targets();
        let descendant = targets
            .iter()
            .find(|target| target.heading_path.last().unwrap() == "Descendant")
            .unwrap();
        assert!(
            w.edit_task(&request(&w, "Item", Some(descendant)))
                .await
                .is_err()
        );
        assert_eq!(text(&w, "inbox.org").await, original);
        let target = targets
            .iter()
            .find(|target| target.heading_path.last().unwrap() == "Parent")
            .unwrap();
        w.edit_task(&request(&w, "Item", Some(target)))
            .await
            .unwrap();
        assert_eq!(
            text(&w, "inbox.org").await,
            format!(
                "* Parent :REFILE:\nbody\n{}** Existing\n",
                item.replacen("* TODO Item", "** TODO Item", 1).replacen(
                    "** Descendant",
                    "*** Descendant",
                    1
                )
            )
        );
        clean(w).await;
    }
}

#[tokio::test]
async fn stale_source_or_destination_never_changes_either_file() {
    for path in ["inbox.org", "projects.org"] {
        let mut w = fixture(&[
            ("inbox.org", "* TODO Item\n"),
            ("projects.org", "* Parent :REFILE:\n"),
        ])
        .await;
        let edit = request(&w, "Item", Some(&w.refile_targets()[0]));
        fs::write(
            std::path::Path::new(&w.repos()[0].root_directory).join(path),
            "* Changed\n",
        )
        .await
        .unwrap();
        let before = [text(&w, "inbox.org").await, text(&w, "projects.org").await];
        assert!(w.edit_task(&edit).await.is_err());
        assert_eq!(
            [text(&w, "inbox.org").await, text(&w, "projects.org").await],
            before
        );
        assert!(w.repos()[0].pending_writes().await.unwrap().is_empty());
        clean(w).await;
    }
}

#[tokio::test]
async fn memo_clears_root_todo_and_delete_removes_complete_subtree() {
    let mut w = fixture(&[("inbox.org", "* TODO Item\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n** TODO Child\n* TODO Keep\n"), ("memo.org", "#+TITLE: Memo\n* Existing\n")]).await;
    let mut edit = request(&w, "Item", None);
    let file = w.repos()[0]
        .files()
        .iter()
        .find(|file| file.path == "memo.org")
        .unwrap();
    edit.destination = Some(TaskDestination {
        repo_id: w.repos()[0].id.clone(),
        path: "memo.org".into(),
        file_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        parent: None,
        clear_todo: true,
    });
    w.edit_task(&edit).await.unwrap();
    assert!(text(&w, "memo.org").await.starts_with("#+TITLE: Memo\n* Item\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n** TODO Child\n* Existing\n"));
    assert_eq!(text(&w, "inbox.org").await, "* TODO Keep\n");
    w.edit_task(&request(&w, "Item", None)).await.unwrap();
    assert_eq!(text(&w, "memo.org").await, "#+TITLE: Memo\n* Existing\n");
    clean(w).await;
}

#[tokio::test]
async fn cross_repo_move_and_failed_staging_preserve_data() {
    let mut w = fixture(&[("inbox.org", "* TODO Item\nBody\n")]).await;
    let other = fixture(&[("projects.org", "* Parent :REFILE:\n")]).await;
    w.add_repo(other.repos()[0].clone()).unwrap();
    let edit = request(&w, "Item", Some(&w.refile_targets()[0]));
    // 源仓库 outbox 无法创建时，不得让目标文件提前生效。
    let outbox = std::path::Path::new(&w.repos()[0].root_directory).join(".sync/outbox");
    fs::write(&outbox, "blocked").await.unwrap();
    assert!(w.edit_task(&edit).await.is_err());
    assert_eq!(text(&w, "inbox.org").await, "* TODO Item\nBody\n");
    let target_path = std::path::Path::new(&w.repos()[1].root_directory).join("projects.org");
    assert_eq!(
        fs::read_to_string(&target_path).await.unwrap(),
        "* Parent :REFILE:\n"
    );
    fs::remove_file(outbox).await.unwrap();
    w.edit_task(&edit).await.unwrap();
    assert_eq!(text(&w, "inbox.org").await, "");
    assert_eq!(
        fs::read_to_string(target_path).await.unwrap(),
        "* Parent :REFILE:\n** TODO Item\nBody\n"
    );
    clean(w).await;
}

#[tokio::test]
async fn invalid_or_missing_paths_do_not_create_directories() {
    let mut w = fixture(&[("inbox.org", "* TODO Item\n")]).await;
    let original = request(&w, "Item", None);
    for path in [
        "/outside.org",
        "../outside.org",
        ".sync/hidden.org",
        "missing/nested.org",
    ] {
        let mut edit = original.clone();
        edit.source.path = path.into();
        assert!(w.edit_task(&edit).await.is_err());
        assert_eq!(text(&w, "inbox.org").await, "* TODO Item\n");
    }
    assert!(
        !std::path::Path::new(&w.repos()[0].root_directory)
            .join("missing")
            .exists()
    );
    clean(w).await;
}

#[tokio::test]
async fn memo_removes_task_metadata_but_keeps_body_properties_and_child_tasks() {
    for newline in ["\n", "\r\n"] {
        for (state, planning) in [
            (
                "NEXT ",
                "SCHEDULED: <2026-11-08 Sun +1w> DEADLINE: <2026-11-09 Mon> CLOSED: [2026-11-07 Sat 10:00]\n",
            ),
            (
                "FINISHED ",
                "CLOSED: [2026-11-07 Sat 10:00]\nSCHEDULED: <2026-11-08 Sun>\nDEADLINE: <2026-11-09 Mon>\n",
            ),
            ("", "DEADLINE: <2026-11-09 Mon>\n"),
        ] {
            let body = ":PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:ID: keep-id\n:END:\n正文保留  \n这里说明 SCHEDULED、DEADLINE 和 CLOSED。\n#+begin_src org\nSCHEDULED: <2030-01-01 Tue>\n,* TODO 示例标题\n#+end_src\n:LOGBOOK:\n- State \"FINISHED\" from \"NEXT\" [2026-11-07 Sat 10:00]\n:END:\n** NEXT [#B] Child\nSCHEDULED: <2026-11-10 Tue>\n子任务正文\n";
            let preamble = "#+TODO: NEXT | FINISHED\n";
            let original =
                format!("{preamble}* {state}[#A] Item :work:\n{planning}{body}* NEXT Keep\n")
                    .replace('\n', newline);
            let mut w = fixture(&[
                ("inbox.org", &original),
                ("memo.org", "#+TODO: NEXT | FINISHED\n* Existing\n"),
            ])
            .await;
            let mut edit = request(&w, "Item", None);
            let file = w.repos()[0]
                .files()
                .iter()
                .find(|file| file.path == "memo.org")
                .unwrap();
            edit.destination = Some(TaskDestination {
                repo_id: w.repos()[0].id.clone(),
                path: "memo.org".into(),
                file_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                parent: None,
                clear_todo: true,
            });
            w.edit_task(&edit).await.unwrap();
            let memo = text(&w, "memo.org").await;
            assert_eq!(
                memo,
                format!(
                    "{preamble}{}* Existing\n",
                    format!("* Item :work:\n{body}").replace('\n', newline)
                )
            );
            assert_eq!(
                text(&w, "inbox.org").await,
                format!("{preamble}* NEXT Keep\n").replace('\n', newline)
            );
            let parsed = orgize::Org::parse(&memo);
            let root = parsed.first_node::<orgize::ast::Headline>().unwrap();
            assert!(root.todo_keyword().is_none());
            assert!(root.priority().is_none());
            assert!(root.planning().is_none());
            clean(w).await;
        }
    }
}

#[tokio::test]
async fn ordinary_refile_keeps_status_priority_and_planning() {
    let original = "* DONE [#A] Item :work:\nSCHEDULED: <2026-11-08 Sun +1w> DEADLINE: <2026-11-09 Mon> CLOSED: [2026-11-07 Sat 10:00]\nBody  \n";
    let mut w = fixture(&[
        ("inbox.org", original),
        ("targets.org", "* Parent :REFILE:\n"),
    ])
    .await;
    let edit = request(&w, "Item", Some(&w.refile_targets()[0]));
    w.edit_task(&edit).await.unwrap();
    assert_eq!(
        text(&w, "targets.org").await,
        format!("* Parent :REFILE:\n*{original}")
    );
    clean(w).await;
}
