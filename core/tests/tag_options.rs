mod support;
use org_tasks_core::{OrgFile, OrgRepo, OrgWorkspace, TaskQuery};

fn workspace(source: &str) -> OrgWorkspace {
    let mut repo = OrgRepo::new("/unused/file-tags".into()).unwrap();
    repo.id = "repo".into();
    { let value = OrgFile::new(repo.id.clone(), "notes.org".into(), source.as_bytes().to_vec()).unwrap(); support::push_file(&mut repo, value); };
    OrgWorkspace::new(vec![repo]).unwrap()
}

#[tokio::test]
async fn header_tag_options_include_unused_choices_and_ignore_shortcuts_groups_and_literal_keywords() {
    let source = "#+tags: { @work(w) @home(h) } 家居(j) unused\n#+TAGS: [ project : child ] 家居 REFILE ARCHIVE ref宜\n#+FILETAGS: :file:家居:REFILE:ARCHIVE:\n#+filetags: :second:file:\n#+begin_src org\n#+TAGS: fake\n#+FILETAGS: :fake:\n#+end_src\n* Note\n#+TAGS: body\n#+FILETAGS: :body:\n";
    let ws = workspace(source);
    let file = &ws.repos()[0].load_files(&[]).await.unwrap()[0];
    assert_eq!(file.tag_options(), ["@work", "@home", "家居", "unused", "project", "child", "ref宜"]);
    assert_eq!(file.tag_groups(), vec![vec!["@work", "@home"]]);
    assert_eq!(support::query_files(&ws.repos()[0]).await.unwrap()[0].tag_options, file.tag_options());
    assert_eq!(file.source_bytes(), source.as_bytes());
    let result = ws.query(&[(TaskQuery { expression: "t.unused".into(), ..Default::default() }).into()]).await.unwrap().remove(0).into_task().unwrap();
    assert!(result.tasks.is_empty(), "TAGS 候选不能作为任务实际标签");
}

#[tokio::test]
async fn example_tag_configuration_preserves_three_exclusive_groups_and_tags_without_shortcuts() {
    let source = "#+TAGS: { iOS(i) Android(a) }\n#+TAGS: { BUG(b) FEAT(f) DEV(d) TASK(t) VER(v) MEET(m) }\n#+TAGS: { SDK(s) COOL(c) COOLITE(l) NOW(n) VStar(p) SEEK(k) SVR }\n";
    let ws = workspace(source);
    let file = &ws.repos()[0].load_files(&[]).await.unwrap()[0];
    assert_eq!(file.tag_groups(), vec![vec!["iOS", "Android"],
        vec!["BUG", "FEAT", "DEV", "TASK", "VER", "MEET"],
        vec!["SDK", "COOL", "COOLITE", "NOW", "VStar", "SEEK", "SVR"]]);
    assert_eq!(file.tag_options().len(), 15);
    assert!(file.tag_options().contains(&"SVR".to_owned()));
    assert_eq!(support::query_files(&ws.repos()[0]).await.unwrap()[0].tag_groups, file.tag_groups());
    assert_eq!(file.source_bytes(), source.as_bytes());
}

#[tokio::test]
async fn configured_choices_do_not_change_record_tags_or_query_matching() {
    let source = "#+TAGS: unused(u) 家居(j) REFILE ARCHIVE\n* Parent :家居:\n** TODO Child :own:\n* Note\n";
    let ws = workspace(source);
    let tasks = ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    assert_eq!(tasks[0].own_tags(), ["家居"]);
    assert_eq!(tasks[1].own_tags(), ["own"]);
    assert_eq!(tasks[1].inherited_tags(), ["家居"]);
    assert!(tasks[2].own_tags().is_empty());
    assert!(tasks[2].inherited_tags().is_empty());
    for expression in ["t.unused", "t.REFILE", "t.ARCHIVE"] {
        assert!(ws.query(&[(TaskQuery { expression: expression.into(), ..Default::default() }).into()]).await.unwrap().remove(0).into_task().unwrap().tasks.is_empty());
    }
    assert!(ws.refile_targets().await.unwrap().is_empty());
    assert_eq!(ws.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(), source.as_bytes());
}

