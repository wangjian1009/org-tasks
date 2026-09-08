use crate::{CoreError, TimestampMs};
use serde::{Deserialize, Serialize};

mod editor;
mod service;
mod workspace;

pub use editor::*;
pub use service::*;
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
        })
    }

    pub fn contains_path(&self, path: &str) -> bool {
        validate_relative_path(path).is_ok()
    }

    pub fn files(&self) -> &[OrgFile] {
        &self.files
    }
}

#[derive(Debug)]
pub struct OrgFile {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub source_bytes: Vec<u8>,
    syntax: orgize::Org,
}

impl OrgFile {
    pub fn new(
        repo_id: OrgRepoId,
        path: String,
        source_bytes: Vec<u8>,
    ) -> Result<Self, OrgFileValidationError> {
        validate_id(&repo_id, "文件仓库 ID 不能为空")?;
        validate_relative_path(&path)?;
        std::str::from_utf8(&source_bytes)
            .map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8 编码"))?;
        Ok(Self {
            repo_id,
            path,
            syntax: orgize::Org::parse(std::str::from_utf8(&source_bytes).expect("已验证 UTF-8")),
            source_bytes,
        })
    }

    pub fn source_bytes(&self) -> &[u8] {
        &self.source_bytes
    }

    pub fn syntax(&self) -> &orgize::Org {
        &self.syntax
    }

    pub(crate) fn reparse(&mut self) -> Result<(), CoreError> {
        let source = std::str::from_utf8(&self.source_bytes)
            .map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8 编码"))?;
        self.syntax = orgize::Org::parse(source);
        Ok(())
    }
}

impl Clone for OrgFile {
    fn clone(&self) -> Self {
        Self::new(
            self.repo_id.clone(),
            self.path.clone(),
            self.source_bytes.clone(),
        )
        .expect("已加载的 Org 文件必须可重新解析")
    }
}

impl PartialEq for OrgFile {
    fn eq(&self, other: &Self) -> bool {
        self.repo_id == other.repo_id
            && self.path == other.path
            && self.source_bytes == other.source_bytes
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
