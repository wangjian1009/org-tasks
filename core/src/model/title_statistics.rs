//! 标题统计统一按 Org Info 的任务分解与 checkbox 规则生成保真编辑。
use super::OrgFile;
use orgize::{
    SyntaxKind,
    ast::{Cookie, Headline, ListItem},
    rowan::ast::AstNode,
};
use std::ops::Range;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Trigger {
    Title,
    Checkbox,
    Todo,
}

fn options(headline: &Headline) -> Option<Vec<String>> {
    headline.properties()?.iter().find_map(|(key, value)| {
        key.eq_ignore_ascii_case("COOKIE_DATA").then(|| {
            value
                .split_whitespace()
                .map(str::to_ascii_lowercase)
                .collect()
        })
    })
}

fn has(options: &[String], word: &str) -> bool {
    options.iter().any(|option| option == word)
}

fn inherited_options(headline: &Headline) -> Option<(Headline, Vec<String>)> {
    headline
        .syntax()
        .ancestors()
        .filter_map(Headline::cast)
        .find_map(|node| options(&node).map(|options| (node, options)))
}

pub(super) fn title_edits(
    file: &OrgFile,
    headline: &Headline,
    trigger: Trigger,
) -> Vec<(Range<usize>, String)> {
    let recursive = if trigger == Trigger::Todo {
        inherited_options(headline).is_some_and(|(_, options)| has(&options, "recursive"))
    } else {
        options(headline).is_some_and(|options| has(&options, "recursive"))
    };
    edits(file, headline, trigger, recursive)
}

fn edits(
    file: &OrgFile,
    headline: &Headline,
    trigger: Trigger,
    recursive: bool,
) -> Vec<(Range<usize>, String)> {
    let options = options(headline).unwrap_or_default();
    // 未指定来源时，checkbox 与 TODO 事件各自更新；标题编辑相当于显式重算。
    if (trigger == Trigger::Checkbox && has(&options, "todo"))
        || (trigger == Trigger::Todo && has(&options, "checkbox"))
    {
        return Vec::new();
    }
    let mut checkbox_completed = 0usize;
    let mut checkbox_total = 0usize;
    let mut has_checkbox = false;
    if let Some(section) = headline.section() {
        for item in section.syntax().descendants().filter_map(ListItem::cast) {
            let Some(checkbox) = item.checkbox() else {
                continue;
            };
            has_checkbox = true;
            if !recursive
                && item
                    .syntax()
                    .ancestors()
                    .skip(1)
                    .any(|node| node.kind() == SyntaxKind::LIST_ITEM)
            {
                continue;
            }
            checkbox_total += 1;
            checkbox_completed += usize::from(matches!(checkbox.as_ref(), "X" | "x"));
        }
    }
    let use_checkbox = match trigger {
        Trigger::Checkbox => true,
        Trigger::Todo => false,
        Trigger::Title => has(&options, "checkbox") || (!has(&options, "todo") && has_checkbox),
    };
    let (completed, total) = if use_checkbox {
        (checkbox_completed, checkbox_total)
    } else {
        let recursive = recursive
            || (trigger == Trigger::Title
                && inherited_options(headline)
                    .is_some_and(|(_, options)| has(&options, "recursive")));
        let mut completed = 0;
        let mut total = 0;
        for child in headline
            .syntax()
            .descendants()
            .skip(1)
            .filter_map(Headline::cast)
        {
            if OrgFile::is_conflict_headline(&child) {
                continue;
            }
            if !recursive
                && child
                    .syntax()
                    .ancestors()
                    .skip(1)
                    .find_map(Headline::cast)
                    .is_none_or(|parent| parent.start() != headline.start())
            {
                continue;
            }
            let Some(state) = child.todo_keyword() else {
                continue;
            };
            let done = file
                .todo
                .done_keywords
                .iter()
                .any(|keyword| keyword == state.as_ref());
            if done
                || file
                    .todo
                    .pending_keywords
                    .iter()
                    .any(|keyword| keyword == state.as_ref())
            {
                total += 1;
                completed += usize::from(done);
            }
        }
        (completed, total)
    };
    headline
        .syntax()
        .children()
        .find(|node| node.kind() == SyntaxKind::HEADLINE_TITLE)
        .into_iter()
        .flat_map(|title| title.descendants().filter_map(Cookie::cast))
        .filter(|cookie| {
            !cookie.syntax().ancestors().skip(1).any(|node| {
                matches!(
                    node.kind(),
                    SyntaxKind::CODE | SyntaxKind::VERBATIM | SyntaxKind::LINK
                )
            })
        })
        .filter_map(|cookie| {
            let raw = cookie.raw();
            let value = if raw.contains('/') {
                format!("[{completed}/{total}]")
            } else if raw.contains('%') {
                format!("[{}%]", completed * 100 / total.max(1))
            } else {
                return None;
            };
            (raw != value).then(|| {
                (
                    u32::from(cookie.start()) as usize..u32::from(cookie.end()) as usize,
                    value,
                )
            })
        })
        .collect()
}

/// TODO 默认更新直属父标题；recursive 继承到最近定义它的祖先为止。
pub(super) fn parent_edits(file: &OrgFile, changed: &Headline) -> Vec<(Range<usize>, String)> {
    let parents = changed
        .syntax()
        .ancestors()
        .skip(1)
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    let Some(parent) = parents.first() else {
        return Vec::new();
    };
    let inherited = inherited_options(parent);
    let recursive = inherited
        .as_ref()
        .is_some_and(|(_, options)| has(options, "recursive"));
    let limit = inherited.as_ref().map(|(owner, _)| owner.start());
    let mut result = Vec::new();
    for (index, parent) in parents.iter().enumerate() {
        if (index > 0 && !recursive) || limit.is_some_and(|limit| parent.start() < limit) {
            break;
        }
        if options(parent).is_some_and(|options| has(&options, "checkbox")) {
            break;
        }
        result.extend(edits(file, parent, Trigger::Todo, recursive));
    }
    result.sort_by_key(|(range, _)| range.start);
    result
}
