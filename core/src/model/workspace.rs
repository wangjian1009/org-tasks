use crate::CoreError;
use crate::filter::{Filter, FilterTask, tasks_from_repo};

use super::{OrgRepo, OrgRepoId, validate_id};

pub type OrgWorkspaceValidationError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
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

    pub fn search(&self, filter: &Filter) -> Vec<FilterTask> {
        let mut tasks = self
            .repos
            .iter()
            .flat_map(tasks_from_repo)
            .collect::<Vec<_>>();
        filter.filter_tasks(&mut tasks);
        tasks
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OrgFile;

    #[test]
    fn search_combines_repositories_and_keeps_repository_identity() {
        let first = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/one".into(),
            files: vec![
                OrgFile::new(
                    "repo-1".into(),
                    "tasks.org".into(),
                    b"* TODO First\n".to_vec(),
                )
                .unwrap(),
            ],
        };
        let second = OrgRepo {
            id: "repo-2".into(),
            root_directory: "/tmp/two".into(),
            files: vec![
                OrgFile::new(
                    "repo-2".into(),
                    "tasks.org".into(),
                    b"* TODO Second\n".to_vec(),
                )
                .unwrap(),
            ],
        };
        let workspace = OrgWorkspace::new(vec![first, second]).unwrap();
        let tasks = workspace.search(&Filter::parse("i.todo"));

        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].repo_id, "repo-1");
        assert_eq!(tasks[1].repo_id, "repo-2");
    }
}
