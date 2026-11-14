//! 卡片编辑使用的正文与检查清单投影；所有源范围与保真改写由 Core 维护。
use super::{CoreError, OrgFile, TaskPath};
use orgize::{
    SyntaxKind,
    ast::{Headline, List, ListItem},
    rowan::ast::AstNode,
};
use serde::{Deserialize, Serialize};
use std::ops::Range;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskChecklistItem {
    pub id: String,
    pub sibling_group: String,
    pub text: String,
    pub checked: bool,
    pub partial: bool,
    pub depth: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskEditContent {
    pub own_tags: Vec<String>,
    pub notes: String,
    pub notes_html: String,
    pub checklist: Vec<TaskChecklistItem>,
    pub scheduled_repeat: Option<super::TaskRepeatInfo>,
    pub deadline_repeat: Option<super::TaskRepeatInfo>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum TaskChecklistChange {
    Add {
        text: String,
    },
    Edit {
        id: String,
        text: String,
    },
    SetChecked {
        id: String,
        checked: bool,
    },
    Remove {
        id: String,
    },
    Move {
        id: String,
        before_id: Option<String>,
    },
}

pub(crate) fn checklist_lists(headline: &Headline) -> Vec<List> {
    headline
        .section()
        .into_iter()
        .flat_map(|section| {
            section
                .syntax()
                .children()
                .filter_map(List::cast)
                .filter(|list| {
                    // 混合普通列表保留为完整备注，避免拆散非 checkbox 内容。
                    list.syntax()
                        .descendants()
                        .filter_map(ListItem::cast)
                        .all(|item| item.checkbox().is_some() && item.tag().next().is_none())
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

pub(crate) fn note_ranges(file: &OrgFile, headline: &Headline) -> Vec<Range<usize>> {
    let lists = checklist_lists(headline);
    // 重复窗口可能使 orgize 将规划行并入普通段落；读写备注共用规划识别范围。
    let planning_end = super::task_operation_executor::planning_lines(file, headline)
        .last()
        .map(|(_, end, _)| *end)
        .unwrap_or(0);
    headline
        .section()
        .into_iter()
        .flat_map(|section| {
            section
                .syntax()
                .children_with_tokens()
                .filter(|node| {
                    !matches!(
                        node.kind(),
                        SyntaxKind::PLANNING | SyntaxKind::PROPERTY_DRAWER | SyntaxKind::DRAWER
                    ) && !(node.kind() == SyntaxKind::COMMENT_BLOCK
                        && super::task_merging::is_archive(&node.to_string()))
                        && !lists
                            .iter()
                            .any(|list| list.syntax().text_range() == node.text_range())
                })
                .map(|node| {
                    (u32::from(node.text_range().start()) as usize).max(planning_end)
                        ..u32::from(node.text_range().end()) as usize
                })
                .filter(|range| range.start < range.end)
                .collect::<Vec<_>>()
        })
        .collect()
}

pub(crate) fn checklist_items(headline: &Headline) -> Vec<ListItem> {
    checklist_lists(headline)
        .iter()
        .flat_map(|list| {
            list.syntax()
                .descendants()
                .filter_map(ListItem::cast)
                .filter(|item| item.checkbox().is_some())
                .collect::<Vec<_>>()
        })
        .collect()
}

pub(crate) fn item_text_range(file: &OrgFile, item: &ListItem) -> Range<usize> {
    let token = item.checkbox().expect("已验证 checkbox");
    let source = file.source_bytes();
    let mut a = u32::from(token.text_range().end()) as usize + 1;
    while matches!(source.get(a), Some(b' ' | b'\t')) {
        a += 1;
    }
    let mut b = source[a..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map(|n| a + n)
        .unwrap_or(source.len());
    while b > a && matches!(source.get(b - 1), Some(b' ' | b'\t' | b'\r')) {
        b -= 1;
    }
    a..b
}

impl OrgFile {
    pub fn task_edit_content(&self, path: &TaskPath) -> Result<TaskEditContent, CoreError> {
        let headline = self
            .path_headlines()
            .into_iter()
            .find(|(candidate, _)| candidate == path)
            .map(|(_, headline)| headline)
            .ok_or(CoreError::InvalidInput("任务不存在或已改变"))?;
        let notes = note_ranges(self, &headline)
            .iter()
            .map(|range| std::str::from_utf8(&self.source_bytes()[range.clone()]).expect("UTF-8"))
            .collect::<String>();
        let checklist = checklist_items(&headline)
            .iter()
            .map(|item| {
                let token = item.checkbox().expect("checkbox");
                TaskChecklistItem {
                    id: u32::from(item.start()).to_string(),
                    sibling_group: u32::from(
                        item.syntax().parent().expect("父列表").text_range().start(),
                    )
                    .to_string(),
                    text: std::str::from_utf8(&self.source_bytes()[item_text_range(self, item)])
                        .expect("UTF-8")
                        .into(),
                    checked: token.as_ref() == "X" || token.as_ref() == "x",
                    partial: token.as_ref() == "-",
                    depth: item
                        .syntax()
                        .ancestors()
                        .skip(1)
                        .filter(|node| node.kind() == SyntaxKind::LIST_ITEM)
                        .count(),
                }
            })
            .collect();
        Ok(TaskEditContent {
            own_tags: headline.tags().map(|tag| tag.to_string()).collect(),
            notes_html: if notes.trim().is_empty() { String::new() } else { super::text_link::editable_html(&notes) },
            notes,
            checklist,
            scheduled_repeat: super::task_repeat::repeat_info(self, &headline, SyntaxKind::PLANNING_SCHEDULED),
            deadline_repeat: super::task_repeat::repeat_info(self, &headline, SyntaxKind::PLANNING_DEADLINE),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TaskModification, model::task_operation_executor::modify};
    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }
    fn projection(file: &OrgFile) -> TaskEditContent {
        file.task_edit_content(&file.path_headlines()[0].0).unwrap()
    }

    #[test]
    fn notes_html_renders_links_from_exact_notes_without_checklists_or_metadata() {
        let source = "* TODO 任务\r\nSCHEDULED: <2026-11-14 Sat>\r\n:PROPERTIES:\r\n:ID: keep\r\n:END:\r\n备注 [[addr:北京][地点]] 和 https://example.com/a_b?x=1&y=2\r\n- [ ] 独立清单\r\n:LOGBOOK:\r\n- Note taken on [2026-11-14 Sat 09:00] 日志\r\n:END:\r\n** 子任务\r\n其他备注\r\n";
        let document = file(source);
        let edit = projection(&document);
        assert_eq!(edit.notes, "备注 [[addr:北京][地点]] 和 https://example.com/a_b?x=1&y=2\r\n");
        assert!(edit.notes_html.contains("href=\"addr:%E5%8C%97%E4%BA%AC\""));
        assert!(edit.notes_html.contains("href=\"https://example.com/a_b?x=1&amp;y=2\""));
        for hidden in ["独立清单", "日志", "SCHEDULED", "PROPERTIES", "其他备注"] {
            assert!(!edit.notes_html.contains(hidden), "{hidden}");
        }
        assert_eq!(edit.checklist.len(), 1);
        assert_eq!(document.source_bytes(), source.as_bytes());
        assert!(projection(&file("* TODO 空备注\n\n- [ ] 仅清单\n")).notes_html.is_empty());
    }

    #[test]
    fn repeater_window_planning_is_not_notes_and_notes_edits_preserve_it() {
        for nl in ["\n", "\r\n"] {
            let source = "* TODO 测量尿酸 [[id:F6E86A8B-282B-46F8-8450-0C95B51FCE34][并记录]] :健康:\nSCHEDULED: <2026-11-14 Sat .+1w/2w>\n:PROPERTIES:\n:ID: measure\n:END:\n原备注\n- [ ] 并记录\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-11-06 Fri 10:14]\n:END:\n** 子记录\n保持原样\n".replace('\n', nl);
            let mut file = file(&source);
            let edit = projection(&file);
            assert_eq!(edit.notes, format!("原备注{nl}"));
            assert_eq!(edit.checklist.len(), 1);
            assert_eq!(edit.scheduled_repeat.unwrap().rule.unwrap().interval, 1);
            assert_eq!(file.source_bytes(), source.as_bytes());
            let headline = file.path_headlines()[0].1.clone();
            modify(&mut file, &headline, &TaskModification::Notes(Some("新备注".into()))).unwrap();
            assert_eq!(file.source_bytes(), source.replace("原备注", "新备注").as_bytes());
        }
    }

    #[test]
    fn repeater_window_without_notes_stays_empty_and_later_planning_text_is_retained() {
        let mut document = file("* TODO Task\nSCHEDULED: <2026-11-14 Sat .+1w/2w>\n");
        assert!(projection(&document).notes.is_empty());
        let headline = document.path_headlines()[0].1.clone();
        modify(&mut document, &headline, &TaskModification::Notes(Some("备注".into()))).unwrap();
        assert_eq!(document.source_bytes(), "* TODO Task\nSCHEDULED: <2026-11-14 Sat .+1w/2w>\n备注\n".as_bytes());
        let headline = document.path_headlines()[0].1.clone();
        modify(&mut document, &headline, &TaskModification::Notes(None)).unwrap();
        assert_eq!(document.source_bytes(), b"* TODO Task\nSCHEDULED: <2026-11-14 Sat .+1w/2w>\n");
        let document = file("* TODO Task\nSCHEDULED: <2026-11-14 Sat .+1w/2w>\n正文\nSCHEDULED: <2026-11-15 Sun>\n");
        assert_eq!(projection(&document).notes, "正文\nSCHEDULED: <2026-11-15 Sun>\n");
    }
    fn apply(file: &mut OrgFile, change: TaskModification) {
        let headline = file.path_headlines()[0].1.clone();
        modify(file, &headline, &change).unwrap();
    }
    #[test]
    fn inline_projection_excludes_metadata_logs_and_code_literals() {
        let file = file(
            "* TODO 任务 :工作:\nSCHEDULED: <2026-11-09 Mon>\n:PROPERTIES:\n:ID: stable\n:END:\n备注\n- [ ] 条目\n:LOGBOOK:\n日志\n:END:\n#+begin_src org\n- [X] 字面文本\n#+end_src\n** 子任务\n- [ ] 子条目\n",
        );
        let edit = projection(&file);
        assert!(edit.notes.contains("备注"));
        assert!(
            !edit.notes.contains("LOGBOOK")
                && !edit.notes.contains("ID: stable")
                && !edit.notes.contains("SCHEDULED")
        );
        assert!(edit.notes.contains("#+begin_src"));
        assert_eq!(edit.checklist.len(), 1);
        assert_eq!(edit.checklist[0].text, "条目");
    }
    #[test]
    fn checkbox_toggle_changes_only_one_byte_and_preserves_nested_content() {
        let source =
            "* TODO Task\r\n备注  \r\n+ [ ] 外层  \r\n  - [-] 内层\r\n\r\n** Child\r\nbody\r\n";
        let mut file = file(source);
        let item = projection(&file).checklist[1].clone();
        assert_eq!(item.depth, 1);
        assert!(item.partial);
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::SetChecked {
                id: item.id,
                checked: true,
            }),
        );
        assert_eq!(
            file.source_bytes(),
            source.replacen("[-]", "[X]", 1).as_bytes()
        );
    }
    #[test]
    fn checkbox_toggle_updates_title_counts_and_preserves_unrelated_bytes() {
        let source = "* TODO 任务 [0/2] [0%] :工作:\r\n备注 [8/9]  \r\n- [ ] 第一项\r\n- [-] 第二项\r\n  - [X] 嵌套项\r\n#+begin_src org\r\n- [X] 字面条目\r\n#+end_src\r\n** 子任务 [0/1]\r\n- [ ] 子条目\r\n";
        let mut file = file(source);
        let id = projection(&file).checklist[0].id.clone();
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::SetChecked { id, checked: true }),
        );
        let expected = source
            .replace("任务 [0/2] [0%]", "任务 [1/2] [50%]")
            .replace("[ ] 第一项", "[X] 第一项");
        assert_eq!(file.source_bytes(), expected.as_bytes());
        let id = projection(&file).checklist[0].id.clone();
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::SetChecked { id, checked: false }),
        );
        assert_eq!(file.source_bytes(), source.as_bytes());
    }
    #[test]
    fn checkbox_counts_respect_cookie_data_and_literal_title_content() {
        for (property, expected) in [("", "[1/2]"), ("recursive", "[2/3]"), ("todo", "[/]")] {
            let source = format!(
                "* Task [/] ~[8/9]~ =[7/9]= [[https://example.com][[6/9]]]\n:PROPERTIES:\n:COOKIE_DATA: {property}\n:END:\n- [ ] First\n  - [X] Nested\n- [ ] Second\n"
            );
            let mut file = file(&source);
            let id = projection(&file).checklist[0].id.clone();
            apply(
                &mut file,
                TaskModification::Checklist(TaskChecklistChange::SetChecked { id, checked: true }),
            );
            let expected = source
                .replacen("[/]", expected, 1)
                .replace("[ ] First", "[X] First");
            assert_eq!(file.source_bytes(), expected.as_bytes());
        }
    }
    #[test]
    fn checklist_add_and_remove_update_empty_title_counts() {
        let mut file = file("* Task [/] [%]\nNotes\n");
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Add {
                text: "Item".into(),
            }),
        );
        assert_eq!(
            file.source_bytes(),
            b"* Task [0/1] [0%]\nNotes\n- [ ] Item\n"
        );
        let id = projection(&file).checklist[0].id.clone();
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Remove { id }),
        );
        assert_eq!(file.source_bytes(), b"* Task [0/0] [0%]\nNotes\n");
    }
    #[test]
    fn editing_notes_preserves_checklist_and_metadata_bytes() {
        let source = "* TODO Task\nSCHEDULED: <2026-11-09 Mon>\n:PROPERTIES:\n:ID: stable\n:END:\nOld notes\n- [ ] Item\n:LOGBOOK:\nLog\n:END:\n** Child\nUnchanged\n";
        let mut file = file(source);
        apply(
            &mut file,
            TaskModification::Notes(Some("New notes\n".into())),
        );
        assert_eq!(
            file.source_bytes(),
            source.replace("Old notes", "New notes").as_bytes()
        );
    }
    #[test]
    fn add_edit_and_remove_keep_newline_style_and_unrelated_source() {
        let source = "* Task\r\nNote\r\n\r\n** Child\r\nChild body\r\n";
        let mut file = file(source);
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Add {
                text: "First".into(),
            }),
        );
        let item = projection(&file).checklist[0].clone();
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Edit {
                id: item.id.clone(),
                text: "中文标题".into(),
            }),
        );
        assert_eq!(projection(&file).checklist[0].text, "中文标题");
        assert!(
            std::str::from_utf8(file.source_bytes())
                .unwrap()
                .contains("- [ ] 中文标题\r\n** Child")
        );
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Remove { id: item.id }),
        );
        assert_eq!(file.source_bytes(), source.as_bytes());
    }
    #[test]
    fn mixed_lists_remain_intact_in_notes() {
        let source = "* Task\n- ordinary\n- [ ] checked item\n";
        let edit = projection(&file(source));
        assert!(edit.checklist.is_empty());
        assert!(edit.notes.contains("ordinary") && edit.notes.contains("checked item"));
    }
    #[test]
    fn changing_a_day_preserves_time_repeater_warning_and_other_planning() {
        let source = "* TODO Task\r\nSCHEDULED: <2026-11-09 Mon 09:30 +1w -2d> DEADLINE: <2026-11-20 Fri>\r\nNotes\r\n";
        let mut file = file(source);
        apply(
            &mut file,
            TaskModification::ScheduleDate(Some("2026-11-10".into())),
        );
        assert_eq!(
            file.source_bytes(),
            source
                .replace("2026-11-09 Mon", "2026-11-10 Tue")
                .as_bytes()
        );
        apply(&mut file, TaskModification::DeadlineDate(None));
        let result = std::str::from_utf8(file.source_bytes()).unwrap();
        assert!(result.contains("09:30 +1w -2d"));
        assert!(!result.contains("DEADLINE:"));
    }
    #[test]
    fn append_checklist_keeps_mixed_list_visible_and_adds_a_separate_list() {
        let mut file = file("* Task\n- ordinary\n- [ ] mixed\n");
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Add { text: "New".into() }),
        );
        let edit = projection(&file);
        assert_eq!(edit.checklist.len(), 1);
        assert_eq!(edit.checklist[0].text, "New");
        assert!(edit.notes.contains("ordinary") && edit.notes.contains("mixed"));
    }
    #[test]
    fn edits_reject_stale_item_ids_and_invalid_text() {
        let mut file = file("* Task\n- [ ] Item\n");
        let h = file.path_headlines()[0].1.clone();
        assert!(
            modify(
                &mut file,
                &h,
                &TaskModification::Checklist(TaskChecklistChange::Remove { id: "wrong".into() })
            )
            .is_err()
        );
        assert!(
            modify(
                &mut file,
                &h,
                &TaskModification::Checklist(TaskChecklistChange::Add {
                    text: "\n* Injected".into()
                })
            )
            .is_err()
        );
        assert!(
            modify(
                &mut file,
                &h,
                &TaskModification::DeadlineDate(Some("2026-02-30".into()))
            )
            .is_err()
        );
        assert_eq!(file.source_bytes(), b"* Task\n- [ ] Item\n");
    }
    #[test]
    fn editable_own_tags_keep_system_tags_for_unrelated_tag_changes() {
        let file = file("* TODO Task :REFILE:work:\nNotes\n");
        assert_eq!(projection(&file).own_tags, ["REFILE", "work"]);
    }
    #[test]
    fn empty_existing_checklist_item_can_be_edited_without_losing_checkbox() {
        let mut file = file("* Task\n- [ ]\n");
        let edit = projection(&file);
        assert_eq!(edit.checklist.len(), 1);
        apply(
            &mut file,
            TaskModification::Checklist(TaskChecklistChange::Edit {
                id: edit.checklist[0].id.clone(),
                text: "Text".into(),
            }),
        );
        assert_eq!(file.source_bytes(), b"* Task\n- [ ] Text\n");
        assert_eq!(projection(&file).checklist[0].text, "Text");
    }
    #[test]
    fn ordinary_nested_items_are_retained_in_notes_instead_of_being_hidden() {
        let file = file("* Task\n- [ ] Parent\n  - Ordinary child\n");
        let edit = projection(&file);
        assert!(edit.checklist.is_empty());
        assert!(edit.notes.contains("Ordinary child") && edit.notes.contains("Parent"));
    }

    fn move_item(file: &mut OrgFile, from: usize, before: Option<usize>) {
        let items = projection(file).checklist;
        apply(
            file,
            TaskModification::Checklist(TaskChecklistChange::Move {
                id: items[from].id.clone(),
                before_id: before.map(|index| items[index].id.clone()),
            }),
        );
    }

    #[test]
    fn checklist_groups_follow_direct_parent_lists_not_visual_depth() {
        let file = file(
            "* Task\n- [ ] Parent\n  - [ ] Child A\n  - [-] Child B\n- [X] Sibling\n\nNotes\n\n- [ ] Separate\n",
        );
        let items = projection(&file).checklist;
        assert_eq!(items.len(), 5);
        assert_eq!(items[0].sibling_group, items[3].sibling_group);
        assert_eq!(items[1].sibling_group, items[2].sibling_group);
        assert_ne!(items[0].sibling_group, items[1].sibling_group);
        assert_ne!(items[0].sibling_group, items[4].sibling_group);
    }

    #[test]
    fn moving_items_preserves_title_statistics_from_todo_children() {
        let source = "* TODO Task [1/1] [100%]\n- [ ] First\n- [ ] Second\n** DONE Child\n";
        let mut file = file(source);
        move_item(&mut file, 1, Some(0));
        assert_eq!(
            file.source_bytes(),
            source
                .replace("- [ ] First\n- [ ] Second\n", "- [ ] Second\n- [ ] First\n")
                .as_bytes()
        );
    }

    #[test]
    fn moving_first_and_last_preserves_unicode_states_and_unrelated_bytes() {
        let prefix =
            "#+TITLE: 原样\n* TODO Task :work:\n:PROPERTIES:\n:ID: stable\n:END:\n备注  \n";
        let suffix = "\n:LOGBOOK:\n日志\n:END:\n** Child\n正文\n";
        let first = "+ [X] 已完成  \n";
        let second = "+ [-] 部分完成\n";
        let third = "+ [ ] 待办 🧭\n";
        let source = format!("{prefix}{first}{second}{third}{suffix}");
        let mut file = file(&source);
        move_item(&mut file, 0, None);
        assert_eq!(
            file.source_bytes(),
            format!("{prefix}{second}{third}{first}{suffix}").as_bytes()
        );
        move_item(&mut file, 2, Some(0));
        assert_eq!(file.source_bytes(), source.as_bytes());
        let items = projection(&file).checklist;
        assert!(items[0].checked && items[1].partial && !items[2].checked);
    }

    #[test]
    fn moving_parent_carries_nested_content_and_continuation_paragraphs() {
        let parent = "- [ ] Parent\n  continuation  \n\n  - [X] Child A\n  - [-] Child B\n";
        let sibling = "- [ ] Sibling\n";
        let mut file = file(&format!("* Task\n{parent}{sibling}\n** Child\nbody\n"));
        move_item(&mut file, 0, None);
        assert_eq!(
            file.source_bytes(),
            format!("* Task\n{sibling}{parent}\n** Child\nbody\n").as_bytes()
        );
        let items = projection(&file).checklist;
        assert_eq!(
            items.iter().map(|item| item.depth).collect::<Vec<_>>(),
            [0, 0, 1, 1]
        );
    }

    #[test]
    fn moving_nested_siblings_preserves_crlf_numbering_and_parent() {
        let source = "* Task\r\n- [ ] Parent\r\n  3. [@3] [X] First\r\n  9. [-] Second\r\n- [ ] Other\r\n\r\n";
        let mut file = file(source);
        move_item(&mut file, 2, Some(1));
        assert_eq!(
            file.source_bytes(),
            source
                .replace(
                    "  3. [@3] [X] First\r\n  9. [-] Second\r\n",
                    "  9. [-] Second\r\n  3. [@3] [X] First\r\n"
                )
                .as_bytes()
        );
        let items = projection(&file).checklist;
        assert_eq!(items.len(), 4);
        assert_eq!(items[1].depth, 1);
        assert_eq!(items[1].sibling_group, items[2].sibling_group);
    }

    #[test]
    fn moving_rejects_other_lists_parents_descendants_and_stale_targets() {
        let source =
            "* Task\n- [ ] Parent\n  - [ ] Child\n- [ ] Sibling\n\nNotes\n\n- [ ] Separate\n";
        for target in [1, 3, 99] {
            let mut file = file(source);
            let items = projection(&file).checklist;
            let headline = file.path_headlines()[0].1.clone();
            assert!(
                modify(
                    &mut file,
                    &headline,
                    &TaskModification::Checklist(TaskChecklistChange::Move {
                        id: items[0].id.clone(),
                        before_id: Some(
                            items
                                .get(target)
                                .map(|item| item.id.clone())
                                .unwrap_or("stale".into())
                        ),
                    })
                )
                .is_err()
            );
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
    }

    #[test]
    fn releasing_at_current_position_does_not_change_bytes() {
        let source = "* Task\n- [ ] First\n\n- [ ] Second\n\n";
        for (from, before) in [(0, Some(0)), (0, Some(1)), (1, None)] {
            let mut file = file(source);
            move_item(&mut file, from, before);
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
    }

    #[test]
    fn moving_unterminated_last_line_adds_only_a_required_join_newline() {
        for nl in ["\n", "\r\n"] {
            let mut file = file(&format!("* Task{nl}- [ ] First{nl}- [X] Last"));
            move_item(&mut file, 1, Some(0));
            assert_eq!(
                file.source_bytes(),
                format!("* Task{nl}- [X] Last{nl}- [ ] First{nl}").as_bytes()
            );
            assert_eq!(projection(&file).checklist.len(), 2);
            let mut file = super::tests::file(&format!("* Task{nl}- [ ] First{nl}- [X] Last"));
            move_item(&mut file, 0, None);
            assert_eq!(
                file.source_bytes(),
                format!("* Task{nl}- [X] Last{nl}- [ ] First{nl}").as_bytes()
            );
        }
    }

    #[test]
    fn checklist_move_wire_format_uses_camel_case_and_nullable_target() {
        for target in [Some("123".into()), None] {
            let change = TaskChecklistChange::Move {
                id: "42".into(),
                before_id: target.clone(),
            };
            let json = serde_json::json!({"type":"move", "id":"42", "beforeId":target});
            assert_eq!(serde_json::to_value(&change).unwrap(), json);
            assert_eq!(
                serde_json::from_value::<TaskChecklistChange>(json).unwrap(),
                change
            );
        }
    }

    #[test]
    fn moving_keeps_blank_line_slots_and_does_not_split_the_list() {
        let source = "* Task\n- [ ] A\n\n- [ ] B\n\n- [ ] C\n\nNotes\n";
        for from in 0..3 {
            for before in [Some(0), Some(1), Some(2), None] {
                let mut file = file(source);
                let original = projection(&file).checklist;
                let mut expected = vec!["A", "B", "C"];
                let target = before.unwrap_or(3);
                if from != target && from + 1 != target {
                    let moved = expected.remove(from);
                    expected.insert(if target > from { target - 1 } else { target }, moved);
                }
                move_item(&mut file, from, before);
                assert_eq!(
                    file.source_bytes(),
                    format!(
                        "* Task\n- [ ] {}\n\n- [ ] {}\n\n- [ ] {}\n\nNotes\n",
                        expected[0], expected[1], expected[2]
                    )
                    .as_bytes()
                );
                let items = projection(&file).checklist;
                assert_eq!(items.len(), original.len());
                assert!(
                    items
                        .iter()
                        .all(|item| item.sibling_group == items[0].sibling_group)
                );
            }
        }
    }
}
