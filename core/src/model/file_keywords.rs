use std::collections::BTreeMap;

/// 文件头关键字的语义值；Org 的 #+、冒号与源节点只留在无损语法树中。
#[derive(Debug)]
pub(super) struct FileKeywords {
    values: BTreeMap<String, Vec<String>>,
    pub(super) properties: BTreeMap<String, String>,
}

impl FileKeywords {
    pub(super) fn parse(syntax: &orgize::Org, setup: &str) -> Self {
        let mut values = BTreeMap::<String, Vec<String>>::new();
        for keyword in syntax.document().keywords() {
            values
                .entry(keyword.key().to_ascii_uppercase())
                .or_default()
                .push(keyword.value().trim().to_owned());
        }
        Self {
            values,
            properties: super::properties::file_properties(syntax, setup),
        }
    }

    pub(super) fn values(&self, name: &str) -> impl Iterator<Item = &str> {
        self.values
            .get(&name.to_ascii_uppercase())
            .into_iter()
            .flatten()
            .map(String::as_str)
    }

    pub(super) fn get(&self, name: &str) -> Option<&str> {
        self.values(name).next()
    }

    /// Org Info 的 Export Settings 规定多行 TITLE 按顺序组成完整标题。
    pub(super) fn title(&self) -> Option<String> {
        let mut values = self.values("TITLE").peekable();
        values.peek()?;
        Some(
            values
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join(" "),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_names_and_values_without_org_keyword_syntax() {
        let source = "  #+project_name:  中文项目  \r\n#+TITLE: 第一行\r\n#+title: 第二行\r\n#+CUSTOM:\r\n#+TAGS: work\r\n#+TAGS: home\r\n#+begin_src org\r\n#+PROJECT_NAME: 源码\r\n#+end_src\r\n* 标题\r\n#+PROJECT_NAME: 标题正文\r\n";
        let syntax = orgize::Org::parse(source);
        let keywords = FileKeywords::parse(&syntax, "");
        assert_eq!(keywords.get("PROJECT_NAME"), Some("中文项目"));
        assert_eq!(keywords.get("project_name"), Some("中文项目"));
        assert_eq!(keywords.get("#+PROJECT_NAME:"), None);
        assert_eq!(keywords.get("CUSTOM"), Some(""));
        assert_eq!(keywords.get("MISSING"), None);
        assert_eq!(keywords.title().as_deref(), Some("第一行 第二行"));
        assert_eq!(
            keywords.values("TAGS").collect::<Vec<_>>(),
            ["work", "home"]
        );
        assert_eq!(syntax.to_org(), source);
    }

    #[test]
    fn rebuilds_semantic_values_after_edit_without_changing_previous_snapshots() {
        use super::super::{OrgFile, OrgFileEdit, SourcePosition, apply_edit};

        let source =
            "#+FILETAGS: :project:\r\n#+PROJECT_NAME: 项目\r\n#+TITLE: 标题\r\n* TODO Task\r\n";
        let mut file = OrgFile::new(
            "repo".into(),
            "project.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap();
        let original = file.clone();
        apply_edit(
            &mut file,
            OrgFileEdit::InsertAt {
                anchor: SourcePosition::new(1, 0, 0).unwrap(),
                content: b"#+PROJECT_NAME: Updated\r\n#+TITLE: New\r\n".to_vec(),
            },
        )
        .unwrap();
        assert_eq!(file.metadata(false).project(), Some("Updated"));
        assert_eq!(file.title().as_deref(), Some("New 标题"));
        assert_eq!(original.metadata(false).project(), Some("项目"));
        assert_eq!(original.title().as_deref(), Some("标题"));
        assert_eq!(
            file.source_bytes(),
            format!("#+PROJECT_NAME: Updated\r\n#+TITLE: New\r\n{source}").as_bytes()
        );
    }
}
