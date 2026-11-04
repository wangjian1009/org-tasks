use std::path::Path;

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use tokio::fs;

use crate::CoreError;

/// 仅用于任务投影的仓库忽略规则，不改变完整文件快照或同步范围。
#[derive(Clone, Debug)]
pub struct TaskScanRules {
    source: String,
    matcher: Gitignore,
}

impl Default for TaskScanRules {
    fn default() -> Self {
        Self {
            source: String::new(),
            matcher: Gitignore::empty(),
        }
    }
}

impl PartialEq for TaskScanRules {
    fn eq(&self, other: &Self) -> bool {
        self.source == other.source
    }
}

impl Eq for TaskScanRules {}

impl TaskScanRules {
    pub fn parse(source: &str) -> Result<Self, CoreError> {
        let mut builder = GitignoreBuilder::new("");
        for (index, line) in source.trim_start_matches('\u{feff}').lines().enumerate() {
            builder.add_line(None, line).map_err(|_| {
                CoreError::Store(format!(".orgzlyignore 第 {} 行规则无效", index + 1))
            })?;
        }
        let matcher = builder
            .build()
            .map_err(|_| CoreError::Store("无法编译 .orgzlyignore 规则".into()))?;
        Ok(Self {
            source: source.into(),
            matcher,
        })
    }

    pub fn excludes(&self, path: &str) -> bool {
        if super::validate_relative_path(path).is_err() {
            return false;
        }
        self.matcher
            .matched_path_or_any_parents(path, false)
            .is_ignore()
    }

    pub(crate) async fn load(root: &Path) -> Result<Self, CoreError> {
        let path = root.join(".orgzlyignore");
        match fs::symlink_metadata(&path).await {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default());
            }
            Err(error) => {
                return Err(CoreError::Store(format!(
                    "无法读取 .orgzlyignore 属性: {error}"
                )));
            }
            Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
                return Err(CoreError::Store(".orgzlyignore 必须是普通文件".into()));
            }
            Ok(_) => {}
        }
        let source = fs::read_to_string(path)
            .await
            .map_err(|error| CoreError::Store(format!("无法读取 .orgzlyignore: {error}")))?;
        Self::parse(&source)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gitignore_rules_match_relative_files_directories_and_exceptions() {
        let rules = TaskScanRules::parse(
            "\u{feff}# 注释\r\n\r\n/root.org\r\n*.private.org\r\narchive/\r\nnotes/**/old?.org\r\n!notes/keep.private.org\r\n\\#literal.org\r\n",
        )
        .unwrap();
        for path in [
            "root.org",
            "secret.private.org",
            "work/secret.private.org",
            "archive/old.org",
            "work/archive/old.org",
            "notes/old1.org",
            "notes/nested/old2.org",
            "#literal.org",
        ] {
            assert!(rules.excludes(path), "{path}");
        }
        for path in [
            "work/root.org",
            "Archive/old.org",
            "archive.org",
            "notes/keep.private.org",
            "notes/old12.org",
            "visible.org",
        ] {
            assert!(!rules.excludes(path), "{path}");
        }
        assert!(!TaskScanRules::default().excludes("visible.org"));
        assert!(!TaskScanRules::parse("").unwrap().excludes("visible.org"));
    }
}
