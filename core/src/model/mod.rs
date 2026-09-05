use crate::{CoreError, TimestampMs};
use serde::{Deserialize, Serialize};

mod edit;
mod service;

pub use edit::*;
pub use service::*;

pub type OrgRepoId = String;
pub type OrgEntryId = String;
pub type OrgRepoSyncRecordId = String;

pub type OrgWorkspaceValidationError = CoreError;
pub type OrgRepoValidationError = CoreError;
pub type OrgFileValidationError = CoreError;
pub type SourcePositionError = CoreError;
pub type SourceRangeError = CoreError;
pub type OrgRepoSyncRecordError = CoreError;
pub type OrgRepoSyncFileRecordError = CoreError;
pub type RemoteFileVersionError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgWorkspace {
    pub repos: Vec<OrgRepo>,
}

impl OrgWorkspace {
    pub fn new(repos: Vec<OrgRepo>) -> Result<Self, OrgWorkspaceValidationError> {
        for (index, repo) in repos.iter().enumerate() {
            validate_id(&repo.id, "仓库 ID 不能为空")?;
            if repos[..index].iter().any(|other| other.id == repo.id) {
                return Err(CoreError::InvalidInput("仓库 ID 必须唯一"));
            }
        }
        Ok(Self { repos })
    }

    pub fn repos(&self) -> &[OrgRepo] {
        &self.repos
    }

