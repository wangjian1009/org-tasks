mod support;
use org_tasks_core::{OrgFile, OrgRepo, OrgWorkspace, TaskQuery};

fn workspace(source: &str) -> OrgWorkspace {
    let mut repo = OrgRepo::new("/unused/projects".into()).unwrap();
    repo.id = "repo".into();
    let file = OrgFile::new(
        repo.id.clone(),
        "project.org".into(),
        source.as_bytes().to_vec(),
    )
    .unwrap();
    support::push_file(&mut repo, file);
    OrgWorkspace::new(vec![repo]).unwrap()
}

#[tokio::test]
async fn only_file_project_tags_enable_names_and_name_property_precedes_title() {
    for (source, expected) in [
        (
            "#+TITLE: Fallback\n#+FILETAGS: :work:project:\n#+PROPERTY_NAME: Named\n* TODO Task\n",
            Some("Named"),
        ),
        (
            "#+TITLE: Fallback\n#+filetags: :project:\n* TODO Task\n",
            Some("Fallback"),
        ),
        ("#+FILETAGS: :project:\n* TODO Task\n", Some("")),
        (
            "#+TITLE: Fallback\n#+FILETAGS: :project:\n#+PROPERTY_NAME:\n* TODO Task\n",
            Some(""),
        ),
        (
            "#+TITLE: Plain\n#+PROPERTY_NAME: Named\n* TODO Task :project:\n",
            None,
        ),
        ("#+TITLE: Plain\n#+TAGS: project\n* TODO Task\n", None),
        ("#+TITLE: Plain\n#+FILETAGS: :PROJECT:\n* TODO Task\n", None),
        (
            "#+TITLE: Plain\n#+begin_src org\n#+FILETAGS: :project:\n#+PROPERTY_NAME: Fake\n#+end_src\n* TODO Task\n",
            None,
        ),
        (
            "#+TITLE: Plain\n* TODO Task\n#+FILETAGS: :project:\n#+PROPERTY_NAME: Body\n",
            None,
        ),
    ] {
        let workspace = workspace(source);
        let metadata = workspace.repos()[0].file_metadata().await.unwrap();
        assert_eq!(metadata[0].project(), expected, "{source}");
        let result = workspace
            .query(&[TaskQuery::default()])
            .await
            .unwrap()
            .remove(0);
        assert_eq!(result.tasks[0].project(), expected, "{source}");
        assert_eq!(result.tasks[0].file_metadata().project(), expected);
        assert_eq!(
            workspace.repos()[0]
                .file("project.org")
                .await
                .unwrap()
                .source_bytes(),
            source.as_bytes()
        );
    }
}

#[tokio::test]
async fn task_projects_delegate_to_shared_file_metadata_and_keep_their_original_snapshot() {
    let workspace =
        workspace("#+FILETAGS: :project:\n#+TITLE: Original\n* TODO First\n** TODO Second\n");
    let tasks = workspace
        .query(&[TaskQuery::default()])
        .await
        .unwrap()
        .remove(0)
        .tasks;
    assert!(std::ptr::eq(
        tasks[0].file_metadata(),
        tasks[1].file_metadata()
    ));
    assert_eq!(tasks[0].project(), Some("Original"));
    let disk = std::path::Path::new(&workspace.repos()[0].root_directory).join("project.org");
    std::fs::write(
        &disk,
        "#+FILETAGS: :project:\n#+PROPERTY_NAME: Changed\n* TODO First\n",
    )
    .unwrap();
    let changed = workspace
        .query(&[TaskQuery::default()])
        .await
        .unwrap()
        .remove(0);
    assert_eq!(changed.tasks[0].project(), Some("Changed"));
    assert_eq!(tasks[0].project(), Some("Original"));
    std::fs::remove_file(disk).unwrap();
    assert_eq!(tasks[1].project(), Some("Original"));
    assert_eq!(changed.tasks[0].project(), Some("Changed"));
}
