use serde::{Deserialize, Serialize};

use super::{
    LocalFileVersion, OrgFileRef, OrgRepo, OrgRepoId, OrgWorkspace, SourcePosition,
    editor::position_at,
};

pub(crate) const REFILE_TAG: &str = "REFILE";
pub(crate) const ARCHIVE_TAG: &str = "ARCHIVE";
pub(crate) const CONFLICT_TAG: &str = "CONFLICT";

/// 文件范围在遍历目标与读取 CATEGORY 前求值。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct RefileTargetQuery {
    pub files: Vec<OrgFileRef>,
    pub excluded_files: Vec<OrgFileRef>,
}

impl RefileTargetQuery {
    fn includes(&self, repo_id: &str, path: &str) -> bool {
        (self.files.is_empty()
            || self
                .files
                .iter()
                .any(|file| file.repo_id == repo_id && file.path == path))
            && !self
                .excluded_files
                .iter()
                .any(|file| file.repo_id == repo_id && file.path == path)
    }
}

/// 当前文件快照中显式标记为可放置任务的标题，不是持久化实体。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefileTarget {
    pub repo_id: OrgRepoId,
    pub full_path: super::TaskPath,
    pub path: String,
    /// 包含所有祖先及目标自身，不包含 TODO、优先级和标签。
    pub heading_path: Vec<String>,
    /// 同名同路径的标题仍以当前快照的源位置区分。
    pub position: SourcePosition,
    pub category: Option<String>,
    /// 与文件元信息使用相同的项目识别；空字符串表示未命名项目。
    pub project_name: Option<String>,
    pub file_version: String,
}

impl RefileTarget {
    /// 仓库使用稳定 ID；宿主可根据 repo_id 替换为配置中的显示名。
    pub fn display_path(&self) -> String {
        std::iter::once(self.repo_id.as_str())
            .chain(std::iter::once(self.path.as_str()))
            .chain(self.heading_path.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" / ")
    }
}

impl OrgRepo {
    /// 遍历完整已加载文件；任务查询条件及任务扫描忽略规则不限制放置目标。
    pub async fn refile_targets(&self) -> Result<Vec<RefileTarget>, crate::CoreError> {
        self.refile_targets_in(&RefileTargetQuery::default()).await
    }

    async fn refile_targets_in(&self, query: &RefileTargetQuery) -> Result<Vec<RefileTarget>, crate::CoreError> {
        let mut targets = Vec::new();
        let ignore_files = query.excluded_files.iter().filter(|file| file.repo_id == self.id)
            .map(|file| file.path.clone()).collect::<Vec<_>>();
        let files = self.load_files(&ignore_files).await?;
        for file in files.iter()
            .filter(|file| query.includes(&self.id, &file.path))
        {
            let category = file.category();
            let project_name = file.project_name();
            let file_version = LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
            let mut ancestors: Vec<(usize, String)> = Vec::new();
            for (full_path, headline) in file.path_headlines() {
                if super::OrgFile::is_conflict_headline(&headline) { continue; }
                let level = headline.level();
                while ancestors.last().is_some_and(|(depth, _)| *depth >= level) {
                    ancestors.pop();
                }
                ancestors.push((level, headline.title_raw().trim().to_owned()));
                // 标记不继承，不能将目标标题下的全部子标题自动当成放置位置。
                if headline.tags().any(|tag| tag.as_ref() == REFILE_TAG) {
                    targets.push(RefileTarget {
                        repo_id: self.id.clone(),
                        full_path,
                        category: category.clone(),
                        project_name: project_name.clone(),
                        file_version: file_version.clone(),
                        path: file.path.clone(),
                        heading_path: ancestors.iter().map(|(_, title)| title.clone()).collect(),
                        position: position_at(
                            file.source_bytes(),
                            u32::from(headline.start()) as usize,
                        ),
                    });
                }
            }
        }
        sort_targets(&mut targets);
        Ok(targets)
    }
}

impl OrgWorkspace {
    /// 汇总已加载仓库中的所有显式 REFILE 标题，不重新读取磁盘。
    pub async fn refile_targets(&self) -> Result<Vec<RefileTarget>, crate::CoreError> {
        self.query_refile_targets(&RefileTargetQuery::default()).await
    }

    pub async fn query_refile_targets(
        &self,
        query: &RefileTargetQuery,
    ) -> Result<Vec<RefileTarget>, crate::CoreError> {
        for file in query.files.iter().chain(&query.excluded_files) {
            super::validate_relative_path(&file.path)?;
            if file.repo_id.is_empty() {
                return Err(crate::CoreError::InvalidInput("目标文件的仓库 ID 不能为空"));
            }
        }
        let mut targets = Vec::new();
        for repo in self.repos() { targets.extend(repo.refile_targets_in(query).await?); }
        sort_targets(&mut targets);
        Ok(targets)
    }
}

fn sort_targets(targets: &mut [RefileTarget]) {
    targets.sort_by(|left, right| {
        left.repo_id
            .cmp(&right.repo_id)
            .then(left.path.cmp(&right.path))
            .then(left.position.byte_offset.cmp(&right.position.byte_offset))
    });
}