    pub fn repo(&self, repo_id: &OrgRepoId) -> Option<&OrgRepo> {
        self.repos.iter().find(|repo| &repo.id == repo_id)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepo {
    pub id: OrgRepoId,
    pub root_directory: String,
    pub files: Vec<OrgFile>,
    pub sync_records: Vec<OrgRepoSyncRecord>,
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
            sync_records: Vec::new(),
        })
    }

    pub fn contains_path(&self, path: &str) -> bool {
        validate_relative_path(path).is_ok()
    }

    pub fn files(&self) -> &[OrgFile] {
        &self.files
    }

    pub fn sync_records(&self) -> &[OrgRepoSyncRecord] {
        &self.sync_records
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgFile {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub source_bytes: Vec<u8>,
    pub entries: Vec<OrgEntry>,
}

impl OrgFile {
    pub fn new(
        repo_id: OrgRepoId,
        path: String,
        source_bytes: Vec<u8>,
        entries: Vec<OrgEntry>,
    ) -> Result<Self, OrgFileValidationError> {
        validate_id(&repo_id, "文件仓库 ID 不能为空")?;
        validate_relative_path(&path)?;
        for entry in &entries {
            validate_entry(entry, &source_bytes, None)?;
        }
        Ok(Self {
            repo_id,
            path,
            source_bytes,
            entries,
        })
    }

    pub fn source_bytes(&self) -> &[u8] {
        &self.source_bytes
    }

    pub fn entries(&self) -> &[OrgEntry] {
        &self.entries
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgEntry {
    pub id: OrgEntryId,
    pub parent_id: Option<OrgEntryId>,
    pub level: u16,
    pub elements: Vec<OrgElement>,
    pub children: Vec<OrgEntry>,
}

impl OrgEntry {
    pub fn id(&self) -> &OrgEntryId {
        &self.id
    }

    pub fn elements(&self) -> &[OrgElement] {
        &self.elements
    }

    pub fn children(&self) -> &[OrgEntry] {
        &self.children
    }

    pub fn find_element(&self, range: &SourceRange) -> Option<&OrgElement> {
        self.elements
            .iter()
            .find(|element| element.source_range == *range)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgElement {
    pub kind: OrgElementKind,
    pub source_range: SourceRange,
}

impl OrgElement {
    pub fn kind(&self) -> &OrgElementKind {
        &self.kind
    }

    pub fn source_range(&self) -> &SourceRange {
        &self.source_range
    }

    pub fn contains(&self, position: &SourcePosition) -> bool {
        self.source_range.contains(position)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgElementKind {
    Title(OrgTitle),
    Scheduled(OrgPlanning),
    Deadline(OrgPlanning),
    Closed(OrgPlanning),
    Property(OrgProperty),
    Timestamp(OrgTimestamp),
    Drawer(OrgDrawer),
    Text(OrgText),
    List(OrgList),
    Link(OrgLink),
    Block(OrgBlock),
    Keyword(OrgKeyword),
    Raw,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgTitle {
    pub text: String,
    pub todo_keyword: Option<String>,
    pub priority: Option<String>,
    pub tags: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgPlanning {
    pub timestamp: OrgTimestamp,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgTimestamp {
    pub active: bool,
    pub start: String,
    pub end: Option<String>,
    pub repeater: Option<String>,
    pub delay: Option<String>,
    pub warning: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgProperty {
    pub key: String,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgDrawer {
    pub name: String,
    pub elements: Vec<OrgElement>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgText {
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgList {
    pub items: Vec<OrgListItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgListItem {
    pub text: String,
    pub children: Vec<OrgListItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgLink {
    pub target: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgBlock {
    pub kind: String,
    pub parameters: String,
    pub content: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgKeyword {
    pub key: String,
    pub value: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourcePosition {
    pub line: u32,
    pub column: u32,
    pub byte_offset: u64,
}

impl SourcePosition {
    pub fn new(line: u32, column: u32, byte_offset: u64) -> Result<Self, SourcePositionError> {
        if line == 0 {
            return Err(CoreError::InvalidInput("源位置行号必须从 1 开始"));
        }
        Ok(Self {
            line,
            column,
            byte_offset,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceRange {
    pub start: SourcePosition,
    pub end: SourcePosition,
}

impl SourceRange {
    pub fn new(start: SourcePosition, end: SourcePosition) -> Result<Self, SourceRangeError> {
        if start.byte_offset > end.byte_offset {
            return Err(CoreError::InvalidInput("源范围起点不能位于终点之后"));
        }
        Ok(Self { start, end })
    }

    pub fn contains(&self, position: &SourcePosition) -> bool {
        self.start.byte_offset <= position.byte_offset
            && position.byte_offset < self.end.byte_offset
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepoSyncRecord {
    pub id: OrgRepoSyncRecordId,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub result: Option<OrgRepoSyncResult>,
    pub files: Vec<OrgRepoSyncFileRecord>,
}

impl OrgRepoSyncRecord {
    pub fn new(
        id: OrgRepoSyncRecordId,
        started_at: TimestampMs,
    ) -> Result<Self, OrgRepoSyncRecordError> {
        validate_id(&id, "同步记录 ID 不能为空")?;
        Ok(Self {
            id,
            started_at,
            finished_at: None,
            result: None,
            files: Vec::new(),
        })
    }

    pub fn append_file(
        &mut self,
        file: OrgRepoSyncFileRecord,
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
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrgRepoSyncResult {
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgRepoSyncFileRecord {
    pub relative_path: String,
    pub action: OrgRepoSyncFileAction,
    pub state: OrgRepoSyncFileState,
    pub local_version: Option<LocalFileVersion>,
    pub remote_version: Option<RemoteFileVersion>,
    pub error: Option<OrgRepoSyncErrorSummary>,
}

impl OrgRepoSyncFileRecord {
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
            remote_version: None,
            error: None,
        })
    }

    pub fn with_versions(
        mut self,
        local: Option<LocalFileVersion>,
        remote: Option<RemoteFileVersion>,
    ) -> Self {
        self.local_version = local;
        self.remote_version = remote;
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

fn validate_entry(
    entry: &OrgEntry,
    source_bytes: &[u8],
    expected_parent_id: Option<&str>,
) -> Result<(), CoreError> {
    validate_id(&entry.id, "条目 ID 不能为空")?;
    if entry.level == 0 {
        return Err(CoreError::InvalidInput("条目层级必须从 1 开始"));
    }
    if entry.parent_id.as_deref() != expected_parent_id {
        return Err(CoreError::InvalidInput("条目父级关系无效"));
    }

    let mut previous_end = 0;
    for element in &entry.elements {
        validate_element(element, source_bytes)?;
        if element.source_range.start.byte_offset < previous_end {
            return Err(CoreError::InvalidInput("同一条目的元素来源范围不能重叠"));
        }
        previous_end = element.source_range.end.byte_offset;
    }
    for child in &entry.children {
        validate_entry(child, source_bytes, Some(&entry.id))?;
    }
    Ok(())
}

fn validate_element(element: &OrgElement, source_bytes: &[u8]) -> Result<(), CoreError> {
    validate_source_range(&element.source_range, source_bytes)?;
    let OrgElementKind::Drawer(drawer) = &element.kind else {
        return Ok(());
    };

    let mut previous_end = element.source_range.start.byte_offset;
    for child in &drawer.elements {
        validate_element(child, source_bytes)?;
        if child.source_range.start.byte_offset < previous_end
            || child.source_range.end.byte_offset > element.source_range.end.byte_offset
        {
            return Err(CoreError::InvalidInput(
                "drawer 子元素必须位于 drawer 来源范围内",
            ));
        }
        previous_end = child.source_range.end.byte_offset;
    }
    Ok(())
}

fn validate_source_range(range: &SourceRange, source_bytes: &[u8]) -> Result<(), CoreError> {
    if range.start.byte_offset > range.end.byte_offset {
        return Err(CoreError::InvalidInput("源范围起点不能位于终点之后"));
    }
    validate_source_position(&range.start, source_bytes)?;
    validate_source_position(&range.end, source_bytes)
}

fn validate_source_position(
    position: &SourcePosition,
    source_bytes: &[u8],
) -> Result<(), CoreError> {
    let source = std::str::from_utf8(source_bytes)
        .map_err(|_| CoreError::InvalidInput("带元素位置的 org 文件必须是 UTF-8 编码"))?;
    let byte_offset = usize::try_from(position.byte_offset)
        .map_err(|_| CoreError::InvalidInput("源位置字节偏移超出文件范围"))?;
    if byte_offset > source_bytes.len() {
        return Err(CoreError::InvalidInput("源位置字节偏移超出文件范围"));
    }
    if !source.is_char_boundary(byte_offset) {
        return Err(CoreError::InvalidInput("源位置不能落在 UTF-8 字符中间"));
    }
    let expected = source_position_at(source_bytes, byte_offset);
    if *position != expected {
        return Err(CoreError::InvalidInput("源位置行号、列号与字节偏移不一致"));
    }
    Ok(())
}

fn source_position_at(source_bytes: &[u8], byte_offset: usize) -> SourcePosition {
    let mut line = 1;
    let mut column = 0;
    for byte in &source_bytes[..byte_offset] {
        if *byte == b'\n' {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    SourcePosition {
        line,
        column,
        byte_offset: byte_offset as u64,
    }
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

    fn position(line: u32, column: u32, byte_offset: u64) -> SourcePosition {
        SourcePosition::new(line, column, byte_offset).expect("位置应有效")
    }

    fn range(start: SourcePosition, end: SourcePosition) -> SourceRange {
        SourceRange::new(start, end).expect("范围应有效")
    }

    fn title(range: SourceRange) -> OrgElement {
        OrgElement {
            kind: OrgElementKind::Title(OrgTitle {
                text: "任务".into(),
                todo_keyword: Some("TODO".into()),
                priority: None,
                tags: vec![],
            }),
            source_range: range,
        }
    }

    #[test]
    fn workspace_rejects_duplicate_repo_ids() {
        let repo = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/data/org".into(),
            files: Vec::new(),
            sync_records: Vec::new(),
        };
        assert!(OrgWorkspace::new(vec![repo.clone(), repo]).is_err());
    }

    #[test]
    fn org_file_validates_element_source_positions() {
        let source_bytes = "* TODO 任务\n".as_bytes().to_vec();
        let entry = OrgEntry {
            id: "entry-1".into(),
            parent_id: None,
            level: 1,
            elements: vec![title(range(position(1, 0, 0), position(1, 13, 13)))],
            children: vec![],
        };
        let file = OrgFile::new(
            "repo-1".into(),
            "inbox.org".into(),
            source_bytes,
            vec![entry],
        )
        .expect("范围应对应源字节");
        assert_eq!(file.source_bytes(), "* TODO 任务\n".as_bytes());

        let invalid_entry = OrgEntry {
            id: "entry-2".into(),
            parent_id: None,
            level: 1,
            elements: vec![title(range(position(1, 0, 0), position(1, 8, 8)))],
            children: vec![],
        };
        assert!(
            OrgFile::new(
                "repo-1".into(),
                "inbox.org".into(),
                "* TODO 任务\n".as_bytes().to_vec(),
                vec![invalid_entry],
            )
            .is_err()
        );
    }

    #[test]
    fn nested_entries_must_reference_their_parent() {
        let child = OrgEntry {
            id: "child".into(),
            parent_id: Some("other".into()),
            level: 2,
            elements: vec![],
            children: vec![],
        };
        let root = OrgEntry {
            id: "root".into(),
            parent_id: None,
            level: 1,
            elements: vec![],
            children: vec![child],
        };
        assert!(
            OrgFile::new("repo-1".into(), "inbox.org".into(), Vec::new(), vec![root],).is_err()
        );
    }

    #[test]
    fn drawer_children_must_stay_within_the_drawer_source_range() {
        let child = OrgElement {
            kind: OrgElementKind::Text(OrgText {
                text: "text".into(),
            }),
            source_range: range(position(2, 0, 7), position(2, 4, 11)),
        };
        let drawer = OrgElement {
            kind: OrgElementKind::Drawer(OrgDrawer {
                name: "META".into(),
                elements: vec![child],
            }),
            source_range: range(position(1, 0, 0), position(2, 0, 7)),
        };
        let entry = OrgEntry {
            id: "entry-1".into(),
            parent_id: None,
            level: 1,
            elements: vec![drawer],
            children: vec![],
        };
        assert!(
            OrgFile::new(
                "repo-1".into(),
                "inbox.org".into(),
                b":META:\ntext\n:END:\n".to_vec(),
                vec![entry],
            )
            .is_err()
        );
    }

    #[test]
    fn sync_record_enforces_terminal_state() {
        let mut record = OrgRepoSyncRecord::new("sync-1".into(), 10).unwrap();
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
        let mut record = OrgRepoSyncRecord::new("sync-1".into(), 10).unwrap();
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
