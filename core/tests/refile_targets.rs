use org_tasks_core::{
    Filter, OrgFile, OrgFileEdit, OrgFileRef, OrgRepo, OrgWorkspace, SourcePosition, TaskQuery,
    TaskScanRules, apply_edit, serialize_file,
};

fn repo(id: &str, files: &[(&str, &str)]) -> OrgRepo {
    let mut repo = OrgRepo::new(format!("/unused/{id}")).unwrap();
    repo.id = id.into();
    repo.files = files
        .iter()
        .map(|(path, source)| {
            OrgFile::new(id.into(), (*path).into(), source.as_bytes().to_vec()).unwrap()
        })
        .collect();
    repo
}

#[test]
fn targets_use_explicit_tags_and_full_outline_including_plain_and_done_headings() {
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
    let targets = repository.refile_targets();
    assert_eq!(targets.len(), 3);
    assert_eq!(targets[0].heading_path, ["项目", "方向", "归档"]);
    assert_eq!(targets[1].heading_path, ["项目", "方向", "旁支"]);
    assert_eq!(targets[2].heading_path, ["无状态"]);
    assert_eq!(
        targets[0].display_path(),
        "work / nested/tasks.org / 项目 / 方向 / 归档"
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
    assert_eq!(serialize_file(&repository.files[0]), source.as_bytes());
}

#[test]
fn workspace_targets_keep_repository_file_segment_and_duplicate_identity() {
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
    second.task_scan_rules = TaskScanRules::parse("a.org\n").unwrap();
    let workspace = OrgWorkspace::new(vec![
        second,
        repo(
            "a",
            &[("a.org", "* TODO [[https://example.org][名称]] :REFILE:\n")],
        ),
    ])
    .unwrap();
    let targets = workspace.refile_targets();
    assert_eq!(
        targets
            .iter()
            .map(|target| (target.repo_id.as_str(), target.path.as_str()))
            .collect::<Vec<_>>(),
        [
            ("a", "a.org"),
            ("b", "a.org"),
            ("b", "a.org"),
            ("b", "z.org")
        ]
    );
    assert_eq!(targets[0].heading_path, ["[[https://example.org][名称]]"]);
    assert_eq!(targets[1].heading_path, ["标题 / 分段", "相同"]);
    assert_eq!(targets[1].heading_path, targets[2].heading_path);
    assert_ne!(targets[1].position, targets[2].position);
    let json = serde_json::to_value(&targets[1]).unwrap();
    assert_eq!(json["repoId"], "b");
    assert_eq!(json["path"], "a.org");
    assert_eq!(
        json["headingPath"],
        serde_json::json!(["标题 / 分段", "相同"])
    );
    assert_eq!(OrgWorkspace::new(vec![]).unwrap().refile_targets(), []);
}

#[test]
fn searches_match_original_tags_but_return_no_refile_own_or_inherited_tags() {
    let source = "* Parent :REFILE:ARCHIVE:work:REFILE:\n\
** TODO Child :REFILE:home:refile:\n\
*** TODO Grandchild :next:\n\
* TODO Other :refile:\n";
    let workspace = OrgWorkspace::new(vec![repo("r", &[("tasks.org", source)])]).unwrap();
    for (expression, expected) in [
        ("", 4),
        ("t.REFILE", 3),
        ("tn.REFILE", 2),
        (".t.REFILE", 1),
        ("REFILE", 4),
        ("t.home", 2),
    ] {
        let searched = workspace.search(&Filter::parse(expression));
        let queried = workspace
            .query(&TaskQuery {
                expression: expression.into(),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(searched.len(), expected, "{expression}");
        assert_eq!(searched, queried.tasks, "{expression}");
        assert!(searched.iter().all(|task| {
            task.own_tags
                .iter()
                .chain(&task.inherited_tags)
                .all(|tag| tag != "REFILE" && tag != "ARCHIVE")
        }));
    }
    let tasks = workspace.search(&Filter::parse(""));
    assert_eq!(tasks[0].own_tags, ["work"]);
    assert_eq!(tasks[1].own_tags, ["home", "refile"]);
    assert_eq!(tasks[1].inherited_tags, ["work"]);
    assert_eq!(tasks[2].inherited_tags, ["work", "home", "refile"]);
    assert_eq!(tasks[3].own_tags, ["refile"]);
    assert_eq!(workspace.refile_targets().len(), 2);
    assert_eq!(
        serialize_file(&workspace.repos[0].files[0]),
        source.as_bytes()
    );
}

#[test]
fn structured_query_flags_and_categories_still_apply_before_returning_tags() {
    let source = "#+CATEGORY: Work\n* DONE Parent :REFILE:work:\n** TODO Child :home:\n";
    let workspace = OrgWorkspace::new(vec![repo("r", &[("tasks.org", source)])]).unwrap();
    let query = TaskQuery {
        expression: "t.REFILE".into(),
        categories: vec![Some("Work".into())],
        include_done: false,
        include_compose_tasks: false,
        ..Default::default()
    };
    let result = workspace.query(&query).unwrap();
    assert_eq!(result.tasks.len(), 1);
    assert_eq!(result.tasks[0].title, "Child");
    assert_eq!(result.tasks[0].own_tags, ["home"]);
    assert_eq!(result.tasks[0].inherited_tags, ["work"]);
    assert_eq!(result.categories[0].count, 1);
    assert_eq!(workspace.refile_targets()[0].heading_path, ["Parent"]);
    assert!(
        workspace
            .query(&TaskQuery {
                excluded_files: vec![OrgFileRef {
                    repo_id: "r".into(),
                    path: "tasks.org".into()
                }],
                ..query
            })
            .unwrap()
            .tasks
            .is_empty()
    );
}

#[test]
fn targets_read_the_current_tree_after_edits_without_reusing_stale_positions() {
    let mut repository = repo("r", &[("tasks.org", "* 原目标 :REFILE:\n")]);
    let old = repository.refile_targets();
    apply_edit(
        &mut repository.files[0],
        OrgFileEdit::InsertAt {
            anchor: SourcePosition::new(1, 0, 0).unwrap(),
            content: "* 新目标 :REFILE:\n".as_bytes().to_vec(),
        },
    )
    .unwrap();
    let current = repository.refile_targets();
    assert_eq!(current.len(), 2);
    assert_eq!(current[0].heading_path, ["新目标"]);
    assert_eq!(current[1].heading_path, ["原目标"]);
    assert_eq!(current[1].position.line, 2);
    assert!(current[1].position.byte_offset > old[0].position.byte_offset);
    assert_eq!(old[0].position.line, 1);
}

#[test]
fn target_query_scopes_files_before_categories_and_keeps_peer_repository_files() {
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
                repo_id: "a".into(),
                path: "inbox.org".into(),
            },
            OrgFileRef {
                repo_id: "a".into(),
                path: "someday.org".into(),
            },
        ],
    };
    let targets = w.query_refile_targets(&query).unwrap();
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
                repo_id: "a".into(),
                path: "someday.org".into(),
            }],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(shortcut.len(), 2);
    assert_eq!(shortcut[0].heading_path, ["First"]);
    assert!(shortcut[0].position.byte_offset < shortcut[1].position.byte_offset);
    assert!(
        w.query_refile_targets(&RefileTargetQuery {
            excluded_files: vec![OrgFileRef {
                repo_id: "a".into(),
                path: "../escape.org".into()
            }],
            ..Default::default()
        })
        .is_err()
    );
}
