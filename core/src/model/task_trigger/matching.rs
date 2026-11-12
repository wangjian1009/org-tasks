//! Org 标签与属性匹配；匹配语法独立于应用页面查询语言。
use super::{Result, error};

pub(super) fn regex(pattern: &str) -> Result<regex::Regex> {
    // Emacs 的分组/或使用反斜线，未转义括号和竖线是字面字符。
    let mut out = String::new();
    let mut chars = pattern.chars().peekable();
    let mut bracket = false;
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('(') => out.push('('),
                Some(')') => out.push(')'),
                Some('|') => out.push('|'),
                Some('`') => out.push_str("\\A"),
                Some('\'') => out.push_str("\\z"),
                Some('<' | '>') => out.push_str("\\b"),
                Some(c) => {
                    out.push('\\');
                    out.push(c);
                }
                None => return Err(error("正则表达式转义未结束")),
            }
        } else {
            if c == '[' {
                bracket = true;
            }
            if !bracket && matches!(c, '(' | ')' | '|') {
                out.push('\\');
            }
            out.push(c);
            if c == ']' {
                bracket = false;
            }
        }
    }
    regex::RegexBuilder::new(&out)
        .case_insensitive(true)
        .build()
        .map_err(|_| error("TRIGGER 正则表达式无效或不受支持"))
}
fn split<'a>(s: &'a str, operators: &[char]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut quoted = false;
    let mut braces = 0;
    let mut escaped = false;
    for (at, c) in s.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if c == '\\' {
            escaped = true;
            continue;
        }
        if c == '"' {
            quoted = !quoted;
        }
        if !quoted {
            if c == '{' {
                braces += 1;
            } else if c == '}' {
                braces -= 1;
            }
            if braces == 0 && operators.contains(&c) {
                out.push(&s[start..at]);
                start = at + c.len_utf8();
            }
        }
    }
    out.push(&s[start..]);
    out
}
pub(super) fn matches(
    spec: &str,
    tags: &[String],
    property: &impl Fn(&str) -> Result<Option<String>>,
) -> Result<bool> {
    let specs = split(spec, &['/']);
    if specs.len() > 2 {
        return Err(error("Org 匹配表达式无效"));
    }
    let mut found = false;
    for part in split(specs[0], &['|']) {
        let mut all = true;
        // 相邻标签以 + 或 - 连接，减号同时是下一项的否定符。
        let mut atoms = Vec::new();
        let mut at = 0;
        let mut quoted = false;
        let mut braces = 0;
        for (i, c) in part.char_indices() {
            if c == '"' {
                quoted = !quoted;
            }
            if !quoted {
                if c == '{' {
                    braces += 1;
                } else if c == '}' {
                    braces -= 1;
                }
                if i > at && braces == 0 && matches!(c, '+' | '-' | '&') {
                    // 属性数字的负号不作为标签分隔符。
                    if c == '-' && part[..i].ends_with(['=', '<', '>']) {
                        continue;
                    }
                    atoms.push(&part[at..i]);
                    at = if c == '-' { i } else { i + 1 };
                }
            }
        }
        atoms.push(&part[at..]);
        for atom in atoms {
            all &= atom_matches(atom.trim(), tags, property)?;
        }
        found |= all;
    }
    if let Some(todo) = specs.get(1) {
        let state = property("TODO")?.unwrap_or_default();
        let todo = todo.trim_start_matches('!');
        let mut yes = false;
        for item in todo.split('|') {
            yes |= text_matches(&state, item)?;
        }
        found &= yes;
    }
    Ok(found)
}
fn atom_matches(
    atom: &str,
    tags: &[String],
    property: &impl Fn(&str) -> Result<Option<String>>,
) -> Result<bool> {
    if atom.is_empty() || atom == "*" {
        return Ok(true);
    }
    let (neg, atom) = if let Some(s) = atom.strip_prefix('-') {
        (true, s)
    } else {
        (false, atom.trim_start_matches('+'))
    };
    let operator = ["<=", ">=", "<>", "!=", "=", "<", ">"]
        .iter()
        .filter_map(|op| atom.find(op).map(|at| (at, *op)))
        .min_by_key(|(at, _)| *at);
    let value = if let Some((at, op)) = operator {
        let key = &atom[..at];
        let expected = atom[at + op.len()..].trim();
        let actual = property(key)?.unwrap_or_default();
        let numeric = !expected.starts_with(['"', '{']);
        let expected = expected.trim_matches('"');
        let order = if numeric {
            actual.parse::<f64>().unwrap_or(0.0).partial_cmp(
                &expected
                    .parse::<f64>()
                    .map_err(|_| error("Org 属性数值比较无效"))?,
            )
        } else {
            Some(actual.as_str().cmp(expected))
        };
        match op {
            "=" => {
                if numeric {
                    order == Some(std::cmp::Ordering::Equal)
                } else {
                    text_matches(&actual, expected)?
                }
            }
            "!=" | "<>" => {
                if numeric {
                    order != Some(std::cmp::Ordering::Equal)
                } else {
                    !text_matches(&actual, expected)?
                }
            }
            "<" => order == Some(std::cmp::Ordering::Less),
            ">" => order == Some(std::cmp::Ordering::Greater),
            "<=" => order.is_some_and(|v| v != std::cmp::Ordering::Greater),
            ">=" => order.is_some_and(|v| v != std::cmp::Ordering::Less),
            _ => false,
        }
    } else {
        let mut found = false;
        for tag in tags {
            found |= text_matches(tag, atom)?;
        }
        found
    };
    Ok(value ^ neg)
}
fn text_matches(value: &str, pattern: &str) -> Result<bool> {
    if let Some(pattern) = pattern.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
        Ok(regex(pattern)?.is_match(value))
    } else {
        Ok(value == pattern)
    }
}