#[tokio::test]
async fn an_empty_file_keeps_configured_options_and_peer_files_do_not_share_tags() {
    let mut ws = workspace("#+TAGS: unused(u)\n#+FILETAGS: :file:\n");
    { let value = OrgFile::new("repo".into(), "other.org".into(), b"* Other\n".to_vec()).unwrap(); support::push_file(&mut ws.repos[0], value); };
    let info = support::query_files(&ws.repos()[0]).await.unwrap();
    assert_eq!(info[0].tag_options, ["unused"]);
    assert_eq!(info[0].task_state_counts.iter().map(|item| item.count).sum::<usize>(), 0);
    assert!(info[1].tag_options.is_empty());
    let tasks = ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    assert_eq!(tasks.len(), 1);
    assert!(tasks[0].inherited_tags().is_empty());
}

#[tokio::test]
async fn task_file_metadata_is_shared_and_remains_an_independent_snapshot() {
    let mut ws = workspace("#+TITLE: Original\n#+TAGS: { iOS Android } 工作\n* TODO First\n* TODO Second\n");
    { let value = OrgFile::new("repo".into(), "other.org".into(), b"* TODO Other\n".to_vec()).unwrap(); support::push_file(&mut ws.repos[0], value); };
    let tasks = ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    let first = tasks.iter().find(|task| task.title() == "First").unwrap();
    let second = tasks.iter().find(|task| task.title() == "Second").unwrap();
    let other = tasks.iter().find(|task| task.title() == "Other").unwrap();
    assert!(std::ptr::eq(first.file_metadata(), second.file_metadata()));
    assert!(std::ptr::eq(first.file_metadata(), first.clone().file_metadata()));
    assert!(!std::ptr::eq(first.file_metadata(), other.file_metadata()));
    assert!(std::ptr::eq(first.support_tags().unwrap(), second.support_tags().unwrap()));
    { let value = OrgFile::new("repo".into(), "notes.org".into(), b"#+TITLE: Updated\n* TODO First\n".to_vec()).unwrap(); support::replace_file(&mut ws.repos[0], 0, value); }
    drop(ws);
    assert_eq!(first.file_metadata().title.as_deref(), Some("Original"));
    assert_eq!(first.support_tags().unwrap().groups, vec![vec!["iOS", "Android"]]);
    assert_eq!(first.file_metadata().task_state_counts.iter().map(|item| item.count).sum::<usize>(), 2);
}

#[tokio::test]
async fn supported_tags_distinguish_absent_configuration_from_explicit_empty_configuration() {
    let ws = workspace("* TODO No configuration :existing:\n");
    assert!(ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks[0].support_tags().is_none());
    let ws = workspace("#+TAGS:\n* TODO Explicit empty\n");
    let tasks = ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    let config = tasks[0].support_tags().unwrap();
    assert!(config.tags.is_empty());
    assert!(config.groups.is_empty());
}

#[tokio::test]
async fn supported_tags_preserve_exclusive_groups_and_are_scoped_to_the_origin_file() {
    let mut ws = workspace("#+TAGS: { iOS(i) Android(a) } { BUG(b) FEAT(f) } 工作 REFILE ARCHIVE\n* TODO First\n** TODO Child\n");
    { let value = OrgFile::new("repo".into(), "other.org".into(), b"#+TAGS: unrelated\n* TODO Other\n".to_vec()).unwrap(); support::push_file(&mut ws.repos[0], value); };
    let tasks = ws.query(&[(TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
    let first = tasks.iter().find(|task| task.title() == "First").unwrap();
    let child = tasks.iter().find(|task| task.title() == "Child").unwrap();
    let config = first.support_tags().unwrap();
    assert_eq!(config.tags, ["iOS", "Android", "BUG", "FEAT", "工作"]);
    assert_eq!(config.groups, vec![vec!["iOS", "Android"], vec!["BUG", "FEAT"]]);
    assert_eq!(child.support_tags(), Some(config));
    assert_eq!(tasks.iter().find(|task| task.title() == "Other").unwrap().support_tags().unwrap().tags, ["unrelated"]);
}
