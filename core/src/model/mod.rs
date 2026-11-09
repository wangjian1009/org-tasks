use crate::{CoreError, TimestampMs};
use orgize::rowan::ast::AstNode;
use serde::{Deserialize, Serialize};

pub(crate) mod write_intent;
mod editor;
mod merge;
mod notification;
pub(crate) mod sync_events;
mod query;
mod refile;
mod render;
pub(crate) mod service;
pub(crate) mod task_identity;
mod task_scan;
mod tags;
mod task_path;
mod task_operation;
mod task_operation_executor;
mod todo;
mod workspace;

pub use write_intent::*;
pub use editor::*;
pub use merge::*;
pub use notification::*;
pub use query::*;
pub use refile::*;
pub use render::*;
pub use service::*;
pub use task_scan::*;
pub use task_path::*;
pub use task_operation::*;
pub use todo::*;
pub use workspace::*;

pub type OrgRepoId = String;
pub type OrgRepoSyncRecordId = String;

pub type OrgRepoValidationError = CoreError;
pub type OrgFileValidationError = CoreError;
pub type OrgRepoSyncRecordError = CoreError;
pub type OrgRepoSyncFileRecordError = CoreError;
pub type RemoteFileVersionError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgRepo {
    pub id: OrgRepoId,
    pub root_directory: String,
    pub files: Vec<OrgFile>,
    pub todo_defaults: TodoConfig,
    pub task_scan_rules: TaskScanRules,
}

/// 文件列表的轻量元信息，不携带正文、语法树或任务投影。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgFileMetadata {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub title: Option<String>,
    pub title_parts: Vec<TitlePart>,
    pub tag_options: Vec<String>,
    pub tag_groups: Vec<Vec<String>>,
    pub is_ignore: bool,
    pub task_count: usize,
    pub byte_length: usize,
    pub modified_at: Option<TimestampMs>,
}

impl OrgRepo {
    pub fn new(root_directory: String) -> Result<Self, OrgRepoValidationError> {
        if root_directory.trim().is_empty() {
            return Err(CoreError::InvalidInput("仓库根目录不能为空"));
        }
        Ok(Self {
            id: String::new(),
            root_directory,
            files: Vec::new(),
            todo_defaults: TodoConfig::default(),
            task_scan_rules: TaskScanRules::default(),
        })
    }

    pub fn set_todo_defaults(&mut self, defaults: TodoConfig) -> Result<(), CoreError> {
        defaults.validate()?;
        let files = self
            .files
            .iter()
            .map(|file| {
                let mut updated = OrgFile::with_todo_defaults_and_setup(
                    file.repo_id.clone(),
                    file.path.clone(),
                    file.source_bytes.clone(),
                    defaults.clone(),
                    file.todo_setup.clone(),
                )?;
                updated.modified_at = file.modified_at;
                Ok(updated)
            })
            .collect::<Result<Vec<_>, _>>()?;
        self.todo_defaults = defaults;
        self.files = files;
        Ok(())
    }

    pub fn contains_path(&self, path: &str) -> bool {
        validate_relative_path(path).is_ok()
    }

    pub fn files(&self) -> &[OrgFile] {
        &self.files
    }

    pub fn file_metadata(&self) -> Vec<OrgFileMetadata> {
        self.files
            .iter()
            .map(|file| OrgFileMetadata {
                repo_id: file.repo_id.clone(),
                path: file.path.clone(),
                title: file.title(),
                title_parts: file.title_parts(),
                tag_options: file.tag_options(),
                tag_groups: file.tag_groups(),
                is_ignore: self.task_scan_rules.excludes(&file.path),
                task_count: if self.task_scan_rules.excludes(&file.path) {
                    0
                } else {
                    file.syntax()
                        .document()
                        .syntax()
                        .descendants()
                        .filter_map(orgize::ast::Headline::cast)
                        .count()
                },
                byte_length: file.source_bytes().len(),
                modified_at: file.modified_at,
            })
            .collect()
    }

    /// 返回当前文件的独立对象；不存在时构造未落盘的空文件供读取默认元信息。
    pub fn file(&self, path: &str) -> Result<OrgFile, CoreError> {
        if !self.contains_path(path) {
            return Err(CoreError::InvalidInput("Org 文件路径无效"));
        }
        match self.files.iter().find(|file| file.path == path) {
            Some(file) => Ok(file.clone()),
            None => self.parse_file(path.into(), Vec::new()),
        }
    }
}

