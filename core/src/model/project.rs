use super::{OrgFile, OrgFileMetadata};

impl OrgFileMetadata {
    /// 非项目返回 None；未命名的项目保留 Some("")，由宿主提供展示占位。
    pub fn project(&self) -> Option<&str> {
        self.project_name.as_deref()
    }
}

impl OrgFile {
    /// 只读取文件头的有效关键字，不解释标题标签或源码块中的字面文本。
    pub(crate) fn project_name(&self) -> Option<String> {
        let is_project = self.syntax().document().keywords().any(|keyword| {
            keyword.key().eq_ignore_ascii_case("FILETAGS")
                && keyword
                    .value()
                    .split(':')
                    .any(|tag| tag.trim() == "project")
        });
        if !is_project {
            return None;
        }
        let name = self
            .syntax()
            .document()
            .keywords()
            .find(|keyword| keyword.key().eq_ignore_ascii_case("PROPERTY_NAME"))
            .map(|keyword| keyword.value().trim().to_owned());
        Some(name.or_else(|| self.title()).unwrap_or_default())
    }
}
