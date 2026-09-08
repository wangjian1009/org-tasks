use crate::CoreError;
use crate::filter::{Filter, FilterTask, tasks_from_repo};

use super::{OrgRepo, OrgRepoId, SyncPolicy, validate_id};

pub type OrgWorkspaceValidationError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgWorkspace {
    pub repos: Vec<OrgRepo>,
}

impl OrgWorkspace {
    pub fn new(repos: Vec<OrgRepo>) -> Result<Self, OrgWorkspaceValidationError> {
        validate_repositories(&repos)?;
        Ok(Self { repos })
    }

    pub fn repos(&self) -> &[OrgRepo] {
        &self.repos
    }

    pub fn repo(&self, repo_id: &OrgRepoId) -> Option<&OrgRepo> {
        self.repos.iter().find(|repo| &repo.id == repo_id)
    }

    pub fn repo_mut(&mut self, repo_id: &OrgRepoId) -> Option<&mut OrgRepo> {
        self.repos.iter_mut().find(|repo| &repo.id == repo_id)
    }

    pub fn add_repo(&mut self, repo: OrgRepo) -> Result<(), OrgWorkspaceValidationError> {
        let mut repositories = self.repos.clone();
        repositories.push(repo.clone());
        validate_repositories(&repositories)?;
        self.repos.push(repo);
        Ok(())
    }

    pub async fn load<P: SyncPolicy>(&mut self) -> Result<(), CoreError> {
        for repo in &mut self.repos {
            repo.load::<P>().await?;
        }
        validate_repositories(&self.repos)?;
        Ok(())
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

fn validate_repositories(repos: &[OrgRepo]) -> Result<(), CoreError> {
    for (index, repo) in repos.iter().enumerate() {
        if repos[..index]
            .iter()
            .any(|other| other.root_directory == repo.root_directory)
        {
            return Err(CoreError::InvalidInput("仓库根目录必须唯一"));
        }
        if !repo.id.is_empty() {
            validate_id(&repo.id, "仓库 ID 不能为空")?;
            if repos[..index]
                .iter()
                .any(|other| !other.id.is_empty() && other.id == repo.id)
            {
                return Err(CoreError::InvalidInput("仓库 ID 必须唯一"));
            }
        }
    }
    Ok(())
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

    #[test]
    fn repo_mut_returns_only_the_repository_with_matching_identity() {
        let mut workspace = OrgWorkspace::new(vec![OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/one".into(),
            files: Vec::new(),
        }])
        .unwrap();

        workspace.repo_mut(&"repo-1".into()).unwrap().root_directory = "/tmp/updated".into();

        assert_eq!(
            workspace.repo(&"repo-1".into()).unwrap().root_directory,
            "/tmp/updated"
        );
        assert!(workspace.repo_mut(&"unknown".into()).is_none());
    }

    #[test]
    fn add_repo_rejects_duplicate_repository_identity() {
        let repo = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/one".into(),
            files: Vec::new(),
        };
        let mut workspace = OrgWorkspace::new(vec![repo.clone()]).unwrap();

        assert!(workspace.add_repo(repo).is_err());
        assert_eq!(workspace.repos().len(), 1);
    }

    #[test]
    fn workspace_accepts_unloaded_repository_until_load_assigns_its_identity() {
        let repo = OrgRepo::new("/tmp/one".into()).unwrap();
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();

        assert!(workspace.repos()[0].id.is_empty());
    }
}
