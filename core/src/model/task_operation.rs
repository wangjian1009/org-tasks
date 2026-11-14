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
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskModificationOperation {
    pub path: TaskPath,
    pub modifications: Vec<TaskModification>,
}

/// 完整时间戳输入兼容原接口；结构化编辑由 Core 保真更新原时间戳。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TaskPlanningValue {
    Timestamp(String),
    Edit(TaskPlanningEdit),
}

impl From<String> for TaskPlanningValue {
    fn from(value: String) -> Self { Self::Timestamp(value) }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskPlanningTime {
    pub start: String,
    pub end: Option<String>,
}

/// time 缺省保留原时间，null 清除时间，对象设置具体时刻或同日范围。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskPlanningEdit {
    pub date: String,
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "planning_time_change")]
    pub time: Option<Option<TaskPlanningTime>>,
}

fn planning_time_change<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<Option<TaskPlanningTime>>, D::Error> {
    Option::<TaskPlanningTime>::deserialize(deserializer).map(Some)
}

impl TaskPlanningEdit {
    pub fn date(date: String) -> Self { Self { date, time: None } }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskPlanningInfo {
    pub date: String,
    pub time: Option<TaskPlanningTime>,
}

/// 每项修改指定字段；TODO 统一维护时间、重复调度和日志，其余未涉及的字段及字节保持原样。
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
    Link(super::TaskLinkChange),
    Todo(Option<String>),
    Priority(Option<String>),
    Tags(Option<Vec<String>>),
    Schedule(Option<TaskPlanningValue>),
    ScheduleRepeat(Option<super::TaskRepeatRule>),
    Deadline(Option<TaskPlanningValue>),
    DeadlineRepeat(Option<super::TaskRepeatRule>),
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

/// paths 按用户选择顺序排列，首条保留并改名为“合并: 原标题”。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskMergeRequest {
    pub paths: Vec<TaskPath>,
    pub file_version: String,
}

/// 合并只规划普通删除和修改；调用方通过原批量入口一次提交。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskMergePlan {
    pub operation_group: TaskOperationGroup,
    pub main_path: TaskPath,
}

/// 冲突选择和普通任务操作共用版本校验、提交、outbox 与回退记录。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskConfilictSelection {
    #[serde(default)]
    pub path: Option<TaskPath>,
    pub id: String,
    pub action: TaskConfilictAction,
    #[serde(default)]
    pub target: Option<super::ConflictTarget>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskConfilictAction {
    Discard,
    UseLocal,
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
