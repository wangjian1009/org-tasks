mod support;
use org_tasks_core::{OrgFile, OrgRepo, OrgWorkspace, TaskQuery};

fn file(source: &str) -> OrgFile {
    OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap()
}

#[test]
fn attachment_flag_uses_own_exact_tag_and_survives_display_filtering() {
    let source = "#+FILETAGS: :ATTACH:file:\n* TODO Parent :ATTACH:work:\n** TODO Child :child:\n* TODO Lower :attach:\n* TODO Literal\n#+begin_src org\n,* Fake :ATTACH:\n#+end_src\n";
    let file = file(source);
    let nodes = file.nodes();
    assert_eq!(nodes.iter().map(|task| task.has_attach()).collect::<Vec<_>>(), [true, false, false, false]);
    assert!(nodes.iter().all(|task| !task.own_tags().iter().chain(task.inherited_tags()).any(|tag| tag == "ATTACH")));
    assert!(nodes[2].own_tags().contains(&"attach".to_owned()));
    assert!(nodes[0].edit_content().own_tags.contains(&"ATTACH".to_owned()));
    assert!(file.special_tags().contains(&"ATTACH".to_owned()));
    assert_eq!(file.source_bytes(), source.as_bytes());
}

#[tokio::test]
async fn queries_match_original_attachment_tags_but_hide_them_in_results() {
    let source = "#+TAGS: { ATTACH(a) work(w) } attach\n* TODO Parent :ATTACH:work:\n** TODO Child :child:\n* TODO Lower :attach:\n";
    let mut repo = OrgRepo::new("/unused/attachment-tags".into()).unwrap();
    repo.id = "repo".into();
    support::push_file(&mut repo, file(source));
    let workspace = OrgWorkspace::new(vec![repo]).unwrap();
    let result = workspace.query(&[TaskQuery { expression: "t.ATTACH".into(), ..Default::default() }.into()]).await.unwrap().remove(0).into_task().unwrap();
    assert_eq!(result.tasks.len(), 2);
    assert!(result.tasks[0].has_attach());
    assert!(!result.tasks[1].has_attach());
    for task in result.tasks {
        assert!(!task.own_tags().iter().chain(task.inherited_tags()).any(|tag| tag == "ATTACH"));
    }
    let nodes = workspace.repos()[0].nodes().await.unwrap();
    assert!(nodes[0].has_attach());
    assert!(nodes.iter().all(|task| !task.own_tags().iter().chain(task.inherited_tags()).any(|tag| tag == "ATTACH")));
    let files = workspace.repos()[0].load_files(&[]).await.unwrap();
    assert_eq!(files[0].tag_options(), ["work", "attach"]);
    assert_eq!(files[0].tag_groups(), [vec!["work"]]);
    assert_eq!(files[0].source_bytes(), source.as_bytes());
}
