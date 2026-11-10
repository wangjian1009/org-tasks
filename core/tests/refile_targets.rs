mod support;
use org_tasks_core::{
    OrgFile, OrgFileEdit, OrgFileRef, OrgRepo, OrgWorkspace, SourcePosition, TaskQuery,
    TaskScanRules, apply_edit, serialize_file,
};

fn repo(id: &str, files: &[(&str, &str)]) -> OrgRepo {
    let mut repo = OrgRepo::new(format!("/unused/{id}")).unwrap();
    repo.id = id.into();
    { let value = files
        .iter()
        .map(|(path, source)| {
            OrgFile::new(id.into(), (*path).into(), source.as_bytes().to_vec()).unwrap()
        })
        .collect(); support::write_files(&mut repo, value); }
    repo
}

#[tokio::test]
async fn targets_use_explicit_tags_and_full_outline_including_plain_and_done_headings() {
    let source = "#+FILETAGS: :REFILE:\r\n\
#+begin_src org\r\n,* 源码中的假目标 :REFILE:\r\n#+end_src\r\n\
#+begin_example\r\n,* 示例中的假目标 :REFILE:\r\n#+end_example\r\n\
* TODO [#A] 项目 :work:\r\n\
** 方向\r\n\
**** DONE [#B] 归档 :REFILE:home:\r\n\
***** 普通子标题\r\n\
**** 旁支 :REFILE:\r\n\
** 其他 :refile:\r\n\
*** 子项 :PREFILE:\r\n\
* 无状态 :REFILE:\r\n";
    let repository = repo("work", &[("nested/tasks.org", source)]);
    let targets = repository.refile_targets().await.unwrap();
    assert_eq!(targets.len(), 3);
    assert_eq!(targets[0].heading_path, ["项目", "方向", "归档"]);
    assert_eq!(targets[1].heading_path, ["项目", "方向", "旁支"]);
    assert_eq!(targets[2].heading_path, ["无状态"]);
    assert_eq!(
        targets[0].display_path(),
        format!("{} / nested/tasks.org / 项目 / 方向 / 归档", support::id("work"))
    );
    let offset = source.find("**** DONE").unwrap();
    assert_eq!(targets[0].position.byte_offset, offset as u64);
    assert_eq!(targets[0].position.column, 0);
    assert_eq!(
        targets[0].position.line,
        source[..offset]
            .bytes()
            .filter(|byte| *byte == b'\n')
            .count() as u32
            + 1
    );
    assert_eq!(serialize_file(&repository.load_files(&[]).await.unwrap()[0]), source.as_bytes());
}

#[tokio::test]
async fn workspace_targets_keep_repository_file_segment_and_duplicate_identity() {
    let source = "* 标题 / 分段\n** 相同 :REFILE:\n** 相同 :REFILE:\n";
    let mut second = repo(
        "b",
        &[
            ("z.org", "* 最后 :REFILE:\n"),
            ("a.org", source),
            ("empty.org", "#+TITLE: 没有放置位置\n"),
        ],
    );
    // 显式目标属于完整文件访问，不受任务扫描范围限制。
    { let value = TaskScanRules::parse("a.org\n").unwrap(); support::set_rules(&mut second, value); }
    let workspace = OrgWorkspace::new(vec![
        second,
        repo(
            "a",
            &[("a.org", "* TODO [[https://example.org][名称]] :REFILE:\n")],
        ),
    ])
    .unwrap();
    let targets = workspace.refile_targets().await.unwrap();
    let a_id = support::id("a");
    let b_id = support::id("b");
    assert_eq!(
        targets
            .iter()
            .map(|target| (target.repo_id.as_str(), target.path.as_str()))
            .collect::<Vec<_>>(),
        [
            (a_id.as_str(), "a.org"),
            (b_id.as_str(), "a.org"),
            (b_id.as_str(), "a.org"),
            (b_id.as_str(), "z.org")
        ]
    );
    assert_eq!(targets[0].heading_path, ["[[https://example.org][名称]]"]);
    assert_eq!(targets[1].heading_path, ["标题 / 分段", "相同"]);
    assert_eq!(targets[1].heading_path, targets[2].heading_path);
    assert_ne!(targets[1].position, targets[2].position);
    let json = serde_json::to_value(&targets[1]).unwrap();
    assert_eq!(json["repoId"], support::id("b"));
    assert_eq!(json["path"], "a.org");
    assert_eq!(
        json["headingPath"],
        serde_json::json!(["标题 / 分段", "相同"])
    );
    assert_eq!(OrgWorkspace::new(vec![]).unwrap().refile_targets().await.unwrap(), []);
}

