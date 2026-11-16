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
            .unwrap_or_else(|| format!("#+SETUPFILE:{ending}"));
        source.replace_range(range, &replacement);
    }

    // 仅填充模板中真实属性抽屉的空 ID，参数值与源码中的字面文本不参与生成。
    // orgize 要求空属性冒号后有空格；仅在投影中补齐，由 CST 判断是否为有效属性。
    let mut projection = String::new();
    let mut inserted_spaces = Vec::new();
    for line in source.split_inclusive('\n') {
        let body = line.trim_end_matches(['\r', '\n']);
        if body.trim_start().eq_ignore_ascii_case(":ID:") {
            projection.push_str(body);
            inserted_spaces.push(projection.len());
            projection.push(' ');
            projection.push_str(&line[body.len()..]);
        } else {
            projection.push_str(line);
        }
    }
    let syntax = orgize::Org::parse(&projection);
    let original_offset =
        |offset: usize| offset - inserted_spaces.partition_point(|at| *at < offset);
    let mut ids = syntax
        .document()
        .syntax()
        .descendants()
        .filter_map(orgize::ast::PropertyDrawer::cast)
        .flat_map(|drawer| super::properties::entries(&drawer).collect::<Vec<_>>())
        .filter(|entry| entry.name == "ID" && !entry.append && entry.value.is_empty())
        .map(|entry| {
            original_offset(usize::from(entry.value_range.start()))
                ..original_offset(usize::from(entry.value_range.end()))
        })
        .collect::<Vec<_>>();
    ids.sort_by_key(|range| std::cmp::Reverse(range.start));
    for range in ids {
        let id = super::service::generate_uuid()?;
        let prefix = if source[..range.start].ends_with(':') {
            " "
        } else {
            ""
        };
        source.replace_range(range, &format!("{prefix}{id}"));
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
    fn fills_or_keeps_empty_setup_before_scanning_arguments_and_keeps_literal_blocks() {
        let template = "#+TITLE: {{name}}\r\n#+SETUPFILE:\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n";
        let arguments = BTreeMap::from([("name".into(), "项目".into())]);
        assert_eq!(
            render(template, &arguments, Some(".setup.org")).unwrap(),
            "#+TITLE: 项目\r\n#+SETUPFILE: .setup.org\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n"
        );
        assert_eq!(
            render(template, &arguments, None).unwrap(),
            "#+TITLE: 项目\r\n#+SETUPFILE:\r\n#+begin_src org\r\n#+SETUPFILE: literal.org\r\n#+end_src\r\n* 任务\r\n"
        );
    }

    #[test]
    fn generates_unique_uuids_only_for_empty_id_properties_in_the_template() {
        let template = ":PROPERTIES:\r\n:ID:\r\n:OWNER: 张三\r\n:END:\r\n#+TITLE: {{name}}\r\n* 分组\r\n:PROPERTIES:\r\n:ID:    \r\n:END:\r\n** 保留\r\n:PROPERTIES:\r\n:ID: existing\r\n:CUSTOM_ID: keep\r\n:END:\r\n#+begin_src org\r\n:PROPERTIES:\r\n:ID:\r\n:END:\r\n#+end_src\r\n";
        let arguments = BTreeMap::from([("name".into(), "项目".into())]);
        let first = render(template, &arguments, None).unwrap();
        let second = render(template, &arguments, None).unwrap();
        let ids = |source: &str| -> Vec<String> {
            orgize::Org::parse(source)
                .document()
                .syntax()
                .descendants()
                .filter_map(orgize::ast::PropertyDrawer::cast)
                .flat_map(|drawer| super::super::properties::entries(&drawer).collect::<Vec<_>>())
                .filter(|entry| entry.name == "ID")
                .map(|entry| entry.value)
                .collect()
        };
        let first_ids = ids(&first);
        let second_ids = ids(&second);
        assert_eq!(first_ids.len(), 3, "{first}");
        assert_eq!(first_ids[2], "existing");
        for id in first_ids[..2].iter().chain(&second_ids[..2]) {
            assert!(
                regex::Regex::new(
                    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
                )
                .unwrap()
                .is_match(id)
            );
        }
        assert_ne!(first_ids[0], first_ids[1]);
        assert_ne!(first_ids[0], second_ids[0]);
        assert_ne!(first_ids[1], second_ids[1]);
        assert_eq!(render(&first, &BTreeMap::new(), None).unwrap(), first);
        assert!(first.contains(":OWNER: 张三\r\n"));
        assert!(first.contains(":CUSTOM_ID: keep\r\n"));
        assert!(first.contains("#+begin_src org\r\n:PROPERTIES:\r\n:ID:\r\n:END:\r\n#+end_src"));
        assert!(!first.replace("\r\n", "").contains('\n'));
    }
}
