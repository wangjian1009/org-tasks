//! 将 Org 文章投影为连续阅读所需的结构，独立于仓库和任务页面。

use super::{TodoConfig, TodoMetadata, properties::Properties, task_identity::path_title};
use crate::CoreError;
use orgize::export::{Container, Event, HtmlEscape, HtmlExport, TraversalContext, Traverser};
use orgize::{SyntaxKind, rowan::ast::AstNode};
use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadingArticle {
    pub html: String,
    pub sections: Vec<ArticleSection>,
    pub images: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArticleSection {
    pub id: String,
    pub title: String,
    pub level: usize,
    pub target: Option<String>,
}

pub fn render_article(source: &[u8]) -> Result<ReadingArticle, CoreError> {
    let source = std::str::from_utf8(source)
        .map_err(|_| CoreError::InvalidInput("帮助文章必须使用 UTF-8 编码"))?;
    let (_, syntax) = TodoMetadata::parse_with_setup(source, &TodoConfig::default(), "")?;
    let mut reader = ArticleView::default();
    let document = syntax.document();
    if let Some(title) = document.title().filter(|title| !title.trim().is_empty()) {
        reader
            .html
            .push_str(format!("<h1>{}</h1>", HtmlEscape(title)));
    }
    if let Some(description) = document
        .keywords()
        .find(|keyword| keyword.key().eq_ignore_ascii_case("DESCRIPTION"))
    {
        reader.html.push_str(format!(
            "<p class=\"summary\">{}</p>",
            HtmlEscape(description.value().trim())
        ));
    }
    syntax.traverse(&mut reader);
    Ok(ReadingArticle {
        html: reader.html.finish(),
        sections: reader.sections,
        images: reader.images,
    })
}

#[derive(Default)]
struct ArticleView {
    html: HtmlExport,
    sections: Vec<ArticleSection>,
    images: Vec<String>,
    descriptive_lists: Vec<bool>,
}

impl Traverser for ArticleView {
    fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
        match event {
            Event::Enter(Container::Headline(headline)) => {
                let level = headline.level();
                let heading = level.saturating_add(1).min(6);
                let id = format!("section-{}", self.sections.len() + 1);
                let target = headline
                    .properties()
                    .and_then(|drawer| Properties::from_drawer(&drawer).get("CUSTOM_ID"))
                    .filter(|id| !id.is_empty());
                self.sections.push(ArticleSection {
                    id: id.clone(),
                    title: path_title(&headline),
                    level,
                    target,
                });
                self.html.push_str(format!("<h{heading} id=\"{id}\">"));
                for element in headline.title() {
                    self.element(element, &mut TraversalContext::default());
                }
                self.html.push_str(format!("</h{heading}>"));
            }
            Event::Enter(
                Container::PropertyDrawer(_)
                | Container::Drawer(_)
                | Container::Keyword(_)
                | Container::AffiliatedKeyword(_)
                | Container::Comment(_)
                | Container::CommentBlock(_)
                | Container::ExportBlock(_)
                | Container::BabelCall(_),
            ) => ctx.skip(),
            Event::Clock(_)
            | Event::Cookie(_)
            | Event::Snippet(_)
            | Event::Macros(_)
            | Event::InlineCall(_) => {}
            Event::Timestamp(value) => self.html.push_str(format!("{}", HtmlEscape(value.raw()))),
            Event::LatexFragment(value) => {
                self.html.push_str(format!("{}", HtmlEscape(value.raw())))
            }
            Event::LatexEnvironment(value) => {
                self.html.push_str(format!("{}", HtmlEscape(value.raw())))
            }
            Event::Enter(Container::Link(link)) => {
                let path = link.path();
                let href = article_href(&path);
                if let Some(image) = path
                    .strip_prefix("file:")
                    .filter(|name| bundled_image(name))
                {
                    if !self.images.iter().any(|name| name == image) {
                        self.images.push(image.to_owned());
                    }
                    let alt = if link.has_description() {
                        link.description_raw()
                    } else {
                        image.to_owned()
                    };
                    self.html.push_str(format!(
                        "<a class=\"article-image\" href=\"org-help-image:{image}\"><img src=\"org-help-image:{image}\" alt=\"{}\"></a>",
                        HtmlEscape(alt)
                    ));
                } else {
                    if let Some(href) = &href {
                        self.html
                            .push_str(format!("<a href=\"{}\">", HtmlEscape(href)));
                    }
                    if link.has_description() {
                        for element in link.description() {
                            self.element(element, &mut TraversalContext::default());
                        }
                    } else {
                        self.html.push_str(format!("{}", HtmlEscape(path)));
                    }
                    if href.is_some() {
                        self.html.push_str("</a>");
                    }
                }
                ctx.skip();
            }
            Event::Enter(Container::List(list)) => {
                let descriptive = !list.is_ordered() && list.is_descriptive();
                self.descriptive_lists.push(descriptive);
                self.html.push_str(if list.is_ordered() {
                    "<ol>"
                } else if descriptive {
                    "<dl>"
                } else {
                    "<ul>"
                });
            }
            Event::Leave(Container::List(list)) => {
                let descriptive = self.descriptive_lists.pop().unwrap_or(false);
                self.html.push_str(if list.is_ordered() {
                    "</ol>"
                } else if descriptive {
                    "</dl>"
                } else {
                    "</ul>"
                });
            }
            Event::Enter(Container::ListItem(item)) => {
                if self.descriptive_lists.last() == Some(&true) {
                    self.html.push_str("<dt>");
                    for element in item.tag() {
                        self.element(element, &mut TraversalContext::default());
                    }
                    self.html.push_str("</dt><dd>");
                } else {
                    self.html.push_str("<li>");
                }
            }
            Event::Leave(Container::ListItem(_)) => {
                self.html
                    .push_str(if self.descriptive_lists.last() == Some(&true) {
                        "</dd>"
                    } else {
                        "</li>"
                    });
            }
            Event::Enter(Container::OrgTable(table)) => {
                self.html.push_str("<div class=\"table-scroll\">");
                self.html
                    .event(Event::Enter(Container::OrgTable(table)), ctx);
            }
            Event::Leave(Container::OrgTable(table)) => {
                self.html
                    .event(Event::Leave(Container::OrgTable(table)), ctx);
                self.html.push_str("</div>");
            }
            Event::Enter(Container::OrgTableRow(row)) if !row.is_rule() => {
                self.html
                    .event(Event::Enter(Container::OrgTableRow(row.clone())), ctx);
                let mut pending_cell = false;
                for element in row.syntax().children_with_tokens() {
                    match element.kind() {
                        SyntaxKind::PIPE => {
                            if pending_cell {
                                self.html.push_str("<td></td>");
                            }
                            pending_cell = true;
                        }
                        SyntaxKind::ORG_TABLE_CELL => {
                            self.element(element, &mut TraversalContext::default());
                            pending_cell = false;
                        }
                        _ => {}
                    }
                }
                self.html
                    .event(Event::Leave(Container::OrgTableRow(row)), ctx);
                ctx.skip();
            }
            event => self.html.event(event, ctx),
        }
    }
}

