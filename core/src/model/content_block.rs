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
    pub paragraph: bool,
    pub blank_lines_before: usize,
    pub source: String,
    pub html: String,
    pub items: Vec<TaskChecklistItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum ContentBlockChange {
    Replace { id: String, source: String },
    Link { id: String, link: super::TextLink, value: Option<super::LinkValue> },
    ReplaceText { id: String, source: String },
    TreeLink { id: String, link: super::TextLink, value: Option<super::LinkValue> },
    InsertLink { id: String, start: usize, end: usize, source: String, value: super::LinkValue },
    InsertParagraph { id: String, source: String },
    InsertLinkedParagraph { id: String, value: super::LinkValue },
}

pub(super) fn sources<'a>(file: &'a OrgFile, section: Option<Section>, headline: Option<&Headline>)
    -> impl Iterator<Item = (orgize::SyntaxElement, usize, &'a str)> + 'a {
    let planning_end = headline.and_then(|headline| super::task_operation_executor::planning_lines(file, headline).last().map(|(_, end, _)| *end)).unwrap_or(0);
    section.into_iter().flat_map(|section| section.syntax().children_with_tokens().collect::<Vec<_>>()).filter_map(move |node| {
        if matches!(node.kind(), SyntaxKind::PLANNING | SyntaxKind::PROPERTY_DRAWER | SyntaxKind::KEYWORD | SyntaxKind::COMMENT | SyntaxKind::COMMENT_BLOCK) { return None; }
        // 带重复窗口的规划可能让紧邻属性解析为普通 drawer，仍按名称排除元数据。
        if node.kind() == SyntaxKind::DRAWER && node.as_node().and_then(|n| orgize::ast::Drawer::cast(n.clone())).is_some_and(|d| ["PROPERTIES", "LOGBOOK"].iter().any(|name| d.name().eq_ignore_ascii_case(name))) { return None; }
        let start = (u32::from(node.text_range().start()) as usize).max(planning_end);
        let end = u32::from(node.text_range().end()) as usize;
        if start >= end { return None; }
        let source = std::str::from_utf8(&file.source_bytes()[start..end]).expect("UTF-8").trim_end_matches(['\r', '\n']);
        if source.trim().is_empty() { return None; }
        Some((node, start, source))
    })
}

pub(super) fn blank_lines(file: &OrgFile, start: usize) -> usize {
    file.source_bytes()[..start].rsplit(|byte| *byte == b'\n').skip(1)
        .take_while(|line| line.iter().all(u8::is_ascii_whitespace)).count()
}

pub(super) fn blocks(file: &OrgFile, section: Option<Section>, headline: Option<&Headline>) -> Vec<ContentBlock> {
    let checklists = headline.map(super::task_inline::checklist_lists).unwrap_or_else(|| section.as_ref().map(|s| {
        s.syntax().children().filter_map(List::cast).filter(super::task_inline::is_checklist).collect()
    }).unwrap_or_default());
    sources(file, section, headline).map(|(node, start, source)| {
        let list = checklists.iter().find(|list| list.syntax().text_range() == node.text_range());
        let kind = if list.is_some() { ContentBlockKind::Checklist } else { match node.kind() {
            SyntaxKind::LIST => ContentBlockKind::List,
            SyntaxKind::ORG_TABLE => ContentBlockKind::Table,
            _ => ContentBlockKind::Text,
        }};
        // 分隔空行由无损节点的原位置投影，不混入可编辑 source，也不扫描块内部字面内容。
        let blank_lines_before = blank_lines(file, start);
        ContentBlock { id: start.to_string(), kind, paragraph: node.kind() == SyntaxKind::PARAGRAPH,
            blank_lines_before, source: source.into(),
            html: if list.is_some() { String::new() } else { super::text_link::editable_html(source) },
            items: list.map(|list| super::task_inline::project_checklist(file, list)).unwrap_or_default(),
        }
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
    let id = match change {
        ContentBlockChange::Replace { id, .. } | ContentBlockChange::Link { id, .. } => id,
        _ => return super::content_tree::modify(file, headline, change),
    };
    let (block, range) = locate(file, headline, id)?;
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
        ContentBlockChange::Link { link, value, .. } => {
            if block.kind == ContentBlockKind::Checklist { return Err(CoreError::InvalidInput("检查清单链接请通过清单原文编辑")); }
            super::text_link::changed_source(&block.source, link, value)?
        }
        _ => unreachable!("树修改已分发"),
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
    fn repeater_window_property_drawer_does_not_create_a_body_block() {
        for newline in ["\n", "\r\n"] {
            let source = "* TODO 测量尿酸 [[id:record][并记录]]\nSCHEDULED: <2026-11-15 Sun .+1w/2w>\n:PROPERTIES:\n:STYLE: habit\n:LAST_REPEAT: [2026-11-06 Fri 10:14]\n:END:\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-11-06 Fri 10:14]\n:END:\n".replace('\n', newline);
            let file = file(&source);
            let edit = file.task_edit_content(&file.path_headlines()[0].0).unwrap();
            assert!(edit.blocks.is_empty(), "属性与日志不应生成正文区块：{:?}", edit.blocks);
            assert!(edit.notes.trim().is_empty());
            assert!(file.document_sections()[1].blocks.is_empty());
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
    }

    #[test]
    fn hiding_property_drawers_preserves_other_drawers_and_literal_metadata() {
        for newline in ["\n", "\r\n"] {
            let body = "正文 PROPERTIES\n\n:NOTES:\n保留普通抽屉\n:END:\n\n#+begin_example\n:PROPERTIES:\n:STYLE: literal\n:END:\n#+end_example";
            let source = format!("* TODO Task\nSCHEDULED: <2026-11-15 Sun .+1w/2w>\n:properties:\n:STYLE: habit\n:END:\n{body}\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-11-06 Fri 10:14]\n:END:\n").replace('\n', newline);
            let mut file = file(&source);
            let blocks = content(&file);
            assert_eq!(blocks.iter().map(|block| block.source.as_str()).collect::<Vec<_>>(), [
                "正文 PROPERTIES".to_owned(),
                ":NOTES:\n保留普通抽屉\n:END:".replace('\n', newline),
                "#+begin_example\n:PROPERTIES:\n:STYLE: literal\n:END:\n#+end_example".replace('\n', newline),
            ]);
            assert!(blocks[1].html.contains("保留普通抽屉"));
            assert!(blocks[2].html.contains(":STYLE: literal"));
            assert_eq!(file.document_sections()[1].blocks, blocks);
            assert_eq!(file.source_bytes(), source.as_bytes());
            let headline = file.path_headlines()[0].1.clone();
            modify(&mut file, &headline, &ContentBlockChange::Replace { id: blocks[0].id.clone(), source: "修改后的正文".into() }).unwrap();
            assert_eq!(file.source_bytes(), source.replace("正文 PROPERTIES", "修改后的正文").as_bytes());
        }
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
    fn paragraph_boundaries_preserve_blank_line_counts_and_literal_block_contents() {
        for newline in ["\n", "\r\n"] {
            let original = "* TODO Task\n\n\nFirst\ncontinued\n\nSecond\n \t\n\nThird\n\n\n\nFourth\n\n#+begin_src text\nkeep\n\n\nliteral\n#+end_src\n\n#+begin_quote\nQuoted\n\n\nparagraph\n#+end_quote\n\n| A | B |\n\n- [ ] Item\n\n\n".replace('\n', newline);
            let file = file(&original);
            let blocks = content(&file);
            assert_eq!(blocks.iter().map(|block| block.blank_lines_before).collect::<Vec<_>>(), [2, 1, 2, 3, 1, 1, 1, 1]);
            assert_eq!(blocks.iter().map(|block| block.paragraph).collect::<Vec<_>>(), [true, true, true, true, false, false, false, false]);
            assert_eq!(blocks[0].source, format!("First{newline}continued"));
            assert!(blocks[4].source.contains(&format!("keep{newline}{newline}{newline}literal")));
            assert!(blocks[5].source.contains(&format!("Quoted{newline}{newline}{newline}paragraph")));
            assert_eq!(file.document_sections()[1].blocks, blocks);
            assert_eq!(file.source_bytes(), original.as_bytes());
        }
    }

    #[test]
    fn editing_a_paragraph_keeps_separator_bytes_and_reprojects_boundaries() {
        let original = "* Task\r\nFirst\r\n \t\r\n\r\nSecond\r\n\r\nThird\r\n";
        let mut file = file(original);
        let block = content(&file)[1].clone();
        assert_eq!(block.blank_lines_before, 2);
        let headline = file.path_headlines()[0].1.clone();
        modify(&mut file, &headline, &ContentBlockChange::Replace { id: block.id, source: "Changed\ncontinued".into() }).unwrap();
        assert_eq!(file.source_bytes(), original.replace("Second", "Changed\r\ncontinued").as_bytes());
        assert_eq!(content(&file).iter().map(|block| block.blank_lines_before).collect::<Vec<_>>(), [0, 2, 1]);
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
    fn reject_foreign_ids_and_metadata_injection() {
        let original = "* Task\nText\n\n- [ ] Item\n** Child\nOther\n";
        for (id, source) in [("999999".into(), "new"), (content(&file(original))[0].id.clone(), "* Injected"),
            (content(&file(original))[0].id.clone(), ":PROPERTIES:\n:ID: hacked\n:END:"),
            (content(&file(original))[0].id.clone(), "SCHEDULED: <2026-11-14 Sat>"),
            (content(&file(original))[0].id.clone(), "bad\0text")] {
            let mut file = file(original);
            let headline = file.path_headlines()[0].1.clone();
            assert!(modify(&mut file, &headline, &ContentBlockChange::Replace { id, source: source.into() }).is_err());
            assert_eq!(file.source_bytes(), original.as_bytes());
        }
    }

    #[test]
    fn replace_and_remove_whole_checklist_preserve_neighbors_and_update_statistics() {
        for newline in ["\n", "\r\n"] {
            let original = "* TODO Task [0/2]\n:PROPERTIES:\n:ID: stable\n:END:\nBefore  \n\n- [ ] First\n  - [X] Nested\n- [ ] Second\n\n| Keep | Table |\n\n- [X] Other list\n** Child\nchild body\n".replace('\n', newline);
            for replacement in ["- [X] Changed\n- [ ] Added", ""] {
                let mut file = file(&original);
                let block = content(&file).into_iter().find(|block| block.kind == ContentBlockKind::Checklist).unwrap();
                let headline = file.path_headlines()[0].1.clone();
                modify(&mut file, &headline, &ContentBlockChange::Replace { id: block.id, source: replacement.into() }).unwrap();
                let counts = if replacement.is_empty() { "[1/1]" } else { "[2/3]" };
                let expected = original.replace(&block.source, &replacement.replace('\n', newline)).replace("[0/2]", counts);
                assert_eq!(file.source_bytes(), expected.as_bytes());
                assert_eq!(content(&file).iter().filter(|block| block.kind == ContentBlockKind::Checklist).count(), if replacement.is_empty() { 1 } else { 2 });
            }
        }
    }
}
