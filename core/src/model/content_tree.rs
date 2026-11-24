//! 投影正文的直属子节点，保留 Org 列表项、段落和单元格的源范围。
use super::{OrgFile, content_block};
use orgize::{
    SyntaxKind, SyntaxNode,
    ast::{Headline, ListItem, Section},
    rowan::ast::AstNode,
};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ContentNodeKind {
    Paragraph,
    List,
    Item,
    Table,
    Row,
    Rule,
    Cell,
    Quote,
    Literal,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentNode {
    pub id: String,
    pub kind: ContentNodeKind,
    pub source: String,
    pub blank_lines_before: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<ContentNode>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub parts: Vec<super::ContentInline>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub marker: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checkbox: Option<ContentCheckbox>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ContentCheckbox {
    Unchecked,
    Checked,
    Partial,
}

pub(super) fn tree(
    file: &OrgFile,
    section: Option<Section>,
    headline: Option<&Headline>,
) -> Vec<ContentNode> {
    content_block::sources(file, section, headline)
        .filter_map(|(element, start, source)| {
            element
                .into_node()
                .map(|node| project(file, &node, start, source))
        })
        .collect()
}

fn project(file: &OrgFile, node: &SyntaxNode, start: usize, source: &str) -> ContentNode {
    use ContentNodeKind::*;
    let kind = match node.kind() {
        SyntaxKind::PARAGRAPH => Paragraph,
        SyntaxKind::LIST => List,
        SyntaxKind::LIST_ITEM => Item,
        SyntaxKind::ORG_TABLE => Table,
        SyntaxKind::ORG_TABLE_STANDARD_ROW => Row,
        SyntaxKind::ORG_TABLE_RULE_ROW => Rule,
        SyntaxKind::ORG_TABLE_CELL => Cell,
        SyntaxKind::QUOTE_BLOCK | SyntaxKind::CENTER_BLOCK => Quote,
        _ => Literal,
    };
    let content = match kind {
        Item => node
            .children()
            .find(|child| child.kind() == SyntaxKind::LIST_ITEM_CONTENT),
        Quote => node
            .children()
            .find(|child| child.kind() == SyntaxKind::BLOCK_CONTENT),
        List | Table | Row => Some(node.clone()),
        _ => None,
    };
    let mut children = content
        .into_iter()
        .flat_map(|content| content.children())
        .filter_map(|child| {
            let range = child.text_range();
            let start = u32::from(range.start()) as usize;
            let end = u32::from(range.end()) as usize;
            let source = std::str::from_utf8(&file.source_bytes()[start..end])
                .expect("UTF-8")
                .trim_end_matches(['\r', '\n']);
            // 空单元格也是合法插入位置。
            (!source.trim().is_empty() || child.kind() == SyntaxKind::ORG_TABLE_CELL)
                .then(|| project(file, &child, start, source))
        })
        .collect::<Vec<_>>();
    let list_item = ListItem::cast(node.clone());
    let marker = list_item
        .as_ref()
        .map(|item| item.bullet().trim().to_owned());
    if let Some(item) = &list_item {
        let tag = item.tag().collect::<Vec<_>>();
        if let (Some(first), Some(last)) = (tag.first(), tag.last()) {
            let start = u32::from(first.text_range().start()) as usize;
            let end = u32::from(last.text_range().end()) as usize;
            let source = std::str::from_utf8(&file.source_bytes()[start..end]).expect("UTF-8");
            children.insert(
                0,
                ContentNode {
                    id: start.to_string(),
                    kind: Paragraph,
                    source: source.into(),
                    blank_lines_before: 0,
                    parts: super::render::content_inlines(source),
                    children: vec![],
                    marker: None,
                    checkbox: None,
                },
            );
        }
    }
    let checkbox = list_item
        .and_then(|item| item.checkbox())
        .map(|token| match token.as_ref() {
            "X" | "x" => ContentCheckbox::Checked,
            "-" => ContentCheckbox::Partial,
            _ => ContentCheckbox::Unchecked,
        });
    let parts = if matches!(kind, Paragraph | Cell) {
        super::render::content_inlines(source)
    } else {
        vec![]
    };
    ContentNode {
        id: start.to_string(),
        kind,
        source: source.into(),
        blank_lines_before: content_block::blank_lines(file, start),
        children,
        parts,
        marker,
        checkbox,
    }
}

use super::{
    ContentBlockChange, CoreError,
    task_operation_executor::{newline, replace},
};
use std::ops::Range;

fn locate(nodes: Vec<ContentNode>, id: &str) -> Option<ContentNode> {
    for mut node in nodes {
        if node.id == id
            && matches!(
                node.kind,
                ContentNodeKind::Paragraph | ContentNodeKind::Cell
            )
        {
            return Some(node);
        }
        if let Some(child) = locate(std::mem::take(&mut node.children), id) {
            return Some(child);
        }
    }
    None
}

fn selection(node: &ContentNode, start: usize, end: usize) -> Option<Range<usize>> {
    let offset = node.id.parse::<usize>().ok()?;
    node.source.get(start..end)?;
    Some(offset + start..offset + end)
}

pub(super) fn modify(
    file: &mut OrgFile,
    headline: &Headline,
    change: &ContentBlockChange,
) -> Result<(), CoreError> {
    let missing = || CoreError::InvalidInput("正文节点已变化，请重新载入后编辑");
    match change {
        ContentBlockChange::ReplaceText { id, source } => {
            let node =
                locate(tree(file, headline.section(), Some(headline)), id).ok_or_else(missing)?;
            if source
                .chars()
                .any(|ch| ch.is_control() && !matches!(ch, '\r' | '\n' | '\t'))
                || (node.kind == ContentNodeKind::Cell && source.contains(['|', '\r', '\n']))
            {
                return Err(CoreError::InvalidInput(
                    "正文内容包含控制字符或表格列分隔符",
                ));
            }
            let range = selection(&node, 0, node.source.len()).ok_or_else(missing)?;
            let old = &node.source;
            let leading = &old[..old.len() - old.trim_start().len()];
            let trailing = &old[old.trim_end().len().max(leading.len())..];
            let input = source.trim().replace("\r\n", "\n").replace('\r', "\n");
            let probe = orgize::Org::parse(&input);
            if node.kind == ContentNodeKind::Paragraph
                && !input.is_empty()
                && (probe.document().headlines().next().is_some()
                    || !probe.document().section().is_some_and(|section| {
                        let mut children = section.syntax().children();
                        children
                            .next()
                            .is_some_and(|child| child.kind() == SyntaxKind::PARAGRAPH)
                            && children.next().is_none()
                    }))
            {
                return Err(CoreError::InvalidInput("请通过区块编辑修改 Org 结构"));
            }
            let indent = headline
                .section()
                .and_then(|section| {
                    section
                        .syntax()
                        .descendants()
                        .filter_map(ListItem::cast)
                        .filter(|item| {
                            u32::from(item.start()) as usize <= range.start
                                && (u32::from(item.end()) as usize) >= range.end
                        })
                        .last()
                })
                .map_or(leading.len(), |item| item.indent() + item.bullet().len());
            let eol = newline(file);
            let mut lines = input.split('\n');
            let mut updated = format!("{leading}{}", lines.next().unwrap_or(""));
            for line in lines {
                updated.push_str(eol);
                updated.push_str(&" ".repeat(indent));
                updated.push_str(line.trim_start());
            }
            updated.push_str(trailing);
            replace(file, range, updated.as_bytes())
        }
        ContentBlockChange::TreeLink { id, link, value } => {
            let node =
                locate(tree(file, headline.section(), Some(headline)), id).ok_or_else(missing)?;
            if !node
                .parts
                .iter()
                .any(|part| part.link.as_ref() == Some(link))
            {
                return Err(CoreError::InvalidInput("链接已变化，请重新载入后编辑"));
            }
            let range = selection(&node, link.start, link.end).ok_or_else(missing)?;
            let content = value
                .as_ref()
                .map(super::text_link::replacement)
                .transpose()?
                .unwrap_or_default();
            if node.kind == ContentNodeKind::Cell && content.contains('|') {
                return Err(CoreError::InvalidInput("表格链接不能包含列分隔符"));
            }
            replace(file, range, content.as_bytes())
        }
        ContentBlockChange::InsertLink {
            id,
            start,
            end,
            source,
            value,
        } => {
            let node =
                locate(tree(file, headline.section(), Some(headline)), id).ok_or_else(missing)?;
            if &node.source != source
                || node
                    .parts
                    .iter()
                    .filter_map(|part| part.link.as_ref())
                    .any(|link| *start < link.end && *end > link.start)
            {
                return Err(CoreError::InvalidInput("链接位置已变化或与已有链接重叠"));
            }
            let range = selection(&node, *start, *end).ok_or_else(missing)?;
            let content = super::text_link::replacement(value)?;
            if node.kind == ContentNodeKind::Cell && content.contains('|') {
                return Err(CoreError::InvalidInput("表格链接不能包含列分隔符"));
            }
            let mut updated = node.source.clone();
            updated.replace_range(*start..*end, &content);
            if !super::render::content_inlines(&updated).iter().any(|part| {
                part.link
                    .as_ref()
                    .is_some_and(|link| link.start == *start && link.source == content)
            }) {
                return Err(CoreError::InvalidInput("当前位置无法识别为 Org 链接"));
            }
            replace(file, range, content.as_bytes())
        }
        ContentBlockChange::InsertParagraph { id, source } => {
            insert_paragraph(file, headline, id, source)
        }
        ContentBlockChange::InsertLinkedParagraph { id, value } => {
            insert_paragraph(file, headline, id, &super::text_link::replacement(value)?)
        }
        _ => unreachable!("仅处理正文树修改"),
    }
}

fn insert_paragraph(
    file: &mut OrgFile,
    headline: &Headline,
    id: &str,
    source: &str,
) -> Result<(), CoreError> {
    if source.trim().is_empty() || source.contains('\0') {
        return Err(CoreError::InvalidInput("段落不能为空或包含 NUL"));
    }
    let probe = orgize::Org::parse(source);
    if probe.document().headlines().next().is_some()
        || !probe.document().section().is_some_and(|section| {
            let nodes = section.syntax().children().collect::<Vec<_>>();
            nodes.len() == 1 && nodes[0].kind() == SyntaxKind::PARAGRAPH
        })
    {
        return Err(CoreError::InvalidInput("说明必须是普通段落"));
    }
    let eol = newline(file);
    let normalized = source.replace("\r\n", "\n").replace('\r', "\n");
    let source = normalized.trim_end_matches('\n');
    if id == "root" {
        let at = headline
            .section()
            .map(|section| u32::from(section.end()) as usize)
            .unwrap_or_else(|| super::task_operation_executor::inline_body_start(file, headline));
        let prefix = if at > 0 && file.source_bytes()[at - 1] == b'\n' {
            eol.to_owned()
        } else {
            eol.repeat(2)
        };
        return replace(
            file,
            at..at,
            format!("{prefix}{}{eol}", source.replace('\n', eol)).as_bytes(),
        );
    }
    let missing = CoreError::InvalidInput("正文容器已变化，请重新载入后编辑");
    let list_id = id.strip_prefix("list:");
    let container = headline
        .section()
        .and_then(|section| {
            section.syntax().descendants().find(|node| {
                let kind_matches = if list_id.is_some() {
                    node.kind() == SyntaxKind::LIST
                } else {
                    matches!(
                        node.kind(),
                        SyntaxKind::LIST_ITEM | SyntaxKind::QUOTE_BLOCK | SyntaxKind::CENTER_BLOCK
                    )
                };
                kind_matches
                    && u32::from(node.text_range().start()).to_string() == list_id.unwrap_or(id)
            })
        })
        .ok_or(missing)?;
    if matches!(
        container.kind(),
        SyntaxKind::QUOTE_BLOCK | SyntaxKind::CENTER_BLOCK
    ) {
        let end = container
            .children()
            .find(|node| node.kind() == SyntaxKind::BLOCK_END)
            .ok_or(CoreError::InvalidInput("引用区块已变化"))?;
        let at = u32::from(end.text_range().start()) as usize;
        return replace(
            file,
            at..at,
            format!("{eol}{}{eol}", source.replace('\n', eol)).as_bytes(),
        );
    }
    let as_list = orgize::ast::List::cast(container.clone());
    let item = if let Some(list) = &as_list {
        list.items().last()
    } else {
        ListItem::cast(container)
    }
    .ok_or(CoreError::InvalidInput("列表条目已变化"))?;
    let start = u32::from(item.start()) as usize;
    let end = u32::from(item.end()) as usize;
    let original = std::str::from_utf8(&file.source_bytes()[start..end]).expect("UTF-8");
    let last_content = start + original.trim_end_matches([' ', '\t', '\r', '\n']).len();
    let at = file.source_bytes()[last_content..end]
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(end, |offset| last_content + offset + 1);
    let indent = " ".repeat(item.indent() + item.bullet().len());
    let prefix = if at > 0 && file.source_bytes()[at - 1] == b'\n' {
        ""
    } else {
        eol
    };
    let mut lines = source.split('\n');
    let first_line = lines.next().expect("段落非空").trim_start();
    let mut content = if as_list.is_some() {
        let checkbox = if item.checkbox().is_some() {
            "[ ] "
        } else {
            ""
        };
        format!(
            "{prefix}{}{checkbox}{first_line}{eol}",
            std::str::from_utf8(
                &file.source_bytes()[start..u32::from(item.bullet().text_range().end()) as usize]
            )
            .expect("UTF-8")
        )
    } else {
        format!("{prefix}{eol}{indent}{first_line}{eol}")
    };
    for line in lines {
        content.push_str(&format!("{indent}{}{eol}", line.trim_start()));
    }
    replace(file, at..at, content.as_bytes())?;
    if as_list.is_some() && item.checkbox().is_some() {
        super::task_operation_executor::update_title_counts(
            file,
            u32::from(headline.start()) as usize,
            super::title_statistics::Trigger::Checkbox,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checklist_projects_nested_content_and_links_with_precise_ranges() {
        let source = "* TODO 发布\r\n- [ ] 首行 [[#release][发布规范]]\r\n\r\n  补充说明 [[https://example.com][报告]]。\r\n\r\n  | 回归 | [[#release][表格链接]] |\r\n\r\n  - [X] 子项 [[*回滚][回滚步骤]]\r\n- [ ] 同级\r\n* 回滚\r\n";
        let mut file = OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap();
        let headline = file.path_headlines().remove(0).1;
        let roots = tree(&file, headline.section(), Some(&headline));
        let item = &roots[0].children[0];
        assert_eq!(
            item.children
                .iter()
                .map(|child| child.kind)
                .collect::<Vec<_>>(),
            [
                ContentNodeKind::Paragraph,
                ContentNodeKind::Paragraph,
                ContentNodeKind::Table,
                ContentNodeKind::List
            ]
        );
        assert_eq!(
            item.children[3].children[0].checkbox,
            Some(ContentCheckbox::Checked)
        );
        assert_eq!(
            item.children[0].parts[1].href.as_deref(),
            Some("org-internal:%23release")
        );
        let cell = &item.children[2].children[0].children[1];
        let link = cell
            .parts
            .iter()
            .find_map(|part| part.link.clone())
            .unwrap();
        assert_eq!(&cell.source[link.start..link.end], "[[#release][表格链接]]");
        modify(
            &mut file,
            &headline,
            &ContentBlockChange::TreeLink {
                id: cell.id.clone(),
                link,
                value: Some(super::super::LinkValue {
                    title: "更新".into(),
                    url: "#release".into(),
                }),
            },
        )
        .unwrap();
        assert_eq!(
            file.source_bytes(),
            source
                .replace("[[#release][表格链接]]", "[[#release][更新]]")
                .as_bytes()
        );
    }

    #[test]
    fn inserting_explanation_after_sublist_preserves_parent_and_siblings() {
        let source = "* TODO 发布\r\n- [ ] 父项\r\n  - [ ] 子项\r\n- [ ] 同级\r\n";
        let mut file = OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap();
        let headline = file.path_headlines().remove(0).1;
        let id = tree(&file, headline.section(), Some(&headline))[0].children[0]
            .id
            .clone();
        modify(
            &mut file,
            &headline,
            &ContentBlockChange::InsertParagraph {
                id,
                source: "补充 [[#release][规范]]".into(),
            },
        )
        .unwrap();
        assert_eq!(
            file.source_bytes(),
            source
                .replace("子项\r\n", "子项\r\n\r\n  补充 [[#release][规范]]\r\n")
                .as_bytes()
        );
        let headline = file.path_headlines().remove(0).1;
        let roots = tree(&file, headline.section(), Some(&headline));
        assert_eq!(roots[0].children.len(), 2);
        let item = &roots[0].children[0];
        assert_eq!(item.children[1].kind, ContentNodeKind::List);
        assert_eq!(item.children[2].kind, ContentNodeKind::Paragraph);
        assert!(
            item.children[2]
                .parts
                .iter()
                .any(|part| part.href.as_deref() == Some("org-internal:%23release"))
        );
    }
}
