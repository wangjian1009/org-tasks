//! 统一任务修改数据；执行与提交由 Core 负责，宿主只传结构化参数。
use super::{OrgFile, OrgRepoId, SupportTags, TaskEditContent, TaskPath, TitlePart, TodoStateKind};
use crate::{AddressLink, CoreError, FilterStateType, FilterTask, TimestampMs};
use serde::{Deserialize, Serialize};

/// after 必须是 parent 的直属子节点；为空时插入到首个子节点之前。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskPosition {
    pub parent: TaskPath,
    #[serde(default)]
    pub after: Option<TaskPath>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskOperationGroup {
    pub operations: Vec<TaskOperation>,
    #[serde(default)]
    pub queue_repo_ids: Vec<OrgRepoId>,
    #[serde(default)]
    pub file_versions: Vec<TaskFileVersion>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data", deny_unknown_fields)]
pub enum TaskOperation {
    Creation(TaskCreation),
    Modification(TaskModificationOperation),
    Movement(TaskMovement),
    Deletion(TaskDeletion),
    ConfilictSelection(TaskConfilictSelection),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskFileVersion {
    pub repo_id: OrgRepoId,
    pub file: String,
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskAddressChange {
    pub old_uri: String,
    pub new_uri: String,
}

/// 创建结构独立定义；state 为空创建无状态标题，显式状态按目标文件配置验证。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskCreation {
    pub position: TaskPosition,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub scheduled: Option<String>,
    #[serde(default)]
    pub deadline: Option<String>,
    #[serde(default)]
    pub closed: Option<String>,
    #[serde(default)]
    pub record_created: bool,
}

impl TaskCreation {
    pub fn new(position: TaskPosition, title: String) -> Self {
        Self {
            position,
            title,
            body: String::new(),
            state: None,
            priority: None,
            tags: Vec::new(),
            scheduled: None,
            deadline: None,
            closed: None,
            record_created: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskModificationOperation {
    pub path: TaskPath,
    pub modifications: Vec<TaskModification>,
}

/// 每项只修改一个字段；None 清除值，未列出的字段及其字节保持原样。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "field",
    content = "value",
    rename_all = "SCREAMING_SNAKE_CASE",
    deny_unknown_fields
)]
pub enum TaskModification {
    Title(Option<String>),
    Body(Option<String>),
    Notes(Option<String>),
    Checklist(super::TaskChecklistChange),
    Todo(Option<String>),
    Priority(Option<String>),
    Tags(Option<Vec<String>>),
    Schedule(Option<String>),
    ScheduleDate(Option<String>),
    Deadline(Option<String>),
    DeadlineDate(Option<String>),
    Closed(Option<String>),
    Created(Option<String>),
    AddressLink(Option<TaskAddressChange>),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskMovement {
    pub path: TaskPath,
    pub position: TaskPosition,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskDeletion {
    pub path: TaskPath,
}

/// 冲突选择和普通任务操作共用版本校验、提交、outbox 与回退记录。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskConfilictSelection {
    pub id: String,
    pub action: TaskConfilictAction,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskConfilictAction {
    Discard,
}

/// 保存准确原文而非反向重建语义字段，以便未来按字节恢复。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskFileFallback {
    pub repo_id: OrgRepoId,
    pub file: String,
    pub before: Option<String>,
    pub after: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskFallbackGroup {
    pub files: Vec<TaskFileFallback>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskOperationRecord {
    pub operation_group: TaskOperationGroup,
    pub fallback_group: TaskFallbackGroup,
}

/// workspace 生命周期内的成功操作历史，不与同步历史混用。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskOperationHistory {
    pub entries: Vec<TaskOperationRecord>,
}

/// 可以用旧身份从宿主已有快照中移除节点，再用 after 替换或插入最新节点。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskNodeIdentity {
    pub id: String,
    pub task_id: Option<String>,
    pub full_path: TaskPath,
    pub repo_id: OrgRepoId,
    pub file_path: String,
    pub source_offset: u64,
}

/// 任务操作成功后返回的完整节点投影；字段与宿主 Task 投影保持一致。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskNodeSnapshot {
    pub id: String,
    pub full_path: TaskPath,
    pub task_id: Option<String>,
    pub file_version: String,
    pub repo_id: OrgRepoId,
    pub heading: String,
    pub category: Option<String>,
    pub heading_parts: Vec<TitlePart>,
    pub todo_state: String,
    pub todo_kind: Option<TodoStateKind>,
    pub is_done: bool,
    pub is_cancelled: bool,
    pub created_at: Option<TimestampMs>,
    pub modified_at: Option<TimestampMs>,
    pub priority: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub own_tags: Vec<String>,
    pub inherited_tags: Vec<String>,
    pub support_tags: Option<SupportTags>,
    pub edit_content: TaskEditContent,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub source_offset: u64,
    pub body: String,
    pub body_first_line: Option<String>,
    #[serde(rename = "addressLinks")]
    pub address_links: Vec<AddressLink>,
    pub body_html: String,
    pub logbook_html: String,
    pub progress: i32,
    pub has_list: bool,
    pub has_text: bool,
    pub is_repeating: bool,
}

impl TaskNodeSnapshot {
    pub fn from_filter_task(task: FilterTask, file: &OrgFile) -> Result<Self, CoreError> {
        let path = task.path().to_owned();
        let edit_content = file.task_edit_content(task.full_path())?;
        let content = task.render_content();
        let mut tags = task.own_tags().to_vec();
        for inherited in task.inherited_tags() {
            if !tags.contains(inherited) {
                tags.push(inherited.clone());
            }
        }
        Ok(Self {
            id: task.id().to_owned(),
            full_path: task.full_path().clone(),
            task_id: task.task_id().map(str::to_owned),
            file_version: crate::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            repo_id: task.repo_id().to_owned(),
            heading: task.title().to_owned(),
            category: task.category().map(str::to_owned),
            heading_parts: task.title_parts(),
            todo_state: task.state().unwrap_or_default().to_owned(),
            todo_kind: match task.state_type() {
                FilterStateType::Todo => Some(TodoStateKind::Pending),
                FilterStateType::Done => Some(TodoStateKind::Done),
                FilterStateType::None => None,
            },
            is_done: task.is_done(),
            is_cancelled: task.is_cancelled(),
            created_at: task.created_at(),
            modified_at: task.modified_at(),
            priority: task.priority().unwrap_or_default().to_owned(),
            scheduled: task
                .scheduled()
                .map(|date| date.date().to_string())
                .unwrap_or_default(),
            deadline: task
                .deadline()
                .map(|date| date.date().to_string())
                .unwrap_or_default(),
            tags,
            own_tags: edit_content.own_tags.clone(),
            inherited_tags: task.inherited_tags().to_vec(),
            support_tags: task.support_tags().cloned(),
            edit_content,
            file_path: path.clone(),
            file_name: path.rsplit('/').next().unwrap_or(&path).to_owned(),
            level: task.level(),
            source_offset: task.byte_offset(),
            body: task.body().to_owned(),
            body_first_line: task.body_first_line(),
            address_links: task.address_links().to_vec(),
            body_html: content.body_html,
            logbook_html: content.logbook_html,
            progress: -1,
            has_list: content.has_list,
            has_text: content.has_text,
            is_repeating: task.is_repeating(),
        })
    }

    pub fn identity(&self) -> TaskNodeIdentity {
        TaskNodeIdentity {
            id: self.id.clone(),
            task_id: self.task_id.clone(),
            full_path: self.full_path.clone(),
            repo_id: self.repo_id.clone(),
            file_path: self.file_path.clone(),
            source_offset: self.source_offset,
        }
    }
}

/// before 为空表示新增，after 为空表示删除；两者都有表示替换或移动。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskNodeChange {
    pub operation_index: usize,
    pub request_path: TaskPath,
    pub before: Option<TaskNodeIdentity>,
    pub after: Option<TaskNodeSnapshot>,
}

/// 操作后受影响文件的新版本；用于更新同文件中未直接修改节点的乐观版本。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskFileVersionChange {
    pub repo_id: OrgRepoId,
    pub file: String,
    pub version: String,
}

/// 操作组成功后的节点增量；回退正文仍只保存在 Core 的操作历史中。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskOperationResult {
    pub node_changes: Vec<TaskNodeChange>,
    pub updated_files: Vec<TaskFileVersionChange>,
}
