use crate::workspace::WorkspaceState;
use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::filter::Filter;
use crate::model::{
    CoreQuery, CoreQueryResult, FileQuery, OrgFileRef, TaskCategory, TaskQuery,
    TaskQueryResult,
};
use crate::{CoreError, FilterTask};
#[cfg(test)]
use crate::OrgWorkspace;

impl CoreQuery {
    pub(crate) fn includes_repo(&self, id: &str) -> bool {
        match self {
            Self::Task { query, repo_ids } => {
                (repo_ids.is_empty() || repo_ids.iter().any(|item| item == id))
                    && (query.include_files.is_empty()
                        || query.include_files.iter().any(|file| file.repo_id == id
                            && !query.exclude_files.contains(file)))
            }
            Self::File { query } => {
                query.include_files.is_empty()
                    || query.include_files.iter().any(|file| file.repo_id == id
                        && !query.exclude_files.contains(file))
            }
            Self::Notification { .. } => true,
        }
    }
    pub(crate) fn needs_file(&self, id: &str, path: &str) -> bool {
        if !self.includes_repo(id) {
            return false;
        }
        let contains = |files: &[OrgFileRef]| {
            files
                .iter()
                .any(|file| file.repo_id == id && file.path == path)
        };
        match self {
            Self::Task { query, .. } => {
                (query.include_files.is_empty() || contains(&query.include_files))
                    && !contains(&query.exclude_files)
            },
            Self::File { query } => {
                (query.include_files.is_empty() || contains(&query.include_files))
                    && !contains(&query.exclude_files)
            }
            Self::Notification { .. } => true,
        }
    }
}


pub(crate) fn normalized_category(category: Option<String>) -> Option<String> {
    category.filter(|value| !value.is_empty())
}

enum QueryWorkResult {
    File { repo_id: String, file: crate::OrgFile },
    Task(FilterTask),
    RepositoryFinished,
    Failed(CoreError),
}

impl WorkspaceState {
    /// 唯一通用查询入口；按输入顺序返回结果，任一错误使整批失败。
    pub async fn query(&self, queries: &[CoreQuery]) -> Result<Vec<CoreQueryResult>, CoreError> {
        let _activity = self.tasks.enter()?;
        let results = self.query_snapshot(queries, false).await?.results;
        self.notifications.flush().await?;
        Ok(results)
    }

