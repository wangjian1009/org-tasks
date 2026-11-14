use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::filter::Filter;
use crate::{CoreError, FilterTask, OrgWorkspace};

fn include_by_default() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct TaskQuery {
    pub expression: String,
    pub categories: Vec<Option<String>>,
    pub excluded_files: Vec<OrgFileRef>,
    pub include_compose_tasks: bool,
}

impl Default for TaskQuery {
    fn default() -> Self {
        Self {
            expression: String::new(),
            categories: Vec::new(),
            excluded_files: Vec::new(),
            include_compose_tasks: include_by_default(),
        }
    }
}

/// 精确到仓库与文件的查询排除对象。
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

/// 通用查询共享一次仓库访问；TaskQuery 的字段与求值规则保持原定义。
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

impl CoreQuery {
    fn includes_repo(&self, id: &str) -> bool {
        match self {
            Self::Task { repo_ids, .. } => {
                repo_ids.is_empty() || repo_ids.iter().any(|item| item == id)
            }
            Self::File { query } => {
                query.include_files.is_empty()
                    || query.include_files.iter().any(|file| file.repo_id == id)
            }
            Self::Notification { .. } => true,
        }
    }
    fn needs_file(&self, id: &str, path: &str) -> bool {
        if !self.includes_repo(id) {
            return false;
        }
        let contains = |files: &[OrgFileRef]| {
            files
                .iter()
                .any(|file| file.repo_id == id && file.path == path)
        };
        match self {
            Self::Task { query, .. } => !contains(&query.excluded_files),
            Self::File { query } => {
                (query.include_files.is_empty() || contains(&query.include_files))
                    && !contains(&query.exclude_files)
            }
            Self::Notification { .. } => true,
        }
    }
}

fn normalized_category(category: Option<String>) -> Option<String> {
    category.filter(|value| !value.is_empty())
}

