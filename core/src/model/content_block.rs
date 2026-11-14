//! 按直属语法节点投影正文区块；宿主只组装区块，不解析 Org 或重建未修改的正文。
use super::{CoreError, OrgFile, TaskChecklistItem};
use orgize::{SyntaxKind, ast::{Headline, List, Section}, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};
use std::ops::Range;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ContentBlockKind { Text, List, Table, Checklist }

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentBlock {
    pub id: String,
    pub kind: ContentBlockKind,
    pub source: String,
    pub html: String,
    pub items: Vec<TaskChecklistItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum ContentBlockChange {
    Replace { id: String, source: String },
    Link { id: String, link: super::TextLink, value: Option<super::LinkValue> },
}

pub(super) fn blocks(file: &OrgFile, section: Option<Section>, headline: Option<&Headline>) -> Vec<ContentBlock> {
    let planning_end = headline.and_then(|headline| super::task_operation_executor::planning_lines(file, headline).last().map(|(_, end, _)| *end)).unwrap_or(0);
    let checklists = headline.map(super::task_inline::checklist_lists).unwrap_or_else(|| section.as_ref().map(|s| {
        s.syntax().children().filter_map(List::cast).filter(super::task_inline::is_checklist).collect()
    }).unwrap_or_default());
    section.into_iter().flat_map(|section| section.syntax().children_with_tokens().collect::<Vec<_>>()).filter_map(|node| {
        if matches!(node.kind(), SyntaxKind::PLANNING | SyntaxKind::PROPERTY_DRAWER | SyntaxKind::KEYWORD | SyntaxKind::COMMENT | SyntaxKind::COMMENT_BLOCK) { return None; }
        if node.kind() == SyntaxKind::DRAWER && node.as_node().and_then(|n| orgize::ast::Drawer::cast(n.clone())).is_some_and(|d| d.name().eq_ignore_ascii_case("LOGBOOK")) { return None; }
        let start = (u32::from(node.text_range().start()) as usize).max(planning_end);
        let end = u32::from(node.text_range().end()) as usize;
        if start >= end { return None; }
        let source = std::str::from_utf8(&file.source_bytes()[start..end]).expect("UTF-8").trim_end_matches(['\r', '\n']);
        if source.trim().is_empty() { return None; }
        let list = checklists.iter().find(|list| list.syntax().text_range() == node.text_range());
        let kind = if list.is_some() { ContentBlockKind::Checklist } else { match node.kind() {
            SyntaxKind::LIST => ContentBlockKind::List,
            SyntaxKind::ORG_TABLE => ContentBlockKind::Table,
            _ => ContentBlockKind::Text,
        }};
        Some(ContentBlock { id: start.to_string(), kind, source: source.into(),
            html: if list.is_some() { String::new() } else { super::text_link::editable_html(source) },
            items: list.map(|list| super::task_inline::project_checklist(file, list)).unwrap_or_default(),
        })
    }).collect()
}

fn locate(file: &OrgFile, headline: &Headline, id: &str) -> Result<(ContentBlock, Range<usize>), CoreError> {
    let block = blocks(file, headline.section(), Some(headline)).into_iter().find(|block| block.id == id)
        .ok_or(CoreError::InvalidInput("正文区块已变化，请重新载入后编辑"))?;
    let start: usize = block.id.parse().map_err(|_| CoreError::InvalidInput("正文区块身份无效"))?;
    let end = start + block.source.len();
    Ok((block, start..end))
}

pub(super) fn modify(file: &mut OrgFile, headline: &Headline, change: &ContentBlockChange) -> Result<(), CoreError> {
    let id = match change { ContentBlockChange::Replace { id, .. } | ContentBlockChange::Link { id, .. } => id };
    let (block, range) = locate(file, headline, id)?;
    if block.kind == ContentBlockKind::Checklist { return Err(CoreError::InvalidInput("检查清单必须使用结构化清单操作")); }
    let source = match change {
        ContentBlockChange::Replace { source, .. } => {
            if source.contains('\0') { return Err(CoreError::InvalidInput("正文区块不能包含 NUL")); }
            let org = orgize::Org::parse(&format!("* probe\n{source}"));
            if org.document().syntax().descendants().filter(|node| node.kind() == SyntaxKind::HEADLINE).count() != 1
                || org.document().syntax().descendants().any(|node| matches!(node.kind(), SyntaxKind::PLANNING | SyntaxKind::PROPERTY_DRAWER)
                    || orgize::ast::Drawer::cast(node).is_some_and(|d| d.name().eq_ignore_ascii_case("LOGBOOK") || d.name().eq_ignore_ascii_case("PROPERTIES"))) {
                return Err(CoreError::InvalidInput("正文区块不能新增标题、规划或属性与日志抽屉"));
            }
            // 输入法使用 LF；只在当前替换区块内适配文件原有换行，外围字节不变。
            source.replace("\r\n", "\n").replace('\r', "\n").replace('\n', super::task_operation_executor::newline(file))
        }
        ContentBlockChange::Link { link, value, .. } => super::text_link::changed_source(&block.source, link, value)?,
    };
    if block.source == source { return Ok(()); }
    let checkbox_changed = matches!(change, ContentBlockChange::Replace { .. }) && [&block.source, &source].into_iter().any(|source| {
        orgize::Org::parse(source).document().syntax().descendants().filter_map(orgize::ast::ListItem::cast).any(|item| item.checkbox().is_some())
    });
    super::task_operation_executor::replace(file, range, source.as_bytes())?;
    if checkbox_changed {
        super::task_operation_executor::update_title_counts(file, u32::from(headline.start()) as usize, super::title_statistics::Trigger::Checkbox)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn file(source: &str) -> OrgFile { OrgFile::new("repo".into(), "a.org".into(), source.as_bytes().to_vec()).unwrap() }
    fn content(file: &OrgFile) -> Vec<ContentBlock> { file.task_edit_content(&file.path_headlines()[0].0).unwrap().blocks }

    #[test]
    fn blocks_preserve_order_and_exclude_metadata_children_and_literal_checkboxes() {
        let file = file("* TODO Task\nSCHEDULED: <2026-11-14 Sat>\n:PROPERTIES:\n:ID: stable\n:END:\nText\n\n- [ ] First\n  - [X] Child\n\n| A | B |\n| 1 | 2 |\n\n- ordinary\n\n#+begin_src text\n- [ ] literal\n#+end_src\n:LOGBOOK:\n- State \"DONE\"\n:END:\n** TODO Child\nchild body\n");
        let blocks = content(&file);
        assert_eq!(blocks.iter().map(|block| block.kind).collect::<Vec<_>>(), vec![ContentBlockKind::Text, ContentBlockKind::Checklist, ContentBlockKind::Table, ContentBlockKind::List, ContentBlockKind::Text]);
        assert_eq!(blocks[1].items.len(), 2);
        assert_eq!(blocks[1].items[1].depth, 1);
        assert!(blocks[2].html.contains("<table"));
        assert!(blocks[4].html.contains("literal"));
        assert!(blocks.iter().all(|block| !block.source.contains("child body") && !block.source.contains("SCHEDULED") && !block.source.contains("LOGBOOK")));
        let sections = file.document_sections();
        assert_eq!(sections[1].blocks, blocks);
    }

    #[test]
    fn replace_only_target_block_and_preserve_crlf_and_surrounding_bytes() {
        let source = "* TODO Task\r\n:PROPERTIES:\r\n:ID: stable\r\n:END:\r\nBefore\r\n\r\n| A | B |\r\n| 1 | 2 |\r\n\r\nAfter  \r\n:LOGBOOK:\r\nkeep\r\n:END:\r\n** Child\r\nchild\r\n";
        let mut file = file(source);
        let block = content(&file).into_iter().find(|block| block.kind == ContentBlockKind::Table).unwrap();
        let headline = file.path_headlines()[0].1.clone();
        modify(&mut file, &headline, &ContentBlockChange::Replace { id: block.id, source: "| A | B |\n| 3 | 4 |".into() }).unwrap();
        assert_eq!(std::str::from_utf8(file.source_bytes()).unwrap(), source.replace("| 1 | 2 |", "| 3 | 4 |"));
    }

    #[test]
    fn block_link_change_is_local_and_uses_original_snapshot_identity() {
        let mut file = file("* Task\nFirst [[https://example.com][old]]\n\n| https://example.org |\n");
        let block = content(&file)[0].clone();
        let link = super::super::text_link::text_links(&block.source)[0].clone();
        let headline = file.path_headlines()[0].1.clone();
        modify(&mut file, &headline, &ContentBlockChange::Link { id: block.id, link, value: Some(super::super::LinkValue { title: "new".into(), url: "https://example.net".into() }) }).unwrap();
        let source = std::str::from_utf8(file.source_bytes()).unwrap();
        assert!(source.contains("First [[https://example.net][new]]\n\n| https://example.org |"));
    }

    #[test]
    fn converting_an_ordinary_list_to_checkboxes_updates_existing_statistics() {
        let mut file = file("* TODO Task [0/1]\n- ordinary\n");
        let block = content(&file)[0].clone();
        let headline = file.path_headlines()[0].1.clone();
        modify(&mut file, &headline, &ContentBlockChange::Replace { id: block.id, source: "- [X] done".into() }).unwrap();
        assert_eq!(std::str::from_utf8(file.source_bytes()).unwrap(), "* TODO Task [1/1]\n- [X] done\n");
        assert_eq!(content(&file)[0].kind, ContentBlockKind::Checklist);
    }

    #[test]
    fn reject_foreign_ids_metadata_injection_and_whole_checklist_replacement() {
        let original = "* Task\nText\n\n- [ ] Item\n** Child\nOther\n";
        for (id, source) in [("999999".into(), "new"), (content(&file(original))[0].id.clone(), "* Injected"), (content(&file(original))[1].id.clone(), "- [X] Item"),
            (content(&file(original))[0].id.clone(), ":PROPERTIES:\n:ID: hacked\n:END:"),
            (content(&file(original))[0].id.clone(), "SCHEDULED: <2026-11-14 Sat>"),
            (content(&file(original))[0].id.clone(), "bad\0text")] {
            let mut file = file(original);
            let headline = file.path_headlines()[0].1.clone();
            assert!(modify(&mut file, &headline, &ContentBlockChange::Replace { id, source: source.into() }).is_err());
            assert_eq!(file.source_bytes(), original.as_bytes());
        }
    }
}
