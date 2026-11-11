mod support;
use org_tasks_core::TaskQuery;
use org_tasks_core::{FilterTask, OrgFile, OrgRepo, OrgWorkspace};

async fn tasks(source: &str) -> Vec<FilterTask> {
    let mut repo = OrgRepo::new("/tmp/task-display-hints".into()).unwrap();
    repo.id = "display".into();
    { let value =
        OrgFile::new(
            repo.id.clone(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap(); support::push_file(&mut repo, value); };
    let workspace = OrgWorkspace::new(vec![repo]).unwrap();
    let result = workspace.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    assert_eq!(
        workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(),
        source.as_bytes()
    );
    result
}

#[tokio::test]
async fn body_first_line_ignores_leading_blank_lines_and_metadata() {
    let source = "* Note\r\n:PROPERTIES:\r\n:CREATED: [2026-11-08 Sun]\r\n:END:\r\n\r\n  \r\n*正文* [[https://example.org][链接]]\r\n第二行\r\n** Child\r\n子标题正文\r\n";
    let records = tasks(source).await;
    assert_eq!(records[0].body_first_line().as_deref(), Some("正文 链接"));
    assert_eq!(records[1].body_first_line().as_deref(), Some("子标题正文"));
    let empty = tasks("* Note\n:PROPERTIES:\n:ID: id\n:END:\n\n:LOGBOOK:\n- 日志内容\n:END:\n** Child\n子标题正文\n").await;
    assert_eq!(empty[0].body_first_line(), None);
}

#[tokio::test]
async fn repetition_hint_uses_only_current_headline_planning() {
    for (planning, expected) in [
        ("SCHEDULED: <2026-11-06 Fri +1d>", true),
        ("DEADLINE: <2026-11-06 Fri ++2w>", true),
        ("SCHEDULED: <2026-11-06 Fri .+4w/5w>", true),
        ("SCHEDULED: <2026-11-06 Fri +1d/3>", true),
        ("SCHEDULED: <2026-11-06 Fri +0d>", true),
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
        let tasks = tasks(&source).await;
        assert_eq!(tasks[0].is_repeating(), expected, "{planning}");
        assert!(tasks[1].is_repeating());
    }
}

#[tokio::test]
async fn repetition_with_org_repeater_deadline_is_a_task_hint_and_not_body_text() {
    let task = tasks(
        "* TODO 阅读 RSS 和资料\nSCHEDULED: <2026-11-08 Sun .+1d/3d>\n:PROPERTIES:\n:END:\n正文\n",
    ).await
    .remove(0);
    assert!(task.is_repeating());
    let rendered = task.render_content();
    assert!(rendered.body_html.contains("正文"), "{}", rendered.body_html);
    assert!(!rendered.body_html.contains("SCHEDULED:"), "{}", rendered.body_html);
    assert!(!rendered.body_html.contains(".+1d/3d"), "{}", rendered.body_html);
}

#[tokio::test]
async fn planning_text_after_body_content_is_not_removed_from_rendering() {
    let task = tasks("* TODO 普通正文\n正文第一行\nSCHEDULED: <2026-11-08 Sun +1d>\n").await
        .remove(0);
    let rendered = task.render_content();
    assert!(rendered.body_html.contains("正文第一行"), "{}", rendered.body_html);
    assert!(rendered.body_html.contains("SCHEDULED:"), "{}", rendered.body_html);
}

#[tokio::test]
async fn body_list_hint_excludes_logbook_and_literal_blocks() {
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
        let task = tasks(&format!("* TODO Task\n{body}")).await.remove(0);
        let rendered = task.render_content();
        assert_eq!(rendered.has_list, expected, "{body}");
        assert_eq!(task.body(), body);
    }
}

#[tokio::test]
async fn body_text_hint_excludes_list_item_text() {
    let list = tasks("* TODO Task\n- [ ] 只有列表\n").await.remove(0).render_content();
    assert!(list.has_list);
    assert!(!list.has_text);

    let mixed = tasks("* TODO Task\n普通正文\n- [ ] 列表\n").await.remove(0).render_content();
    assert!(mixed.has_list);
    assert!(mixed.has_text);
}

#[tokio::test]
async fn task_category_preserves_file_value_without_reading_headline_properties() {
    for (header, expected) in [
        ("#+CATEGORY: 生活\n", Some("生活")),
        ("#+category: Work\n", Some("Work")),
        ("#+CATEGORY:\n", Some("")),
        ("", None),
    ] {
        let source = format!(
            "{header}* TODO Parent\n:PROPERTIES:\n:CATEGORY: Other\n:END:\n** TODO Child\n"
        );
        for task in tasks(&source).await {
            assert_eq!(task.category(), expected);
        }
    }
}
