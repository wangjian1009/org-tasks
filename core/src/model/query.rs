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

fn normalized_category(category: Option<String>) -> Option<String> {
    category.filter(|value| !value.is_empty())
}

impl OrgWorkspace {
    /// 一批查询共享同次文件加载；结果按输入顺序返回，任一错误使整批失败。
    pub async fn query(&self, queries: &[TaskQuery]) -> Result<Vec<TaskQueryResult>, CoreError> {
        if queries.is_empty() {
            return Ok(Vec::new());
        }
        for query in queries {
            for source in &query.excluded_files {
                super::validate_relative_path(&source.path)?;
                if source.repo_id.is_empty() {
                    return Err(CoreError::InvalidInput("排除文件的仓库 ID 不能为空"));
                }
            }
        }
        let today = chrono::Local::now().date_naive();
        let mut roots = BTreeMap::new();
        for repo in self.repos() {
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
        for repo in roots.values() {
            let mut exclusions = queries.iter().map(|query| {
                query
                    .excluded_files
                    .iter()
                    .filter(|source| source.repo_id == repo.id)
                    .map(|source| source.path.clone())
                    .collect::<BTreeSet<_>>()
            });
            let mut common = exclusions.next().expect("非空查询批次");
            for excluded in exclusions {
                common.retain(|path| excluded.contains(path));
            }
            let files = repo
                .load_files_unlocked(&common.into_iter().collect::<Vec<_>>())
                .await?;
            loaded.insert(repo.id.clone(), files);
        }
        drop(guards);
        let mut file_categories = BTreeMap::new();
        let mut all = Vec::new();
        // 加锁按规范化根目录排序，投影仍按原 workspace 顺序组装。
        let mut projected = BTreeSet::new();
        for repo in self.repos() {
            if !projected.insert(&repo.id) {
                continue;
            }
            let files = &loaded[&repo.id];
            for file in files.iter().filter(|file| !file.scan_ignored) {
                file_categories.insert(
                    (file.repo_id.clone(), file.path.clone()),
                    normalized_category(file.category()),
                );
                all.extend(crate::filter::tasks_from_file(repo, file));
            }
        }
        // 必须在表达式过滤前判断，子任务未命中查询不代表父任务失去子任务。
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
        Ok(queries
            .iter()
            .map(|query| {
                let excluded = query
                    .excluded_files
                    .iter()
                    .map(|source| (source.repo_id.as_str(), source.path.as_str()))
                    .collect::<BTreeSet<_>>();
                let tasks = all
                    .iter()
                    .filter(|task| !excluded.contains(&(task.repo_id(), task.path())))
                    .cloned()
                    .collect();
                evaluate_query(query, tasks, &file_categories, &parents, today)
            })
            .collect())
    }
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
        (query.include_done || !task.is_done())
            && (query.include_compose_tasks
                || !parents.contains(&(
                    task.repo_id().to_owned(),
                    task.path().to_owned(),
                    task.byte_offset,
                )))
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
                    { let value = sources
                        .iter()
                        .filter(|(repo_id, _, _)| *repo_id == id)
                        .map(|(_, path, source)| {
                            OrgFile::new(id.into(), (*path).into(), source.as_bytes().to_vec())
                                .unwrap()
                        })
                        .collect(); crate::model::test_support::write_files(&mut repo, value); }
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
        let mut results = workspace.query(&queries).await.unwrap();
        assert_eq!(results.len(), queries.len());
        assert!(results[1].tasks.is_empty());
        assert_eq!(results[2], results[5]);
        for (repo, before) in workspace.repos().iter().zip(before) {
            let after = super::super::test_support::repository_accesses(&repo.root_directory);
            assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        }
        for (query, result) in queries.iter().zip(&results) {
            let expected = workspace
                .query(std::slice::from_ref(query))
                .await
                .unwrap()
                .remove(0);
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
        let results = workspace.query(&queries).await.unwrap();
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
                .query(&[queries[0].clone(), TaskQuery::default()])
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
        assert!(workspace.query(&[]).await.unwrap().is_empty());
        for (repo_id, path) in [
            (workspace.repos()[0].id.clone(), "../unsafe.org"),
            (String::new(), "valid.org"),
        ] {
            let error = workspace
                .query(&[
                    TaskQuery::default(),
                    TaskQuery {
                        excluded_files: vec![OrgFileRef {
                            repo_id,
                            path: path.into(),
                        }],
                        ..Default::default()
                    },
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
            include_done: false,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn generic_defaults_include_all_records_and_flags_filter_in_core() {
        let workspace = workspace();
        let result = workspace.query(&[TaskQuery::default()]).await.unwrap().remove(0);
        assert_eq!(result.tasks.len(), 12);
        let result = workspace.query(&[category_query()]).await.unwrap().remove(0);
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
            assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), category.count);
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
        assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), 4);
        let query = TaskQuery {
            categories: vec![None],
            ..category_query()
        };
        assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), 1);
        let query = TaskQuery {
            categories: vec![Some("未分类".into())],
            ..category_query()
        };
        assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), 1);
        let query = TaskQuery {
            categories: vec![Some("gone".into())],
            ..category_query()
        };
        assert!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.is_empty());
        assert_eq!(workspace.query(&[category_query()]).await.unwrap().remove(0).tasks.len(), 6);
    }

    #[tokio::test]
    async fn archive_file_category_is_hidden_from_task_projection_and_summary() {
        let mut repo = OrgRepo::new("/tmp/archive-category".into()).unwrap();
        repo.id = "archive".into();
        { let value =
            OrgFile::new(
                repo.id.clone(),
                "archive.org".into(),
                b"#+CATEGORY: ARCHIVE\n* TODO Archived\n".to_vec(),
            )
            .unwrap(); crate::model::test_support::push_file(&mut repo, value); };
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let result = workspace.query(&[TaskQuery::default()]).await.unwrap().remove(0);
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
        let result = workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0);
        assert_eq!(result.tasks.len(), 4);
        assert_eq!(result.tasks.iter().filter(|task| task.is_done()).count(), 2);
        assert!(result.tasks.iter().any(|task| task.state.is_none()));
        assert_eq!(
            workspace
                .query(&[TaskQuery {
                    expression: "b.work.org".into(),
                    ..Default::default()
                }]).await
                .unwrap().remove(0)
                .tasks
                .len(),
            3
        );
    }

    #[tokio::test]
    async fn address_query_uses_real_links_and_combines_state_and_configured_note_file() {
        let mut repo = OrgRepo::new("/tmp/address-query".into()).unwrap();
        repo.id = "repo".into();
        { let value = [
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
        }).collect(); crate::model::test_support::write_files(&mut repo, value); }
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let query = TaskQuery {
            expression: "has.address (it.todo or (b.notes.org it.none))".into(),
            include_done: false,
            ..Default::default()
        };
        let result = workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0);
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
            .query(&[TaskQuery {
                expression: ".has.address".into(),
                ..Default::default()
            }]).await
            .unwrap().remove(0);
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
        { let value = vec![
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
        ]; crate::model::test_support::write_files(&mut repository, value); }
        { let value = crate::TaskScanRules::parse("ann.org\n").unwrap(); crate::model::test_support::set_rules(&mut repository, value); }
        let workspace = OrgWorkspace::new(vec![repository]).unwrap();
        let result = workspace
            .query(&[TaskQuery {
                expression: "s.none d.none".into(),
                include_done: false,
                include_compose_tasks: true,
                ..Default::default()
            }]).await
            .unwrap().remove(0);
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].path(), "visible.org");
    }

    #[tokio::test]
    async fn pending_undated_task_query_excludes_notes_done_and_either_planning_field() {
        let mut workspace = workspace();
        let mut repo = &mut workspace.repos[0];
        { let value = OrgFile::new(repo.id.clone(), "undated.org".into(),
            "#+CATEGORY: Work\n#+TODO: NEXT | CLOSED\n* NEXT Undated task\n* Plain heading\n* CLOSED Completed task\n* NEXT Scheduled task\nSCHEDULED: <2026-11-09 Mon>\n* NEXT Deadline task\nDEADLINE: <2026-11-10 Tue>\n".as_bytes().to_vec()).unwrap(); crate::model::test_support::push_file(&mut repo, value); };
        let result = workspace.query(&[TaskQuery {
            expression: "it.todo s.none d.none".into(), include_done: false, include_compose_tasks: true,
            ..Default::default()
        }]).await.unwrap().remove(0);
        let titles = result.tasks.iter().filter(|task| task.path() == "undated.org").map(|task| task.title()).collect::<Vec<_>>();
        assert_eq!(titles, ["Undated task"]);
        assert!(result.tasks.iter().all(|task| task.state_type() == crate::FilterStateType::Todo && task.scheduled().is_none() && task.deadline().is_none()));
    }

    #[tokio::test]
    async fn compose_tasks_are_detected_before_expression_filter_and_respect_file_boundaries() {
        let workspace = workspace();
        let query = TaskQuery {
            include_compose_tasks: false,
            ..category_query()
        };
        assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), 5);
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            include_compose_tasks: false,
            ..Default::default()
        };
        assert!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.is_empty());
        let query = TaskQuery {
            expression: "\"Parent home\"".into(),
            ..Default::default()
        };
        assert_eq!(workspace.query(std::slice::from_ref(&query)).await.unwrap().remove(0).tasks.len(), 1);
        let repos = [
            ("one", "* TODO Parent\n** DONE Child\n"),
            ("two", "* TODO Peer\n"),
        ]
        .into_iter()
        .map(|(id, source)| {
            let mut repo = OrgRepo::new(format!("/tmp/{id}")).unwrap();
            repo.id = id.into();
            { let value =
                OrgFile::new(id.into(), "same.org".into(), source.as_bytes().to_vec()).unwrap(); crate::model::test_support::push_file(&mut repo, value); };
            repo
        })
        .collect();
        let same_paths = OrgWorkspace::new(repos).unwrap();
        let result = same_paths
            .query(&[TaskQuery {
                include_done: false,
                include_compose_tasks: false,
                ..Default::default()
            }]).await
            .unwrap().remove(0);
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].title, "Peer");
    }

    #[tokio::test]
    async fn unsafe_exclusions_are_rejected_and_json_defaults_are_generic() {
        let workspace = workspace();
        for path in ["", "../capture.org", "/capture.org", "a\\capture.org"] {
            assert!(
                workspace
                    .query(&[TaskQuery {
                        excluded_files: vec![OrgFileRef {
                            repo_id: crate::model::test_support::id("r1"),
                            path: path.into()
                        }],
                        ..Default::default()
                    }]).await
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
