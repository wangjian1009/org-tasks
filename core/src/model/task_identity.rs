use std::collections::BTreeMap;

use orgize::{SyntaxKind, ast::Headline};

/// 任务身份独立于源位置；无状态祖先不参与路径，自身标题始终保留。
pub(crate) struct TaskIdentity<'a> {
    root: &'a str,
    path: &'a str,
    ancestors: Vec<(usize, String)>,
    occurrences: BTreeMap<Vec<String>, u64>,
}

impl<'a> TaskIdentity<'a> {
    pub(crate) fn new(root: &'a str, path: &'a str) -> Self {
        Self {
            root,
            path,
            ancestors: Vec::new(),
            occurrences: BTreeMap::new(),
        }
    }

    pub(crate) fn id_for(&mut self, headline: &Headline, is_task: bool) -> String {
        let level = headline.level();
        while self
            .ancestors
            .last()
            .is_some_and(|(ancestor, _)| *ancestor >= level)
        {
            self.ancestors.pop();
        }
        let title = identity_title(headline);
        let mut titles = self
            .ancestors
            .iter()
            .map(|(_, title)| title.clone())
            .collect::<Vec<_>>();
        titles.push(title.clone());
        if is_task {
            self.ancestors.push((level, title));
        }
        let occurrence = self.occurrences.entry(titles.clone()).or_default();
        *occurrence += 1;
        // JSON 保留路径分段边界，避免标题中的点号被误当作层级分隔符。
        let input = if *occurrence == 1 {
            serde_json::to_string(&(self.root, self.path, &titles))
        } else {
            serde_json::to_string(&(self.root, self.path, &titles, *occurrence))
        }
        .expect("字符串路径与出现序号可以序列化");
        input
    }
}

fn identity_title(headline: &Headline) -> String {
    let parts = headline.title().collect::<Vec<_>>();
    let is_edge = |index: usize| {
        let part = &parts[index];
        part.kind() == SyntaxKind::COOKIE || part.to_string().trim().is_empty()
    };
    let mut start = 0;
    let mut end = parts.len();
    while start < end && is_edge(start) {
        start += 1;
    }
    while start < end && is_edge(end - 1) {
        end -= 1;
    }
    parts[start..end]
        .iter()
        .map(ToString::to_string)
        .collect::<String>()
        .trim()
        .to_owned()
}

/// 完整结构路径与同步匹配共用；只排除标题直属的进度节点，不改写源文本。
pub(crate) fn path_title(headline: &Headline) -> String {
    let mut output = String::new();
    let mut removed_cookie = false;
    let mut separator = false;
    for part in headline.title() {
        if part.kind() == SyntaxKind::COOKIE {
            removed_cookie = true;
            let trimmed = output.trim_end_matches([' ', '\t']).len();
            separator |= trimmed < output.len();
            output.truncate(trimmed);
            continue;
        }
        let text = part.to_string();
        if removed_cookie {
            let trimmed = text.trim_start_matches([' ', '\t']);
            separator |= trimmed.len() < text.len();
            if trimmed.is_empty() {
                continue;
            }
            if separator && !output.is_empty() {
                output.push(' ');
            }
            output.push_str(trimmed);
            removed_cookie = false;
            separator = false;
        } else {
            output.push_str(&text);
        }
    }
    output.trim_end().to_owned()
}

/// 规范化一个已经从标题行切出的标题片段，用于同步字段合并。
pub(crate) fn normalized_title_text(title: &str) -> String {
    let parsed = orgize::Org::parse(&format!("* {title}\n"));
    parsed
        .first_node::<Headline>()
        .map(|headline| path_title(&headline))
        .unwrap_or_else(|| title.trim().to_owned())
}
