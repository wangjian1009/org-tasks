//! 行内链接的快照定位与局部修改；不由宿主拼接 Org 源码。
use super::{CoreError, OrgFile};
use orgize::{SyntaxKind, ast::Headline, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TextLink {
    pub start: usize,
    pub end: usize,
    pub source: String,
    pub title: String,
    pub url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskLinkField { Title, Notes }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinkValue {
    pub title: String,
    pub url: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskLinkChange {
    pub field: TaskLinkField,
    pub link: TextLink,
    pub value: Option<LinkValue>,
}

pub(super) fn text_links(source: &str) -> Vec<TextLink> {
    let prefix = if source.contains('\n') { 0 } else { 2 };
    let org = orgize::Org::parse(&if prefix == 0 { source.to_owned() } else { format!("x {source}") });
    let mut links = org.document().syntax().descendants()
        .filter_map(orgize::ast::Link::cast)
        .filter(|link| !link.syntax().ancestors().skip(1).any(|node| matches!(node.kind(),
            SyntaxKind::LINK | SyntaxKind::SOURCE_BLOCK | SyntaxKind::EXAMPLE_BLOCK
            | SyntaxKind::COMMENT_BLOCK | SyntaxKind::COMMENT | SyntaxKind::KEYWORD)))
        .map(|link| TextLink {
            start: (u32::from(link.start()) as usize).saturating_sub(prefix),
            end: (u32::from(link.end()) as usize).saturating_sub(prefix),
            source: link.raw(),
            title: link.description().map(|part| part.to_string()).collect(),
            url: link.path().to_string(),
        }).collect::<Vec<_>>();
    // 与渲染器使用同一行内边界，不能让裸链接跨过表格列或描述列表的分隔符。
    let mut inline_ranges = org.document().syntax().descendants().filter(|node| matches!(node.kind(),
        SyntaxKind::PARAGRAPH | SyntaxKind::ORG_TABLE_CELL | SyntaxKind::HEADLINE_TITLE))
        .filter(|node| !node.ancestors().skip(1).any(|parent| matches!(parent.kind(),
            SyntaxKind::LINK | SyntaxKind::SOURCE_BLOCK | SyntaxKind::EXAMPLE_BLOCK
            | SyntaxKind::COMMENT_BLOCK | SyntaxKind::COMMENT | SyntaxKind::EXPORT_BLOCK)))
        .map(|node| node.text_range()).collect::<Vec<_>>();
    for item in org.document().syntax().descendants().filter_map(orgize::ast::ListItem::cast) {
        let tag = item.tag().collect::<Vec<_>>();
        if let (Some(first), Some(last)) = (tag.first(), tag.last()) {
            inline_ranges.push(orgize::rowan::TextRange::new(first.text_range().start(), last.text_range().end()));
        }
    }
    for range in inline_ranges {
        let start = (u32::from(range.start()) as usize).saturating_sub(prefix);
        let end = (u32::from(range.end()) as usize).saturating_sub(prefix).min(source.len());
        for link in super::plain_links::plain_links(&source[start..end]) {
            let range = start + link.range.start..start + link.range.end;
            links.push(TextLink { source: source[range.clone()].into(), start: range.start, end: range.end,
                title: String::new(), url: link.target });
        }
    }
    links.sort_by_key(|link| link.start);
    links.dedup_by_key(|link| link.start);
    links
}

pub(super) fn editable_html(source: &str) -> String {
    let html = super::render::render_fragment(source);
    let links = text_links(source);
    let mut next = links.iter();
    let mut result = String::with_capacity(html.len());
    let mut rest = html.as_str();
    while let Some(start) = [rest.find("<a class=\"link\""), rest.find("<span class=\"link unsupported\"")]
        .into_iter().flatten().min()
    {
        let Some(end) = rest[start..].find('>').map(|offset| start + offset) else { break; };
        result.push_str(&rest[..end]);
        if let Some(link) = next.next() {
            result.push_str(&format!(" data-org-link=\"{}\"", orgize::export::HtmlEscape(serde_json::to_string(link).expect("链接投影"))));
        }
        result.push('>');
        rest = &rest[end + 1..];
    }
    result.push_str(rest);
    result
}

fn replacement(value: &LinkValue) -> Result<String, CoreError> {
    if value.url.trim().is_empty() || value.url.chars().any(char::is_control)
        || value.title.chars().any(char::is_control)
    {
        return Err(CoreError::InvalidInput("链接地址不能为空，标题与地址不能包含换行或控制字符"));
    }
    let url = value.url.replace('[', "%5B").replace(']', "%5D");
    let result = if value.title.is_empty() { format!("[[{url}]]") }
        else { format!("[[{url}][{}]]", value.title) };
    let links = text_links(&result);
    if links.len() != 1 || links[0].source != result || links[0].title != value.title || links[0].url != url {
        return Err(CoreError::InvalidInput("标题或地址包含无法保存的 Org 链接分隔符"));
    }
    Ok(result)
}

pub(super) fn changed_source(source: &str, link: &TextLink, value: &Option<LinkValue>) -> Result<String, CoreError> {
    if !text_links(source).contains(link) { return Err(CoreError::InvalidInput("链接已变化，请重新载入后编辑")); }
    let content = value.as_ref().map(replacement).transpose()?.unwrap_or_default();
    let mut result = source.to_owned();
    result.replace_range(link.start..link.end, &content);
    Ok(result)
}

pub(super) fn modify_link(file: &mut OrgFile, headline: &Headline, change: &TaskLinkChange) -> Result<(), CoreError> {
    let (source, ranges) = match change.field {
        TaskLinkField::Title => {
            let node = headline.syntax().children().find(|node| node.kind() == SyntaxKind::HEADLINE_TITLE)
                .ok_or(CoreError::InvalidInput("标题文字节点不存在"))?;
            let start = u32::from(node.text_range().start()) as usize;
            let source = headline.title_raw().trim_end().to_owned();
            let end = start + source.len();
            (source, vec![start..end])
        }
        TaskLinkField::Notes => {
            let ranges = super::task_inline::note_ranges(file, headline);
            let source = ranges.iter().map(|range| std::str::from_utf8(&file.source_bytes()[range.clone()]).expect("UTF-8")).collect();
            (source, ranges)
        }
    };
    if !text_links(&source).contains(&change.link) {
        return Err(CoreError::InvalidInput("链接已变化，请重新载入后编辑"));
    }
    if change.value.as_ref().is_some_and(|value| value.title == change.link.title && value.url == change.link.url) { return Ok(()); }
    let content = change.value.as_ref().map(replacement).transpose()?.unwrap_or_default();
    let mut offset = 0;
    for range in ranges {
        let length = range.len();
        if offset <= change.link.start && change.link.end <= offset + length {
            if change.field == TaskLinkField::Title {
                let mut title = source.clone();
                title.replace_range(change.link.start..change.link.end, &content);
                // 复用标题结构校验；真实提交只替换链接，不顺带重算未涉及的统计节点。
                let mut candidate = file.clone();
                super::task_operation_executor::modify(&mut candidate, headline, &super::TaskModification::Title(Some(title)))?;
            }
            return super::task_operation_executor::replace(file,
                range.start + change.link.start - offset..range.start + change.link.end - offset,
                content.as_bytes());
        }
        offset += length;
    }
    Err(CoreError::InvalidInput("链接跨越了不可编辑的正文范围"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TaskModification;

    fn file(source: &str) -> OrgFile {
        OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap()
    }
    fn apply(document: &mut OrgFile, change: TaskLinkChange) -> Result<(), CoreError> {
        let headline = document.path_headlines()[0].1.clone();
        super::super::task_operation_executor::modify(document, &headline, &TaskModification::Link(change))
    }

    #[test]
    fn identical_adjacent_links_keep_distinct_native_references_and_unsupported_links_can_be_edited() {
        let source = "* TODO 前[[https://example.com][甲]][[https://example.com][乙]] [[id:stable][中文]] https://example.org/a\n";
        let document = file(source);
        let task = document.nodes().remove(0);
        let parts = task.title_parts();
        let projected = parts.iter().filter_map(|part| part.link.clone()).collect::<Vec<_>>();
        assert_eq!(projected.len(), 4);
        assert_eq!(projected, text_links(&task.title));
        assert_ne!(projected[0].start, projected[1].start);
        assert_eq!(projected[2].url, "id:stable");
        assert!(parts.iter().any(|part| part.text == "中文" && part.href.is_none() && part.link.is_some()));
        let empty_caption = file("* TODO [[https://example.com/hidden][]][[https://example.com/visible][可见]]\n");
        let visible = empty_caption.nodes()[0].title_parts();
        assert_eq!(visible[0].link.as_ref().unwrap().url, "https://example.com/visible");
    }

    #[test]
    fn modifies_only_selected_title_link_with_repeated_target_and_preserves_crlf_and_other_fields() {
        let source = "* TODO 前[[https://example.com][甲]][[https://example.com][乙]] 后 [1/2] :tag:\r\nSCHEDULED: <2026-11-14 Sat>\r\n备注不变  \r\n";
        let mut document = file(source);
        let link = document.nodes()[0].title_parts().iter().filter_map(|part| part.link.clone()).nth(1).unwrap();
        apply(&mut document, TaskLinkChange { field: TaskLinkField::Title, link,
            value: Some(LinkValue { title: "新标题".into(), url: "https://example.org/new".into() }) }).unwrap();
        assert_eq!(document.source_bytes(), source.replace("[[https://example.com][乙]]", "[[https://example.org/new][新标题]]").as_bytes());
    }

    #[test]
    fn notes_html_links_keep_exact_references_after_literal_blocks_and_deleted_checklists() {
        let source = "* TODO 任务\n#+begin_src text\nhttps://example.com/literal\n[[https://example.com/literal][源码]]\n#+end_src\n正文 https://example.com/a\n- [ ] 独立清单\n后文 [[addr:北京][地点]]\n#+begin_export html\nhttps://example.com/export\n#+end_export\n";
        let document = file(source);
        let notes = document.task_edit_content(&document.path_headlines()[0].0).unwrap();
        let links = text_links(&notes.notes);
        assert_eq!(links.len(), 2, "{links:?}");
        let mut reader = quick_xml::Reader::from_str(&notes.notes_html);
        let mut projected = Vec::<TextLink>::new();
        loop {
            match reader.read_event().unwrap() {
                quick_xml::events::Event::Start(tag) => {
                    for attribute in tag.attributes() {
                        let attribute = attribute.unwrap();
                        if attribute.key.as_ref() == b"data-org-link" {
                            projected.push(serde_json::from_str(&attribute.decode_and_unescape_value(reader.decoder()).unwrap()).unwrap());
                        }
                    }
                }
                quick_xml::events::Event::Eof => break,
                _ => {}
            }
        }
        assert_eq!(projected, links);
    }

    #[test]
    fn edits_and_removes_notes_link_without_rebuilding_checklists_logs_or_children() {
        let source = "* TODO 任务\r\n前 [[https://example.com][甲]]\r\n- [ ] 清单\r\n后 https://example.com/b。\r\n:LOGBOOK:\r\n保留日志\r\n:END:\r\n** 子任务\r\n保留正文\r\n";
        let mut document = file(source);
        let content = document.task_edit_content(&document.path_headlines()[0].0).unwrap();
        let link = text_links(&content.notes).remove(1);
        apply(&mut document, TaskLinkChange { field: TaskLinkField::Notes, link, value: None }).unwrap();
        assert_eq!(document.source_bytes(), source.replace("https://example.com/b", "").as_bytes());
    }

    #[test]
    fn rejects_stale_references_literals_and_delimiter_injection_without_changing_bytes() {
        let source = "* TODO [[https://example.com][甲]]\n备注 https://example.org/\n~https://example.net/~\n";
        let mut document = file(source);
        let title = document.nodes()[0].title_parts()[0].link.clone().unwrap();
        let mut stale = title.clone(); stale.start += 1;
        assert!(apply(&mut document, TaskLinkChange { field: TaskLinkField::Title, link: stale, value: None }).is_err());
        for value in [LinkValue { title: "x]][[id:bad".into(), url: "https://example.com".into() },
            LinkValue { title: "甲".into(), url: "https://example.com\n* TODO 注入".into() },
            LinkValue { title: "甲".into(), url: String::new() }]
        {
            assert!(apply(&mut document, TaskLinkChange { field: TaskLinkField::Title, link: title.clone(), value: Some(value) }).is_err());
            assert_eq!(document.source_bytes(), source.as_bytes());
        }
        let notes = document.task_edit_content(&document.path_headlines()[0].0).unwrap();
        assert_eq!(text_links(&notes.notes).len(), 1);
        assert_eq!(document.source_bytes(), source.as_bytes());
    }

    #[test]
    fn unchanged_link_keeps_bare_spelling_and_deleting_only_title_is_rejected() {
        let source = "* TODO https://example.com/path\r\n正文保持不变\r\n";
        let mut document = file(source);
        let link = document.nodes()[0].title_parts()[0].link.clone().unwrap();
        apply(&mut document, TaskLinkChange { field: TaskLinkField::Title, link: link.clone(),
            value: Some(LinkValue { title: link.title.clone(), url: link.url.clone() }) }).unwrap();
        assert_eq!(document.source_bytes(), source.as_bytes());
        assert!(apply(&mut document, TaskLinkChange { field: TaskLinkField::Title, link, value: None }).is_err());
        assert_eq!(document.source_bytes(), source.as_bytes());
    }

    #[test]
    fn bare_link_ranges_stay_inside_table_cells_and_description_terms() {
        let source = "* TODO 任务\n|https://example.com/a|另一列|\n\n- https://example.org/term :: 说明 https://example.net/body\n";
        let mut document = file(source);
        let notes = document.task_edit_content(&document.path_headlines()[0].0).unwrap();
        let links = text_links(&notes.notes);
        assert_eq!(links.iter().map(|link| link.url.as_str()).collect::<Vec<_>>(),
            ["https://example.com/a", "https://example.org/term", "https://example.net/body"]);
        assert_eq!(notes.notes_html.matches("data-org-link=").count(), 3);
        apply(&mut document, TaskLinkChange { field: TaskLinkField::Notes, link: links[0].clone(),
            value: Some(LinkValue { title: "表格链接".into(), url: "https://example.com/new".into() }) }).unwrap();
        assert_eq!(document.source_bytes(), source.replace("https://example.com/a", "[[https://example.com/new][表格链接]]").as_bytes());
    }
}
