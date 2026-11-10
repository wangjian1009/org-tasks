use crate::CoreError;

use super::{OrgRepo, OrgRepoId, TodoConfig, validate_id};

pub type OrgWorkspaceValidationError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgWorkspace {
    pub repos: Vec<OrgRepo>,
    pub todo_defaults: TodoConfig,
    pub task_operation_history: super::TaskOperationHistory,
}

impl OrgWorkspace {
    pub fn new(repos: Vec<OrgRepo>) -> Result<Self, OrgWorkspaceValidationError> {
        validate_repositories(&repos)?;
        Ok(Self {
            repos,
            todo_defaults: TodoConfig::default(),
            task_operation_history: Default::default(),
        })
    }

    pub fn set_todo_defaults(&mut self, defaults: TodoConfig) -> Result<(), CoreError> {
        defaults.validate()?;
        let mut repos = self.repos.clone();
        for repo in &mut repos {
            repo.set_todo_defaults(defaults.clone())?;
        }
        self.repos = repos;
        self.todo_defaults = defaults;
        Ok(())
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

    pub fn repo_by_root_directory(&self, root_directory: &str) -> Option<&OrgRepo> {
        self.repos
            .iter()
            .find(|repo| repo.root_directory == root_directory)
    }

    pub fn repo_mut_by_root_directory(&mut self, root_directory: &str) -> Option<&mut OrgRepo> {
        self.repos
            .iter_mut()
            .find(|repo| repo.root_directory == root_directory)
    }

    pub fn add_repo(&mut self, mut repo: OrgRepo) -> Result<(), OrgWorkspaceValidationError> {
        repo.set_todo_defaults(self.todo_defaults.clone())?;
        let mut repositories = self.repos.clone();
        repositories.push(repo.clone());
        validate_repositories(&repositories)?;
        self.repos.push(repo);
        Ok(())
    }

    pub fn remove_repo_by_root_directory(
        &mut self,
        root_directory: &str,
    ) -> Result<OrgRepo, OrgWorkspaceValidationError> {
        let index = self
            .repos
            .iter()
            .position(|repo| repo.root_directory == root_directory)
            .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
        Ok(self.repos.remove(index))
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
    fn query_combines_repositories_and_keeps_repository_identity() {
        let first = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/one".into(),
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
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
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
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
        let tasks = workspace.query(&crate::TaskQuery { expression: "i.todo".into(), ..Default::default() }).unwrap().tasks;

        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].repo_id(), "repo-1");
        assert_eq!(tasks[1].repo_id(), "repo-2");
    }

    #[test]
    fn repo_mut_returns_only_the_repository_with_matching_identity() {
        let mut workspace = OrgWorkspace::new(vec![OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/one".into(),
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
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
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
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

    #[test]
    fn removes_repository_by_root_directory() {
        let mut workspace =
            OrgWorkspace::new(vec![OrgRepo::new("/tmp/one".into()).unwrap()]).unwrap();

        let removed = workspace.remove_repo_by_root_directory("/tmp/one").unwrap();

        assert_eq!(removed.root_directory, "/tmp/one");
        assert!(workspace.repos().is_empty());
    }
    #[test]
    fn workspace_updates_external_defaults_for_loaded_and_new_repos() {
        let mut repo = OrgRepo::new("/tmp/one".into()).unwrap();
        repo.id = "repo".into();
        repo.files.push(
            OrgFile::new("repo".into(), "default.org".into(), b"* OPEN A\n".to_vec()).unwrap(),
        );
        repo.files.push(
            OrgFile::new(
                "repo".into(),
                "override.org".into(),
                b"#+TODO: OWN | CLOSED\n* OWN B\n".to_vec(),
            )
            .unwrap(),
        );
        let mut workspace = OrgWorkspace::new(vec![repo]).unwrap();
        workspace
            .set_todo_defaults(crate::TodoConfig::from_settings("#+TODO: OPEN | END").unwrap())
            .unwrap();
        assert_eq!(workspace.query(&crate::TaskQuery { expression: "it.todo".into(), ..Default::default() }).unwrap().tasks.len(), 2);
        workspace
            .set_todo_defaults(crate::TodoConfig::from_settings("#+TODO: OTHER | END").unwrap())
            .unwrap();
        assert_eq!(workspace.query(&crate::TaskQuery { expression: "it.todo".into(), ..Default::default() }).unwrap().tasks.len(), 1);
        workspace
            .add_repo(OrgRepo::new("/tmp/two".into()).unwrap())
            .unwrap();
        assert_eq!(workspace.repos[1].todo_defaults, workspace.todo_defaults);
        assert_eq!(workspace.repos[0].files[0].source_bytes(), b"* OPEN A\n");
    }
}
