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
        if self.repo_id == "<preview>" {
            let id=self.file.as_ref().ok_or(CoreError::InvalidInput("预览路径必须指定创建 UUID"))?;
            if !super::conflict_preview::valid_preview_id(id) { return Err(CoreError::InvalidInput("预览文件必须是创建 UUID")); }
            if self.occurrence==0 || (self.titles.is_empty() && self.occurrence!=1) {return Err(CoreError::InvalidInput("路径出现序号无效"));}
            return Ok(());
        }
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
    pub async fn nodes(&self) -> Result<Vec<crate::FilterTask>, CoreError> {
        let mut nodes = self.load_files(&[]).await?.iter()
            .flat_map(|file| crate::filter::tasks_from_file(self, file)).collect::<Vec<_>>();
        for node in &mut nodes { node.exclude_system_tags(); }
        Ok(nodes)
    }
    pub fn full_path(&self) -> TaskPath {
        TaskPath::repository(self.id.clone())
    }
}

impl OrgFile {
    /// 自身或祖先带有冲突标签的标题均属于受保护的冲突子树。
    pub(crate) fn is_conflict_headline(headline: &Headline) -> bool {
        headline
            .syntax()
            .ancestors()
            .filter_map(Headline::cast)
            .any(|node| node.tags().any(|tag| tag == super::CONFLICT_TAG))
    }

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
                ancestors.push((headline.level(), super::task_identity::path_title(&headline)));
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

#[cfg(test)]
mod tests {
    use super::*;

    fn file(source: &str) -> OrgFile {
        OrgFile::new("repo".into(), "a.org".into(), source.as_bytes().to_vec()).unwrap()
    }

    #[test]
    fn progress_is_excluded_from_all_path_segments_without_rewriting_source() {
        let plain = file("* TODO 项目\n** 无状态分组\n*** TODO 阶段 任务\n").node_paths();
        let source = "* DONE [1/2] 项目 [50%]\r\n** 无状态分组 [/]\r\n*** TODO 阶段 [0/3] 任务 [%]\r\n";
        let updated = file(source);
        assert_eq!(plain, updated.node_paths());
        assert_eq!(updated.source_bytes(), source.as_bytes());
    }

    #[test]
    fn normalized_duplicate_paths_keep_occurrences_and_literal_markup() {
        let file = file("* TODO Task [/]\n* TODO Task [1/2]\n* TODO =[1/2]= Task\n* TODO [[https://example.org][[1/2]]] Task\n* TODO [one/two] Task\n* TODO *[1/2]* Task\n");
        let paths = file.node_paths();
        assert_eq!(paths[0].titles, ["Task"]);
        assert_eq!(paths[1].titles, ["Task"]);
        assert_eq!(paths[0].occurrence, 1);
        assert_eq!(paths[1].occurrence, 2);
        assert_eq!(paths[2].titles, ["=[1/2]= Task"]);
        assert_eq!(paths[3].titles, ["[[https://example.org][[1/2]]] Task"]);
        assert_eq!(paths[4].titles, ["[one/two] Task"]);
        assert_eq!(paths[5].titles, ["*[1/2]* Task"]);
    }
}
