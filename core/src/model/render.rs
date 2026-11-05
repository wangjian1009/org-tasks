//! 基于现有 orgize 语法树的只读 HTML 投影；不改变源字节，不执行文内 HTML。
use super::OrgFile;
use crate::FilterTask;
use orgize::export::{Container, Event, HtmlEscape, HtmlExport, TraversalContext, Traverser};
use orgize::{SyntaxKind, rowan::ast::AstNode};
use serde::Serialize;

/// 标题的运行时行内投影；href 为空时只展示文字。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TitlePart {
    pub text: String,
    pub href: Option<String>,
    pub is_link: bool,
}

impl OrgFile {
    pub fn title_parts(&self) -> Vec<TitlePart> {
        title_parts(&self.title().unwrap_or_default())
    }

    /// 返回不含脚本、样式或外部资源的只读文档片段，样式由宿主提供。
    pub fn render_html(&self) -> String {
        let mut view = ReadingView(HtmlExport::default(), Vec::new(), None);
        self.syntax().traverse(&mut view);
        view.0.finish()
    }
}

/// 任务详情的运行时展示投影，原始 body 仍用于查询和其他宿主。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderedTaskContent {
    pub body_html: String,
    pub logbook_html: String,
}

impl FilterTask {
    pub fn title_parts(&self) -> Vec<TitlePart> {
        title_parts(&self.title)
    }

    pub fn render_content(&self) -> RenderedTaskContent {
        let mut view = ReadingView(HtmlExport::default(), Vec::new(), Some(String::new()));
        orgize::Org::parse(&self.body).traverse(&mut view);
        RenderedTaskContent {
            body_html: view.0.finish(),
            logbook_html: view.2.unwrap_or_default(),
        }
    }
}

fn title_parts(source: &str) -> Vec<TitlePart> {
    if source.is_empty() {
        return Vec::new();
    }
    // 用普通段落承载行内语法，避免 TITLE 被识别为列表、标题或关键字。
    let mut view = TitleView(Vec::new(), None, false);
    orgize::Org::parse(&format!("x {source}")).traverse(&mut view);
    if let Some(first) = view.0.first_mut() {
        first.text.drain(..2);
    }
    view.0.retain(|part| !part.text.is_empty());
    view.0
}

struct TitleView(Vec<TitlePart>, Option<String>, bool);

impl TitleView {
    fn push(&mut self, text: &str) {
        if let Some(last) = self
            .0
            .last_mut()
            .filter(|part| part.href == self.1 && part.is_link == self.2)
        {
            last.text.push_str(text);
        } else {
            self.0.push(TitlePart {
                text: text.into(),
                href: self.1.clone(),
                is_link: self.2,
            });
        }
    }
}

impl Traverser for TitleView {
    fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
        match event {
            Event::Text(text) => self.push(text.as_ref()),
            Event::Entity(entity) => self.push(entity.utf8()),
            Event::Timestamp(value) => self.push(&value.raw()),
            Event::Cookie(value) => self.push(&value.raw()),
            Event::Macros(value) => self.push(&value.raw()),
            Event::Snippet(value) => self.push(&value.raw()),
            Event::InlineCall(value) => self.push(&value.raw()),
            Event::InlineSrc(value) => self.push(&value.raw()),
            Event::LatexFragment(value) => self.push(&value.raw()),
            Event::LineBreak(_) => self.push("\n"),
            Event::Enter(Container::Link(link)) => {
                let previous = self.1.take();
                let previous_is_link = self.2;
                self.1 = external_link_href(link.path().as_ref());
                self.2 = true;
                if link.has_description() {
                    for element in link.description() {
                        self.element(element, &mut TraversalContext::default());
                    }
                } else {
                    self.push(link.path().as_ref());
                }
                self.1 = previous;
                self.2 = previous_is_link;
                ctx.skip();
            }
            _ => {}
        }
    }
}

struct ReadingView(HtmlExport, Vec<bool>, Option<String>);

impl ReadingView {
    fn literal(&mut self, class: &str, text: impl AsRef<str>) {
        self.0
            .push_str(format!("<pre class=\"{class}\">{}</pre>", HtmlEscape(text)));
    }
}