#[derive(Debug)]
pub struct OrgFile {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub source_bytes: Vec<u8>,
    pub todo: TodoMetadata,
    todo_defaults: TodoConfig,
    todo_setup: String,
    pub(crate) modified_at: Option<TimestampMs>,
    syntax: orgize::Org,
}

impl OrgFile {
    pub fn new(
        repo_id: OrgRepoId,
        path: String,
        source_bytes: Vec<u8>,
    ) -> Result<Self, OrgFileValidationError> {
        Self::with_todo_defaults(repo_id, path, source_bytes, TodoConfig::default())
    }

    pub fn with_todo_defaults(
        repo_id: OrgRepoId,
        path: String,
        source_bytes: Vec<u8>,
        defaults: TodoConfig,
    ) -> Result<Self, OrgFileValidationError> {
        Self::with_todo_defaults_and_setup(repo_id, path, source_bytes, defaults, String::new())
    }

    pub(crate) fn with_todo_defaults_and_setup(
        repo_id: OrgRepoId,
        path: String,
        source_bytes: Vec<u8>,
        defaults: TodoConfig,
        todo_setup: String,
    ) -> Result<Self, OrgFileValidationError> {
        validate_id(&repo_id, "文件仓库 ID 不能为空")?;
        validate_relative_path(&path)?;
        defaults.validate()?;
        let source = std::str::from_utf8(&source_bytes)
            .map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8 编码"))?;
        let (todo, syntax) = TodoMetadata::parse_with_setup(source, &defaults, &todo_setup)?;
        Ok(Self {
            repo_id,
            path,
            source_bytes,
            todo,
            todo_defaults: defaults,
            todo_setup,
            modified_at: None,
            syntax,
        })
    }

    pub fn source_bytes(&self) -> &[u8] {
        &self.source_bytes
    }

    /// 读取文件头的 CATEGORY 声明；未声明时为空，不使用文件名兜底。
    pub fn category(&self) -> Option<String> {
        let category = self
            .syntax
            .document()
            .keywords()
            .find(|keyword| keyword.key().eq_ignore_ascii_case("CATEGORY"))
            .map(|keyword| keyword.value().trim().to_owned());
        category.filter(|value| !value.eq_ignore_ascii_case("ARCHIVE"))
    }

    /// 复用已有语法树，仅遍历文件头关键字，找到第一条 TITLE 即返回。
    pub fn title(&self) -> Option<String> {
        self.syntax
            .document()
            .keywords()
            .find(|keyword| keyword.key().eq_ignore_ascii_case("TITLE"))
            .map(|keyword| keyword.value().trim().to_owned())
    }

    pub fn syntax(&self) -> &orgize::Org {
        &self.syntax
    }

    pub(crate) fn reparse(&mut self) -> Result<(), CoreError> {
        let source = std::str::from_utf8(&self.source_bytes)
            .map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8 编码"))?;
        let (todo, syntax) =
            TodoMetadata::parse_with_setup(source, &self.todo_defaults, &self.todo_setup)?;
        self.todo = todo;
        self.syntax = syntax;
        Ok(())
    }
}

impl Clone for OrgFile {
    fn clone(&self) -> Self {
        let mut file = Self::with_todo_defaults_and_setup(
            self.repo_id.clone(),
            self.path.clone(),
            self.source_bytes.clone(),
            self.todo_defaults.clone(),
            self.todo_setup.clone(),
        )
        .expect("已加载的 Org 文件必须可重新解析");
        file.modified_at = self.modified_at;
        file
    }
}

impl PartialEq for OrgFile {
    fn eq(&self, other: &Self) -> bool {
        self.repo_id == other.repo_id
            && self.path == other.path
            && self.source_bytes == other.source_bytes
            && self.todo_defaults == other.todo_defaults
            && self.todo == other.todo
    }
}

impl Eq for OrgFile {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepoSyncRecord<C = serde_json::Value, F = serde_json::Value> {
    pub id: OrgRepoSyncRecordId,
    pub kind: String,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub result: Option<OrgRepoSyncResult>,
    pub context_detail: C,
    pub files: Vec<OrgRepoSyncFileRecord<F>>,
}

impl<C: Default, F: Default> OrgRepoSyncRecord<C, F> {
    pub fn new(
        id: OrgRepoSyncRecordId,
        started_at: TimestampMs,
    ) -> Result<Self, OrgRepoSyncRecordError> {
        validate_id(&id, "同步记录 ID 不能为空")?;
        Ok(Self {
            id,
            kind: String::new(),
            started_at,
            finished_at: None,
            result: None,
            context_detail: C::default(),
            files: Vec::new(),
        })
    }

