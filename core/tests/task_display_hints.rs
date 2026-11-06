use org_tasks_core::{Filter, FilterTask, OrgFile, OrgRepo, OrgWorkspace};

fn tasks(source: &str) -> Vec<FilterTask> {
    let mut repo = OrgRepo::new("/tmp/task-display-hints".into()).unwrap();
    repo.id = "display".into();
    repo.files.push(
        OrgFile::new(
            repo.id.clone(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap(),
    );
    let workspace = OrgWorkspace::new(vec![repo]).unwrap();
    let result = workspace.search(&Filter::parse(""));
    assert_eq!(
        workspace.repos()[0].files()[0].source_bytes(),
        source.as_bytes()
    );
    result
}

#[test]
fn repetition_hint_uses_only_current_headline_planning() {
    for (planning, expected) in [
        ("SCHEDULED: <2026-11-06 Fri +1d>", true),
        ("DEADLINE: <2026-11-06 Fri ++2w>", true),
        ("SCHEDULED: <2026-11-06 Fri .+4w/5w>", true),
        (
            "SCHEDULED: <2026-11-06 Fri> DEADLINE: <2026-11-07 Sat +1m>",
            true,
        ),
        ("SCHEDULED: <2026-11-06 Fri -2d>", false),
        ("CLOSED: [2026-11-06 Fri +1d]", false),
        ("普通文字 +1d", false),
        (
            "#+begin_src org\nSCHEDULED: <2026-11-06 Fri +1d>\n#+end_src",
            false,
        ),
    ] {
        let source =
            format!("* TODO Parent\n{planning}\n** TODO Child\nSCHEDULED: <2026-11-06 Fri +1d>\n");
        let tasks = tasks(&source);
        assert_eq!(tasks[0].is_repeating, expected, "{planning}");
        assert!(tasks[1].is_repeating);
    }
}

#[test]
fn body_list_hint_excludes_logbook_and_literal_blocks() {
    for (body, expected) in [
        ("- [ ] 条目\n- 第二项\n", true),
        ("1. 第一项\n2. 第二项\n", true),
        ("- 名词 :: 说明\n", true),
        ("普通正文\n", false),
        ("#+begin_src text\n- 源码中的列表\n#+end_src\n", false),
        ("#+begin_example\n- 示例中的列表\n#+end_example\n", false),
        (":LOGBOOK:\n- State changed\n:END:\n", false),
        (":OTHER:\n- 抽屉中的字面文本\n:END:\n", false),
    ] {
        let task = tasks(&format!("* TODO Task\n{body}")).remove(0);
        let rendered = task.render_content();
        assert_eq!(rendered.has_list, expected, "{body}");
        assert_eq!(task.body, body);
    }
}