impl OrgWorkspace {
    /// 唯一通用查询入口；按输入顺序返回结果，任一错误使整批失败。
    pub async fn query(&self, queries: &[CoreQuery]) -> Result<Vec<CoreQueryResult>, CoreError> {
        if queries.is_empty() {
            return Ok(Vec::new());
        }
        for query in queries {
            match query {
                CoreQuery::Task { query, repo_ids } => {
                    for id in repo_ids {
                        if id.is_empty() || !self.repos().iter().any(|repo| &repo.id == id) {
                            return Err(CoreError::InvalidInput("查询仓库不属于 workspace"));
                        }
                    }
                    for file in &query.excluded_files {
                        validate_query_file(file)?;
                    }
                }
                CoreQuery::File { query } => {
                    if !query.include_files.is_empty() && !query.exclude_files.is_empty() {
                        return Err(CoreError::InvalidInput(
                            "include_files 和 exclude_files 不能同时使用",
                        ));
                    }
                    for file in query.include_files.iter().chain(&query.exclude_files) {
                        validate_query_file(file)?;
                        if !self.repos().iter().any(|repo| repo.id == file.repo_id) {
                            return Err(CoreError::InvalidInput("查询文件的仓库不属于 workspace"));
                        }
                    }
                }
                CoreQuery::Notification { .. } => {}
            }
        }
        let today = chrono::Local::now().date_naive();
        let need_notifications = queries
            .iter()
            .any(|query| matches!(query, CoreQuery::Notification { .. }));
        let need_files = queries
            .iter()
            .any(|query| matches!(query, CoreQuery::File { .. }));
        let need_tasks = queries.iter().any(|query| match query {
            CoreQuery::Task { .. } => true,
            CoreQuery::File { query } => !query.file_tags.is_empty(),
            _ => false,
        });
        let mut roots = BTreeMap::new();
        for repo in self
            .repos()
            .iter()
            .filter(|repo| queries.iter().any(|query| query.includes_repo(&repo.id)))
        {
            let root = tokio::fs::canonicalize(&repo.root_directory)
                .await
                .map_err(|error| CoreError::Store(format!("无法读取查询仓库目录: {error}")))?;
            if roots
                .insert(root, repo)
                .is_some_and(|previous| previous.id != repo.id)
            {
                return Err(CoreError::InvalidInput("同一磁盘目录不能具有不同仓库身份"));
            }
        }
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut guards = Vec::with_capacity(roots.len());
        for root in roots.keys() {
            guards.push(crate::webdav::transaction::lock_before(root, deadline).await?);
        }
        for (root, repo) in &roots {
            super::access::recover(root, &repo.id).await?;
        }
        let mut loaded = BTreeMap::new();
        let mut changed = false;
        for (root, repo) in &roots {
            let mut candidates = BTreeSet::new();
            let mut included = Some(BTreeSet::new());
            for query in queries.iter().filter(|query| query.includes_repo(&repo.id)) {
                let refs = match query {
                    CoreQuery::Task { query, .. } => {
                        included = None;
                        &query.excluded_files
                    }
                    CoreQuery::File { query } => {
                        if query.include_files.is_empty() {
                            included = None;
                        }
                        if let Some(paths) = &mut included {
                            paths.extend(
                                query
                                    .include_files
                                    .iter()
                                    .filter(|file| file.repo_id == repo.id)
                                    .map(|file| file.path.clone()),
                            );
                        }
                        &query.exclude_files
                    }
                    CoreQuery::Notification { .. } => {
                        included = None;
                        continue;
                    }
                };
                candidates.extend(
                    refs.iter()
                        .filter(|file| file.repo_id == repo.id)
                        .map(|file| file.path.clone()),
                );
            }
            candidates.retain(|path| !queries.iter().any(|query| query.needs_file(&repo.id, path)));
            let files = repo
                .load_files_in_unlocked(
                    &candidates.into_iter().collect::<Vec<_>>(),
                    included.as_ref(),
                )
                .await?;
            if need_notifications {
                changed |=
                    crate::webdav::remote_base::local_changes_from_files(root, &files).await?;
            }
            loaded.insert(repo.id.clone(), files);
        }
        drop(guards);
        let mut file_categories = BTreeMap::new();
        let mut all = Vec::new();
        let mut metadata = Vec::new();
        let mut notifications = Vec::new();
        let mut projected = BTreeSet::new();
        for repo in self.repos() {
            if !projected.insert(&repo.id) {
                continue;
            }
            let Some(files) = loaded.get(&repo.id) else {
                continue;
            };
            for file in files {
                file_categories.insert(
                    (file.repo_id.clone(), file.path.clone()),
                    normalized_category(file.category()),
                );
                if need_files {
                    metadata.push(file.metadata(file.scan_ignored));
                }
                if need_tasks {
                    all.extend(crate::filter::tasks_from_file(repo, file));
                }
                if need_notifications && file.has_conflict() {
                    notifications.push(super::CoreNotification::SyncConflict(
                        super::SyncConflictNotification {
                            repo_id: repo.id.clone(),
                            path: file.path.clone(),
                        },
                    ));
                }
            }
        }
        if changed {
            notifications.push(super::CoreNotification::SyncRequired);
        }
        let parents = all
            .windows(2)
            .filter_map(|pair| {
                let (parent, child) = (&pair[0], &pair[1]);
                (parent.repo_id() == child.repo_id()
                    && parent.path() == child.path()
                    && child.level > parent.level)
                    .then(|| {
                        (
                            parent.repo_id().to_owned(),
                            parent.path().to_owned(),
                            parent.byte_offset,
                        )
                    })
            })
            .collect::<BTreeSet<_>>();
        let mut file_tags = BTreeMap::<(&str, &str), BTreeSet<&str>>::new();
        if queries
            .iter()
            .any(|query| matches!(query, CoreQuery::File { query } if !query.file_tags.is_empty()))
        {
            for task in &all {
                file_tags
                    .entry((task.repo_id(), task.path()))
                    .or_default()
                    .extend(
                        task.own_tags()
                            .iter()
                            .chain(task.inherited_tags())
                            .map(String::as_str),
                    );
            }
        }
        Ok(queries
            .iter()
            .map(|query| match query {
                CoreQuery::Task {
                    query: task_query, ..
                } => {
                    let tasks = all
                        .iter()
                        .filter(|task| {
                            !task.file_metadata().is_ignore
                                && query.needs_file(task.repo_id(), task.path())
                        })
                        .cloned()
                        .collect();
                    CoreQueryResult::Task(evaluate_query(
                        task_query,
                        tasks,
                        &file_categories,
                        &parents,
                        today,
                    ))
                }
                CoreQuery::File { query: file_query } => {
                    let files = metadata
                        .iter()
                        .filter(|file| {
                            query.needs_file(&file.repo_id, &file.path)
                                && (file_query.include_ignored || !file.is_ignore)
                                && file_query
                                    .is_project
                                    .is_none_or(|expected| file.project().is_some() == expected)
                                && (file_query.file_tags.is_empty()
                                    || file_tags
                                        .get(&(file.repo_id.as_str(), file.path.as_str()))
                                        .is_some_and(|tags| {
                                            file_query
                                                .file_tags
                                                .iter()
                                                .any(|tag| tags.contains(tag.as_str()))
                                        }))
                        })
                        .cloned()
                        .collect();
                    CoreQueryResult::File(files)
                }
                CoreQuery::Notification { .. } => {
                    CoreQueryResult::Notification(notifications.clone())
                }
            })
            .collect())
    }
}

