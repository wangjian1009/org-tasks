//! 基于现有 orgize 语法树的只读 HTML 投影；不改变源字节，不执行文内 HTML。
use super::OrgFile;
use orgize::export::{Container, Event, HtmlEscape, HtmlExport, TraversalContext, Traverser};
use orgize::{SyntaxKind, rowan::ast::AstNode};

impl OrgFile {
    /// 返回不含脚本、样式或外部资源的只读文档片段，样式由宿主提供。
    pub fn render_html(&self) -> String {
        let mut view = ReadingView(HtmlExport::default(), Vec::new());
        if let Some(title) = self.title().filter(|title| !title.is_empty()) {
            view.0.push_str(format!(
                "<h1 class=\"document-title\">{}</h1>",
                HtmlEscape(title)
            ));
        }
        self.syntax().traverse(&mut view);
        view.0.finish()
    }
}

struct ReadingView(HtmlExport, Vec<bool>);

impl ReadingView {
    fn literal(&mut self, class: &str, text: impl AsRef<str>) {
        self.0
            .push_str(format!("<pre class=\"{class}\">{}</pre>", HtmlEscape(text)));
    }
}

impl Traverser for ReadingView {
    fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
        match event {
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
                // 链接仅投影文本，图片也不触发本地文件或网络读取。
                self.0.push_str(format!(
                    "<span class=\"link\" title=\"{}\">",
                    HtmlEscape(link.path())
                ));
                if link.has_description() {
                    for element in link.description() {
                        self.element(element, &mut TraversalContext::default());
                    }
                } else {
                    self.0.push_str(format!("{}", HtmlEscape(link.path())));
                }
                self.0.push_str("</span>");
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
    fn renders_whole_document_without_changing_bytes() {
        let source = "#+TITLE: 花园\n前言 *粗体*\n* TODO 整平 :weekend:\nSCHEDULED: <2026-10-31 Sat 10:00-13:00>\n:PROPERTIES:\n:ID: garden\n:END:\n正文 [[https://example.com][堆肥]]\n** 材料\n| Item | Qty |\n|------+-----|\n| 木材 | 18 |\n#+TBLFM: $2=18\n#+begin_src python\nprint(\"<wood>\")\n#+end_src\n* DONE 完成\n";
        let file = file(source);
        let html = file.render_html();
        for expected in [
            "花园</h1>",
            "前言 <b>粗体</b>",
            "todo pending",
            "todo done",
            "weekend</span>",
            "SCHEDULED",
            "10:00-13:00&gt;",
            "PROPERTIES",
            "garden</dd>",
            "堆肥</span>",
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
}