fn resource_name(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}

fn bundled_image(value: &str) -> bool {
    value.rsplit_once('.').is_some_and(|(name, extension)| {
        resource_name(name) && matches!(extension, "png" | "jpg" | "jpeg" | "webp")
    })
}

fn article_href(path: &str) -> Option<String> {
    if path.chars().any(char::is_control) {
        return None;
    }
    if let Some(target) = path
        .strip_prefix('#')
        .filter(|target| resource_name(target))
    {
        return Some(format!("org-help-anchor:{target}"));
    }
    if let Some(file) = path.strip_prefix("file:") {
        let (name, anchor) = file.split_once("::#").unwrap_or((file, ""));
        let id = name.strip_suffix(".org").filter(|id| resource_name(id))?;
        return (anchor.is_empty() || resource_name(anchor))
            .then(|| format!("org-help-article:{id}#{anchor}"));
    }
    if let Some(id) = path
        .strip_prefix("orgtasks://page/")
        .filter(|id| resource_name(id))
    {
        return Some(format!("orgtasks://page/{id}"));
    }
    let url = reqwest::Url::parse(path).ok()?;
    matches!(url.scheme(), "https" | "http").then(|| url.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_article_layout_and_omits_task_metadata() {
        let source = "#+TITLE: 帮助\n#+DESCRIPTION: 简介\n#+TODO: HOLD | DONE\n#+FILETAGS: :private:\n\n* HOLD [#A] 章节 [1/2] :ARCHIVE:hidden:\nSCHEDULED: <2026-11-27 Fri>\n:PROPERTIES:\n:CUSTOM_ID: first\n:VISIBILITY: folded\n:REMINDER: private\n:END:\n:LOGBOOK:\nprivate\n:END:\n- [X] 内容\n\n#+begin_example\n#+TODO: TODO | DONE\n#+end_example\n";
        let article = render_article(source.as_bytes()).unwrap();
        assert_eq!(article.sections[0].title, "章节");
        assert_eq!(article.sections[0].target.as_deref(), Some("first"));
        for visible in [
            "<h1>帮助",
            "简介",
            "章节",
            "<li>",
            "内容",
            "#+TODO: TODO | DONE",
        ] {
            assert!(
                article.html.contains(visible),
                "{visible}: {}",
                article.html
            );
        }
        for hidden in [
            "HOLD",
            "1/2",
            "ARCHIVE",
            "private",
            "SCHEDULED",
            "checkbox",
            "VISIBILITY",
        ] {
            assert!(!article.html.contains(hidden), "{hidden}: {}", article.html);
        }
    }

    #[test]
    fn resolves_help_links_and_only_bundled_images() {
        let source = "[[orgtasks://page/task-reminders][设置]] [[file:repeat.org::#edit][重复]] [[#steps][步骤]] [[file:sample.png][图]] [[file:../private.png][外部文件]] [[javascript:alert(1)][文本]] @@html:<script>bad</script>@@";
        let article = render_article(source.as_bytes()).unwrap();
        assert_eq!(article.images, ["sample.png"]);
        for link in [
            "orgtasks://page/task-reminders",
            "org-help-article:repeat#edit",
            "org-help-anchor:steps",
            "org-help-image:sample.png",
        ] {
            assert!(article.html.contains(link));
        }
        for hidden in ["../private.png", "javascript:", "<script>"] {
            assert!(!article.html.contains(hidden));
        }
    }
}
