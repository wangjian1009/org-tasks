mod support;
use org_tasks_core::{
    CoreQuery, CoreSettings, FileQuery, OrgFile, OrgRepo, OrgWorkspace, TaskQuery, TaskState,
    TaskStateCategory,
};

fn workspace() -> OrgWorkspace {
    let mut repo = OrgRepo::new("/unused/core-settings".into()).unwrap();
    repo.id = "settings".into();
    let file = OrgFile::new(repo.id.clone(), "tasks.org".into(),
        b"#+TODO: OPEN RUN HOLD STOP FINISH | END\n* OPEN One\n* RUN Two\n* HOLD Three\n* STOP Four\n* FINISH Five\n* END Six\n* Plain\n".to_vec()).unwrap();
    support::push_file(&mut repo, file);
    OrgWorkspace::new(vec![repo]).unwrap()
}

fn state(name: &str, category: Option<TaskStateCategory>) -> TaskState {
    TaskState {
        name: name.into(),
        category,
    }
}

#[test]
fn categories_serialize_canonical_names_and_read_legacy_cancel() {
    use TaskStateCategory::*;
    for (category, name) in [
        (Todo, "Todo"),
        (Doing, "Doing"),
        (Wait, "Wait"),
        (Done, "Done"),
        (Cancel, "Cancel"),
    ] {
        assert_eq!(serde_json::to_value(category).unwrap(), name);
        assert_eq!(
            serde_json::from_value::<TaskStateCategory>(name.into()).unwrap(),
            category
        );
    }
    let legacy = r#"{"additionStates":[{"name":"STOP","category":"Cancle"}]}"#;
    let settings: CoreSettings = serde_json::from_str(legacy).unwrap();
    assert_eq!(settings.addition_states[0].category, Some(Cancel));
    assert_eq!(
        serde_json::to_value(settings).unwrap()["additionStates"][0]["category"],
        "Cancel"
    );
}

#[test]
fn legacy_cancel_declarations_preserve_source_and_normalize_settings() {
    let source =
        b"#+TODO: TODO STOP | DONE\n#+TASK_STATE_CATEGORY: Cancle STOP\n* STOP Cancelled\n";
    let file = OrgFile::new("repo".into(), "tasks.org".into(), source.to_vec()).unwrap();
    assert_eq!(
        file.nodes()[0].state().unwrap().category,
        Some(TaskStateCategory::Cancel)
    );
    assert!(file.nodes()[0].is_done());
    assert_eq!(file.source_bytes(), source);
    let settings = org_tasks_core::TodoConfig::from_settings(
        "#+TODO: TODO STOP | DONE\n#+TASK_STATE_CATEGORY: Cancle STOP\n",
    )
    .unwrap()
    .to_settings();
    assert!(settings.contains("#+TASK_STATE_CATEGORY: Cancel STOP"));
    assert!(!settings.contains("Cancle"));
}

#[test]
fn settings_are_owned_objects_and_invalid_updates_are_atomic() {
    let mut workspace = workspace();
    assert_eq!(
        workspace.get_settings(),
        CoreSettings {
            addition_states: vec![]
        }
    );
    let configured = CoreSettings {
        addition_states: vec![
            state("RUN", Some(TaskStateCategory::Doing)),
            state("UNASSIGNED", None),
        ],
    };
    workspace.set_settings(configured.clone()).unwrap();
    let mut copy = workspace.get_settings();
    copy.addition_states.clear();
    assert_eq!(workspace.get_settings(), configured);
    for invalid in [
        vec![state("TODO", Some(TaskStateCategory::Done))],
        vec![state("CNCL", None)],
        vec![
            state("RUN", Some(TaskStateCategory::Doing)),
            state("RUN", Some(TaskStateCategory::Wait)),
        ],
        vec![state("BAD NAME", None)],
        vec![state("WAITING(w)", Some(TaskStateCategory::Wait))],
    ] {
        let before = workspace.clone();
        assert!(
            workspace
                .set_settings(CoreSettings {
                    addition_states: invalid
                })
                .is_err()
        );
        assert_eq!(workspace, before);
    }
    workspace.set_settings(CoreSettings::default()).unwrap();
    assert!(workspace.get_settings().addition_states.is_empty());
}

