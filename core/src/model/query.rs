use serde::{Deserialize, Serialize};

use crate::filter::FilterTask;
use crate::CoreError;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct TaskQuery {
    pub expression: String,
    pub categories: Vec<Option<String>>,
    pub include_files: Vec<OrgFileRef>,
    pub exclude_files: Vec<OrgFileRef>,
}

/// 精确到仓库与文件的查询范围对象。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrgFileRef {
    pub repo_id: super::OrgRepoId,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskCategory {
    pub key: String,
    pub category: Option<String>,
    pub count: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskQueryResult {
    pub tasks: Vec<FilterTask>,
    pub categories: Vec<TaskCategory>,
}

/// 通用查询共享一次仓库访问，各项结果分别应用自己的文件范围。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum CoreQuery {
    Task {
        query: TaskQuery,
        #[serde(default, rename = "repoIds")]
        repo_ids: Vec<super::OrgRepoId>,
    },
    File {
        query: FileQuery,
    },
    Notification {
        query: NotificationQuery,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct FileQuery {
    pub include_files: Vec<OrgFileRef>,
    pub exclude_files: Vec<OrgFileRef>,
    pub file_tags: Vec<String>,
    pub is_project: Option<bool>,
    pub include_ignored: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NotificationQuery {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreQueryResult {
    Task(TaskQueryResult),
    File(Vec<super::OrgFileMetadata>),
    Notification(Vec<super::CoreNotification>),
}

impl From<TaskQuery> for CoreQuery {
    fn from(query: TaskQuery) -> Self {
        Self::Task {
            query,
            repo_ids: Vec::new(),
        }
    }
}

impl From<&TaskQuery> for CoreQuery {
    fn from(query: &TaskQuery) -> Self {
        query.clone().into()
    }
}

impl CoreQueryResult {
    pub fn into_task(self) -> Result<TaskQueryResult, CoreError> {
        match self {
            Self::Task(result) => Ok(result),
            _ => Err(CoreError::InvalidState("查询结果不是任务结果")),
        }
    }
    pub fn into_files(self) -> Result<Vec<super::OrgFileMetadata>, CoreError> {
        match self {
            Self::File(result) => Ok(result),
            _ => Err(CoreError::InvalidState("查询结果不是文件结果")),
        }
    }
    pub fn into_notifications(self) -> Result<Vec<super::CoreNotification>, CoreError> {
        match self {
            Self::Notification(result) => Ok(result),
            _ => Err(CoreError::InvalidState("查询结果不是通知结果")),
        }
    }
}
