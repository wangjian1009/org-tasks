//! 仅从 orgize 属性节点取得语义值，统一处理大小写、空值和追加声明。
use orgize::{
    SyntaxKind, TextRange,
    ast::{Headline, Keyword, PropertyDrawer},
    rowan::ast::AstNode,
};
use std::collections::BTreeMap;

pub(crate) struct PropertyEntry {
    pub name: String,
    pub value: String,
    pub append: bool,
    pub value_range: TextRange,
}

pub(crate) fn entries(drawer: &PropertyDrawer) -> impl Iterator<Item = PropertyEntry> {
    drawer.node_properties().filter_map(|property| {
        let mut texts = property
            .syntax()
            .children_with_tokens()
            .filter_map(|element| element.into_token())
            .filter(|token| token.kind() == SyntaxKind::TEXT);
        let name = texts.next()?.text().to_ascii_uppercase();
        let value = texts.next();
        // orgize 会省略空值的 TEXT token；保留节点中的空值与合法插入位置。
        let value_range = value
            .as_ref()
            .map(|token| token.text_range())
            .unwrap_or_else(|| {
                let at = property
                    .syntax()
                    .children_with_tokens()
                    .find(|element| element.kind() == SyntaxKind::NEW_LINE)
                    .map_or(property.end(), |element| element.text_range().start());
                TextRange::empty(at)
            });
        Some(PropertyEntry {
            name,
            value: value.map_or_else(String::new, |token| token.text().trim().to_owned()),
            append: property
                .syntax()
                .children_with_tokens()
                .any(|element| element.kind() == SyntaxKind::PLUS),
            value_range,
        })
    })
}

#[derive(Debug, Default)]
struct PropertyValue {
    base: Option<String>,
    additions: Vec<String>,
}

#[derive(Debug, Default)]
pub(crate) struct Properties {
    values: BTreeMap<String, PropertyValue>,
}

impl Properties {
    pub(crate) fn from_drawer(drawer: &PropertyDrawer) -> Self {
        let mut result = Self::default();
        for entry in entries(drawer) {
            let value = result.values.entry(entry.name).or_default();
            if entry.append {
                value.additions.push(entry.value);
            } else if value.base.is_none() {
                value.base = Some(entry.value);
            }
        }
        result
    }

    pub(crate) fn resolve(&self, name: &str, inherited: Option<&str>) -> Option<String> {
        let Some(value) = self.values.get(&name.to_ascii_uppercase()) else {
            return inherited.map(str::to_owned);
        };
        let mut parts = Vec::new();
        if let Some(base) = value.base.as_deref().or(inherited) {
            if !base.is_empty() {
                parts.push(base);
            }
        }
        parts.extend(
            value
                .additions
                .iter()
                .map(String::as_str)
                .filter(|value| !value.is_empty()),
        );
        Some(parts.join(" "))
    }

    pub(crate) fn get(&self, name: &str) -> Option<String> {
        self.resolve(name, None)
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = (&str, String)> {
        self.values
            .keys()
            .map(|name| (name.as_str(), self.get(name).unwrap()))
    }
}

pub(crate) fn own(headline: &Headline, name: &str) -> Option<String> {
    Properties::from_drawer(&headline.properties()?).get(name)
}

/// SETUPFILE 与 PROPERTY 声明按顺序生效，文件顶层属性 drawer 再覆盖或追加。
pub(crate) fn file_properties(syntax: &orgize::Org, setup: &str) -> BTreeMap<String, String> {
    let setup = orgize::Org::parse(setup);
    let mut values = BTreeMap::<String, String>::new();
    for syntax in [&setup, syntax] {
        for keyword in syntax
            .document()
            .syntax()
            .descendants()
            .filter_map(Keyword::cast)
            .filter(|keyword| keyword.key().eq_ignore_ascii_case("PROPERTY"))
        {
            let declaration = keyword.value();
            let declaration = declaration.trim();
            let (name, value) = declaration
                .split_once(char::is_whitespace)
                .unwrap_or((declaration, ""));
            if name.is_empty() {
                continue;
            }
            let name = name.to_ascii_uppercase();
            let value = value.trim();
            if let Some(name) = name.strip_suffix('+') {
                let existing = values.entry(name.to_owned()).or_default();
                if !existing.is_empty() && !value.is_empty() {
                    existing.push(' ');
                }
                existing.push_str(value);
            } else {
                values.insert(name, value.to_owned());
            }
        }
    }
    if let Some(drawer) = syntax.document().properties() {
        let properties = Properties::from_drawer(&drawer);
        for name in properties.values.keys() {
            let value = properties
                .resolve(name, values.get(name).map(String::as_str))
                .unwrap();
            values.insert(name.clone(), value);
        }
    }
    values
}

pub(crate) fn resolve(
    headline: &Headline,
    name: &str,
    inherited: Option<&str>,
    inherit: bool,
) -> Option<String> {
    let mut value = inherited.map(str::to_owned);
    let mut ancestors = headline
        .syntax()
        .ancestors()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    if !inherit {
        ancestors.truncate(1);
    }
    for node in ancestors.iter().rev() {
        if let Some(drawer) = node.properties() {
            value = Properties::from_drawer(&drawer).resolve(name, value.as_deref());
        }
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_emacs_property_values_and_inheritance() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../../tests/data/properties_emacs.json")).unwrap();
        for case in cases {
            let source = case["source"].as_str().unwrap();
            let name = case["property"].as_str().unwrap();
            let syntax = orgize::Org::parse(source);
            let child = syntax
                .document()
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
                .find(|node| node.title_raw().trim() == "Child")
                .unwrap();
            let defaults = file_properties(&syntax, "");
            assert_eq!(
                serde_json::json!(own(&child, name)),
                case["own"],
                "{source}"
            );
            assert_eq!(
                serde_json::json!(resolve(
                    &child,
                    name,
                    defaults.get(&name.to_ascii_uppercase()).map(String::as_str),
                    true
                )),
                case["inherited"],
                "{source}"
            );
            assert_eq!(syntax.to_org(), source);
        }
    }

    #[test]
    fn preserves_empty_node_values_and_append_flags_without_syntax_markers() {
        let source = "* Child\r\n:properties:\r\n:EMPTY:   \r\n:Genres: Classic\r\n:Genres+: Baroque\r\n:end:\r\n";
        let syntax = orgize::Org::parse(source);
        let drawer = syntax
            .first_node::<Headline>()
            .unwrap()
            .properties()
            .unwrap();
        let entries = entries(&drawer).collect::<Vec<_>>();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].name, "EMPTY");
        assert_eq!(entries[0].value, "");
        assert!(entries[0].value_range.is_empty());
        assert!(entries[2].append);
        assert_eq!(entries[2].name, "GENRES");
        let properties = Properties::from_drawer(&drawer);
        assert_eq!(properties.get("empty"), Some("".into()));
        assert_eq!(properties.get("Genres"), Some("Classic Baroque".into()));
        assert_eq!(properties.get(":GENRES:"), None);
        assert_eq!(syntax.to_org(), source);
    }

    #[test]
    fn file_defaults_apply_setup_then_local_keywords_then_buffer_properties() {
        let syntax = orgize::Org::parse(
            ":PROPERTIES:\n:Genres+: Drawer\n:END:\n#+PROPERTY: Genres+ File\n* Child\n",
        );
        let defaults = file_properties(&syntax, "#+PROPERTY: Genres Setup\n");
        assert_eq!(
            defaults.get("GENRES").map(String::as_str),
            Some("Setup File Drawer")
        );
    }
}