#[tokio::test]
async fn tasks_and_file_metadata_choose_the_same_valid_state_and_keep_snapshot_semantics() {
    use TaskStateCategory::*;
    let mut workspace = workspace();
    let configured = CoreSettings {
        addition_states: vec![
            state("RUN", Some(Doing)),
            state("HOLD", Some(Wait)),
            state("STOP", Some(Cancel)),
            state("FINISH", Some(Done)),
        ],
    };
    workspace.set_settings(configured).unwrap();
    let results = workspace
        .query(&[
            TaskQuery::default().into(),
            CoreQuery::File {
                query: FileQuery::default(),
            },
        ])
        .await
        .unwrap();
    let tasks = results[0].clone().into_task().unwrap().tasks;
    let metadata = tasks[0].file_metadata();
    assert_eq!(tasks[1].state(), Some(&state("RUN", Some(Doing))));
    assert_eq!(tasks[3].state(), Some(&state("STOP", Some(Cancel))));
    assert!(tasks[3].is_done());
    assert!(tasks[6].state().is_none());
    for (category, name) in [
        (Todo, "OPEN"),
        (Doing, "RUN"),
        (Wait, "HOLD"),
        (Done, "FINISH"),
        (Cancel, "STOP"),
    ] {
        assert_eq!(
            tasks[0].task_state_of(category),
            Some(state(name, Some(category)))
        );
        assert_eq!(
            metadata.task_state_of(category),
            tasks[0].task_state_of(category)
        );
    }
    let mut returned = tasks[0].task_state_of(Done).unwrap();
    returned.name.clear();
    assert_eq!(tasks[0].task_state_of(Done).unwrap().name, "FINISH");
    workspace
        .set_settings(CoreSettings {
            addition_states: vec![state("RUN", Some(Wait)), state("FINISH", None)],
        })
        .unwrap();
    let after = workspace
        .query(&[TaskQuery::default().into()])
        .await
        .unwrap()
        .remove(0)
        .into_task()
        .unwrap()
        .tasks;
    assert_eq!(after[1].state(), Some(&state("RUN", Some(Wait))));
    assert_eq!(after[4].state(), Some(&state("FINISH", None)));
    assert!(!after[4].is_done());
    assert_eq!(after[0].task_state_of(Doing), None);
    assert_eq!(tasks[1].state(), Some(&state("RUN", Some(Doing))));
    assert_eq!(metadata.task_state_of(Done).unwrap().name, "FINISH");
}

#[tokio::test]
async fn added_repositories_inherit_settings_and_query_filters_use_categories() {
    use TaskStateCategory::*;
    let mut workspace = workspace();
    workspace
        .set_settings(CoreSettings {
            addition_states: vec![state("STOP", Some(Cancel))],
        })
        .unwrap();
    let mut other = OrgRepo::new("/unused/add-settings".into()).unwrap();
    other.id = "other".into();
    let file = OrgFile::new(
        other.id.clone(),
        "other.org".into(),
        b"#+TODO: OPEN STOP | END\n* STOP Cancelled\n".to_vec(),
    )
    .unwrap();
    support::push_file(&mut other, file);
    workspace.add_repo(other).unwrap();
    let tasks = workspace
        .query(&[TaskQuery {
            expression: "it.done".into(),
            ..Default::default()
        }
        .into()])
        .await
        .unwrap()
        .remove(0)
        .into_task()
        .unwrap()
        .tasks;
    assert_eq!(
        tasks
            .iter()
            .filter(|task| task.state().unwrap().category == Some(Cancel))
            .count(),
        2
    );
    assert!(tasks.iter().all(|task| task.is_done()));
    let plain = OrgFile::new(
        "repo".into(),
        "empty.org".into(),
        b"#+TODO:\n* Plain\n".to_vec(),
    )
    .unwrap();
    assert!(plain.nodes()[0].task_state_of(Done).is_none());
}