#[tokio::test]
async fn queries_exclude_conflicts_before_matching_other_system_tags() {
    let source = "* Parent :REFILE:ARCHIVE:CONFLICT:work:REFILE:\n\
** TODO Child :REFILE:CONFLICT:home:refile:\n\
*** TODO Grandchild :next:\n\
* TODO Other :REFILE:refile:\n";
    let workspace = OrgWorkspace::new(vec![repo("r", &[("tasks.org", source)])]).unwrap();
    for (expression, expected) in [
        ("", 1),
        ("t.REFILE", 1),
        ("tn.REFILE", 1),
        (".t.REFILE", 0),
        ("REFILE", 1),
        ("t.home", 0),
        ("t.CONFLICT", 0),
        ("tn.CONFLICT", 0),
        (".t.CONFLICT", 1),
    ] {
        let result = workspace
            .query(&TaskQuery {
                expression: expression.into(),
                ..Default::default()
            }).await
            .unwrap();
        assert_eq!(result.tasks.len(), expected, "{expression}");
        assert!(result.tasks.iter().all(|task| task.title() == "Other"));
    }
    let tasks = workspace.query(&TaskQuery::default()).await.unwrap().tasks;
    assert_eq!(tasks[0].own_tags(), ["refile"]);
    assert!(tasks[0].inherited_tags().is_empty());
    assert_eq!(workspace.refile_targets().await.unwrap().len(), 1);
    assert_eq!(
        serialize_file(&workspace.repos[0].load_files(&[]).await.unwrap()[0]),
        source.as_bytes()
    );
}

#[tokio::test]
async fn structured_query_flags_and_categories_still_apply_before_returning_tags() {
    let source = "#+CATEGORY: Work\n* DONE Parent :REFILE:work:\n** TODO Child :home:\n";
    let workspace = OrgWorkspace::new(vec![repo("r", &[("tasks.org", source)])]).unwrap();
    let query = TaskQuery {
        expression: "t.REFILE".into(),
        categories: vec![Some("Work".into())],
        include_done: false,
        include_compose_tasks: false,
        ..Default::default()
    };
    let result = workspace.query(&query).await.unwrap();
    assert_eq!(result.tasks.len(), 1);
    assert_eq!(result.tasks[0].title(), "Child");
    assert_eq!(result.tasks[0].own_tags(), ["home"]);
    assert_eq!(result.tasks[0].inherited_tags(), ["work"]);
    assert_eq!(result.categories[0].count, 1);
    assert_eq!(workspace.refile_targets().await.unwrap()[0].heading_path, ["Parent"]);
    assert!(
        workspace
            .query(&TaskQuery {
                excluded_files: vec![OrgFileRef {
                    repo_id: support::id("r"),
                    path: "tasks.org".into()
                }],
                ..query
            }).await
            .unwrap()
            .tasks
            .is_empty()
    );
}

#[tokio::test]
async fn targets_read_the_current_tree_after_edits_without_reusing_stale_positions() {
    let mut repository = repo("r", &[("tasks.org", "* 原目标 :REFILE:\n")]);
    let old = repository.refile_targets().await.unwrap();
    let mut file = repository.file("tasks.org").await.unwrap();
    apply_edit(
        &mut file,
        OrgFileEdit::InsertAt {
            anchor: SourcePosition::new(1, 0, 0).unwrap(),
            content: "* 新目标 :REFILE:\n".as_bytes().to_vec(),
        },
    )
    .unwrap();
    support::push_file(&mut repository, file);
    let current = repository.refile_targets().await.unwrap();
    assert_eq!(current.len(), 2);
    assert_eq!(current[0].heading_path, ["新目标"]);
    assert_eq!(current[1].heading_path, ["原目标"]);
    assert_eq!(current[1].position.line, 2);
    assert!(current[1].position.byte_offset > old[0].position.byte_offset);
    assert_eq!(old[0].position.line, 1);
}

#[tokio::test]
async fn target_query_scopes_files_before_categories_and_keeps_peer_repository_files() {
    use org_tasks_core::RefileTargetQuery;
    let source = "#+CATEGORY: Hidden\n* First :REFILE:\n* Second :REFILE:\n";
    let w = OrgWorkspace::new(vec![
        repo(
            "a",
            &[
                ("inbox.org", source),
                ("someday.org", source),
                ("normal.org", "#+CATEGORY: Work\n* Normal :REFILE:\n"),
            ],
        ),
        repo(
            "b",
            &[("someday.org", "#+CATEGORY: Peer\n* Peer :REFILE:\n")],
        ),
    ])
    .unwrap();
    let query = RefileTargetQuery {
        files: vec![],
        excluded_files: vec![
            OrgFileRef {
                repo_id: support::id("a"),
                path: "inbox.org".into(),
            },
            OrgFileRef {
                repo_id: support::id("a"),
                path: "someday.org".into(),
            },
        ],
    };
    let targets = w.query_refile_targets(&query).await.unwrap();
    assert_eq!(
        targets
            .iter()
            .map(|target| target.category.as_deref())
            .collect::<Vec<_>>(),
        [Some("Work"), Some("Peer")]
    );
    let shortcut = w
        .query_refile_targets(&RefileTargetQuery {
            files: vec![OrgFileRef {
                repo_id: support::id("a"),
                path: "someday.org".into(),
            }],
            ..Default::default()
        }).await
        .unwrap();
    assert_eq!(shortcut.len(), 2);
    assert_eq!(shortcut[0].heading_path, ["First"]);
    assert!(shortcut[0].position.byte_offset < shortcut[1].position.byte_offset);
    assert!(
        w.query_refile_targets(&RefileTargetQuery {
            excluded_files: vec![OrgFileRef {
                repo_id: support::id("a"),
                path: "../escape.org".into()
            }],
            ..Default::default()
        }).await
        .is_err()
    );
}
