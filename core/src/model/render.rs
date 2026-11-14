//! 基于现有 orgize 语法树的只读 HTML 投影；不改变源字节，不执行文内 HTML。
use super::OrgFile;
use crate::FilterTask;
use chrono::NaiveDate;
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
    pub count: Option<TitleCount>,
    pub link: Option<super::TextLink>,
}

/// 标题中的分数统计；空统计保留为空，不由展示层重新计算。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TitleCount {
    pub completed: Option<u32>,
    pub total: Option<u32>,
}

/// 按文件顺序排列的直属正文；path 为空表示文件前言，标题由现有节点接口提供。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSection {
    pub path: Option<super::TaskPath>,
    pub html: String,
    pub blocks: Vec<super::ContentBlock>,
    pub link_targets: Vec<DocumentLinkTarget>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentLinkTarget {
    pub target: String,
    pub priority: u8,
}

impl TitleCount {
    fn from_cookie(cookie: &orgize::ast::Cookie) -> Option<Self> {
        if cookie.syntax().ancestors().skip(1).any(|node| {
            matches!(
                node.kind(),
                SyntaxKind::CODE | SyntaxKind::VERBATIM | SyntaxKind::LINK
            )
        }) {
            return None;
        }
        Self::parse(&cookie.raw())
    }

    fn parse(raw: &str) -> Option<Self> {
        let (completed, total) = raw.strip_prefix('[')?.strip_suffix(']')?.split_once('/')?;
        if completed.is_empty() && total.is_empty() {
            return Some(Self {
                completed: None,
                total: None,
            });
        }
        let completed: u32 = completed.parse().ok()?;
        let total: u32 = total.parse().ok()?;
        (completed <= total).then_some(Self {
            completed: Some(completed),
            total: Some(total),
        })
    }

    fn label(&self) -> String {
        match (self.completed, self.total) {
            (Some(completed), Some(total)) => format!("{completed}/{total}"),
            _ => "—/—".into(),
        }
    }

    fn html(&self) -> String {
        let (completed, total) = (self.completed.unwrap_or(0), self.total.unwrap_or(0));
        let state = if total > 0 && completed == total {
            "complete"
        } else if completed > 0 {
            "active"
        } else {
            "empty"
        };
        let turn = if total > 0 {
            completed as f64 / total as f64
        } else {
            0.0
        };
        let description = if self.total.is_some() {
            format!("已完成 {completed} 项，共 {total} 项")
        } else {
            "尚无有效计数".into()
        };
        format!(
            "<span class=\"title-count {state}\" style=\"--count-turn:{turn}turn\" role=\"img\" aria-label=\"{description}\"><span class=\"count-ring\" aria-hidden=\"true\"></span><span>{}</span></span>",
            self.label()
        )
    }
}

impl OrgFile {
    /// 将同一语法树拆为前言和各标题的直属正文，保留表格和清单，排除属性与日志抽屉。
    /// 不包含标题或后代正文，不应用任务查询过滤；受保护的冲突子树除外。
    pub fn document_sections(&self) -> Vec<DocumentSection> {
        let render = |section: Option<orgize::ast::Section>| {
            let mut view = ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, Some(self.todo.clone()), true);
            if let Some(section) = section {
                for element in section.syntax().children_with_tokens() {
                    if element.kind() != SyntaxKind::PLANNING {
                        view.element(element, &mut TraversalContext::default());
                    }
                }
            }
            view.0.finish()
        };
        let mut sections = vec![DocumentSection { path: None, html: render(self.syntax().document().section()), blocks: super::content_block::blocks(self, self.syntax().document().section(), None), link_targets: document_link_targets(None, self.syntax().document().section()) }];
        sections.extend(self.path_headlines().into_iter()
            .filter(|(_, headline)| !Self::is_conflict_headline(headline))
            .map(|(path, headline)| DocumentSection { path: Some(path), html: render(headline.section()), blocks: super::content_block::blocks(self, headline.section(), Some(&headline)), link_targets: document_link_targets(Some(&headline), headline.section()) }));
        sections
    }

    pub fn title_parts(&self) -> Vec<TitlePart> {
        title_parts(&self.title().unwrap_or_default())
    }

    /// 返回不含脚本、样式或外部资源的只读文档片段，样式由宿主提供。
    pub fn render_html(&self) -> String {
        let mut view = ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, None, false);
        self.syntax().traverse(&mut view);
        view.0.finish()
    }

    /// 完整文档的语义投影；宿主决定哪些任务可折叠，不新增页面领域状态。
    pub fn render_document_html(&self) -> String {
        let mut view = ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, Some(self.todo.clone()), false);
        view.0.push_str("<header class=\"document-header\">");
        if let Some(name) = self.project_name() {
            view.0.push_str(format!("<div class=\"document-project-name\">{}</div>", HtmlEscape(name)));
        }
        if let Some(category) = self.category().filter(|value| !value.is_empty()) {
            view.0.push_str(format!("<div class=\"document-category\">{}</div>", HtmlEscape(category)));
        }
        if let Some(title) = self.title() {
            let title = title_parts(&title).into_iter().map(|part| part.text).collect::<String>();
            view.0.push_str(format!("<div class=\"document-file-title\">{}</div>", HtmlEscape(title)));
        }
        view.0.push_str("<div class=\"file-tags\">");
        for value in self.file_keywords.values("FILETAGS") {
            for tag in value.split(':').map(str::trim).filter(|tag| !tag.is_empty()) {
                view.0.push_str(format!("<span class=\"tag\">{}</span>", HtmlEscape(tag)));
            }
        }
        view.0.push_str("</div><dl class=\"file-properties\">");
        for keyword in self.syntax().document().keywords() {
            if !["TITLE", "PROJECT_NAME", "FILETAGS", "CATEGORY", "PROPERTY"].iter().any(|key| keyword.key().eq_ignore_ascii_case(key)) {
                view.0.push_str(format!("<dt>{}</dt><dd>{}</dd>", HtmlEscape(keyword.key()), HtmlEscape(keyword.value().trim())));
            }
        }
        for (name, value) in &self.file_keywords.properties {
            view.0.push_str(format!("<dt>{}</dt><dd>{}</dd>", HtmlEscape(name), HtmlEscape(value)));
        }
        view.0.push_str(format!("</dl><div class=\"document-file-stats\" data-byte-length=\"{}\"", self.source_bytes().len()));
        if let Some(modified) = self.modified_at {
            view.0.push_str(format!(" data-modified-at=\"{modified}\""));
        }
        view.0.push_str("></div></header>");
        self.syntax().traverse(&mut view);
        view.0.finish()
    }

}

/// 任务详情的运行时展示投影，原始 body 仍用于查询和其他宿主。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderedTaskContent {
    pub body_html: String,
    pub logbook_html: String,
    pub logs: Vec<super::TaskLog>,
    /// 正文中存在真实列表，不包含 LOGBOOK 或源码中的字面列表。
    pub has_list: bool,
    /// 正文中存在列表之外的可读文本，不包含规划、drawer、源码和日志。
    pub has_text: bool,
}