    /// 一次读取同时返回查询结果与可选的原始投影；普通查询不保留原始投影。
    pub(crate) async fn query_snapshot(
        &self,
        queries: &[CoreQuery],
        retain_data: bool,
    ) -> Result<QuerySnapshot, CoreError> {
        let activity = std::sync::Arc::new(self.tasks.enter()?);
        if queries.is_empty() {
            return Ok(QuerySnapshot::default());
        }
        for query in queries {
            match query {
                CoreQuery::Task { query, repo_ids } => {
                    for id in repo_ids {
                        if id.is_empty() || !self.repos().iter().any(|repo| &repo.id == id) {
                            return Err(CoreError::InvalidInput("查询仓库不属于 workspace"));
                        }
                    }
                    Filter::validate_expression(&query.expression)?;
                    for file in query.include_files.iter().chain(&query.exclude_files) {
                        validate_query_file(file)?;
                        if !self.repos().iter().any(|repo| repo.id == file.repo_id) {
                            return Err(CoreError::InvalidInput("查询文件的仓库不属于 workspace"));
                        }
                    }
                }
                CoreQuery::File { query } => {
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
        let need_files = retain_data
            || queries
                .iter()
                .any(|query| matches!(query, CoreQuery::File { .. }));
        let need_tasks = retain_data
            || queries.iter().any(|query| match query {
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
            crate::model::access::recover(root, &repo.id).await?;
        }
        let expected = roots.len();
        let (sender, mut receiver) = tokio::sync::mpsc::channel(expected.max(1));
        let mut jobs = Vec::with_capacity(expected);
        for (_, repo) in &roots {
            let mut candidates = BTreeSet::new();
            let mut included = Some(BTreeSet::new());
            for query in queries.iter().filter(|query| query.includes_repo(&repo.id)) {
                let refs = match query {
                    CoreQuery::Task { query, .. } => {
                        if query.include_files.is_empty() {
                            included = None;
                        }
                        if let Some(paths) = &mut included {
                            paths.extend(query.include_files.iter()
                                .filter(|file| file.repo_id == repo.id)
                                .map(|file| file.path.clone()));
                        }
                        &query.exclude_files
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
            let repo = (*repo).clone();
            let ignored = candidates.into_iter().collect::<Vec<_>>();
            let repo_id = repo.id.clone();
            let sender = sender.clone();
            let activity = activity.clone();
            jobs.push(tokio::spawn(async move {
                let _activity = activity;
                let result = async {
                    let files = repo
                        .load_files_in_unlocked(&ignored, included.as_ref())
                        .await?;
                    for file in files {
                        if need_tasks {
                            for task in crate::filter::tasks_from_file(&repo, &file) {
                                if sender.send(QueryWorkResult::Task(task)).await.is_err() {
                                    return Ok(());
                                }
                            }
                        }
                        if sender
                            .send(QueryWorkResult::File {
                                repo_id: repo_id.clone(),
                                file,
                            })
                            .await
                            .is_err()
                        {
                            return Ok(());
                        }
                    }
                    Ok(())
                }
                .await;
                match result {
                    Ok(()) => {
                        let _ = sender
                            .send(QueryWorkResult::RepositoryFinished)
                            .await;
                    }
                    Err(error) => {
                        let _ = sender.send(QueryWorkResult::Failed(error)).await;
                    }
                }
            }));
        }
        drop(sender);
        // 合并任务也交给调用方 runtime；生产任务只负责读取文件和投影结果。
        let merge_activity = activity.clone();
        let merge_job = tokio::spawn(async move {
            let _activity = merge_activity;
            let mut loaded = BTreeMap::new();
            let changed = false;
            let mut file_categories = BTreeMap::new();
            let mut all = Vec::new();
            let mut metadata = Vec::new();
            let mut notifications = Vec::new();
            let mut received = 0;
            while let Some(result) = receiver.recv().await {
                match result {
                    QueryWorkResult::Task(task) => all.push(task),
                    QueryWorkResult::File { repo_id, file } => {
                        file_categories.insert(
                            (file.repo_id.clone(), file.path.clone()),
                            normalized_category(file.category()),
                        );
                        if need_files {
                            metadata.push(file.metadata(file.scan_ignored));
                        }
                        if need_notifications && file.has_conflict() {
                            notifications.push(crate::CoreNotification::SyncConflict(
                                crate::SyncConflictNotification {
                                    repo_id: file.repo_id.clone(),
                                    path: file.path.clone(),
                                },
                            ));
                        }
                        loaded.entry(repo_id).or_insert_with(Vec::new).push(file);
                    }
                    QueryWorkResult::RepositoryFinished => received += 1,
                    QueryWorkResult::Failed(error) => {
                        for job in &jobs {
                            job.abort();
                        }
                        for job in jobs {
                            let _ = job.await;
                        }
                        return Err(error);
                    }
                }
            }
            if received != expected {
                for job in &jobs {
                    job.abort();
                }
                for job in jobs {
                    let _ = job.await;
                }
                return Err(CoreError::Store("查询任务提前结束".into()));
            }
            for job in jobs {
                job.await
                    .map_err(|error| CoreError::Store(format!("查询任务失败: {error}")))?;
            }
            Ok::<_, CoreError>((loaded, changed, file_categories, all, metadata, notifications))
        });
        let (loaded, mut changed, file_categories, mut all, mut metadata, mut notifications) =
            merge_job
                .await
                .map_err(|error| CoreError::Store(format!("查询合并任务失败: {error}")))??;
        if need_notifications {
            for (repo_id, files) in &loaded {
                let root = roots
                    .iter()
                    .find(|(_, repo)| repo.id == *repo_id)
                    .map(|(root, _)| root)
                    .expect("已加载仓库必须存在根目录");
                changed |=
                    crate::webdav::remote_base::local_changes_from_files(root, files).await?;
            }
        }
        let repository_order = self
            .repos()
            .iter()
            .enumerate()
            .map(|(index, repo)| (repo.id.as_str(), index))
            .collect::<BTreeMap<_, _>>();
        all.sort_by(|left, right| {
            repository_order
                .get(left.repo_id())
                .cmp(&repository_order.get(right.repo_id()))
                .then(left.path().cmp(right.path()))
                .then(left.byte_offset().cmp(&right.byte_offset()))
        });
        metadata.sort_by(|left, right| {
            repository_order
                .get(left.repo_id.as_str())
                .cmp(&repository_order.get(right.repo_id.as_str()))
                .then(left.path.cmp(&right.path))
        });
        notifications.sort_by(|left, right| {
            let path = |notice: &crate::CoreNotification| match notice {
                crate::CoreNotification::SyncConflict(conflict) => {
                    Some((conflict.repo_id.clone(), conflict.path.clone()))
                }
                crate::CoreNotification::SyncRequired => None,
            };
            match (path(left), path(right)) {
                (Some((left_repo, left_path)), Some((right_repo, right_path))) => repository_order
                    .get(left_repo.as_str())
                    .cmp(&repository_order.get(right_repo.as_str()))
                    .then(left_path.cmp(&right_path)),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            }
        });
        drop(guards);
        if changed {
            notifications.push(crate::CoreNotification::SyncRequired);
        }
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
        let results = queries
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
                        today,
                    ))
                }
                CoreQuery::File { query: file_query } => {
                    let files = metadata
                        .iter()
                        .filter(|file| {
                            query.needs_file(&file.repo_id, &file.path)
                                && file_matches_query(
                                    file_query,
                                    file,
                                    file_tags
                                        .get(&(file.repo_id.as_str(), file.path.as_str()))
                                        .unwrap_or(&BTreeSet::new()),
                                )
                        })
                        .cloned()
                        .collect();
                    CoreQueryResult::File(files)
                }
                CoreQuery::Notification { .. } => {
                    CoreQueryResult::Notification(notifications.clone())
                }
            })
            .collect();
        let files = if retain_data {
            metadata
                .into_iter()
                .map(|metadata| {
                    let file = loaded[&metadata.repo_id]
                        .iter()
                        .find(|file| file.path == metadata.path)
                        .expect("已加载文件");
                    (
                        metadata,
                        crate::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                    )
                })
                .collect()
        } else {
            Vec::new()
        };
        Ok(QuerySnapshot {
            results,
            tasks: if retain_data { all } else { Vec::new() },
            files,
            evaluated_on: Some(today),
        })
    }
}

#[derive(Default)]
pub(crate) struct QuerySnapshot {
    pub evaluated_on: Option<chrono::NaiveDate>,
    pub results: Vec<CoreQueryResult>,
    pub tasks: Vec<FilterTask>,
    pub files: Vec<(crate::OrgFileMetadata, String)>,
}

pub(crate) fn file_matches_query(
    query: &FileQuery,
    file: &crate::OrgFileMetadata,
    tags: &BTreeSet<&str>,
) -> bool {
    (query.include_ignored || !file.is_ignore)
        && query
            .is_project
            .is_none_or(|expected| file.project().is_some() == expected)
        && (query.file_tags.is_empty()
            || query
                .file_tags
                .iter()
                .any(|tag| tags.contains(tag.as_str())))
}

fn validate_query_file(file: &OrgFileRef) -> Result<(), CoreError> {
    crate::model::validate_relative_path(&file.path)?;
    if file.repo_id.is_empty() {
        return Err(CoreError::InvalidInput("查询文件的仓库 ID 不能为空"));
    }
    Ok(())
}

pub(crate) fn evaluate_query(
    query: &TaskQuery,
    mut all: Vec<FilterTask>,
    file_categories: &BTreeMap<(String, String), Option<String>>,
    today: chrono::NaiveDate,
) -> TaskQueryResult {
    Filter::parse(&query.expression).filter_tasks_at(&mut all, today);
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

/// 通用查询的可比较投影；只含标量，不携带任务正文或语法树。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum QueryOrderValue {
    Number(i64),
    Text(String),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryOrderPart {
    pub value: Option<QueryOrderValue>,
    pub descending: bool,
    pub missing_last: bool,
}
#[derive(Clone, Debug)]
pub struct QueryOrdering {
    filter: Option<Filter>,
    repo_ids: Vec<String>,
}
impl QueryOrdering {
    pub(crate) fn new(query: &CoreQuery, repo_ids: Vec<String>) -> Result<Self, CoreError> {
        Ok(Self {
            filter: match query {
                CoreQuery::Task { query, .. } => Some(Filter::parse(&query.expression)),
                CoreQuery::File { .. } => None,
                CoreQuery::Notification { .. } => {
                    return Err(CoreError::InvalidInput("通知查询不提供数据排序键"));
                }
            },
            repo_ids,
        })
    }
    fn repo_key(&self, repo_id: &str) -> QueryOrderPart {
        QueryOrderPart {
            value: Some(QueryOrderValue::Number(
                self.repo_ids
                    .iter()
                    .position(|id| id == repo_id)
                    .unwrap_or(self.repo_ids.len()) as i64,
            )),
            descending: false,
            missing_last: false,
        }
    }
    pub fn task_key(&self, task: &FilterTask) -> Vec<QueryOrderPart> {
        let mut keys = self
            .filter
            .as_ref()
            .map(|filter| filter.order_key(task))
            .unwrap_or_default();
        keys.push(self.repo_key(task.repo_id()));
        keys
    }
    pub fn file_key(&self, file: &crate::OrgFileMetadata) -> Vec<QueryOrderPart> {
        vec![
            self.repo_key(&file.repo_id),
            QueryOrderPart {
                value: Some(QueryOrderValue::Text(crate::filter::order_text(&file.path))),
                descending: false,
                missing_last: false,
            },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{NotificationQuery, OrgFile, OrgRepo};

    async fn workspace() -> OrgWorkspace {
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
        OrgWorkspace::start(
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
        ).await
        .unwrap()
    }

    #[tokio::test]
    async fn batch_preserves_positions_and_independent_results_with_one_access_per_repository() {
        let workspace = workspace().await;
        let before = workspace
            .repos()
            .iter()
            .map(|repo| crate::model::test_support::repository_accesses(&repo.root_directory))
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
            let after = crate::model::test_support::repository_accesses(&repo.root_directory);
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
        let workspace = workspace().await;
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
                exclude_files: vec![
                    broken.clone(),
                    OrgFileRef {
                        repo_id: repo.id.clone(),
                        path: "work.org".into(),
                    },
                ],
                ..Default::default()
            },
            TaskQuery {
                exclude_files: vec![broken.clone()],
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
        let workspace = workspace().await;
        let before = workspace
            .repos()
            .iter()
            .map(|repo| crate::model::test_support::repository_accesses(&repo.root_directory))
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
                        exclude_files: vec![OrgFileRef {
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
                crate::model::test_support::repository_accesses(&repo.root_directory),
                before
            );
        }
    }

    #[tokio::test]
    async fn mixed_queries_share_one_repository_access_and_keep_all_result_positions() {
        let workspace = workspace().await;
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
            .map(|repo| crate::model::test_support::repository_accesses(&repo.root_directory))
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
        assert!(notices.iter().any(|notice| matches!(notice, crate::CoreNotification::SyncConflict(conflict) if conflict.path == "conflict.org")));
        assert_eq!(
            notices
                .iter()
                .filter(|notice| matches!(notice, crate::CoreNotification::SyncRequired))
                .count(),
            1
        );
        assert_eq!(results[2], results[3]);
        for (repo, before) in workspace.repos().iter().zip(before) {
            let after = crate::model::test_support::repository_accesses(&repo.root_directory);
            assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        }
    }

    #[tokio::test]
    async fn file_queries_filter_sources_tags_and_project_status_without_modifying_task_queries() {
        let workspace = workspace().await;
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
        let before = crate::model::test_support::repository_accesses(&repo.root_directory);
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
                .unwrap().remove(0).into_files().unwrap().is_empty()
        );
        assert_eq!(
            crate::model::test_support::repository_accesses(&repo.root_directory),
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
            exclude_files: vec![
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
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        workspace
            .set_settings(crate::CoreSettings {
                addition_states: vec![crate::TaskState {
                    name: "OTHER".into(),
                    category: None,
                }],
            }).await
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
        let workspace = workspace().await;
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
        let workspace = workspace().await;
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
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
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
    async fn ui_can_request_inbox_using_file_scope_and_include_all_record_types() {
        let workspace = workspace().await;
        let query = TaskQuery {
            include_files: workspace.repos().iter().map(|repo| OrgFileRef {
                repo_id: repo.id.clone(), path: "capture.org".into(),
            }).collect(),
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
                    include_files: workspace.repos().iter().map(|repo| OrgFileRef {
                        repo_id: repo.id.clone(), path: "work.org".into(),
                    }).collect(),
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
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        let results = workspace.query(&[
            TaskQuery { expression: "has.address it.todo".into(), ..Default::default() }.into(),
            TaskQuery {
                expression: "has.address it.none".into(),
                include_files: vec![OrgFileRef { repo_id: workspace.repos()[0].id.clone(), path: "notes.org".into() }],
                ..Default::default()
            }.into(),
        ]).await.unwrap();
        let mut result = results[0].clone().into_task().unwrap();
        result.tasks.extend(results[1].clone().into_task().unwrap().tasks);
        result.tasks.sort_by(|left, right| left.path().cmp(right.path()).then(left.byte_offset().cmp(&right.byte_offset())));
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
        let workspace = OrgWorkspace::start(vec![repository]).await.unwrap();
        let result = workspace
            .query(&[(TaskQuery {
                expression: ".it.done s.none d.none".into(),

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
        let workspace = workspace().await;
        let mut repo = &mut workspace.repos()[0];
        {
            let value = OrgFile::new(repo.id.clone(), "undated.org".into(),
            "#+CATEGORY: Work\n#+TODO: NEXT | CLOSED\n* NEXT Undated task\n* Plain heading\n* CLOSED Completed task\n* NEXT Scheduled task\nSCHEDULED: <2026-11-09 Mon>\n* NEXT Deadline task\nDEADLINE: <2026-11-10 Tue>\n".as_bytes().to_vec()).unwrap();
            crate::model::test_support::push_file(&mut repo, value);
        };
        let result = workspace
            .query(&[(TaskQuery {
                expression: "it.todo s.none d.none".into(),

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
    async fn parent_tasks_remain_queryable_independently_of_their_children() {
        let workspace = workspace().await;
        let result = workspace
            .query(&[category_query().into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert!(
            result
                .tasks
                .iter()
                .any(|task| task.title() == "Parent home")
        );
        assert!(result.tasks.iter().any(|task| task.title() == "Child home"));
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            ..Default::default()
        };
        let result = workspace
            .query(&[query.into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].title(), "Parent home");
    }

    #[tokio::test]
    async fn unsafe_exclusions_are_rejected_and_json_defaults_are_generic() {
        let workspace = workspace().await;
        for path in ["", "../capture.org", "/capture.org", "a\\capture.org"] {
            assert!(
                workspace
                    .query(&[(TaskQuery {
                        exclude_files: vec![OrgFileRef {
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
