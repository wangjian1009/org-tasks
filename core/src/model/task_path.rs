use std::collections::BTreeMap;

use orgize::{ast::Headline, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};

use super::{OrgFile, OrgRepo, OrgRepoId};
use crate::CoreError;

/// 完整结构路径；file 为空表示仓库，titles 为空表示文件，标题链包含无状态祖先。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskPath {
    pub repo_id: OrgRepoId,
    pub file: Option<String>,
    #[serde(default)]
    pub titles: Vec<String>,
    /// 相同完整标题链在文件中的出现次序，从 1 开始。
    #[serde(default = "first_occurrence")]
    pub occurrence: usize,
}

fn first_occurrence() -> usize {
    1
}

impl TaskPath {
    pub fn repository(repo_id: OrgRepoId) -> Self {
        Self {
            repo_id,
            file: None,
            titles: Vec::new(),
            occurrence: 1,
        }
    }

    pub fn file(repo_id: OrgRepoId, file: String) -> Self {
        Self {
            repo_id,
            file: Some(file),
            titles: Vec::new(),
            occurrence: 1,
        }
    }

    pub(crate) fn validate(&self) -> Result<(), CoreError> {
        super::validate_id(&self.repo_id, "仓库 ID 不能为空")?;
        if let Some(file) = &self.file {
            super::validate_relative_path(file)?;
            if !file.ends_with(".org") || file.split('/').any(|part| part == ".sync") {
                return Err(CoreError::InvalidInput(
                    "任务路径必须指向控制目录之外的 Org 文件",
                ));
            }
        } else if !self.titles.is_empty() {
            return Err(CoreError::InvalidInput("标题路径必须指定文件"));
        }
        if self.occurrence == 0 || (self.titles.is_empty() && self.occurrence != 1) {
            return Err(CoreError::InvalidInput("路径出现序号无效"));
        }
        Ok(())
    }
}

impl OrgRepo {
    /// 所有标题节点的投影，不应用任务扫描忽略或查询筛选。
    pub fn nodes(&self) -> Vec<crate::FilterTask> {
        self.files()
            .iter()
            .flat_map(|file| crate::filter::tasks_from_file(self, file))
            .collect()
    }
    pub fn full_path(&self) -> TaskPath {
        TaskPath::repository(self.id.clone())
    }
}

impl OrgFile {
    pub fn full_path(&self) -> TaskPath {
        TaskPath::file(self.repo_id.clone(), self.path.clone())
    }

    /// 完整无损标题树的路径，不受任务查询过滤、系统标签与 TODO 状态影响。
    pub fn node_paths(&self) -> Vec<TaskPath> {
        self.path_headlines()
            .into_iter()
            .map(|(path, _)| path)
            .collect()
    }

    pub(crate) fn path_headlines(&self) -> Vec<(TaskPath, Headline)> {
        let mut ancestors: Vec<(usize, String)> = Vec::new();
        let mut occurrences = BTreeMap::<Vec<String>, usize>::new();
        self.syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .map(|headline| {
                while ancestors
                    .last()
                    .is_some_and(|(level, _)| *level >= headline.level())
                {
                    ancestors.pop();
                }
                ancestors.push((headline.level(), headline.title_raw().trim_end().to_owned()));
                let titles = ancestors
                    .iter()
                    .map(|(_, title)| title.clone())
                    .collect::<Vec<_>>();
                let occurrence = occurrences.entry(titles.clone()).or_default();
                *occurrence += 1;
                (
                    TaskPath {
                        repo_id: self.repo_id.clone(),
                        file: Some(self.path.clone()),
                        titles,
                        occurrence: *occurrence,
                    },
                    headline,
                )
            })
            .collect()
    }
}