impl FilterTask {
    /// 正文首个非空段落的第一行，不包含规划、属性、drawer 或子标题。
    pub fn body_first_line(&self) -> Option<String> {
        struct FirstLine(Option<String>);
        impl Traverser for FirstLine {
            fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
                match event {
                    Event::Enter(
                        Container::PropertyDrawer(_) | Container::Drawer(_)
                        | Container::Comment(_) | Container::CommentBlock(_),
                    ) => ctx.skip(),
                    Event::Enter(Container::Paragraph(paragraph)) => {
                        if let Some(line) = paragraph.raw().lines().find(|line| !line.trim().is_empty()) {
                            let text = title_parts(line.trim())
                                .into_iter()
                                .map(|part| part.text)
                                .collect::<String>();
                            if !text.trim().is_empty() {
                                self.0 = Some(text);
                                ctx.stop();
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        let mut preview = FirstLine(None);
        orgize::Org::parse(&body_without_planning(&self.body)).traverse(&mut preview);
        preview.0
    }

    pub fn title_parts(&self) -> Vec<TitlePart> {
        title_parts(&self.title)
    }

    pub fn render_content(&self) -> RenderedTaskContent {
        let body = body_without_planning(&self.body);
        let mut view = ReadingView(
            HtmlExport::default(),
            Vec::new(),
            Some(String::new()),
            false,
            false,
            false,
            None,
            false,
        );
        let org = orgize::Org::parse(&body);
        org.traverse(&mut view);
        RenderedTaskContent {
            body_html: view.0.finish(),
            logbook_html: view.2.unwrap_or_default(),
            logs: super::task_log::task_logs(&org),
            has_list: view.3,
            has_text: view.5,
        }
    }
}

pub(super) fn render_fragment(source: &str) -> String {
    let mut view = ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, None, false);
    orgize::Org::parse(source).traverse(&mut view);
    view.0.finish()
}

// 任务的规划行属于标题元数据，独立展示在任务字段区域，不重复塞进正文。
// 只处理正文开头的规划行，避免误删用户正文中后续出现的同名普通文本。
fn body_without_planning(body: &str) -> String {
    let mut result = String::with_capacity(body.len());
    let mut at_planning_start = true;
    for line in body.split_inclusive('\n') {
        let content = line.strip_suffix('\n').unwrap_or(line);
        let content = content.strip_suffix('\r').unwrap_or(content);
        if at_planning_start && is_planning_line(content) {
            continue;
        }
        if !content.trim().is_empty() {
            at_planning_start = false;
        }
        result.push_str(line);
    }
    result
}

fn is_planning_line(line: &str) -> bool {
    ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
        .iter()
        .any(|keyword| {
            let Some(value) = line
                .trim_start()
                .strip_prefix(keyword)
                .map(str::trim_start)
            else {
                return false;
            };
            let Some(opener) = value.chars().next() else {
                return false;
            };
            (opener == '<' || opener == '[')
                && value
                    .get(1..11)
                    .and_then(|date| NaiveDate::parse_from_str(date, "%Y-%m-%d").ok())
                    .is_some()
        })
}

fn title_parts(source: &str) -> Vec<TitlePart> {
    title_parts_with_progress(source, false)
}

pub(super) fn refile_title_parts(source: &str) -> Vec<TitlePart> {
    title_parts_with_progress(source, true)
}

fn title_parts_with_progress(source: &str, hide_progress: bool) -> Vec<TitlePart> {
    if source.is_empty() {
        return Vec::new();
    }
    // 用普通段落承载行内语法，避免 TITLE 被识别为列表、标题或关键字。
    let mut view = TitleView(Vec::new(), None, false, hide_progress);
    if !render_inline_links(&mut view, source) {
        orgize::Org::parse(&format!("x {source}")).traverse(&mut view);
        if let Some(first) = view.0.first_mut() {
            first.text.drain(..2);
        }
    }
    let mut links = super::text_link::text_links(source).into_iter();
    for part in view.0.iter_mut().filter(|part| part.is_link) { part.link = links.next(); }
    view.0.retain(|part| !part.text.is_empty());
    view.0
}

struct TitleView(Vec<TitlePart>, Option<String>, bool, bool);

impl TitleView {
    fn start_link(&mut self) {
        self.0.push(TitlePart { text: String::new(), href: self.1.clone(), is_link: true, count: None, link: None });
    }
    fn push(&mut self, text: &str) {
        if let Some(last) = self
            .0
            .last_mut()
            .filter(|part| part.href == self.1 && part.is_link == self.2 && part.count.is_none())
        {
            last.text.push_str(text);
        } else {
            self.0.push(TitlePart {
                text: text.into(),
                href: self.1.clone(),
                is_link: self.2,
                count: None,
                link: None,
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
            Event::Cookie(value) => {
                if self.3 && !self.2 && !value.syntax().ancestors().skip(1).any(|node| {
                    matches!(node.kind(), SyntaxKind::CODE | SyntaxKind::VERBATIM | SyntaxKind::LINK)
                }) {
                    return;
                }
                if let Some(count) = TitleCount::from_cookie(&value).filter(|_| !self.2) {
                    self.0.push(TitlePart {
                        text: count.label(),
                        href: None,
                        is_link: false,
                        count: Some(count),
                        link: None,
                    });
                } else {
                    self.push(&value.raw());
                }
            }
            Event::Macros(value) => self.push(&value.raw()),
            Event::Snippet(value) => self.push(&value.raw()),
            Event::InlineCall(value) => self.push(&value.raw()),
            Event::InlineSrc(value) => self.push(&value.raw()),
            Event::LatexFragment(value) => self.push(&value.raw()),
            Event::LineBreak(_) => self.push("\n"),
            Event::Enter(Container::Link(link)) => {
                let previous = self.1.take();
                let previous_is_link = self.2;
                self.1 = rendered_link_href(link.path().as_ref());
                self.2 = true;
                self.start_link();
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

// 用不会形成 Org 语法的占位符重新解析行内排版，避免 URL 中的下划线、斜线等被拆为格式节点。
// 仅重建运行时段落，不改变原始语法树及标题的字节定位。
trait InlineLinkView: Traverser {
    fn inline_text(&mut self, text: &str);
    fn inline_link(&mut self, target: &str);
}

impl InlineLinkView for TitleView {
    fn inline_text(&mut self, text: &str) { self.push(text); }

    fn inline_link(&mut self, target: &str) {
        let previous = self.1.take();
        let was_link = self.2;
        self.1 = external_link_href(target);
        self.2 = true;
        self.start_link();
        self.push(target);
        self.1 = previous;
        self.2 = was_link;
    }
}

fn render_inline_links(view: &mut impl InlineLinkView, source: &str) -> bool {
    let links = super::plain_links::plain_links(source);
    if links.is_empty() { return false; }
    let mut prefix = "ORGPLAINLINKTOKEN".to_string();
    while source.contains(&prefix) { prefix.push('X'); }
    let markers = links.iter().enumerate().map(|(index, link)|
        (format!("{prefix}{index}END"), link.target.clone())
    ).collect::<Vec<_>>();
    let mut prepared = source.to_string();
    for (link, (marker, _)) in links.iter().zip(&markers).rev() {
        prepared.replace_range(link.range.clone(), marker);
    }
    struct Inline<'a, T> { view: &'a mut T, markers: &'a [(String, String)], prefix: usize }
    impl<T: InlineLinkView> Traverser for Inline<'_, T> {
        fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
            match event {
                Event::Enter(Container::Document(_) | Container::Section(_) | Container::Paragraph(_))
                | Event::Leave(Container::Document(_) | Container::Section(_) | Container::Paragraph(_)) => {}
                Event::Text(text) => {
                    let skip = self.prefix.min(text.len());
                    self.prefix -= skip;
                    let mut text = &text.as_ref()[skip..];
                    while !text.is_empty() {
                        let next = self.markers.iter().filter_map(|(marker, target)|
                            text.find(marker).map(|start| (start, marker.len(), target))
                        ).min_by_key(|(start, _, _)| *start);
                        let Some((start, length, target)) = next else { self.view.inline_text(text); break; };
                        self.view.inline_text(&text[..start]);
                        self.view.inline_link(target);
                        text = &text[start + length..];
                    }
                }
                _ => self.view.event(event, ctx),
            }
        }
    }
    orgize::Org::parse(&format!("x {prepared}")).traverse(&mut Inline { view, markers: &markers, prefix: 2 });
    true
}

// 最后一项仅用于分段正文：隐藏属性与日志抽屉，通用文件预览继续保留它们。
struct ReadingView(HtmlExport, Vec<bool>, Option<String>, bool, bool, bool, Option<super::TodoMetadata>, bool);

impl ReadingView {
    fn literal(&mut self, class: &str, text: impl AsRef<str>) {
        self.0
            .push_str(format!("<pre class=\"{class}\">{}</pre>", HtmlEscape(text)));
    }
}

impl InlineLinkView for ReadingView {
    fn inline_text(&mut self, text: &str) {
        if self.2.is_some() && !self.4 && self.1.is_empty() && !text.trim().is_empty() { self.5 = true; }
        self.0.push_str(format!("{}", HtmlEscape(text)));
    }

    fn inline_link(&mut self, target: &str) {
        if self.2.is_some() && !self.4 && self.1.is_empty() { self.5 = true; }
        if let Some(href) = external_link_href(target) {
            self.0.push_str(format!("<a class=\"link\" href=\"{}\" title=\"{}\">{}</a>",
                HtmlEscape(href), HtmlEscape(target), HtmlEscape(target)));
        } else {
            self.0.push_str(format!("<span class=\"link unsupported\" role=\"link\" aria-disabled=\"true\">{}</span>", HtmlEscape(target)));
        }
    }
}

impl Traverser for ReadingView {
    fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
        match event {
            Event::Enter(Container::Paragraph(paragraph)) => {
                let source = paragraph.raw();
                self.0.event(Event::Enter(Container::Paragraph(paragraph)), ctx);
                if render_inline_links(self, &source) {
                    self.0.push_str("</p>");
                    ctx.skip();
                }
            }
            Event::Enter(Container::OrgTableCell(cell)) => {
                let source = cell.raw();
                self.0.event(Event::Enter(Container::OrgTableCell(cell)), ctx);
                if render_inline_links(self, &source) {
                    self.0.push_str("</td>");
                    ctx.skip();
                }
            }
            Event::Cookie(value) if self.4 => {
                if let Some(count) = TitleCount::from_cookie(&value) {
                    self.0.push_str(count.html());
                } else {
                    self.0.push_str(format!("{}", HtmlEscape(value.raw())));
                }
            }
            Event::Enter(Container::Document(_) | Container::Section(_))
            | Event::Leave(Container::Document(_) | Container::Section(_))
                if self.2.is_some() => {}
            // Section 仅包含当前标题的直属正文；后代 Headline 是它的兄弟节点。
            Event::Enter(Container::Section(_)) if self.6.is_some() => {
                self.0.push_str("<div class=\"heading-body\">");
            }
            Event::Leave(Container::Section(_)) if self.6.is_some() => {
                self.0.push_str("</div>");
            }
            Event::Enter(Container::Headline(headline)) => {
                if self.6.is_some() && OrgFile::is_conflict_headline(&headline) {
                    ctx.skip();
                    return;
                }
                let level = headline.level().min(6);
                let document = self.6.is_some();
                let tag = if document { "section" } else { "details" };
                let summary = if document { "div class=\"heading-summary\"" } else { "summary" };
                self.0.push_str(format!("<{tag} class=\"heading level-{level}\" data-org-start=\"{}\" data-org-end=\"{}\" id=\"org-node-{}\"", u32::from(headline.start()), u32::from(headline.end()), u32::from(headline.start())));
                self.0.push_str(internal_target_attributes(&headline_link_targets(&headline), 2));
                if let Some(todo) = headline.todo_keyword().filter(|_| document) {
                    let state = self.6.as_ref().and_then(|metadata| metadata.category(todo.as_ref()));
                    let content = headline.section().is_some_and(|section| section.syntax().children().any(|node| node.kind() != SyntaxKind::PLANNING));
                    self.0.push_str(format!(" data-org-task=\"true\" data-org-state=\"{}\" data-org-foldable=\"{content}\"", state.map(|value| format!("{value:?}")).unwrap_or_default()));
                }
                self.0.push_str(if document { ">" } else { " open>" });
                self.0.push_str(format!("<{summary}><span role=\"heading\" aria-level=\"{level}\" class=\"heading-title\">"));
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
                self.4 = true;
                let title = headline.title().map(|element| element.to_string()).collect::<String>();
                if !render_inline_links(self, &title) {
                    for element in headline.title() {
                        self.element(element, &mut TraversalContext::default());
                    }
                }
                self.4 = false;
                self.0.push_str("</span><span class=\"tags\">");
                for tag in headline.tags() {
                    self.0
                        .push_str(format!("<span class=\"tag\">{}</span>", HtmlEscape(tag)));
                }
                self.0.push_str(if document { "</span>" } else { "</span></summary>" });
                for (label, timestamp) in [
                    ("SCHEDULED", headline.scheduled()),
                    ("DEADLINE", headline.deadline()),
                    ("CLOSED", headline.closed()),
                ] {
                    if let Some(timestamp) = timestamp {
                        self.0.push_str(format!("<div class=\"planning\"><span>{label}: </span><span class=\"timestamp\">{}</span></div>", HtmlEscape(timestamp.raw().trim())));
                    }
                }
                if document { self.0.push_str("</div><div class=\"heading-content\">"); }
            }
            Event::Leave(Container::Headline(_)) => self.0.push_str(if self.6.is_some() { "</div></section>" } else { "</details>" }),
            Event::Enter(Container::PropertyDrawer(drawer)) => {
                let document = self.6.is_some();
                if self.7 || (document && !drawer.syntax().ancestors().any(|node| node.kind() == SyntaxKind::HEADLINE)) {
                    ctx.skip();
                    return;
                }
                self.0.push_str(if document { "<section class=\"drawer\"><div class=\"drawer-title\">PROPERTIES</div><dl>" }
                    else { "<details class=\"drawer\"><summary>PROPERTIES</summary><dl>" });
                for (key, value) in super::properties::Properties::from_drawer(&drawer).iter() {
                    self.0.push_str(format!(
                        "<dt>{}</dt><dd>{}</dd>",
                        HtmlEscape(key),
                        HtmlEscape(value)
                    ));
                }
                self.0.push_str(if document { "</dl></section>" } else { "</dl></details>" });
                ctx.skip();
            }
            Event::Enter(Container::Drawer(drawer)) => {
                if self.7 && ["PROPERTIES", "LOGBOOK"].iter().any(|name| drawer.name().eq_ignore_ascii_case(name)) {
                    ctx.skip();
                    return;
                }
                if drawer.name().eq_ignore_ascii_case("LOGBOOK") && self.2.is_some() {
                    let mut log =
                        ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, None, false);
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
                let document = self.6.is_some();
                self.0.push_str(if document {
                    format!("<section class=\"drawer\"><div class=\"drawer-title\">{}</div>", HtmlEscape(drawer.name()))
                } else { format!("<details class=\"drawer\"><summary>{}</summary>", HtmlEscape(drawer.name())) });
                let mut content = ReadingView(HtmlExport::default(), Vec::new(), None, false, false, false, self.6.clone(), self.7);
                for element in drawer.syntax().children()
                    .filter(|node| node.kind() == SyntaxKind::DRAWER_CONTENT)
                    .flat_map(|node| node.children_with_tokens()) {
                    content.element(element, &mut TraversalContext::default());
                }
                self.0.push_str(format!("<div class=\"drawer-content\">{}</div>", content.0.finish()));
                self.0.push_str(if document { "</section>" } else { "</details>" });
                ctx.skip();
            }
            Event::Enter(Container::Target(target)) => {
                let raw = target.raw();
                let name = raw.trim_start_matches("<<").trim_end_matches(">>").trim();
                self.0.push_str(format!("<span{}></span>", internal_target_attributes(&[name.to_owned()], 0)));
                ctx.skip();
            }
            Event::Enter(Container::AffiliatedKeyword(keyword)) => {
                if keyword.key().eq_ignore_ascii_case("NAME") {
                    self.0.push_str(format!("<span{}></span>", internal_target_attributes(&[keyword.value().map(|value| value.trim().to_owned()).unwrap_or_default()], 1)));
                }
                ctx.skip();
            }
            Event::Enter(Container::SourceBlock(block)) => {
                if let Some(name) = block.name().and_then(|keyword| keyword.value()) {
                    self.0.push_str(format!("<span{}></span>", internal_target_attributes(&[name.trim().into()], 1)));
                }
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
                    .event(Event::Leave(Container::OrgTable(table)), ctx);
                self.0.push_str("</div>");
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
                if self.6.is_some() {
                    if keyword.syntax().ancestors().any(|node| node.kind() == SyntaxKind::HEADLINE) {
                        self.literal("metadata", keyword.raw());
                    }
                    ctx.skip();
                    return;
                }
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
                }
                // 配置关键字由解析层消费，阅读投影不输出原始声明。
                ctx.skip();
            }
            Event::Enter(Container::Link(link)) => {
                // 只生成链接目标，不下载图片或其他外部资源；打开动作由宿主承接。
                let href = rendered_link_href(link.path().as_ref());
                if let Some(href) = &href {
                    self.0.push_str(format!(
                        "<a class=\"link\" href=\"{}\" title=\"{}\" data-org-url=\"{}\">",
                        HtmlEscape(href),
                        HtmlEscape(link.path()), HtmlEscape(link.path())
                    ));
                } else {
                    self.0.push_str(format!(
                        "<span class=\"link unsupported\" role=\"link\" aria-disabled=\"true\" title=\"{}\" data-org-url=\"{}\">",
                        HtmlEscape(link.path()), HtmlEscape(link.path())
                    ));
                }
                let in_title = self.4;
                self.4 = false;
                if link.has_description() {
                    for element in link.description() {
                        self.element(element, &mut TraversalContext::default());
                    }
                } else {
                    self.0.push_str(format!("{}", HtmlEscape(link.path())));
                }
                self.4 = in_title;
                self.0
                    .push_str(if href.is_some() { "</a>" } else { "</span>" });
                ctx.skip();
            }
            Event::Enter(Container::List(list)) => {
                self.3 = true;
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
                let checkbox = item.checkbox();
                if self.1.last() == Some(&true) {
                    self.0.push_str("<dt>");
                    let tag = item.tag().map(|element| element.to_string()).collect::<String>();
                    if !render_inline_links(self, &tag) {
                        for element in item.tag() {
                            self.element(element, &mut TraversalContext::default());
                        }
                    }
                    self.0.push_str("</dt><dd>");
                } else {
                    self.0.push_str(if checkbox.is_some() {
                        "<li class=\"checkbox-item\">"
                    } else {
                        "<li>"
                    });
                }
                if let Some(checkbox) = checkbox {
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
            Event::Text(text)
                if self.2.is_some()
                    && !self.4
                    && self.1.is_empty()
                    && !text.as_ref().trim().is_empty() =>
            {
                self.5 = true;
                self.0.event(Event::Text(text), ctx);
            }
            Event::Enter(Container::ExportBlock(block)) => {
                self.literal("literal", block.raw());
                ctx.skip();
            }
            Event::Enter(Container::CommentBlock(block)) => {
                // 合并原文保存在标准注释块中，阅读时只展示整理后的列表。
                if !super::task_merging::is_archive(&block.raw()) {
                    self.literal("metadata", block.raw());
                }
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
                if self.6.is_some() { self.literal("metadata", call.raw()); }
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

fn headline_link_targets(headline: &orgize::ast::Headline) -> Vec<String> {
    let title = headline.title_raw().trim().to_owned();
    let mut targets = vec![format!("*{title}"), title];
    if let Some(drawer) = headline.properties() {
        if let Some(id) = super::properties::Properties::from_drawer(&drawer).get("CUSTOM_ID").filter(|id| !id.is_empty()) {
            targets.push(format!("#{id}"));
        }
    }
    targets
}

fn document_link_targets(headline: Option<&orgize::ast::Headline>, section: Option<orgize::ast::Section>) -> Vec<DocumentLinkTarget> {
    let mut targets = headline.map(headline_link_targets).unwrap_or_default().into_iter()
        .map(|target| DocumentLinkTarget { target, priority: 2 }).collect::<Vec<_>>();
    if let Some(section) = section {
        for node in section.syntax().descendants().filter(|node| !node.ancestors().skip(1).any(|parent| {
            matches!(parent.kind(), SyntaxKind::EXAMPLE_BLOCK | SyntaxKind::COMMENT_BLOCK | SyntaxKind::COMMENT | SyntaxKind::PROPERTY_DRAWER)
                || (parent.kind() == SyntaxKind::SOURCE_BLOCK && node.kind() != SyntaxKind::AFFILIATED_KEYWORD)
                || orgize::ast::Drawer::cast(parent).is_some_and(|drawer| drawer.name().eq_ignore_ascii_case("LOGBOOK"))
        })) {
            if let Some(target) = orgize::ast::Target::cast(node.clone()) {
                targets.push(DocumentLinkTarget { target: target.raw().trim_start_matches("<<").trim_end_matches(">>").trim().into(), priority: 0 });
            } else if let Some(keyword) = orgize::ast::AffiliatedKeyword::cast(node) {
                if keyword.key().eq_ignore_ascii_case("NAME") {
                    if let Some(value) = keyword.value().filter(|value| !value.trim().is_empty()) {
                        targets.push(DocumentLinkTarget { target: value.trim().into(), priority: 1 });
                    }
                }
            }
        }
    }
    targets
}

// 内部链接键与目的地均由 Core 投影；宿主只匹配当前文档的语义键。
fn internal_target_attributes(targets: &[String], priority: u8) -> String {
    let json = serde_json::to_string(targets).expect("内部链接目标");
    // 目的地是机器可读元数据，避免其文字与正文搜索、链接源码样式混淆。
    let json = json.chars().map(|value| {
        if value.is_ascii() { value.to_string() }
        else { value.encode_utf16(&mut [0; 2]).iter().map(|unit| format!("\\u{unit:04x}")).collect() }
    }).collect::<String>();
    let escaped = HtmlEscape(json).to_string().replace('[', "&#91;").replace(']', "&#93;");
    format!(" data-org-link-targets=\"{escaped}\" data-org-link-priority=\"{priority}\"")
}

fn rendered_link_href(path: &str) -> Option<String> {
    external_link_href(path).or_else(|| {
        if path.is_empty() || path.chars().any(char::is_control)
            || (!path.starts_with(['#', '*']) && (path.contains(':') || path.starts_with(['/', '.', '~']))) {
            return None;
        }
        let encoded = path.bytes().map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) { (byte as char).to_string() }
            else { format!("%{byte:02X}") }
        }).collect::<String>();
        Some(format!("org-internal:{encoded}"))
    })
}

fn external_link_href(path: &str) -> Option<String> {
    if path.chars().any(char::is_control) {
        return None;
    }
    let url = reqwest::Url::parse(path).ok()?;
    match url.scheme() {
        "http" | "https" if url.host_str().is_some() => Some(url.into()),
        "mailto" | "tel" if !url.path().is_empty() => Some(url.into()),
        // Org-mode 使用 RFC 5870 的 geo URI 表示地址；系统地图应用通过
        // viewData Want 接收该 URI。geo URI 没有 host，坐标或查询参数位于 path/query。
        "geo" if !url.path().is_empty() => Some(url.into()),
        // addr 是应用约定的文字地址协议；宿主点击时转换为地图搜索 URI。
        "addr" if !url.path().is_empty() => Some(url.into()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_links_share_title_body_log_and_document_projections_without_changing_bytes() {
        let source = "#+TITLE: http://example.com/file\r\n* TODO *查看 https://example.com/a_b?x=1&y=2* [1/2]\r\n正文 http://example.org/a(b).\r\n- 项目 https://example.com/list\r\n| 表格 | https://example.com/table |\r\n:LOGBOOK:\n- Note taken on [2026-11-13 Fri 09:00] \\\\\n  https://example.com/log\n:END:\n";
        let document = file(source);
        let task = document.nodes().remove(0);
        let title = task.title_parts();
        assert_eq!(title.iter().filter_map(|part| part.href.as_deref()).collect::<Vec<_>>(), ["https://example.com/a_b?x=1&y=2"]);
        assert_eq!(title.iter().filter_map(|part| part.count.as_ref()).count(), 1);
        assert_eq!(document.title_parts()[0].href.as_deref(), Some("http://example.com/file"));
        let content = task.render_content();
        for target in ["http://example.org/a(b)", "https://example.com/list", "https://example.com/table"] {
            assert!(content.body_html.contains(&format!("href=\"{target}\"")), "{}", content.body_html);
        }
        assert!(content.logbook_html.contains("href=\"https://example.com/log\""));
        assert!(content.has_text && content.has_list);
        for html in [document.render_html(), document.render_document_html()] {
            assert!(html.contains("<b>查看 <a class=\"link\""), "{html}");
            assert!(html.contains("?x=1&amp;y=2"));
            assert!(!html.contains("ORGPLAINLINKTOKEN"));
            assert!(html.contains("data-org-start=\""));
        }
        assert_eq!(document.source_bytes(), source.as_bytes());
    }

    #[test]
    fn plain_links_keep_surrounding_formatting_and_literal_org_contexts() {
        let source = "* TODO /阅读 https://example.com/path/\n~https://example.com/verbatim~ =http://example.com/code=\n[[https://example.com/explicit][说明 https://example.com/label]]\n#+begin_src text\nhttps://example.com/source\n#+end_src\n#+begin_example\nhttps://example.com/example\n#+end_example\n<https://example.com/a b>\n";
        let html = file(source).render_html();
        assert!(html.contains("<i>阅读 <a class=\"link\" href=\"https://example.com/path\""), "{html}");
        assert_eq!(html.matches("<a class=\"link\"").count(), 3, "{html}");
        assert!(!html.contains("<a class=\"link\" href=\"http://example.com/code"));
        assert!(html.contains("https://example.com/label</a>"));
        assert!(html.contains("href=\"https://example.com/a%20b\""));
        assert!(!html.contains("ORGPLAINLINKTOKEN"));
    }

    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "notes.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }

    #[test]
    fn document_sections_keep_direct_content_and_exact_node_paths_without_header_metadata() {
        let source = "#+TITLE: 文件标题\r\n#+FILETAGS: :project:work:work:ARCHIVE:\r\n#+PROPERTY: OWNER 文件所有者\r\n前言\r\n| 前言表格 |\r\n| 内容 |\r\n* 普通章节 :REFILE:work:\r\n章节文字\r\n** TODO 重名\r\nSCHEDULED: <2026-11-13 Fri>\r\n:PROPERTIES:\r\n:ID: keep-id\r\n:END:\r\n正文文字\r\n- [ ] 保留清单\r\n| 标题 |\r\n| 数据 |\r\n:LOGBOOK:\r\n- Note taken on [2026-11-13 Fri] 记录\r\n:END:\r\n*** TODO 子任务\r\n子任务文字\r\n** TODO 重名\r\n第二段文字\r\n* 冲突 :CONFLICT:\r\n** TODO 候选\r\n私有候选文字\r\n";
        let file = file(source);
        let sections = file.document_sections();
        assert_eq!(sections.len(), 5);
        assert_eq!(sections[0].path, None);
        assert!(sections[0].html.contains("前言") && sections[0].html.contains("<table>"));
        assert!(!sections[0].html.contains("文件所有者") && !sections[0].html.contains("FILETAGS"));
        assert_eq!(sections[2].path.as_ref().unwrap().occurrence, 1);
        assert_eq!(sections[4].path.as_ref().unwrap().occurrence, 2);
        for section in sections.iter().skip(1) {
            let node = file.nodes().into_iter().find(|node| Some(node.full_path()) == section.path.as_ref());
            assert!(node.is_some(), "正文必须能在同版本节点中定位");
        }
        let body = &sections[2].html;
        for text in ["正文文字", "checkbox-item", "保留清单", "<table>", "数据"] {
            assert!(body.contains(text), "缺少 {text}: {body}");
        }
        for hidden in ["子任务文字", "SCHEDULED", "PROPERTIES", "keep-id", "LOGBOOK", "记录"] {
            assert!(!body.contains(hidden), "正文不应包含 {hidden}: {body}");
        }
        let task = file.nodes().into_iter().find(|node| node.full_path() == sections[2].path.as_ref().unwrap()).unwrap();
        assert!(task.render_content().logbook_html.contains("记录"));
        assert!(!task.render_content().logs.is_empty());
        assert!(file.render_html().contains("keep-id"));
        assert!(!sections.iter().any(|section| section.html.contains("私有候选文字")));
        assert_eq!(file.file_tags(), ["project", "work", "ARCHIVE"]);
        assert_eq!(file.special_tags(), ["project", "REFILE", "ARCHIVE", "CONFLICT", "ATTACH"]);
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn document_sections_include_empty_and_literal_content_without_executing_html() {
        let empty = file("").document_sections();
        assert_eq!(empty, [DocumentSection { path: None, html: String::new(), blocks: Vec::new(), link_targets: Vec::new() }]);
        let sections = file("* TODO 空任务\n** 普通标题\n#+begin_export html\n<script>bad()</script>\n#+end_export\n").document_sections();
        assert!(sections[1].html.trim().is_empty());
        assert!(sections[2].html.contains("&lt;script&gt;"));
        assert!(!sections[2].html.contains("<script>"));
    }

    #[test]
    fn document_body_hides_real_metadata_drawers_but_preserves_literals_and_other_drawers() {
        let source = "#+FILETAGS: :project:\n:LOGBOOK:\n文件日志应隐藏\n:END:\n* TODO 仅元数据\n:PROPERTIES:\n:ID: task-only-metadata\n:END:\n:logbook:\nCLOCK: [2026-11-13 Fri 09:00]--[2026-11-13 Fri 10:00] => 1:00\n:END:\n** 普通标题\n:PROPERTIES:\n:CUSTOM: 隐藏章节属性\n:END:\n:LOGBOOK:\n隐藏章节日志\n:END:\n:NOTES:\n保留其他抽屉\n:END:\n#+begin_src text\n:PROPERTIES:\n:ID: literal-property\n:END:\n:LOGBOOK:\nliteral-logbook\n:END:\n#+end_src\n";
        let file = file(source);
        let sections = file.document_sections();
        assert!(sections[0].html.trim().is_empty());
        assert!(sections[1].html.trim().is_empty());
        let html = &sections[2].html;
        for visible in ["保留其他抽屉", "literal-property", "literal-logbook", ":PROPERTIES:", ":LOGBOOK:"] {
            assert!(html.contains(visible), "缺少 {visible}: {html}");
        }
        for hidden in ["文件日志应隐藏", "隐藏章节属性", "隐藏章节日志", "CLOCK:", "task-only-metadata"] {
            assert!(!sections.iter().any(|section| section.html.contains(hidden)), "正文不应包含 {hidden}");
        }
        let task = file.nodes().into_iter().find(|node| node.full_path() == sections[1].path.as_ref().unwrap()).unwrap();
        assert_eq!(task.render_content().logs.len(), 1);
        assert!(file.render_html().contains("隐藏章节属性"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn document_reading_omits_protected_conflict_material_without_changing_source() {
        let source = "#+FILETAGS: :project:\n前言\n* TODO 当前任务\n正文\n* 同步冲突 :CONFLICT:ARCHIVE:\n** 候选\n:PROPERTIES:\n:CONFILICT_ID: private-id\n:END:\n*** DONE 远端材料\n候选正文\n";
        let file = file(source);
        let html = file.render_document_html();
        assert!(html.contains("当前任务") && html.contains("前言"));
        for hidden in ["同步冲突", "CONFLICT", "CONFILICT_ID", "private-id", "远端材料", "候选正文"] {
            assert!(!html.contains(hidden), "文档阅读不应暴露 {hidden}: {html}");
        }
        assert_eq!(html.matches("<section").count(), html.matches("</section>").count());
        assert!(file.render_html().contains("远端材料"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn complete_document_projects_file_identity_custom_states_and_visible_drawers() {
        let source = "#+TITLE: 文档标题\r\n#+FILETAGS: :project:work:\r\n#+PROJECT_NAME: 项目 <一>\r\n#+PROPERTY: OWNER 张三\r\n#+TODO: TODO INPROGRESS WAIT | DONE CNCL\r\n前言\r\n* 普通章节\r\n完整文字\r\n** INPROGRESS 执行\r\nSCHEDULED: <2026-11-13 Fri>\r\n:PROPERTIES:\r\n:ID: task-one\r\n:END:\r\n| 项目 | 结果 |\r\n|------+------|\r\n| 内容 | 完整 |\r\n:LOGBOOK:\r\n- Note taken on [2026-11-13 Fri]\r\n:END:\r\n*** 普通子章节\r\n子文字\r\n* DONE 完成\r\n* WAIT 等待\r\n";
        let file = file(source);
        let html = file.render_document_html();
        assert_eq!(file.project().as_deref(), Some("项目 <一>"));
        for text in ["项目 &lt;一&gt;", "文档标题", "OWNER</dt><dd>张三", "data-org-state=\"Doing\"", "data-org-state=\"Wait\"", "data-org-state=\"Done\"", "data-org-foldable=\"true\"", "data-org-foldable=\"false\"", "完整文字", "子文字", "<table>", "LOGBOOK", "task-one</dd>"] {
            assert!(html.contains(text), "缺少 {text}: {html}");
        }
        assert!(!html.contains("<details"), "宿主决定折叠，不在语义投影中隐藏任何内容");
        assert_eq!(html.matches("data-org-task=\"true\"").count(), 3);
        assert!(html.find("前言").unwrap() < html.find("普通章节").unwrap());
        assert!(html.find("</span><div class=\"planning\"").is_some());
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn complete_document_preserves_unknown_content_and_escapes_active_metadata() {
        let file = file("#+FILETAGS: :project:\n#+PROJECT_NAME: <img src=x onerror=alert(1)>\n#+PROPERTY: CUSTOM <script>bad()</script>\n#+CUSTOM: preserve\n* TODO 元数据任务\nSCHEDULED: <2026-11-13 Fri>\n#+begin_export html\n<script>bad()</script>\n#+end_export\n");
        let html = file.render_document_html();
        assert!(!html.contains("<img"));
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("CUSTOM</dt><dd>preserve"));
        let only_date = super::tests::file("* TODO 只有日期\nSCHEDULED: <2026-11-13 Fri>\n").render_document_html();
        assert!(only_date.contains("data-org-foldable=\"false\""), "{only_date}");
    }

    #[test]
    fn document_description_ends_before_children_and_does_not_fold_child_only_tasks() {
        let source = "#+FILETAGS: :project:\n* TODO 父任务\n父描述\n** TODO 子任务\n子描述\n** 普通下级章节\n始终可读\n* TODO 只有子任务\nSCHEDULED: <2026-11-13 Fri>\n** TODO 叶子任务\n";
        let file = file(source);
        let html = file.render_document_html();
        assert!(html.contains("<div class=\"heading-body\"><p>父描述\n</p></div><section"), "{html}");
        assert!(html.contains("<div class=\"heading-body\"><p>子描述\n</p></div>"), "{html}");
        let child_only = html.find("只有子任务").unwrap();
        let start = html[..child_only].rfind("<section class=\"heading").unwrap();
        assert!(html[start..child_only].contains("data-org-foldable=\"false\""), "{html}");
        assert_eq!(html.matches("data-org-foldable=\"true\"").count(), 2);
        assert!(html.contains("始终可读"));
        assert!(!html.contains("<details"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn projects_title_links_without_exposing_org_markup_or_changing_source() {
        let source = "#+TITLE: TODO [#A] [[https://example.com/?a=1&b=2][资料 *入口*]] 与 [[mailto:team@example.com]]\n* TODO 阅读 [[https://example.org][课程]] :reading:\n";
        let file = file(source);
        let mut parts = file.title_parts();
        assert!(parts.iter().filter(|part| part.is_link).all(|part| part.link.is_some()));
        for part in &mut parts { part.link = None; }
        assert_eq!(
            parts,
            vec![
                TitlePart {
                    text: "TODO [#A] ".into(),
                    href: None,
                    is_link: false,
                    count: None,
                link: None,
                },
                TitlePart {
                    text: "资料 入口".into(),
                    href: Some("https://example.com/?a=1&b=2".into()),
                    is_link: true,
                    count: None,
                link: None,
                },
                TitlePart {
                    text: " 与 ".into(),
                    href: None,
                    is_link: false,
                    count: None,
                link: None,
                },
                TitlePart {
                    text: "mailto:team@example.com".into(),
                    href: Some("mailto:team@example.com".into()),
                    is_link: true,
                    count: None,
                link: None,
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
        let address = title_parts("[[geo:39.9042,116.4074][北京市]]");
        assert_eq!(address.len(), 1);
        assert_eq!(address[0].text, "北京市");
        assert_eq!(address[0].href.as_deref(), Some("geo:39.9042,116.4074"));
        assert!(address[0].is_link);
        let search_address = title_parts("[[geo:0,0?q=北京市][北京市]]");
        assert_eq!(
            search_address[0].href.as_deref(),
            Some("geo:0,0?q=%E5%8C%97%E4%BA%AC%E5%B8%82")
        );
        assert!(external_link_href("geo:").is_none());
        let named_address = title_parts("[[addr:北京市朝阳区][北京市朝阳区]]");
        assert_eq!(named_address.len(), 1);
        assert_eq!(named_address[0].text, "北京市朝阳区");
        assert_eq!(
            named_address[0].href.as_deref(),
            Some("addr:%E5%8C%97%E4%BA%AC%E5%B8%82%E6%9C%9D%E9%98%B3%E5%8C%BA")
        );
        assert!(named_address[0].is_link);
        assert!(external_link_href("addr:").is_none());
        let address_html = file("* 地址 [[geo:39.9042,116.4074][北京市]]\n").render_html();
        assert!(address_html.contains("<a class=\"link\" href=\"geo:39.9042,116.4074\""));
        assert_eq!(title_parts(""), Vec::new());
        assert_eq!(
            title_parts("=code= ~verbatim~ \\alpha"),
            vec![TitlePart {
                text: "code verbatim α".into(),
                href: None,
                is_link: false,
                count: None,
                link: None,
            }]
        );
    }

    #[test]
    fn projects_fraction_counts_and_preserves_literals_and_unsupported_values() {
        let parts = title_parts(
            "[1/2] 项目 [0/6] [2/2] [/] [0/0] [3/2] [50%] =字面[1/2]= ~[2/2]~ [[https://example.com][链接资料]] [4294967296/4294967296]",
        );
        let counts = parts
            .iter()
            .filter_map(|p| p.count.as_ref())
            .collect::<Vec<_>>();
        assert_eq!(counts.len(), 5, "{parts:#?}");
        assert_eq!(
            counts[0],
            &TitleCount {
                completed: Some(1),
                total: Some(2)
            }
        );
        assert_eq!(
            counts[3],
            &TitleCount {
                completed: None,
                total: None
            }
        );
        assert_eq!(counts[4].total, Some(0));
        let text = parts.iter().map(|p| p.text.as_str()).collect::<String>();
        for literal in [
            "[3/2]",
            "[50%]",
            "字面[1/2]",
            "[2/2]",
            "链接资料",
            "[4294967296/4294967296]",
        ] {
            assert!(text.contains(literal), "{literal}");
        }
        assert!(
            parts
                .iter()
                .filter(|p| p.is_link)
                .all(|p| p.count.is_none())
        );
        let value = serde_json::to_value(&parts).unwrap();
        assert_eq!(value[0]["count"]["completed"], 1);
    }

    #[test]
    fn renders_counts_only_in_headings_with_safe_ring_values_and_original_bytes() {
        let source = "* TODO 项目 [1/2] [2/2] [/] [0/0] [3/2] [50%] =代码[1/2]= [[https://example.com][链接资料]]\r\n正文 [1/2]\r\n";
        let file = file(source);
        let html = file.render_html();
        assert_eq!(html.matches("class=\"title-count ").count(), 4, "{html}");
        assert!(html.contains("--count-turn:0.5turn"));
        assert!(html.contains("--count-turn:1turn"));
        assert!(html.contains("--count-turn:0turn"));
        assert!(html.contains("aria-label=\"已完成 1 项，共 2 项\""));
        assert!(html.contains("正文 [1/2]"));
        assert!(html.contains("[3/2]"));
        assert!(html.contains("[50%]"));
        assert!(html.contains("链接资料</a>"));
        assert_eq!(file.source_bytes(), source.as_bytes());
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
        assert!(!html.contains("#+TBLFM:"));
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
            "checkbox-item",
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
    fn reads_metadata_by_name_and_hides_keyword_declarations_in_reading_view() {
        let source = "#+TITLE: 文件标题\r\n#+FILETAGS: :project:work:\r\n#+project_name: 中文项目\r\n#+CATEGORY: 工作\r\n#+TAGS: work home\r\n#+TODO: NEXT | FINISHED\r\n#+CUSTOM_SETTING: 未知配置\r\n#+CALL: ignored()\r\n前言\r\n* NEXT 任务\r\n#+PROJECT_NAME: 正文配置\r\n正文\r\n| 数值 |\r\n| 1 |\r\n#+TBLFM: $1=1\r\n";
        let file = file(source);
        let metadata = file.metadata(false);
        assert_eq!(metadata.title.as_deref(), Some("文件标题"));
        assert_eq!(metadata.project(), Some("中文项目"));
        assert_eq!(metadata.tag_options, ["work", "home"]);
        assert_eq!(file.category().as_deref(), Some("工作"));
        let html = file.render_html();
        assert!(!html.contains("#+"), "{html}");
        for hidden in ["中文项目", "未知配置", "正文配置", "ignored()"] {
            assert!(!html.contains(hidden), "{html}");
        }
        for visible in ["前言", "正文", "project</span>", "work</span>", "todo pending", "<table>"] {
            assert!(html.contains(visible), "{html}");
        }
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn preserves_keyword_text_when_it_is_literal_content() {
        let source = "#+PROJECT_NAME: 隐藏配置\n#+begin_src org\n#+PROJECT_NAME: 源码示例\n#+end_src\n#+begin_example\n#+PROJECT_NAME: 字面示例\n#+end_example\n正文中的 #+PROJECT_NAME: 普通文字\n";
        let file = file(source);
        let html = file.render_html();
        assert!(!html.contains("隐藏配置"));
        for literal in ["#+PROJECT_NAME: 源码示例", "#+PROJECT_NAME: 字面示例", "正文中的 #+PROJECT<sub>NAME</sub>: 普通文字"] {
            assert!(html.contains(literal), "{html}");
        }
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn property_drawers_show_resolved_values_and_keep_supported_empty_properties() {
        let source = "* Task\r\n:PROPERTIES:\r\n:EMPTY: \r\n:Genres: Classic\r\n:Genres+: Baroque\r\n:END:\r\n";
        let file = file(source);
        let html = file.render_html();
        assert!(html.contains("<dt>EMPTY</dt><dd></dd>"), "{html}");
        assert!(html.contains("<dt>GENRES</dt><dd>Classic Baroque</dd>"), "{html}");
        assert_eq!(html.matches("<dt>GENRES</dt>").count(), 1);
        assert!(!html.contains(":PROPERTIES:"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn ordinary_drawers_render_safe_org_content_and_exclude_metadata_keywords() {
        let source = "* Task\n:NOTES:\n*bold* [[https://example.com][link]]\n- item\n#+PROJECT_NAME: 隐藏配置\n#+begin_src org\n#+PROJECT_NAME: 字面配置\n#+end_src\n[[javascript:alert(1)][脚本]]\n:END:\n";
        let file = file(source);
        let html = file.render_html();
        for expected in ["<summary>NOTES</summary>", "<b>bold</b>", "href=\"https://example.com/\"", "<ul>", "#+PROJECT_NAME: 字面配置", "link unsupported"] {
            assert!(html.contains(expected), "{html}");
        }
        assert!(!html.contains("隐藏配置"));
        assert!(!html.contains("href=\"javascript:"));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[tokio::test]
    async fn keyword_only_task_has_no_readable_body_or_preview() {
        let source = "* TODO Task\n#+PROJECT_NAME: 配置\n#+CUSTOM: 配置\n#+CALL: ignored()\n";
        let mut repo = crate::OrgRepo::new("/unused/keyword-only".into()).unwrap();
        repo.id = "repo".into();
        crate::model::test_support::push_file(&mut repo, file(source));
        let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        let task = workspace.query(&[(crate::TaskQuery::default()).into()]).await.unwrap()
            .remove(0).into_task().unwrap().tasks.remove(0);
        let rendered = task.render_content();
        assert_eq!(rendered.body_html, "");
        assert!(!rendered.has_text);
        assert!(!rendered.has_list);
        assert_eq!(task.body_first_line(), None);
        assert!(task.body.contains("#+PROJECT_NAME:"));
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

    #[tokio::test]
    async fn task_content_extracts_only_real_logbook_drawers() {
        let source = "* TODO Task\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-11-05 Thu 10:00]\nCLOCK: [2026-11-05 Thu 09:00]--[2026-11-05 Thu 10:00] => 1:00\n:END:\n正文 *粗体* [[https://example.com][链接]]\n#+begin_src text\n:LOGBOOK:\n保留代码\n:END:\n#+end_src\n:OTHER:\n其他抽屉\n:END:\n:LOGBOOK:\n- 第二条记录\n:END:\n";
        let file = file(source);
        let mut repo = crate::OrgRepo::new("/tmp/render-only".into()).unwrap();
        repo.id = "repo".into();
        { let value = file; crate::model::test_support::push_file(&mut repo, value); };
        let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        let task = workspace.query(&[(crate::TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks.remove(0);
        let rendered = task.render_content();
        assert!(rendered.body_html.contains("<b>粗体</b>"));
        assert!(rendered.body_html.contains("链接</a>"));
        assert!(rendered.body_html.contains("保留代码"));
        assert!(rendered.body_html.contains("其他抽屉"));
        assert!(!rendered.body_html.contains("CLOCK:"));
        assert!(!rendered.body_html.contains("第二条记录"));
        assert!(rendered.logbook_html.contains("CLOCK:"));
        assert!(rendered.logbook_html.contains("第二条记录"));
        assert_eq!(rendered.logs, task.logs());
        assert_eq!(rendered.logs.len(), 3);
        assert!(matches!(rendered.logs[0], super::super::TaskLog::TaskStateChange { .. }));
        assert!(task.body.contains(":LOGBOOK:"));
        assert_eq!(
            workspace.repos()[0].load_files(&[]).await.unwrap()[0].source_bytes(),
            source.as_bytes()
        );
    }

    #[test]
    fn logbook_only_task_has_empty_rendered_body() {
        let mut view = ReadingView(
            HtmlExport::default(),
            Vec::new(),
            Some(String::new()),
            false,
            false,
            false,
            None,
            false,
        );
        orgize::Org::parse(
            ":LOGBOOK:\nCLOCK: [2026-11-05 Thu 09:00]--[2026-11-05 Thu 10:00] => 1:00\n:END:\n",
        )
        .traverse(&mut view);
        assert!(view.0.finish().is_empty());
        assert!(view.2.unwrap().contains("CLOCK:"));
    }
    #[test]
    fn internal_links_project_semantic_targets_and_leave_literal_sources_untouched() {
        let source = "#+TITLE: [[#custom][目录]]\n前言 [[*章节][标题]] [[目的地]] [[命名元素]]\n* TODO 章节\n:PROPERTIES:\n:CUSTOM_ID: custom\n:END:\n这里 <<目的地>>\n#+NAME: 命名元素\n命名正文\n\n#+begin_src org\n<<伪目标>>\n[[#脚本字面链接]]\n#+end_src\n";
        let document = file(source);
        assert_eq!(document.title_parts()[0].href.as_deref(), Some("org-internal:%23custom"));
        let sections = document.document_sections();
        assert!(sections[1].link_targets.contains(&DocumentLinkTarget { target: "#custom".into(), priority: 2 }));
        assert!(sections[1].link_targets.contains(&DocumentLinkTarget { target: "*章节".into(), priority: 2 }));
        assert!(sections[1].link_targets.contains(&DocumentLinkTarget { target: "目的地".into(), priority: 0 }));
        assert!(sections[1].link_targets.contains(&DocumentLinkTarget { target: "命名元素".into(), priority: 1 }));
        assert!(!sections[1].link_targets.iter().any(|target| target.target == "伪目标"));
        let html = document.render_document_html();
        assert!(html.contains("data-org-link-targets="), "{html}");
        assert!(html.contains("org-internal:%2A"));
        assert!(html.contains("data-org-url="));
        assert!(html.contains("&lt;&lt;伪目标&gt;&gt;"));
        assert_eq!(document.source_bytes(), source.as_bytes());
        for href in ["javascript:alert(1)", "file:other.org", "../other.org", "/secret", "data:text/html,hello"] {
            assert!(rendered_link_href(href).is_none());
        }
    }

}
