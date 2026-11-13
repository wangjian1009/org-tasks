use super::{OrgFile, OrgFileMetadata};

impl OrgFileMetadata {
    /// 非项目返回 None；未命名的项目保留 Some("")，由宿主提供展示占位。
    pub fn project(&self) -> Option<&str> {
        self.project_name.as_deref()
    }
}

impl OrgFile {
    /// 返回当前文件快照的项目身份，保留非项目与显式空名称的区别。
    pub fn project(&self) -> Option<String> { self.project_name() }

    /// 只读取文件头的有效关键字，不解释标题标签或源码块中的字面文本。
    pub(crate) fn project_name(&self) -> Option<String> {
        let is_project = self
            .file_keywords
            .values("FILETAGS")
            .any(|value| value.split(':').any(|tag| tag.trim() == "project"));
        if !is_project {
            return None;
        }
        let name = self
            .file_keywords
            .get("PROJECT_NAME")
            .or_else(|| {
                self.file_keywords
                    .properties
                    .get("PROJECT_NAME")
                    .map(String::as_str)
            })
            .map(str::to_owned);
        Some(name.or_else(|| self.title()).unwrap_or_default())
    }
}
