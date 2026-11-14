//! Org 外部裸链接的只读投影；边界依据 Org Info 与 org-link-plain-re。
use orgize::{SyntaxKind, rowan::ast::AstNode};
use regex::Regex;
use std::{ops::Range, sync::OnceLock};

pub(super) struct PlainLink {
    pub range: Range<usize>,
    pub target: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_emacs_plain_and_angle_link_boundaries() {
        let oracle: serde_json::Value = serde_json::from_str(include_str!("../../tests/data/plain_links_emacs.json")).unwrap();
        let mut differences = Vec::new();
        for case in oracle["cases"].as_array().unwrap() {
            let source = case["source"].as_str().unwrap();
            let actual = plain_links(source).iter().map(|link| serde_json::json!({
                "target": link.target, "start": link.range.start, "end": link.range.end,
            })).collect::<Vec<_>>();
            if serde_json::json!(actual) != case["links"] {
                differences.push(format!("{source}: actual={} expected={}", serde_json::json!(actual), case["links"]));
            }
        }
        assert!(differences.is_empty(), "{}", differences.join("\n"));
    }
}

pub(super) fn plain_links(source: &str) -> Vec<PlainLink> {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    static WORD_PREFIX: OnceLock<Regex> = OnceLock::new();
    let word_prefix = WORD_PREFIX.get_or_init(|| Regex::new(r"[\p{Latin}\pN_]$").expect("固定的单词边界表达式"));
    let pattern = PATTERN.get_or_init(|| {
        // Org 的括号组最多嵌套两层；末尾排除标点，但保留斜线、连字符与括号组。
        let atom = r"[^\[\] \t\n()<>]";
        let group = format!(r"[<(\[](?:{atom}|[<(\[]{atom}*[\])>])*[\])>]");
        Regex::new(&format!(
            r"<(?P<angle>https?:[^>\n]*(?:\n[ \t]*[^> \t\n][^>\n]*)*)>|(?P<plain>https?:(?:{atom}|{group})+(?:[^\pP\pS\s]|[-/]|{group}))"
        )).expect("固定的 Org 链接表达式")
    });
    if !pattern.is_match(source) { return Vec::new(); }
    // 前缀保证行内文本不会被识别为标题、列表或配置声明。
    let org = orgize::Org::parse(&format!("x {source}"));
    let protected = org.document().syntax().descendants().filter(|node| matches!(
        node.kind(), SyntaxKind::LINK | SyntaxKind::CODE | SyntaxKind::VERBATIM
            | SyntaxKind::INLINE_SRC | SyntaxKind::INLINE_CALL | SyntaxKind::SNIPPET
            | SyntaxKind::LATEX_FRAGMENT | SyntaxKind::MACROS
    )).map(|node| {
        let range = node.text_range();
        (u32::from(range.start()) as usize).saturating_sub(2)
            ..(u32::from(range.end()) as usize).saturating_sub(2)
    }).collect::<Vec<_>>();
    pattern.captures_iter(source).filter_map(|capture| {
        let matched = capture.get(0)?;
        let mut range = matched.start()..matched.end();
        if protected.iter().any(|literal| literal.start < range.end && range.start < literal.end) {
            return None;
        }
        if capture.name("plain").is_some()
            && word_prefix.is_match(&source[..range.start])
        {
            return None;
        }
        if capture.name("plain").is_some() && source[..range.end].ends_with('/')
            && org.document().syntax().descendants().any(|node| node.kind() == SyntaxKind::ITALIC
                && (u32::from(node.text_range().start()) as usize) < range.start + 2
                && (u32::from(node.text_range().end()) as usize) == range.end + 2)
        {
            range.end -= 1;
        }
        let target = capture.name("angle").map(|angle| angle.as_str()).unwrap_or(&source[range.clone()]);
        Some(PlainLink {
            range,
            target: target.lines().map(str::trim).collect::<String>(),
        })
    }).collect()
}