fn validate_query_file(file: &OrgFileRef) -> Result<(), CoreError> {
    super::validate_relative_path(&file.path)?;
    if file.repo_id.is_empty() {
        return Err(CoreError::InvalidInput("查询文件的仓库 ID 不能为空"));
    }
    Ok(())
}

fn evaluate_query(
    query: &TaskQuery,
    mut all: Vec<FilterTask>,
    file_categories: &BTreeMap<(String, String), Option<String>>,
    parents: &BTreeSet<(String, String, u64)>,
    today: chrono::NaiveDate,
) -> TaskQueryResult {
    Filter::parse(&query.expression).filter_tasks_at(&mut all, today);
    all.retain(|task| {
        query.include_compose_tasks
            || !parents.contains(&(
                task.repo_id().to_owned(),
                task.path().to_owned(),
                task.byte_offset,
            ))
    });
    // 分类摘要不受当前 categories 选择影响，供 UI 展示可选分类和计数。
    let mut counts = BTreeMap::<Option<String>, usize>::new();
    for task in &all {
        let category = file_categories
            .get(&(task.repo_id().to_owned(), task.path().to_owned()))
            .cloned()
            .flatten();
        *counts.entry(category).or_default() += 1;
    }
    let mut categories = counts
        .into_iter()
        .map(|(category, count)| {
            let key = category
                .as_ref()
                .map_or_else(|| "uncategorized".into(), |name| format!("category:{name}"));
            TaskCategory {
                key,
                category,
                count,
            }
        })
        .collect::<Vec<_>>();
    categories.sort_by(|left, right| match (&left.category, &right.category) {
        (Some(left), Some(right)) => left.cmp(right),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    if !query.categories.is_empty() {
        let selected = query
            .categories
            .iter()
            .cloned()
            .map(normalized_category)
            .collect::<BTreeSet<_>>();
        all.retain(|task| {
            let category = file_categories
                .get(&(task.repo_id().to_owned(), task.path().to_owned()))
                .cloned()
                .flatten();
            selected.contains(&category)
        });
    }
    for task in &mut all {
        task.exclude_system_tags();
    }
    TaskQueryResult {
        tasks: all,
        categories,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OrgFile, OrgRepo};

    fn workspace() -> OrgWorkspace {
        let sources = [
            (
                "r1",
                "capture.org",
                "#+CATEGORY: Inbox\n* TODO Pending inbox\n* DONE Done inbox\n* Plain inbox\n",
            ),
            (
                "r1",
                "work.org",
                "#+CATEGORY: Work\n#+TODO: TODO | DONE CNCL\n* TODO Pending work\n* CNCL Cancelled work\n",
            ),
            (
                "r1",
                "home.org",
                "#+CATEGORY: Home\n* TODO Parent home\n** TODO Child home\n",
            ),
            ("r1", "old.org", "#+CATEGORY: Finished\n* DONE Done\n"),
            ("r1", "plain.org", "* Plain record\n"),
            (
                "r1",
                "literal.org",
                "#+CATEGORY: 未分类\n* TODO Named unclassified\n",
            ),
            (
                "r2",
                "work.org",
                "#+CATEGORY: Work\n#+TODO: OPEN | FINISHED\n* OPEN Pending cancel\n",
            ),
            (
                "r2",
                "capture.org",
                "#+CATEGORY: Inbox\n* DONE Other inbox\n",
            ),
        ];
        OrgWorkspace::new(
            ["r1", "r2"]
                .into_iter()
                .map(|id| {
                    let mut repo = OrgRepo::new(format!("/tmp/{id}")).unwrap();
                    repo.id = id.into();
                    {
                        let value = sources
                            .iter()
                            .filter(|(repo_id, _, _)| *repo_id == id)
                            .map(|(_, path, source)| {
                                OrgFile::new(id.into(), (*path).into(), source.as_bytes().to_vec())
                                    .unwrap()
                            })
                            .collect();
                        crate::model::test_support::write_files(&mut repo, value);
                    }
                    repo
                })
                .collect(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn batch_preserves_positions_and_independent_results_with_one_access_per_repository() {
        let workspace = workspace();
        let before = workspace
            .repos()
            .iter()
            .map(|repo| super::super::test_support::repository_accesses(&repo.root_directory))
            .collect::<Vec<_>>();
        let queries = [
            TaskQuery {
                expression: "it.done .o.created".into(),
                ..Default::default()
            },
            TaskQuery {
                expression: "t.no_such_tag".into(),
                ..Default::default()
            },
            category_query(),
            TaskQuery {
                categories: vec![Some("Work".into())],
                include_compose_tasks: false,
                ..Default::default()
            },
            TaskQuery::default(),
            category_query(),
        ];
        let mut results = workspace
            .query(&queries.iter().cloned().map(Into::into).collect::<Vec<_>>())
            .await
            .unwrap()
            .into_iter()
            .map(|result| result.into_task().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.len(), queries.len());
        assert!(results[1].tasks.is_empty());
        assert_eq!(results[2], results[5]);
        for (repo, before) in workspace.repos().iter().zip(before) {
            let after = super::super::test_support::repository_accesses(&repo.root_directory);
            assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        }
        for (query, result) in queries.iter().zip(&results) {
            let expected = workspace
                .query(&[(query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap();
            assert_eq!(*result, expected);
        }
        let duplicate = results[5].clone();
        results[2].tasks.clear();
        assert_eq!(results[5], duplicate);
    }

    #[tokio::test]
    async fn batch_exclusions_are_intersected_before_loading_and_applied_per_query() {
        let workspace = workspace();
        let repo = &workspace.repos()[0];
        std::fs::write(
            std::path::Path::new(&repo.root_directory).join("broken.org"),
            [0xff],
        )
        .unwrap();
        let broken = OrgFileRef {
            repo_id: repo.id.clone(),
            path: "broken.org".into(),
        };
        let queries = [
            TaskQuery {
                excluded_files: vec![
                    broken.clone(),
                    OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: "work.org".into(),
                    },
                ],
                ..Default::default()
            },
            TaskQuery {
                excluded_files: vec![broken.clone()],
                ..Default::default()
            },
        ];
        let results = workspace
            .query(&queries.iter().cloned().map(Into::into).collect::<Vec<_>>())
            .await
            .unwrap()
            .into_iter()
            .map(|result| result.into_task().unwrap())
            .collect::<Vec<_>>();
        assert!(
            results[0]
                .tasks
                .iter()
                .all(|task| task.repo_id() != repo.id || task.path() != "work.org")
        );
        assert!(
            results[0]
                .tasks
                .iter()
                .any(|task| task.repo_id() != repo.id && task.path() == "work.org")
        );
        assert!(
            results[1]
                .tasks
                .iter()
                .any(|task| task.repo_id() == repo.id && task.path() == "work.org")
        );
        assert!(
            results
                .iter()
                .all(|result| result.tasks.iter().all(|task| task.path() != "broken.org"))
        );
        // 任意查询需要损坏文件即整体失败，不能返回另一查询的部分成功。
        assert!(
            workspace
                .query(&[(queries[0].clone()).into(), (TaskQuery::default()).into()])
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn empty_and_invalid_batches_do_not_acquire_repository_locks_or_load_files() {
        let workspace = workspace();
        let before = workspace
            .repos()
            .iter()
            .map(|repo| super::super::test_support::repository_accesses(&repo.root_directory))
            .collect::<Vec<_>>();
        assert!(
            workspace
                .query(&[])
                .await
                .unwrap()
                .into_iter()
                .map(|result| result.into_task().unwrap())
                .collect::<Vec<_>>()
                .is_empty()
        );
        for (repo_id, path) in [
            (workspace.repos()[0].id.clone(), "../unsafe.org"),
            (String::new(), "valid.org"),
        ] {
            let error = workspace
                .query(&[
                    (TaskQuery::default()).into(),
                    (TaskQuery {
                        excluded_files: vec![OrgFileRef {
                            repo_id,
                            path: path.into(),
                        }],
                        ..Default::default()
                    })
                    .into(),
                ])
                .await
                .unwrap_err();
            assert!(matches!(error, CoreError::InvalidInput(_)));
        }
        for (repo, before) in workspace.repos().iter().zip(before) {
            assert_eq!(
                super::super::test_support::repository_accesses(&repo.root_directory),
                before
            );
        }
    }

    #[tokio::test]
    async fn mixed_queries_share_one_repository_access_and_keep_all_result_positions() {
        let workspace = workspace();
        let repo = &workspace.repos()[0];
        std::fs::write(
            std::path::Path::new(&repo.root_directory).join(".orgzlyignore"),
            "capture.org\n",
        )
        .unwrap();
        std::fs::write(
            std::path::Path::new(&repo.root_directory).join("conflict.org"),
            "* Visible\n* Pending conflict :CONFLICT:\n** Variant\n",
        )
        .unwrap();
        let before = workspace
            .repos()
            .iter()
            .map(|repo| super::super::test_support::repository_accesses(&repo.root_directory))
            .collect::<Vec<_>>();
        let queries = [
            category_query().into(),
            CoreQuery::File {
                query: FileQuery {
                    include_files: vec![OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: "capture.org".into(),
                    }],
                    include_ignored: true,
                    ..Default::default()
                },
            },
            CoreQuery::Notification {
                query: NotificationQuery {},
            },
            CoreQuery::Notification {
                query: NotificationQuery {},
            },
        ];
        let results = workspace.query(&queries).await.unwrap();
        assert_eq!(results.len(), 4);
        assert!(
            results[0]
                .clone()
                .into_task()
                .unwrap()
                .tasks
                .iter()
                .all(|task| task.path() != "capture.org")
        );
        let files = results[1].clone().into_files().unwrap();
        assert_eq!(files.len(), 1);
        assert!(files[0].is_ignore);
        let notices = results[2].clone().into_notifications().unwrap();
        assert!(notices.iter().any(|notice| matches!(notice, super::super::CoreNotification::SyncConflict(conflict) if conflict.path == "conflict.org")));
        assert_eq!(
            notices
                .iter()
                .filter(|notice| matches!(notice, super::super::CoreNotification::SyncRequired))
                .count(),
            1
        );
        assert_eq!(results[2], results[3]);
        for (repo, before) in workspace.repos().iter().zip(before) {
            let after = super::super::test_support::repository_accesses(&repo.root_directory);
            assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        }
    }

    #[tokio::test]
    async fn file_queries_filter_sources_tags_and_project_status_without_modifying_task_queries() {
        let workspace = workspace();
        let repo = &workspace.repos()[0];
        std::fs::write(
            std::path::Path::new(&repo.root_directory).join("project.org"),
            "#+FILETAGS: :project:\n#+TITLE: Project\n* TODO Parent :work:\n** TODO Child\n",
        )
        .unwrap();
        let results = workspace
            .query(&[
                CoreQuery::File {
                    query: FileQuery {
                        file_tags: vec!["absent".into(), "work".into()],
                        is_project: Some(true),
                        ..Default::default()
                    },
                },
                CoreQuery::File {
                    query: FileQuery {
                        exclude_files: vec![OrgFileRef {
                            repo_id: repo.id.clone(),
                            path: "project.org".into(),
                        }],
                        is_project: Some(false),
                        ..Default::default()
                    },
                },
                CoreQuery::Task {
                    query: TaskQuery::default(),
                    repo_ids: vec![workspace.repos()[1].id.clone()],
                },
            ])
            .await
            .unwrap();
        let files = results[0].clone().into_files().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].project(), Some("Project"));
        assert!(
            results[1]
                .clone()
                .into_files()
                .unwrap()
                .iter()
                .all(|file| file.project().is_none())
        );
        assert!(
            results[2]
                .clone()
                .into_task()
                .unwrap()
                .tasks
                .iter()
                .all(|task| task.repo_id() == workspace.repos()[1].id)
        );
        let reference = OrgFileRef {
            repo_id: repo.id.clone(),
            path: "project.org".into(),
        };
        let before = super::super::test_support::repository_accesses(&repo.root_directory);
        assert!(
            workspace
                .query(&[CoreQuery::File {
                    query: FileQuery {
                        include_files: vec![reference.clone()],
                        exclude_files: vec![reference.clone()],
                        ..Default::default()
                    }
                }])
                .await
                .is_err()
        );
        assert_eq!(
            super::super::test_support::repository_accesses(&repo.root_directory),
            before
        );
        std::fs::create_dir_all(
            std::path::Path::new(&repo.root_directory).join(".sync/remote_base"),
        )
        .unwrap();
        std::fs::write(
            std::path::Path::new(&repo.root_directory).join(".sync/remote_base/current.json"),
            "broken",
        )
        .unwrap();
        assert!(
            workspace
                .query(&[
                    TaskQuery::default().into(),
                    CoreQuery::Notification {
                        query: NotificationQuery {}
                    }
                ])
                .await
                .is_err()
        );
        assert!(
            workspace
                .query(&[CoreQuery::File {
                    query: FileQuery {
                        include_files: vec![reference],
                        ..Default::default()
                    }
                }])
                .await
                .is_ok()
        );
    }

    fn category_query() -> TaskQuery {
        TaskQuery {
            excluded_files: vec![
                OrgFileRef {
                    repo_id: crate::model::test_support::id("r1"),
                    path: "capture.org".into(),
                },
                OrgFileRef {
                    repo_id: crate::model::test_support::id("r2"),
                    path: "capture.org".into(),
                },
            ],
            expression: ".it.done".into(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn state_presence_and_terminal_scope_are_controlled_only_by_expressions() {
        let mut repo = OrgRepo::new("/tmp/query-state-presence".into()).unwrap();
        repo.id = "repo".into();
        let file = OrgFile::new(
            repo.id.clone(),
            "states.org".into(),
            b"#+TODO: TODO INPROGRESS OTHER | DONE CNCL\n* TODO Pending\n* INPROGRESS Running\n* OTHER Unclassified\n* DONE Completed\n* CNCL Cancelled\n* Plain\n".to_vec(),
        )
        .unwrap();
        crate::model::test_support::write_files(&mut repo, vec![file]);
        let mut workspace = OrgWorkspace::new(vec![repo]).unwrap();
        workspace
            .set_settings(crate::CoreSettings {
                addition_states: vec![crate::TaskState {
                    name: "OTHER".into(),
                    category: None,
                }],
            })
            .unwrap();
        let cases = [
            (
                "",
                vec![
                    "Pending",
                    "Running",
                    "Unclassified",
                    "Completed",
                    "Cancelled",
                    "Plain",
                ],
            ),
            (
                ".it.none",
                vec![
                    "Pending",
                    "Running",
                    "Unclassified",
                    "Completed",
                    "Cancelled",
                ],
            ),
            ("it.none", vec!["Plain"]),
            ("i.none", vec!["Unclassified", "Plain"]),
            ("it.todo", vec!["Pending", "Running", "Unclassified"]),
            ("it.done", vec!["Completed", "Cancelled"]),
            (
                ".it.done",
                vec!["Pending", "Running", "Unclassified", "Plain"],
            ),
            (
                ".it.done (it.done or i.none)",
                vec!["Unclassified", "Plain"],
            ),
        ];
        let queries = cases
            .iter()
            .map(|(expression, _)| {
                TaskQuery {
                    expression: (*expression).into(),
                    ..Default::default()
                }
                .into()
            })
            .collect::<Vec<_>>();
        for (result, (expression, expected)) in workspace
            .query(&queries)
            .await
            .unwrap()
            .into_iter()
            .zip(cases)
        {
            let result = result.into_task().unwrap();
            assert_eq!(
                result
                    .tasks
                    .iter()
                    .map(FilterTask::title)
                    .collect::<Vec<_>>(),
                expected,
                "{expression}"
            );
            assert_eq!(
                result
                    .categories
                    .iter()
                    .map(|category| category.count)
                    .sum::<usize>(),
                expected.len()
            );
        }
    }

    #[tokio::test]
    async fn generic_defaults_include_all_records_and_expressions_filter_in_core() {
        let workspace = workspace();
        let result = workspace
            .query(&[(TaskQuery::default()).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 12);
        let result = workspace
            .query(&[(category_query()).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 6);
        assert!(
            result
                .tasks
                .iter()
                .all(|task| !task.is_done() && task.path() != "capture.org")
        );
        assert!(
            !result
                .categories
                .iter()
                .any(|category| category.category.as_deref() == Some("Inbox")
                    || category.category.as_deref() == Some("Finished"))
        );
        assert_eq!(
            result
                .categories
                .iter()
                .find(|c| c.category.as_deref() == Some("Work"))
                .unwrap()
                .count,
            2
        );
        assert!(result.categories.last().unwrap().category.is_none());
        for category in result.categories {
            let query = TaskQuery {
                categories: vec![category.category],
                ..category_query()
            };
            assert_eq!(
                workspace
                    .query(&[(&query).into()])
                    .await
                    .unwrap()
                    .remove(0)
                    .into_task()
                    .unwrap()
                    .tasks
                    .len(),
                category.count
            );
        }
    }

    #[tokio::test]
    async fn categories_are_values_with_union_and_empty_means_no_category_filter() {
        let workspace = workspace();
        let query = TaskQuery {
            categories: vec![
                Some("Work".into()),
                Some("Home".into()),
                Some("Work".into()),
            ],
            ..category_query()
        };
        assert_eq!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            4
        );
        let query = TaskQuery {
            categories: vec![None],
            ..category_query()
        };
        assert_eq!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            1
        );
        let query = TaskQuery {
            categories: vec![Some("未分类".into())],
            ..category_query()
        };
        assert_eq!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            1
        );
        let query = TaskQuery {
            categories: vec![Some("gone".into())],
            ..category_query()
        };
        assert!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .is_empty()
        );
        assert_eq!(
            workspace
                .query(&[(category_query()).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            6
        );
    }

    #[tokio::test]
    async fn archive_file_category_is_hidden_from_task_projection_and_summary() {
        let mut repo = OrgRepo::new("/tmp/archive-category".into()).unwrap();
        repo.id = "archive".into();
        {
            let value = OrgFile::new(
                repo.id.clone(),
                "archive.org".into(),
                b"#+CATEGORY: ARCHIVE\n* TODO Archived\n".to_vec(),
            )
            .unwrap();
            crate::model::test_support::push_file(&mut repo, value);
        };
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let result = workspace
            .query(&[(TaskQuery::default()).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks[0].category, None);
        assert_eq!(result.categories.len(), 1);
        assert_eq!(result.categories[0].category, None);
    }

    #[tokio::test]
    async fn ui_can_request_inbox_using_expression_and_include_all_record_types() {
        let workspace = workspace();
        let query = TaskQuery {
            expression: "b.capture.org".into(),
            ..Default::default()
        };
        let result = workspace
            .query(&[(&query).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 4);
        assert_eq!(result.tasks.iter().filter(|task| task.is_done()).count(), 2);
        assert!(result.tasks.iter().any(|task| task.state.is_none()));
        assert_eq!(
            workspace
                .query(&[(TaskQuery {
                    expression: "b.work.org".into(),
                    ..Default::default()
                })
                .into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            3
        );
    }

    #[tokio::test]
    async fn address_query_uses_real_links_and_combines_state_and_configured_note_file() {
        let mut repo = OrgRepo::new("/tmp/address-query".into()).unwrap();
        repo.id = "repo".into();
        {
            let value = [
            ("tasks.org", concat!(
                "#+TODO: NEXT | FINISHED\n",
                "* NEXT Coordinates\n[[geo:39.9,116.4][地点]]\n",
                "* NEXT Address\n[[addr:北京市]]\n",
                "* FINISHED Finished\n[[addr:已完成]]\n",
                "* NEXT Without address\n普通正文 geo:39.9,116.4\n",
                "* NEXT Web link\n[[https://example.org/geo:39.9][网页]]\n",
                "* NEXT Literals\n#+begin_src org\n[[addr:源码]]\n#+end_src\n",
                "#+begin_example\n[[geo:1,2]]\n#+end_example\n",
                "~[[addr:行内字面文本]]~\n# [[addr:注释]]\n",
                "* NEXT Parent without own address\n** NEXT Child\n[[addr:子任务]]\n",
                "* NEXT Title [[addr:标题地址][地点]]\n",
                "* Other note\n[[addr:不在配置备忘文件]]\n",
                "* NEXT Empty URI\n[[addr:]]\n",
            )),
            ("notes.org", "* Note\n[[addr:备忘地点][备忘]]\n* DONE Finished note\n[[geo:1,2]]\n* No address\n正文\n"),
        ].into_iter().map(|(path, source)| {
            OrgFile::new("repo".into(), path.into(), source.as_bytes().to_vec()).unwrap()
        }).collect();
            crate::model::test_support::write_files(&mut repo, value);
        }
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let query = TaskQuery {
            expression: "has.address (it.todo or (b.notes.org it.none))".into(),
            ..Default::default()
        };
        let result = workspace
            .query(&[(&query).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        let titles = result
            .tasks
            .iter()
            .map(|task| task.title.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            titles,
            [
                "Note",
                "Coordinates",
                "Address",
                "Child",
                "Title [[addr:标题地址][地点]]"
            ]
        );
        let address = result
            .tasks
            .iter()
            .find(|task| task.title == "Address")
            .unwrap();
        assert_eq!(
            address.address_links,
            vec![crate::filter::AddressLink {
                uri: "addr:北京市".into(),
                label: String::new()
            }]
        );
        let without = workspace
            .query(&[(TaskQuery {
                expression: ".has.address".into(),
                ..Default::default()
            })
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert!(
            without
                .tasks
                .iter()
                .all(|task| task.address_links.is_empty())
        );
        assert!(without.tasks.iter().any(|task| task.title == "Literals"));
    }

    #[tokio::test]
    async fn anytime_query_excludes_files_from_task_ignore_rules() {
        let mut repository = OrgRepo::new("/tmp/ignored-anytime".into()).unwrap();
        repository.id = "repo".into();
        {
            let value = vec![
                OrgFile::new(
                    "repo".into(),
                    "visible.org".into(),
                    b"* TODO Visible\n".to_vec(),
                )
                .unwrap(),
                OrgFile::new(
                    "repo".into(),
                    "ann.org".into(),
                    b"* TODO Announcement\n".to_vec(),
                )
                .unwrap(),
            ];
            crate::model::test_support::write_files(&mut repository, value);
        }
        {
            let value = crate::TaskScanRules::parse("ann.org\n").unwrap();
            crate::model::test_support::set_rules(&mut repository, value);
        }
        let workspace = OrgWorkspace::new(vec![repository]).unwrap();
        let result = workspace
            .query(&[(TaskQuery {
                expression: ".it.done s.none d.none".into(),
                include_compose_tasks: true,
                ..Default::default()
            })
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].path(), "visible.org");
    }

    #[tokio::test]
    async fn pending_undated_task_query_excludes_notes_done_and_either_planning_field() {
        let mut workspace = workspace();
        let mut repo = &mut workspace.repos[0];
        {
            let value = OrgFile::new(repo.id.clone(), "undated.org".into(),
            "#+CATEGORY: Work\n#+TODO: NEXT | CLOSED\n* NEXT Undated task\n* Plain heading\n* CLOSED Completed task\n* NEXT Scheduled task\nSCHEDULED: <2026-11-09 Mon>\n* NEXT Deadline task\nDEADLINE: <2026-11-10 Tue>\n".as_bytes().to_vec()).unwrap();
            crate::model::test_support::push_file(&mut repo, value);
        };
        let result = workspace
            .query(&[(TaskQuery {
                expression: "it.todo s.none d.none".into(),
                include_compose_tasks: true,
                ..Default::default()
            })
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        let titles = result
            .tasks
            .iter()
            .filter(|task| task.path() == "undated.org")
            .map(|task| task.title())
            .collect::<Vec<_>>();
        assert_eq!(titles, ["Undated task"]);
        assert!(
            result
                .tasks
                .iter()
                .all(|task| task.state_type() == crate::FilterStateType::Todo
                    && task.scheduled().is_none()
                    && task.deadline().is_none())
        );
    }

    #[tokio::test]
    async fn compose_tasks_are_detected_before_expression_filter_and_respect_file_boundaries() {
        let workspace = workspace();
        let query = TaskQuery {
            include_compose_tasks: false,
            ..category_query()
        };
        assert_eq!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            5
        );
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            include_compose_tasks: false,
            ..Default::default()
        };
        assert!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .is_empty()
        );
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            ..Default::default()
        };
        assert_eq!(
            workspace
                .query(&[(&query).into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .len(),
            1
        );
        let repos = [
            ("one", "* TODO Parent\n** DONE Child\n"),
            ("two", "* TODO Peer\n"),
        ]
        .into_iter()
        .map(|(id, source)| {
            let mut repo = OrgRepo::new(format!("/tmp/{id}")).unwrap();
            repo.id = id.into();
            {
                let value =
                    OrgFile::new(id.into(), "same.org".into(), source.as_bytes().to_vec()).unwrap();
                crate::model::test_support::push_file(&mut repo, value);
            };
            repo
        })
        .collect();
        let same_paths = OrgWorkspace::new(repos).unwrap();
        let result = same_paths
            .query(&[(TaskQuery {
                expression: ".it.done".into(),
                include_compose_tasks: false,
                ..Default::default()
            })
            .into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].title, "Peer");
    }

    #[tokio::test]
    async fn unsafe_exclusions_are_rejected_and_json_defaults_are_generic() {
        let workspace = workspace();
        for path in ["", "../capture.org", "/capture.org", "a\\capture.org"] {
            assert!(
                workspace
                    .query(&[(TaskQuery {
                        excluded_files: vec![OrgFileRef {
                            repo_id: crate::model::test_support::id("r1"),
                            path: path.into()
                        }],
                        ..Default::default()
                    })
                    .into()])
                    .await
                    .is_err()
            );
        }
        assert_eq!(
            serde_json::from_str::<TaskQuery>("{}").unwrap(),
            TaskQuery::default()
        );
        assert!(serde_json::from_str::<TaskQuery>(r#"{"toggleCategory":"Work"}"#).is_err());
    }
}