impl Traverser for ReadingView {
    fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
        match event {
            Event::Enter(Container::Document(_) | Container::Section(_))
            | Event::Leave(Container::Document(_) | Container::Section(_))
                if self.2.is_some() => {}
            Event::Enter(Container::Headline(headline)) => {
                let level = headline.level().min(6);
                self.0.push_str(format!("<details class=\"heading level-{level}\" open><summary><span role=\"heading\" aria-level=\"{level}\" class=\"heading-title\">"));
                if let Some(todo) = headline.todo_keyword() {
                    let kind = if headline.is_done() {
                        "done"
                    } else {
                        "pending"
                    };
                    self.0.push_str(format!(
                        "<span class=\"todo {kind}\">{}</span> ",
                        HtmlEscape(todo)
                    ));
                }
                if let Some(priority) = headline.priority() {
                    self.0.push_str(format!(
                        "<span class=\"priority\">[#{}]</span> ",
                        HtmlEscape(priority)
                    ));
                }
                for element in headline.title() {
                    self.element(element, &mut TraversalContext::default());
                }
                self.0.push_str("</span><span class=\"tags\">");
                for tag in headline.tags() {
                    self.0
                        .push_str(format!("<span class=\"tag\">{}</span>", HtmlEscape(tag)));
                }
                self.0.push_str("</span></summary>");
                for (label, timestamp) in [
                    ("SCHEDULED", headline.scheduled()),
                    ("DEADLINE", headline.deadline()),
                    ("CLOSED", headline.closed()),
                ] {
                    if let Some(timestamp) = timestamp {
                        self.0.push_str(format!("<div class=\"planning\"><span>{label}: </span><span class=\"timestamp\">{}</span></div>", HtmlEscape(timestamp.raw().trim())));
                    }
                }
            }
            Event::Leave(Container::Headline(_)) => self.0.push_str("</details>"),
            Event::Enter(Container::PropertyDrawer(drawer)) => {
                self.0
                    .push_str("<details class=\"drawer\"><summary>PROPERTIES</summary><dl>");
                for (key, value) in drawer.iter() {
                    self.0.push_str(format!(
                        "<dt>{}</dt><dd>{}</dd>",
                        HtmlEscape(key),
                        HtmlEscape(value)
                    ));
                }
                self.0.push_str("</dl></details>");
                ctx.skip();
            }
            Event::Enter(Container::Drawer(drawer)) => {
                if drawer.name().eq_ignore_ascii_case("LOGBOOK") && self.2.is_some() {
                    let mut log = ReadingView(HtmlExport::default(), Vec::new(), None);
                    for element in drawer
                        .syntax()
                        .children()
                        .filter(|node| node.kind() == SyntaxKind::DRAWER_CONTENT)
                        .flat_map(|node| node.children_with_tokens())
                    {
                        log.element(element, &mut TraversalContext::default());
                    }
                    self.2.as_mut().unwrap().push_str(&log.0.finish());
                    ctx.skip();
                    return;
                }
                self.0.push_str(format!(
                    "<details class=\"drawer\"><summary>{}</summary>",
                    HtmlEscape(drawer.name())
                ));
                self.literal("drawer-content", drawer.content_raw());
                self.0.push_str("</details>");
                ctx.skip();
            }
            Event::Enter(Container::SourceBlock(block)) => {
                self.0.push_str(format!(
                    "<div class=\"source\"><div class=\"source-language\">src {}</div>",
                    HtmlEscape(block.language().map(|v| v.to_string()).unwrap_or_default())
                ));
                self.literal("source-code", block.value());
                self.0.push_str("</div>");
                ctx.skip();
            }
            Event::Enter(Container::OrgTable(table)) => {
                self.0.push_str("<div class=\"table-scroll\">");
                self.0.event(Event::Enter(Container::OrgTable(table)), ctx);
            }
            Event::Leave(Container::OrgTable(table)) => {
                self.0
                    .event(Event::Leave(Container::OrgTable(table.clone())), ctx);
                self.0.push_str("</div>");
                for formula in table.tblfm() {
                    self.literal("metadata", format!("#+TBLFM: {}", formula.trim()));
                }
            }
            Event::Enter(Container::OrgTableRow(row)) if !row.is_rule() => {
                self.0
                    .event(Event::Enter(Container::OrgTableRow(row.clone())), ctx);
                // orgize 的空单元格没有 OrgTableCell 节点；按 CST 的 PIPE 保留列位。
                let mut started = false;
                let mut has_cell = false;
                for element in row.syntax().children_with_tokens() {
                    match element.kind() {
                        SyntaxKind::PIPE => {
                            if started && !has_cell {
                                self.0.push_str("<td></td>");
                            }
                            started = true;
                            has_cell = false;
                        }
                        SyntaxKind::ORG_TABLE_CELL => {
                            self.element(element, &mut TraversalContext::default());
                            has_cell = true;
                        }
                        _ => {}
                    }
                }
                self.0.event(Event::Leave(Container::OrgTableRow(row)), ctx);
                ctx.skip();
            }
            Event::Enter(Container::Keyword(keyword)) => {
                if keyword.key().eq_ignore_ascii_case("FILETAGS") {
                    self.0.push_str("<div class=\"file-tags\">");
                    for tag in keyword
                        .value()
                        .trim()
                        .split(':')
                        .filter(|tag| !tag.is_empty())
                    {
                        self.0
                            .push_str(format!("<span class=\"tag\">{}</span>", HtmlEscape(tag)));
                    }
                    self.0.push_str("</div>");
                } else if !keyword.key().eq_ignore_ascii_case("TITLE")
                    && !keyword.key().eq_ignore_ascii_case("TBLFM")
                {
                    self.literal("metadata", keyword.raw().trim());
                }
                ctx.skip();
            }
            Event::Enter(Container::Link(link)) => {
                // 只生成链接目标，不下载图片或其他外部资源；打开动作由宿主承接。
                let href = external_link_href(link.path().as_ref());
                if let Some(href) = &href {
                    self.0.push_str(format!(
                        "<a class=\"link\" href=\"{}\" title=\"{}\">",
                        HtmlEscape(href),
                        HtmlEscape(link.path())
                    ));
                } else {
                    self.0.push_str(format!(
                        "<span class=\"link unsupported\" role=\"link\" aria-disabled=\"true\" title=\"{}\">",
                        HtmlEscape(link.path())
                    ));
                }
                if link.has_description() {
                    for element in link.description() {
                        self.element(element, &mut TraversalContext::default());
                    }
                } else {
                    self.0.push_str(format!("{}", HtmlEscape(link.path())));
                }
                self.0
                    .push_str(if href.is_some() { "</a>" } else { "</span>" });
                ctx.skip();
            }
            Event::Enter(Container::List(list)) => {
                let descriptive = !list.is_ordered() && list.is_descriptive();
                self.1.push(descriptive);
                self.0.push_str(if list.is_ordered() {
                    "<ol>"
                } else if descriptive {
                    "<dl>"
                } else {
                    "<ul>"
                });
            }
            Event::Leave(Container::List(list)) => {
                let descriptive = self.1.pop().unwrap_or(false);
                self.0.push_str(if list.is_ordered() {
                    "</ol>"
                } else if descriptive {
                    "</dl>"
                } else {
                    "</ul>"
                });
            }
            Event::Enter(Container::ListItem(item)) => {
                if self.1.last() == Some(&true) {
                    self.0.push_str("<dt>");
                    for element in item.tag() {
                        self.element(element, &mut TraversalContext::default());
                    }
                    self.0.push_str("</dt><dd>");
                } else {
                    self.0.push_str("<li>");
                }
                if let Some(checkbox) = item.checkbox() {
                    let symbol = match checkbox.as_ref() {
                        "X" => "☑",
                        "-" => "◩",
                        _ => "☐",
                    };
                    self.0
                        .push_str(format!("<span class=\"checkbox\">{symbol}</span> "));
                }
            }
            Event::Leave(Container::ListItem(_)) => {
                self.0.push_str(if self.1.last() == Some(&true) {
                    "</dd>"
                } else {
                    "</li>"
                })
            }
            Event::Timestamp(timestamp) => self.0.push_str(format!(
                "<span class=\"timestamp\">{}</span>",
                HtmlEscape(timestamp.raw())
            )),
            Event::Enter(Container::ExportBlock(block)) => {
                self.literal("literal", block.raw());
                ctx.skip();
            }
            Event::Enter(Container::CommentBlock(block)) => {
                self.literal("metadata", block.raw());
                ctx.skip();
            }
            Event::Enter(Container::Comment(comment)) => {
                self.literal("metadata", comment.raw());
                ctx.skip();
            }
            Event::Enter(Container::FixedWidth(block)) => {
                self.literal("literal", block.raw());
                ctx.skip();
            }
            Event::Enter(Container::BabelCall(call)) => {
                self.literal("metadata", call.raw());
                ctx.skip();
            }
            Event::Snippet(value) => self.0.push_str(format!("{}", HtmlEscape(value.raw()))),
            Event::LatexFragment(value) => self.0.push_str(format!("{}", HtmlEscape(value.raw()))),
            Event::LatexEnvironment(value) => self.literal("literal", value.raw()),
            Event::InlineSrc(value) => self
                .0
                .push_str(format!("<code>{}</code>", HtmlEscape(value.raw()))),
            Event::InlineCall(value) => self
                .0
                .push_str(format!("<code>{}</code>", HtmlEscape(value.raw()))),
            Event::Macros(value) => self.0.push_str(format!("{}", HtmlEscape(value.raw()))),
            Event::Cookie(value) => self.0.push_str(format!("{}", HtmlEscape(value.raw()))),
            Event::Clock(value) => self.literal("metadata", value.raw()),
            _ => self.0.event(event, ctx),
        }
    }
}

