use std::collections::BTreeMap;

use orgize::rowan::ast::AstNode;

use crate::CoreError;

// 只扫描模板本身；参数值中的占位符保持字面值，不递归解释。
pub(super) fn render(
    template: &str,
    arguments: &BTreeMap<String, String>,
    setup_file: Option<&str>,
) -> Result<String, CoreError> {
    let syntax = orgize::Org::parse(template);
    let mut source = template.to_owned();
    let mut setup_ranges = syntax
        .document()
        .keywords()
        .filter(|keyword| keyword.key().eq_ignore_ascii_case("SETUPFILE"))
        .map(|keyword| {
            let range = keyword.syntax().text_range();
            usize::from(range.start())..usize::from(range.end())
        })
        .collect::<Vec<_>>();
    setup_ranges.sort_by_key(|range| std::cmp::Reverse(range.start));
    for range in setup_ranges {
        let original = &source[range.clone()];
        let ending = if original.ends_with("\r\n") {
            "\r\n"
        } else if original.ends_with('\n') {
            "\n"
        } else {
            ""
        };
        let replacement = setup_file
            .map(|path| format!("#+SETUPFILE: {path}{ending}"))
            .unwrap_or_default();
        source.replace_range(range, &replacement);
    }

    let mut rendered = String::new();
    let mut remaining = source.as_str();
    while let Some(start) = remaining.find("{{") {
        rendered.push_str(&remaining[..start]);
        let placeholder = &remaining[start + 2..];
        let end = placeholder
            .find("}}")
            .ok_or(CoreError::InvalidInput("模板参数缺少结束标记 }}"))?;
        let name = placeholder[..end].trim();
        if name.is_empty() || name.contains(['{', '}', '\r', '\n']) {
            return Err(CoreError::InvalidInput("模板参数名称无效"));
        }
        let value = arguments
            .get(name)
            .ok_or(CoreError::InvalidInput("模板所需参数未全部配置"))?;
        rendered.push_str(value);
        remaining = &placeholder[end + 2..];
    }
    rendered.push_str(remaining);
    Ok(rendered)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_repeated_unicode_fields_without_recursively_expanding_values() {
        let arguments = BTreeMap::from([
            ("项目名".into(), "{{literal}}".into()),
            ("owner".into(), "张三".into()),
        ]);
        assert_eq!(
            render(
                "#+TITLE: {{ 项目名 }}\r\n{{owner}} / {{owner}}\r\n",
                &arguments,
                None
            )
            .unwrap(),
            "#+TITLE: {{literal}}\r\n张三 / 张三\r\n"
        );
        assert!(matches!(
            render("{{missing}}", &arguments, None),
            Err(CoreError::InvalidInput(_))
        ));
        assert!(render("{{broken", &arguments, None).is_err());
        assert!(render("{{ }}", &arguments, None).is_err());
    }

    #[test]
    fn resolves_or_removes_setup_before_scanning_arguments_and_keeps_literal_blocks() {
        let template = "#+TITLE: {{name}}\r\n#+SETUPFILE: {{setup}}\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n";
        let arguments = BTreeMap::from([("name".into(), "项目".into())]);
        assert_eq!(
            render(template, &arguments, Some(".setup.org")).unwrap(),
            "#+TITLE: 项目\r\n#+SETUPFILE: .setup.org\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n"
        );
        assert_eq!(
            render(template, &arguments, None).unwrap(),
            "#+TITLE: 项目\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n"
        );
    }
}