    pub fn with_kind(mut self, kind: impl Into<String>) -> Self {
        self.kind = kind.into();
        self
    }

    pub fn append_file(
        &mut self,
        file: OrgRepoSyncFileRecord<F>,
    ) -> Result<(), OrgRepoSyncRecordError> {
        if self.finished_at.is_some() {
            return Err(CoreError::InvalidState("已完成的同步记录不能追加文件结果"));
        }
        self.files.push(file);
        Ok(())
    }

    pub fn finish(
        &mut self,
        result: OrgRepoSyncResult,
        finished_at: TimestampMs,
    ) -> Result<(), OrgRepoSyncRecordError> {
        if self.finished_at.is_some() {
            return Err(CoreError::InvalidState("同步记录只能完成一次"));
        }
        if finished_at < self.started_at {
            return Err(CoreError::InvalidInput("同步完成时间不能早于开始时间"));
        }
        self.finished_at = Some(finished_at);
        self.result = Some(result);
        Ok(())
    }

    pub fn with_context_detail(mut self, detail: C) -> Self {
        self.context_detail = detail;
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgRepoSyncResult {
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepoSyncFileRecord<F = serde_json::Value> {
    pub relative_path: String,
    pub action: OrgRepoSyncFileAction,
    pub state: OrgRepoSyncFileState,
    pub local_version: Option<LocalFileVersion>,
    pub detail: F,
    pub error: Option<OrgRepoSyncErrorSummary>,
}

impl<F: Default> OrgRepoSyncFileRecord<F> {
    pub fn new(
        relative_path: String,
        action: OrgRepoSyncFileAction,
        state: OrgRepoSyncFileState,
    ) -> Result<Self, OrgRepoSyncFileRecordError> {
        validate_relative_path(&relative_path)?;
        Ok(Self {
            relative_path,
            action,
            state,
            local_version: None,
            detail: F::default(),
            error: None,
        })
    }

    pub fn with_local_version(mut self, local: Option<LocalFileVersion>) -> Self {
        self.local_version = local;
        self
    }

    pub fn with_detail(mut self, detail: F) -> Self {
        self.detail = detail;
        self
    }

    pub fn with_error(mut self, error: OrgRepoSyncErrorSummary) -> Self {
        self.error = Some(error);
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgRepoSyncFileAction {
    Unchanged,
    Downloaded,
    Uploaded,
    Created,
    Deleted,
    Conflicted,
    Skipped,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgRepoSyncFileState {
    Synchronized,
    LocalChanged,
    RemoteChanged,
    RemoteDeleted,
    Conflict,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalFileVersion {
    pub content_hash: String,
}

impl LocalFileVersion {
    pub fn new(content_hash: String) -> Result<Self, CoreError> {
        validate_id(&content_hash, "本地文件内容哈希不能为空")?;
        Ok(Self { content_hash })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteFileVersion {
    pub etag: Option<String>,
    pub modified_at: Option<TimestampMs>,
    pub size: Option<i64>,
}

impl RemoteFileVersion {
    pub fn new(
        etag: Option<String>,
        modified_at: Option<TimestampMs>,
        size: Option<i64>,
    ) -> Result<Self, RemoteFileVersionError> {
        if etag.as_deref().is_some_and(str::is_empty) {
            return Err(CoreError::InvalidInput("远端 ETag 不能为空字符串"));
        }
        if size.is_some_and(|value| value < 0) {
            return Err(CoreError::InvalidInput("远端文件大小不能为负数"));
        }
        Ok(Self {
            etag,
            modified_at,
            size,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepoSyncErrorSummary {
    pub category: OrgRepoSyncErrorCategory,
    pub retryable: bool,
    pub message: String,
}

impl OrgRepoSyncErrorSummary {
    pub fn new(
        category: OrgRepoSyncErrorCategory,
        retryable: bool,
        message: String,
    ) -> Result<Self, CoreError> {
        validate_id(&message, "同步错误摘要不能为空")?;
        Ok(Self {
            category,
            retryable,
            message,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgRepoSyncErrorCategory {
    Network,
    Authentication,
    Tls,
    Validation,
    LocalStorage,
    Conflict,
}

fn validate_id(value: &str, message: &'static str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        return Err(CoreError::InvalidInput(message));
    }
    Ok(())
}

fn validate_relative_path(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty()
        || value.starts_with('/')
        || value.contains('\\')
        || value
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(CoreError::InvalidInput("文件路径必须是安全的相对路径"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_rejects_duplicate_repo_ids() {
        let repo = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/data/org".into(),
            todo_defaults: TodoConfig::default(),
            task_scan_rules: Default::default(),
            files: Vec::new(),
        };
        assert!(OrgWorkspace::new(vec![repo.clone(), repo]).is_err());
    }

    #[test]
    fn org_file_is_lossless_for_valid_utf8() {
        let source_bytes = "* TODO 任务\n".as_bytes().to_vec();
        let file = OrgFile::new("repo-1".into(), "inbox.org".into(), source_bytes)
            .expect("UTF-8 Org 文件应可解析");
        assert_eq!(file.source_bytes(), "* TODO 任务\n".as_bytes());
        assert_eq!(file.syntax().to_org().as_bytes(), file.source_bytes());
        assert!(OrgFile::new("repo-1".into(), "inbox.org".into(), vec![0xff]).is_err());
    }

    #[test]
    fn category_reads_only_real_keywords_in_file_header() {
        for (source, expected) in [
            ("", None),
            ("#+TITLE: 没有分类\n* TODO Task\n", None),
            ("#+CATEGORY: 家庭事务\r\n* TODO Task\r\n", Some("家庭事务")),
            (
                "  #+category:  Work Projects  \n* Task\n",
                Some("Work Projects"),
            ),
            ("#+CATEGORY:\n* Task\n", Some("")),
            ("#+CATEGORY: First\n#+CATEGORY: Second\n", Some("First")),
            ("#+CATEGORY: ARCHIVE\n* Task\n", None),
            ("#+CATEGORY: archive\n* Task\n", None),
            ("#+CATEGORY: \n#+CATEGORY: Second\n", Some("")),
            ("* Task\n#+CATEGORY: Heading category\n", None),
            ("* Task\n:PROPERTIES:\n:CATEGORY: Property\n:END:\n", None),
            ("#+begin_src org\n#+CATEGORY: Hidden\n#+end_src\n", None),
            ("#+begin_example\n#+CATEGORY: Hidden\n#+end_example\n", None),
            ("# #+CATEGORY: Comment\n", None),
            (
                ":PROPERTIES:\n:ID: header-id\n:END:\n#+CATEGORY: File\n* Task\n",
                Some("File"),
            ),
        ] {
            let file = OrgFile::new(
                "repo".into(),
                "inbox.org".into(),
                source.as_bytes().to_vec(),
            )
            .unwrap();
            assert_eq!(file.category().as_deref(), expected, "{source}");
            assert_eq!(serialize_file(&file), source.as_bytes());
        }
    }

    #[test]
    fn file_title_and_lightweight_metadata_follow_header_syntax_without_source_copy() {
        for (source, expected) in [
            ("", None),
            ("#+TITLE: 工作计划\r\n* Task\r\n", Some("工作计划")),
            ("  #+title:  Work Plan  \n", Some("Work Plan")),
            ("#+TITLE:\n* Task\n", Some("")),
            ("#+TITLE: First\n#+TITLE: Second\n", Some("First")),
            ("* Task\n#+TITLE: Heading section\n", None),
            ("#+begin_src org\n#+TITLE: Hidden\n#+end_src\n", None),
            ("#+begin_example\n#+TITLE: Hidden\n#+end_example\n", None),
            ("# #+TITLE: Comment\n", None),
        ] {
            let file =
                OrgFile::new("repo".into(), "work.org".into(), source.as_bytes().to_vec()).unwrap();
            assert_eq!(file.title().as_deref(), expected);
            let mut repo = OrgRepo::new("/unused".into()).unwrap();
            repo.files.push(file);
            let metadata = repo.file_metadata();
            assert_eq!(metadata[0].title.as_deref(), expected);
            assert_eq!(metadata[0].path, "work.org");
            assert_eq!(repo.files[0].source_bytes(), source.as_bytes());
            let value = serde_json::to_value(&metadata[0]).unwrap();
            assert_eq!(value.as_object().unwrap().len(), 10);
            assert_eq!(value["tagOptions"], serde_json::json!([]));
            assert_eq!(value["tagGroups"], serde_json::json!([]));
            assert_eq!(
                value["titleParts"],
                serde_json::to_value(&metadata[0].title_parts).unwrap()
            );
            assert!(value.get("source").is_none());
        }
        let file = OrgFile::new(
            "repo".into(),
            "later.org".into(),
            format!(
                "{}#+TITLE: Later header title\n* Task\n",
                "# comment\n".repeat(100)
            )
            .into_bytes(),
        )
        .unwrap();
        assert_eq!(file.title().as_deref(), Some("Later header title"));
    }

    #[test]
    fn category_tracks_edits_without_rewriting_unrelated_bytes() {
        let source = "#+CATEGORY: Old\r\n* TODO Task\r\n  body  \r\n";
        let mut file = OrgFile::new(
            "repo".into(),
            "inbox.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap();
        apply_edit(
            &mut file,
            OrgFileEdit::ReplaceRange {
                target: SourceRange::new(
                    SourcePosition::new(1, 12, 12).unwrap(),
                    SourcePosition::new(1, 15, 15).unwrap(),
                )
                .unwrap(),
                content: b"New".to_vec(),
            },
        )
        .unwrap();
        assert_eq!(file.category().as_deref(), Some("New"));
        assert_eq!(file.clone().category(), file.category());
        assert_eq!(
            serialize_file(&file),
            source.replace("Old", "New").as_bytes()
        );
    }

    #[test]
    fn repository_file_objects_preserve_values_and_support_unsaved_targets() {
        let mut repo = OrgRepo::new("/unused".into()).unwrap();
        assert!(repo.file("new.org").is_err());
        repo.id = "repo".into();
        repo.set_todo_defaults(TodoConfig::from_settings("#+TODO: NEXT | CLOSED").unwrap())
            .unwrap();
        repo.files.push(
            OrgFile::new(
                "repo".into(),
                "work.org".into(),
                b"#+CATEGORY: Work\n".to_vec(),
            )
            .unwrap(),
        );
        let file = repo.file("work.org").unwrap();
        repo.files.clear();
        assert_eq!(file.category().as_deref(), Some("Work"));
        let draft = repo.file("new.org").unwrap();
        assert_eq!(draft.repo_id, "repo");
        assert_eq!(draft.path, "new.org");
        assert!(draft.source_bytes().is_empty());
        assert_eq!(draft.todo.initial_state.as_deref(), Some("NEXT"));
        assert!(draft.category().is_none());
        assert!(repo.files().is_empty());
        assert!(repo.file("../work.org").is_err());
    }

    #[test]
    fn sync_record_enforces_terminal_state() {
        let mut record =
            OrgRepoSyncRecord::<serde_json::Value, serde_json::Value>::new("sync-1".into(), 10)
                .unwrap();
        let file = OrgRepoSyncFileRecord::new(
            "inbox.org".into(),
            OrgRepoSyncFileAction::Uploaded,
            OrgRepoSyncFileState::Synchronized,
        )
        .unwrap();
        assert!(record.append_file(file).is_ok());

        record.finish(OrgRepoSyncResult::Succeeded, 11).unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert!(record.finish(OrgRepoSyncResult::Failed, 12).is_err());
    }

    #[test]
    fn sync_record_json_does_not_repeat_repository_identity() {
        let mut record =
            OrgRepoSyncRecord::<serde_json::Value, serde_json::Value>::new("sync-1".into(), 10)
                .unwrap();
        record
            .append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Uploaded,
                    OrgRepoSyncFileState::Synchronized,
                )
                .unwrap(),
            )
            .unwrap();
        record.finish(OrgRepoSyncResult::Succeeded, 11).unwrap();

        let value = serde_json::to_value(record).unwrap();
        assert!(value.get("repo_id").is_none());
        assert!(value["files"][0].get("repo_id").is_none());
    }

    #[test]
    fn remote_version_is_validated() {
        assert!(RemoteFileVersion::new(None, None, Some(-1)).is_err());
        assert!(RemoteFileVersion::new(Some(String::new()), None, None).is_err());
    }
}

#[cfg(test)]
pub(crate) mod test_support;
