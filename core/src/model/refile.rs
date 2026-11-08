use orgize::{ast::Headline, rowan::ast::AstNode};
use serde::Serialize;

use super::{
    LocalFileVersion, OrgRepo, OrgRepoId, OrgWorkspace, SourcePosition, editor::position_at,
};

pub(crate) const REFILE_TAG: &str = "REFILE";

/// 当前文件快照中显式标记为可放置任务的标题，不是持久化实体。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefileTarget {
    pub repo_id: OrgRepoId,
    pub path: String,
    /// 包含所有祖先及目标自身，不包含 TODO、优先级和标签。
    pub heading_path: Vec<String>,
    /// 同名同路径的标题仍以当前快照的源位置区分。
    pub position: SourcePosition,
    pub category: Option<String>,
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
    pub fn refile_targets(&self) -> Vec<RefileTarget> {
        let mut targets = Vec::new();
        for file in self.files() {
            let mut ancestors: Vec<(usize, String)> = Vec::new();
            for headline in file
                .syntax()
                .document()
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
            {
                let level = headline.level();
                while ancestors.last().is_some_and(|(depth, _)| *depth >= level) {
                    ancestors.pop();
                }
                ancestors.push((level, headline.title_raw().trim().to_owned()));
                // 标记不继承，不能将目标标题下的全部子标题自动当成放置位置。
                if headline.tags().any(|tag| tag.as_ref() == REFILE_TAG) {
                    targets.push(RefileTarget {
                        repo_id: self.id.clone(),
                        category: file.category(),
                        file_version: LocalFileVersion::from_bytes(file.source_bytes())
                            .content_hash,
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
        targets
    }
}

impl OrgWorkspace {
    /// 汇总已加载仓库中的所有显式 REFILE 标题，不重新读取磁盘。
    pub fn refile_targets(&self) -> Vec<RefileTarget> {
        let mut targets = self
            .repos()
            .iter()
            .flat_map(OrgRepo::refile_targets)
            .collect::<Vec<_>>();
        sort_targets(&mut targets);
        targets
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
