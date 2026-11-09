//! 统一任务修改数据；执行与提交由 Core 负责，宿主只传结构化参数。
use super::{OrgRepoId, TaskPath};
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

/// paths 与 operations 一一对应，记录每一步完成后的节点位置；删除为 None。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskOperationResult {
    pub paths: Vec<Option<TaskPath>>,
    pub fallback: TaskFallbackGroup,
}
