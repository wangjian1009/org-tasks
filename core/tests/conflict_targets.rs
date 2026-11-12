//! 自动定位只能在主树内得到唯一任务；显式 Org ID 始终优先。
use org_tasks_core::{ConflictTarget, OrgFile, TodoConfig};

fn target(main: &str, candidate: &str, defaults: Option<&str>) -> Option<ConflictTarget> {
    let source = format!(
        "{main}\n* 同步冲突 :CONFLICT:ARCHIVE:\n** 候选\n:PROPERTIES:\n:CONFILICT_ID: point\n:END:\n#+CONFLICT_REASON: modify\n{candidate}"
    );
    let file = OrgFile::with_todo_defaults(
        "repo".into(),
        "a.org".into(),
        source.into_bytes(),
        defaults
            .map(TodoConfig::from_settings)
            .transpose()
            .unwrap()
            .unwrap_or_default(),
    )
    .unwrap();
    file.conflicts().unwrap().remove(0).suggested_target
}

#[test]
fn task_matching_ignores_state_progress_and_plain_headings_but_keeps_the_main_path() {
    let Some(ConflictTarget::Existing(path)) = target(
        "* 分组\n** DONE 工作 [1/2]\n远端\n* 工作\n笔记\n",
        "*** TODO 工作 [0/2]\n本地\n",
        None,
    ) else {
        panic!("唯一任务应可定位")
    };
    assert_eq!(path.titles, ["分组", "工作"]);
}

#[test]
fn duplicated_task_titles_in_different_branches_require_an_explicit_target() {
    assert!(target(
        "* 甲\n** TODO 工作\n* 乙\n** DONE 工作\n",
        "*** TODO 工作\n本地\n",
        None,
    )
    .is_none());
}

#[test]
fn plain_notes_and_unrecognized_states_never_match_as_tasks() {
    for candidate in ["*** 工作\n本地\n", "*** OPEN 工作\n本地\n"] {
        assert!(target("* 工作\n远端\n", candidate, None).is_none());
    }
}

#[test]
fn custom_todo_workflows_are_used_when_identifying_tasks() {
    let Some(ConflictTarget::Existing(path)) = target(
        "* FINISHED 工作\n远端\n",
        "*** OPEN 工作\n本地\n",
        Some("#+TODO: OPEN | FINISHED"),
    ) else {
        panic!("自定义任务状态应可定位")
    };
    assert_eq!(path.titles, ["工作"]);
}

#[test]
fn explicit_id_matches_renamed_tasks_and_never_falls_back_to_another_identity() {
    let Some(ConflictTarget::Existing(path)) = target(
        "* DONE 已改名\n:PROPERTIES:\n:ID: stable\n:END:\n远端\n",
        "*** TODO 工作\n:PROPERTIES:\n:ID: stable\n:END:\n本地\n",
        None,
    ) else {
        panic!("Org ID 应优先于标题")
    };
    assert_eq!(path.titles, ["已改名"]);
    assert!(target(
        "* TODO 工作\n:PROPERTIES:\n:ID: other\n:END:\n远端\n",
        "*** TODO 工作\n:PROPERTIES:\n:ID: missing\n:END:\n本地\n",
        None,
    )
    .is_none());
}

#[test]
fn cards_locate_existing_deletions_and_keep_the_current_subtree_visible() {
    let source = org_tasks_core::merge(
        b"* Group\n** TODO Old\n:PROPERTIES:\n:ID: old\n:END:\nbase\n",
        b"* Group\n",
        b"* Group\n** TODO Old\n:PROPERTIES:\n:ID: old\n:END:\nremote changed\n",
    )
    .unwrap();
    let file = OrgFile::new("repo".into(), "a.org".into(), source).unwrap();
    let point = file.conflicts().unwrap().remove(0);
    assert_eq!(point.reason, "delete");
    assert!(point.display_at_target);
    assert_eq!(point.display_anchor.unwrap().start.byte_offset, 8);
    assert!(point.candidate_html.contains("remote changed"));
    assert!(!point.candidate_html.contains("CONFILICT_ID"));
}

#[test]
fn cards_fall_back_to_the_nearest_surviving_ancestor_without_choosing_an_apply_target() {
    let base = "* Root\n:PROPERTIES:\n:ID: root\n:END:\n** Gone\n:PROPERTIES:\n:ID: gone\n:END:\n*** TODO Child\n:PROPERTIES:\n:ID: child\n:END:\nbase\n";
    let local = base.replace("base", "local changed");
    let remote = "* Root\n:PROPERTIES:\n:ID: root\n:END:\nremote introduction\n";
    let source =
        org_tasks_core::merge(base.as_bytes(), local.as_bytes(), remote.as_bytes()).unwrap();
    let file = OrgFile::new("repo".into(), "a.org".into(), source).unwrap();
    let point = file.conflicts().unwrap().remove(0);
    assert_eq!(point.reason, "modify-missing");
    assert!(!point.display_at_target);
    assert_eq!(point.display_anchor.unwrap().start.byte_offset, 0);
    assert!(point.suggested_target.is_none());
    assert!(point.requires_target);
    assert!(point.candidate_html.contains("local changed"));
    assert!(!point.candidate_html.contains("CONFLICT_ANCESTORS"));
}

#[test]
fn legacy_material_without_ancestor_information_stays_at_document_root() {
    let file = OrgFile::new("repo".into(), "a.org".into(),
        "* Unrelated\n\n* 同步冲突 :CONFLICT:ARCHIVE:\n** New\n:PROPERTIES:\n:CONFILICT_ID: new\n:END:\n#+CONFLICT_REASON: create\n*** TODO New\ntext\n".as_bytes().to_vec()).unwrap();
    let point = file.conflicts().unwrap().remove(0);
    assert!(point.display_anchor.is_none());
    assert!(!point.display_at_target);
    assert!(point.candidate_html.contains("text"));
}
