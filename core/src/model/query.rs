use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{CoreError, Filter, FilterTask, OrgWorkspace};

fn include_by_default() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct TaskQuery {
    pub expression: String,
    pub categories: Vec<Option<String>>,
    pub excluded_files: Vec<String>,
    pub include_done: bool,
    pub include_compose_tasks: bool,
}

impl Default for TaskQuery {
    fn default() -> Self {
        Self {
            expression: String::new(),
            categories: Vec::new(),
            excluded_files: Vec::new(),
            include_done: include_by_default(),
            include_compose_tasks: include_by_default(),
        }
    }
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

fn normalized_category(category: Option<String>) -> Option<String> {
    category.filter(|value| !value.is_empty())
}

impl OrgWorkspace {
    /// UI 组装通用查询；任务过滤、文件关联及组合任务判断统一在 core 中执行。
    pub fn query(&self, query: &TaskQuery) -> Result<TaskQueryResult, CoreError> {
        for path in &query.excluded_files {
            super::validate_relative_path(path)?;
        }
        let file_categories = self
            .repos()
            .iter()
            .flat_map(|repo| repo.files().iter())
            .map(|file| {
                (
                    (file.repo_id.clone(), file.path.clone()),
                    normalized_category(file.category()),
                )
            })
            .collect::<BTreeMap<_, _>>();
        let mut all = self
            .repos()
            .iter()
            .flat_map(crate::filter::tasks_from_repo)
            .collect::<Vec<_>>();
        // 必须在表达式过滤前判断，子任务未命中查询不代表父任务失去子任务。
        let parents = all
            .windows(2)
            .filter_map(|pair| {
                let (parent, child) = (&pair[0], &pair[1]);
                (parent.repo_id == child.repo_id
                    && parent.path == child.path
                    && child.level > parent.level)
                    .then(|| {
                        (
                            parent.repo_id.clone(),
                            parent.path.clone(),
                            parent.byte_offset,
                        )
                    })
            })
            .collect::<BTreeSet<_>>();
        Filter::parse(&query.expression).filter_tasks(&mut all);
        all.retain(|task| {
            (query.include_done || !task.is_done())
                && !query.excluded_files.contains(&task.path)
                && (query.include_compose_tasks
                    || !parents.contains(&(
                        task.repo_id.clone(),
                        task.path.clone(),
                        task.byte_offset,
                    )))
        });
        // 分类摘要不受当前 categories 选择影响，供 UI 展示可选分类和计数。
        let mut counts = BTreeMap::<Option<String>, usize>::new();
        for task in &all {
            let category = file_categories
                .get(&(task.repo_id.clone(), task.path.clone()))
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
                    .get(&(task.repo_id.clone(), task.path.clone()))
                    .cloned()
                    .flatten();
                selected.contains(&category)
            });
        }
        Ok(TaskQueryResult {
            tasks: all,
            categories,
        })
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
                "#+CATEGORY: Work\n#+TODO: CNCL | FINISHED\n* CNCL Pending cancel\n",
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
                    repo.files = sources
                        .iter()
                        .filter(|(repo_id, _, _)| *repo_id == id)
                        .map(|(_, path, source)| {
                            OrgFile::new(id.into(), (*path).into(), source.as_bytes().to_vec())
                                .unwrap()
                        })
                        .collect();
                    repo
                })
                .collect(),
        )
        .unwrap()
    }

    fn category_query() -> TaskQuery {
        TaskQuery {
            excluded_files: vec!["capture.org".into()],
            include_done: false,
            ..Default::default()
        }
    }

    #[test]
    fn generic_defaults_include_all_records_and_flags_filter_in_core() {
        let workspace = workspace();
        let result = workspace.query(&TaskQuery::default()).unwrap();
        assert_eq!(result.tasks.len(), 12);
        let result = workspace.query(&category_query()).unwrap();
        assert_eq!(result.tasks.len(), 6);
        assert!(
            result
                .tasks
                .iter()
                .all(|task| !task.is_done() && task.path != "capture.org")
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
            assert_eq!(workspace.query(&query).unwrap().tasks.len(), category.count);
        }
    }

    #[test]
    fn categories_are_values_with_union_and_empty_means_no_category_filter() {
        let workspace = workspace();
        let query = TaskQuery {
            categories: vec![
                Some("Work".into()),
                Some("Home".into()),
                Some("Work".into()),
            ],
            ..category_query()
        };
        assert_eq!(workspace.query(&query).unwrap().tasks.len(), 4);
        let query = TaskQuery {
            categories: vec![None],
            ..category_query()
        };
        assert_eq!(workspace.query(&query).unwrap().tasks.len(), 1);
        let query = TaskQuery {
            categories: vec![Some("未分类".into())],
            ..category_query()
        };
        assert_eq!(workspace.query(&query).unwrap().tasks.len(), 1);
        let query = TaskQuery {
            categories: vec![Some("gone".into())],
            ..category_query()
        };
        assert!(workspace.query(&query).unwrap().tasks.is_empty());
        assert_eq!(workspace.query(&category_query()).unwrap().tasks.len(), 6);
    }

    #[test]
    fn ui_can_request_inbox_using_expression_and_include_all_record_types() {
        let workspace = workspace();
        let query = TaskQuery {
            expression: "b.capture.org".into(),
            ..Default::default()
        };
        let result = workspace.query(&query).unwrap();
        assert_eq!(result.tasks.len(), 4);
        assert_eq!(result.tasks.iter().filter(|task| task.is_done()).count(), 2);
        assert!(result.tasks.iter().any(|task| task.state.is_none()));
        assert_eq!(
            workspace
                .query(&TaskQuery {
                    expression: "b.work.org".into(),
                    ..Default::default()
                })
                .unwrap()
                .tasks
                .len(),
            3
        );
    }

    #[test]
    fn compose_tasks_are_detected_before_expression_filter_and_respect_file_boundaries() {
        let workspace = workspace();
        let query = TaskQuery {
            include_compose_tasks: false,
            ..category_query()
        };
        assert_eq!(workspace.query(&query).unwrap().tasks.len(), 5);
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            include_compose_tasks: false,
            ..Default::default()
        };
        assert!(workspace.query(&query).unwrap().tasks.is_empty());
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            ..Default::default()
        };
        assert_eq!(workspace.query(&query).unwrap().tasks.len(), 1);
        let repos = [
            ("one", "* TODO Parent\n** DONE Child\n"),
            ("two", "* TODO Peer\n"),
        ]
        .into_iter()
        .map(|(id, source)| {
            let mut repo = OrgRepo::new(format!("/tmp/{id}")).unwrap();
            repo.id = id.into();
            repo.files.push(
                OrgFile::new(id.into(), "same.org".into(), source.as_bytes().to_vec()).unwrap(),
            );
            repo
        })
        .collect();
        let same_paths = OrgWorkspace::new(repos).unwrap();
        let result = same_paths
            .query(&TaskQuery {
                include_done: false,
                include_compose_tasks: false,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].title, "Peer");
    }

    #[test]
    fn unsafe_exclusions_are_rejected_and_json_defaults_are_generic() {
        let workspace = workspace();
        for path in ["", "../capture.org", "/capture.org", "a\\capture.org"] {
            assert!(
                workspace
                    .query(&TaskQuery {
                        excluded_files: vec![path.into()],
                        ..Default::default()
                    })
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