fn external_link_href(path: &str) -> Option<String> {
    if path.chars().any(char::is_control) {
        return None;
    }
    let url = reqwest::Url::parse(path).ok()?;
    match url.scheme() {
        "http" | "https" if url.host_str().is_some() => Some(url.into()),
        "mailto" | "tel" if !url.path().is_empty() => Some(url.into()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "notes.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }

    #[test]
    fn projects_title_links_without_exposing_org_markup_or_changing_source() {
        let source = "#+TITLE: TODO [#A] [[https://example.com/?a=1&b=2][资料 *入口*]] 与 [[mailto:team@example.com]]\n* TODO 阅读 [[https://example.org][课程]] :reading:\n";
        let file = file(source);
        assert_eq!(
            file.title_parts(),
            vec![
                TitlePart {
                    text: "TODO [#A] ".into(),
                    href: None,
                    is_link: false
                },
                TitlePart {
                    text: "资料 入口".into(),
                    href: Some("https://example.com/?a=1&b=2".into()),
                    is_link: true
                },
                TitlePart {
                    text: " 与 ".into(),
                    href: None,
                    is_link: false
                },
                TitlePart {
                    text: "mailto:team@example.com".into(),
                    href: Some("mailto:team@example.com".into()),
                    is_link: true
                },
            ]
        );
        let html = file.render_html();
        assert!(html.contains("<a class=\"link\" href=\"https://example.org/\""));
        assert!(html.contains("课程</a>"));
        assert!(!html.contains("[[https://"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn title_projection_keeps_literal_targets_and_disallows_active_protocols() {
        let parts = title_parts(
            "[[javascript:alert(1)][脚本]] [[file:/secret.png][本地]] [[id:task-id][记录]]",
        );
        assert_eq!(
            parts
                .iter()
                .map(|part| part.text.as_str())
                .collect::<String>(),
            "脚本 本地 记录"
        );
        assert!(parts.iter().all(|part| part.href.is_none()));
        assert_eq!(
            parts.iter().map(|part| part.is_link).collect::<Vec<_>>(),
            vec![true, false, true, false, true]
        );
        let html = file("* 标题 [[id:task-id][内部引用]]\n").render_html();
        assert!(html.contains("class=\"link unsupported\""));
        assert!(html.contains("aria-disabled=\"true\""));
        assert!(html.contains("内部引用</span>"));
        assert!(!html.contains("href="));
        assert_eq!(serde_json::to_value(&parts[0]).unwrap()["isLink"], true);
        assert!(external_link_href("https://example.com/\nsecret").is_none());
        assert!(external_link_href("data:text/html,hello").is_none());
        assert_eq!(
            external_link_href("TEL:12345").as_deref(),
            Some("tel:12345")
        );
        assert_eq!(title_parts(""), Vec::new());
        assert_eq!(
            title_parts("=code= ~verbatim~ \\alpha"),
            vec![TitlePart {
                text: "code verbatim α".into(),
                href: None,
                is_link: false
            }]
        );
    }

    #[test]
    fn renders_whole_document_without_changing_bytes() {
        let source = "#+TITLE: 花园\n前言 *粗体*\n* TODO 整平 :weekend:\nSCHEDULED: <2026-10-31 Sat 10:00-13:00>\n:PROPERTIES:\n:ID: garden\n:END:\n正文 [[https://example.com][堆肥]]\n** 材料\n| Item | Qty |\n|------+-----|\n| 木材 | 18 |\n#+TBLFM: $2=18\n#+begin_src python\nprint(\"<wood>\")\n#+end_src\n* DONE 完成\n";
        let file = file(source);
        let html = file.render_html();
        for expected in [
            "前言 <b>粗体</b>",
            "todo pending",
            "todo done",
            "weekend</span>",
            "SCHEDULED",
            "10:00-13:00&gt;",
            "PROPERTIES",
            "garden</dd>",
            "堆肥</a>",
            "<table>",
            "<td>木材",
            "#+TBLFM: $2=18",
            "src python",
            "&lt;wood&gt;",
        ] {
            assert!(html.contains(expected), "缺少 {expected}: {html}");
        }
        assert_eq!(html.matches("<details class=\"heading").count(), 3);
        assert_eq!(html.matches("</details>").count(), 4);
        assert_eq!(file.source_bytes(), source.as_bytes());
        assert!(!html.contains("document-title"));
        assert!(!html.contains("花园"));
    }

    #[test]
    fn treats_active_content_as_literal_and_never_loads_resources() {
        let html = file("#+TITLE: <script>alert(1)</script>\n#+begin_export html\n<img src=x onerror=alert(1)>\n#+end_export\n@@html:<script>evil()</script>@@\n[[javascript:alert(1)][点击]] [[file:/secret.png]]\n").render_html();
        assert!(!html.contains("<script>"));
        assert!(!html.contains("<img"));
        assert!(!html.contains("href="));
        assert!(html.contains("&lt;script&gt;"));
    }

    #[test]
    fn renders_preamble_empty_file_and_custom_done_state() {
        assert!(file("只有前言\n").render_html().contains("只有前言"));
        assert_eq!(file("").render_html(), "<main></main>");
        let html = file("#+TODO: NEXT | FINISHED\n* FINISHED 发布\n").render_html();
        assert!(html.contains("todo done\">FINISHED"));
    }

    #[test]
    fn renders_file_tags_nested_lists_and_safe_description_terms() {
        let html = file("#+FILETAGS: :project:diy:\n- [ ] 待办\n  - [X] 完成\n- [-] 部分\n\n\n- 术语 :: [[file:/secret.png]] 说明\n- @@html:<img src=x>@@ :: 字面文本\n").render_html();
        for expected in [
            "project</span>",
            "diy</span>",
            "☐</span>",
            "☑</span>",
            "◩</span>",
            "<dl><dt>",
            "说明",
            "&lt;img src=x&gt;",
        ] {
            assert!(html.contains(expected), "缺少 {expected}: {html}");
        }
        assert!(!html.contains("<img"));
        assert_eq!(html.matches("<ul>").count(), html.matches("</ul>").count());
    }

    #[test]
    fn keeps_empty_table_cells_in_their_original_columns() {
        let html = file("| Item | Qty | Unit price | Total |\n|------+-----+------------+-------|\n| Timber | 18 | 6.50 | 117.00 |\n| Total | | | 202.90 |\n| | 2 | | |\n| Last | | | tail\n").render_html();
        assert!(
            html.contains("<tr><td>Total</td><td></td><td></td><td>202.90</td></tr>"),
            "{html}"
        );
        assert!(
            html.contains("<tr><td></td><td>2</td><td></td><td></td></tr>"),
            "{html}"
        );
        assert!(
            html.contains("<tr><td>Last</td><td></td><td></td><td>tail</td></tr>"),
            "{html}"
        );
    }

    #[test]
    fn task_content_extracts_only_real_logbook_drawers() {
        let source = "* TODO Task\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-11-05 Thu 10:00]\nCLOCK: [2026-11-05 Thu 09:00]--[2026-11-05 Thu 10:00] => 1:00\n:END:\n正文 *粗体* [[https://example.com][链接]]\n#+begin_src text\n:LOGBOOK:\n保留代码\n:END:\n#+end_src\n:OTHER:\n其他抽屉\n:END:\n:LOGBOOK:\n- 第二条记录\n:END:\n";
        let file = file(source);
        let mut repo = crate::OrgRepo::new("/tmp/render-only".into()).unwrap();
        repo.id = "repo".into();
        repo.files.push(file);
        let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        let task = workspace.search(&crate::Filter::parse("")).remove(0);
        let rendered = task.render_content();
        assert!(rendered.body_html.contains("<b>粗体</b>"));
        assert!(rendered.body_html.contains("链接</a>"));
        assert!(rendered.body_html.contains("保留代码"));
        assert!(rendered.body_html.contains("其他抽屉"));
        assert!(!rendered.body_html.contains("CLOCK:"));
        assert!(!rendered.body_html.contains("第二条记录"));
        assert!(rendered.logbook_html.contains("CLOCK:"));
        assert!(rendered.logbook_html.contains("第二条记录"));
        assert!(task.body.contains(":LOGBOOK:"));
        assert_eq!(
            workspace.repos()[0].files()[0].source_bytes(),
            source.as_bytes()
        );
    }

    #[test]
    fn logbook_only_task_has_empty_rendered_body() {
        let mut view = ReadingView(HtmlExport::default(), Vec::new(), Some(String::new()));
        orgize::Org::parse(
            ":LOGBOOK:\nCLOCK: [2026-11-05 Thu 09:00]--[2026-11-05 Thu 10:00] => 1:00\n:END:\n",
        )
        .traverse(&mut view);
        assert!(view.0.finish().is_empty());
        assert!(view.2.unwrap().contains("CLOCK:"));
    }
}
