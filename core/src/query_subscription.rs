//! 查询与数据监控的一次性启动接口；长期状态只保留成员身份、文件版本和分类计数。
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Arc, Mutex};

use crate::query::{
    evaluate_query, file_matches_query, normalized_category,
};
use crate::model::{
    CoreQuery, CoreQueryResult, DataChangeEvent, DataChangeSubscription, FileDataChange,
    OrgFileMetadata, OrgFileRef, TaskCategory, TaskDataChange, TaskDataChangeKind,
    TaskDataSnapshot, TaskQueryResult,
};
use crate::{CoreError, FilterTask};

type FileKey = (String, String);
type Members = BTreeMap<FileKey, BTreeSet<String>>;
const MAX_PENDING_EVENTS: usize = 256;

/// 批量启动中的一个独立查询与回调；批次只共享初始文件加载。
pub struct QuerySubscriptionRequest {
    pub query: CoreQuery,
    pub callback: Box<dyn Fn(DataChangeEvent) + Send + Sync>,
}

impl QuerySubscriptionRequest {
    pub fn new<F>(query: CoreQuery, callback: F) -> Self
    where
        F: Fn(DataChangeEvent) + Send + Sync + 'static,
    {
        Self { query, callback: Box::new(callback) }
    }
}

/// 初始数据归调用方所有，订阅不会保存其副本。
pub struct QuerySubscriptionStart {
    pub data: CoreQueryResult,
    pub subscription: QuerySubscription,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuerySubscriptionStatus {
    Current,
    AwaitingEvents,
    Invalidated,
    Closed,
}

pub struct QuerySubscription {
    hub: Arc<Hub>,
    watch: Option<DataChangeSubscription>,
}

impl QuerySubscription {
    pub(crate) fn status(&self) -> QuerySubscriptionStatus {
        if self.watch.as_ref().is_some_and(|watch| !watch.subscription.is_active()) {
            return QuerySubscriptionStatus::Closed;
        }
        self.hub.state.lock().unwrap().status()
    }
    pub(crate) fn cancel(&mut self) {
        {
            let mut state = self.hub.state.lock().unwrap();
            state.closed = true;
            state.pending.clear();
            state.outgoing.clear();
            state.members.clear();
            state.versions.clear();
            state.counts.clear();
        }
        self.watch.take();
    }
}
impl Drop for QuerySubscription {
    fn drop(&mut self) {
        self.cancel();
    }
}

struct Hub {
    state: Mutex<State>,
    callback: Box<dyn Fn(DataChangeEvent) + Send + Sync>,
}

struct State {
    query: CoreQuery,
    today: chrono::NaiveDate,
    ready: bool,
    closed: bool,
    invalidated: bool,
    members: Members,
    versions: BTreeMap<FileKey, String>,
    counts: BTreeMap<FileKey, Vec<TaskCategory>>,
    pending: Vec<DataChangeEvent>,
    outgoing: VecDeque<DataChangeEvent>,
    dispatching: bool,
}

pub(crate) fn prepare<F>(query: CoreQuery, on_change: F) -> Result<QuerySubscription, CoreError>
where
    F: Fn(DataChangeEvent) + Send + Sync + 'static,
{
    if matches!(query, CoreQuery::Notification { .. }) {
        return Err(CoreError::InvalidInput(
            "查询订阅只支持任务和文件数据，不支持通知查询",
        ));
    }
    Ok(QuerySubscription {
        hub: Arc::new(Hub {
            state: Mutex::new(State::new(query)),
            callback: Box::new(on_change),
        }),
        watch: None,
    })
}

impl QuerySubscription {
    pub(crate) fn monitor(&self) -> Box<dyn Fn(DataChangeEvent) + Send + Sync> {
        let hub = self.hub.clone();
        Box::new(move |event| hub.receive(event))
    }
    pub(crate) fn attach(&mut self, watch: DataChangeSubscription) {
        self.watch = Some(watch);
    }
    pub(crate) fn initialize(
        &self,
        mut data: CoreQueryResult,
        snapshot: &crate::query::QuerySnapshot,
        repo_order: &[String],
    ) -> CoreQueryResult {
        {
            let mut state = self.hub.state.lock().unwrap();
            state.today = snapshot.evaluated_on.expect("非空启动查询具有求值日期");
            state.members = members_from_result(&data);
            let mut tasks_by_file = BTreeMap::<FileKey, Vec<FilterTask>>::new();
            for task in &snapshot.tasks {
                tasks_by_file.entry(task_key(task)).or_default().push(task.clone());
            }
            for (file, version) in &snapshot.files {
                if !state.query.needs_file(&file.repo_id, &file.path) { continue; }
                let key = file_key(file);
                if let CoreQuery::Task { query, .. } = &state.query {
                    let tasks = tasks_by_file.remove(&key).unwrap_or_default();
                    let categories = task_result(query, &file, tasks, state.today).categories;
                    state.counts.insert(key.clone(), categories);
                }
                state.versions.insert(key, version.clone());
            }
            // 查询期间排队的事件若已包含在快照中则去重，其余增量合并进返回数据。
            let events = state.drain();
            for event in events {
                apply_initial(&mut data, &event);
            }
            match &mut data {
                CoreQueryResult::Task(result) => {
                    // 普通查询的稳定排序以仓库遍历顺序为基础；补入启动增量后先恢复这个基础顺序。
                    result.tasks.sort_by_key(|task| {
                        (
                            repo_order
                                .iter()
                                .position(|id| id == task.repo_id())
                                .unwrap_or(usize::MAX),
                            task.path().to_owned(),
                            task.byte_offset(),
                        )
                    });
                    if let CoreQuery::Task { query, .. } = &state.query {
                        crate::filter::Filter::parse(&query.expression)
                            .sort_tasks(&mut result.tasks);
                    }
                    result.categories = state.categories();
                }
                CoreQueryResult::File(files) => files.sort_by_key(|file| {
                    (
                        repo_order
                            .iter()
                            .position(|id| id == &file.repo_id)
                            .unwrap_or(usize::MAX),
                        file.path.clone(),
                    )
                }),
                CoreQueryResult::Notification(_) => unreachable!(),
            }
            state.ready = true;
        }
        data
    }
}

impl Hub {
    fn receive(&self, event: DataChangeEvent) {
        {
            let mut state = self.state.lock().unwrap();
            if state.closed {
                return;
            }
            let DataChangeEvent::RepositoryChanged { repo_id, files, .. } = &event;
            if !state.query.includes_repo(repo_id) {
                return;
            }
            if files.is_none() {
                // 旧同步、重载等入口没有数据载荷；不伪造增量，也不在这里发起查询。
                state.invalidated = true;
                return;
            }
            if !files.as_ref().unwrap().iter().any(|file| {
                state
                    .query
                    .needs_file(&file.after.repo_id, &file.after.path)
            }) {
                return;
            }
            state.pending.push(event);
            if state.pending.len() > MAX_PENDING_EVENTS {
                state.pending.clear();
                state.invalidated = true;
            }
            if !state.ready {
                return;
            }
            let events = state.drain();
            state.outgoing.extend(events);
            if state.outgoing.len() > MAX_PENDING_EVENTS {
                state.outgoing.clear();
                state.invalidated = true;
            }
            if state.dispatching {
                return;
            }
            state.dispatching = true;
        }
        loop {
            let event = {
                let mut state = self.state.lock().unwrap();
                if state.closed {
                    state.outgoing.clear();
                }
                match state.outgoing.pop_front() {
                    Some(event) => event,
                    None => {
                        state.dispatching = false;
                        return;
                    }
                }
            };
            // 用户回调在状态锁外运行；串行分发保证并发提交不会倒置本订阅的通知。
            (self.callback)(event);
        }
    }
}

impl State {
    fn new(query: CoreQuery) -> Self {
        Self {
            query,
            today: chrono::Local::now().date_naive(),
            ready: false,
            closed: false,
            invalidated: false,
            members: BTreeMap::new(),
            versions: BTreeMap::new(),
            counts: BTreeMap::new(),
            pending: Vec::new(),
            outgoing: VecDeque::new(),
            dispatching: false,
        }
    }
    fn status(&self) -> QuerySubscriptionStatus {
        if self.closed {
            QuerySubscriptionStatus::Closed
        } else if self.invalidated
            || (matches!(self.query, CoreQuery::Task { .. })
                && self.today != chrono::Local::now().date_naive())
        {
            QuerySubscriptionStatus::Invalidated
        } else if !self.pending.is_empty() {
            QuerySubscriptionStatus::AwaitingEvents
        } else {
            QuerySubscriptionStatus::Current
        }
    }
    fn categories(&self) -> Vec<TaskCategory> {
        let mut counts = BTreeMap::<Option<String>, usize>::new();
        for category in self.counts.values().flatten() {
            *counts.entry(category.category.clone()).or_default() += category.count;
        }
        let mut categories = counts
            .into_iter()
            .map(|(category, count)| TaskCategory {
                key: category
                    .as_ref()
                    .map_or_else(|| "uncategorized".into(), |name| format!("category:{name}")),
                category,
                count,
            })
            .collect::<Vec<_>>();
        categories.sort_by_key(|category| (category.category.is_none(), category.category.clone()));
        categories
    }

    fn drain(&mut self) -> Vec<DataChangeEvent> {
        let mut output = Vec::new();
        // 版本图仅在本轮排队事件中暂存，用于剔除启动快照已经包含的完整历史链。
        let mut covered = self
            .versions
            .iter()
            .map(|(key, version)| (key.clone(), BTreeSet::from([version.clone()])))
            .collect::<BTreeMap<_, _>>();
        loop {
            let mut progress = false;
            loop {
                let mut expanded = false;
                for event in &self.pending {
                    let DataChangeEvent::RepositoryChanged {
                        files: Some(files), ..
                    } = event
                    else {
                        continue;
                    };
                    for file in files {
                        let seen = covered.entry(file_key(&file.after)).or_default();
                        if seen.contains(&file.after_version) {
                            if let Some(before) = &file.before_version {
                                expanded |= seen.insert(before.clone());
                            }
                        }
                    }
                }
                if !expanded {
                    break;
                }
            }
            let pending = std::mem::take(&mut self.pending);
            for event in pending {
                let DataChangeEvent::RepositoryChanged {
                    repo_id,
                    operation_id,
                    files,
                    changes,
                    ..
                } = event;
                let mut ready = Vec::new();
                let mut waiting = Vec::new();
                for file in files.unwrap_or_default() {
                    let key = file_key(&file.after);
                    if !self.query.needs_file(&key.0, &key.1) {
                        continue;
                    }
                    if covered
                        .get(&key)
                        .is_some_and(|seen| seen.contains(&file.after_version))
                    {
                        progress = true;
                        continue;
                    }
                    if self.versions.get(&key) == file.before_version.as_ref() {
                        ready.push(file);
                    } else {
                        waiting.push(file);
                    }
                }
                if !ready.is_empty() {
                    progress = true;
                    for file in &ready {
                        covered
                            .entry(file_key(&file.after))
                            .or_default()
                            .insert(file.after_version.clone());
                    }
                    if let Some(event) = self.apply(&repo_id, operation_id.clone(), ready, &changes)
                    {
                        output.push(event);
                    }
                }
                if !waiting.is_empty() {
                    self.pending.push(DataChangeEvent::RepositoryChanged {
                        repo_id,
                        operation_id,
                        files: Some(waiting),
                        changes,
                        removed_files: Vec::new(),
                        categories: None,
                    });
                }
            }
            if !progress {
                break;
            }
        }
        output
    }

    fn apply(
        &mut self,
        repo_id: &str,
        operation_id: Option<String>,
        files: Vec<FileDataChange>,
        raw: &[TaskDataChange],
    ) -> Option<DataChangeEvent> {
        let keys = files
            .iter()
            .map(|file| file_key(&file.after))
            .collect::<BTreeSet<_>>();
        let before_members = keys
            .iter()
            .filter_map(|key| self.members.get(key).map(|ids| (key.clone(), ids.clone())))
            .collect::<Members>();
        let before_categories = self.categories();
        let mut selected_files = Vec::new();
        let mut removed_files = Vec::new();
        for mut file in files {
            let key = file_key(&file.after);
            let mut tasks = raw
                .iter()
                .filter_map(|change| change.after.as_ref())
                .filter(|snapshot| task_key(&snapshot.task) == key)
                .map(|snapshot| snapshot.task.clone())
                .collect::<Vec<_>>();
            tasks.sort_by_key(FilterTask::byte_offset);
            self.members.remove(&key);
            match &self.query {
                CoreQuery::Task { query, .. } => {
                    let result = task_result(query, &file.after, tasks, self.today);
                    let ids = result
                        .tasks
                        .iter()
                        .map(|task| task.id().to_owned())
                        .collect();
                    self.members.insert(key.clone(), ids);
                    self.counts.insert(key.clone(), result.categories);
                    selected_files.push(file.clone());
                }
                CoreQuery::File { query } => {
                    let tags = tasks
                        .iter()
                        .flat_map(|task| task.own_tags().iter().chain(task.inherited_tags()))
                        .map(String::as_str)
                        .collect();
                    if file_matches_query(query, &file.after, &tags) {
                        if !before_members.contains_key(&key) {
                            file.before = None;
                            file.before_version = None;
                        }
                        self.members
                            .insert(key.clone(), BTreeSet::from([String::new()]));
                        selected_files.push(file.clone());
                    } else if before_members.contains_key(&key) {
                        removed_files.push(OrgFileRef {
                            repo_id: key.0.clone(),
                            path: key.1.clone(),
                        });
                    }
                }
                CoreQuery::Notification { .. } => unreachable!(),
            }
            self.versions.insert(key, file.after_version);
        }
        let changes = if matches!(self.query, CoreQuery::Task { .. }) {
            raw.iter()
                .filter_map(|change| {
                    let before = change
                        .before
                        .as_ref()
                        .filter(|snapshot| {
                            keys.contains(&task_key(&snapshot.task))
                                && contains(&before_members, &snapshot.task)
                        })
                        .cloned()
                        .map(display_snapshot);
                    let after = change
                        .after
                        .as_ref()
                        .filter(|snapshot| {
                            keys.contains(&task_key(&snapshot.task))
                                && contains(&self.members, &snapshot.task)
                        })
                        .cloned()
                        .map(display_snapshot);
                    let kind = match (&before, &after) {
                        (None, None) => return None,
                        (None, Some(_)) => TaskDataChangeKind::Created,
                        (Some(_), None) => TaskDataChangeKind::Deleted,
                        (Some(_), Some(_)) if change.kind == TaskDataChangeKind::Moved => {
                            TaskDataChangeKind::Moved
                        }
                        (Some(_), Some(_)) => TaskDataChangeKind::Updated,
                    };
                    Some(TaskDataChange {
                        kind,
                        before,
                        after,
                    })
                })
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let categories = matches!(self.query, CoreQuery::Task { .. }).then(|| self.categories());
        let category_changed = categories
            .as_ref()
            .is_some_and(|categories| categories != &before_categories);
        if changes.is_empty()
            && removed_files.is_empty()
            && !category_changed
            && (matches!(self.query, CoreQuery::Task { .. }) || selected_files.is_empty())
        {
            return None;
        }
        Some(DataChangeEvent::RepositoryChanged {
            repo_id: repo_id.into(),
            operation_id,
            files: Some(selected_files),
            changes,
            removed_files,
            categories,
        })
    }
}

fn file_key(file: &OrgFileMetadata) -> FileKey {
    (file.repo_id.clone(), file.path.clone())
}
fn task_key(task: &FilterTask) -> FileKey {
    (task.repo_id().into(), task.path().into())
}
fn contains(members: &Members, task: &FilterTask) -> bool {
    members
        .get(&task_key(task))
        .is_some_and(|ids| ids.contains(task.id()))
}
fn display_snapshot(mut snapshot: TaskDataSnapshot) -> TaskDataSnapshot {
    snapshot.task.exclude_system_tags();
    snapshot
}
fn task_result(
    query: &crate::TaskQuery,
    file: &OrgFileMetadata,
    tasks: Vec<FilterTask>,
    today: chrono::NaiveDate,
) -> TaskQueryResult {
    let categories = BTreeMap::from([(file_key(file), normalized_category(file.category.clone()))]);
    evaluate_query(
        query,
        if file.is_ignore { Vec::new() } else { tasks },
        &categories,
        today,
    )
}
fn members_from_result(data: &CoreQueryResult) -> Members {
    let mut members = Members::new();
    match data {
        CoreQueryResult::Task(result) => {
            for task in &result.tasks {
                members
                    .entry(task_key(task))
                    .or_default()
                    .insert(task.id().into());
            }
        }
        CoreQueryResult::File(files) => {
            for file in files {
                members.insert(file_key(file), BTreeSet::from([String::new()]));
            }
        }
        CoreQueryResult::Notification(_) => unreachable!(),
    }
    members
}
fn apply_initial(data: &mut CoreQueryResult, event: &DataChangeEvent) {
    let DataChangeEvent::RepositoryChanged {
        files,
        changes,
        removed_files,
        categories,
        ..
    } = event;
    match data {
        CoreQueryResult::Task(result) => {
            let removed = changes
                .iter()
                .filter_map(|change| change.before.as_ref())
                .map(|snapshot| (task_key(&snapshot.task), snapshot.task.id().to_owned()))
                .collect::<BTreeSet<_>>();
            result
                .tasks
                .retain(|task| !removed.contains(&(task_key(task), task.id().to_owned())));
            result.tasks.extend(
                changes
                    .iter()
                    .filter_map(|change| change.after.as_ref())
                    .map(|snapshot| snapshot.task.clone()),
            );
            if let Some(categories) = categories {
                result.categories = categories.clone();
            }
        }
        CoreQueryResult::File(result) => {
            let changed = files
                .iter()
                .flatten()
                .map(|file| file_key(&file.after))
                .chain(
                    removed_files
                        .iter()
                        .map(|file| (file.repo_id.clone(), file.path.clone())),
                )
                .collect::<BTreeSet<_>>();
            result.retain(|file| !changed.contains(&file_key(file)));
            result.extend(files.iter().flatten().map(|file| file.after.clone()));
        }
        CoreQueryResult::Notification(_) => unreachable!(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        OrgRepo, OrgWorkspace, TaskFileVersion, TaskModification, TaskModificationOperation,
        TaskOperation, TaskOperationGroup, TaskPath, TaskQuery, webdav::WebDavSyncPolicy,
    };

    struct Fixture {
        root: std::path::PathBuf,
        workspace: OrgWorkspace,
        raw: Arc<Mutex<Vec<DataChangeEvent>>>,
        _watch: DataChangeSubscription,
        title: String,
    }
    impl Fixture {
        async fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!(
                "query-subscription-unit-{}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            std::fs::create_dir(&root).unwrap();
            std::fs::write(root.join("a.org"), "* TODO A\n").unwrap();
            let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            repo.load::<WebDavSyncPolicy>().await.unwrap();
            let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
            let raw = Arc::new(Mutex::new(Vec::new()));
            let capture = raw.clone();
            let _watch =
                workspace.watch_data_changes(move |event| capture.lock().unwrap().push(event));
            Self {
                root,
                workspace,
                raw,
                _watch,
                title: "A".into(),
            }
        }
        fn query(&self) -> CoreQuery {
            TaskQuery::default().into()
        }
        async fn change(&mut self, title: &str) {
            self.workspace
                .execute_task_operations(&TaskOperationGroup {
                    operation_id: Some("same-operation".into()),
                    operations: vec![TaskOperation::Modification(TaskModificationOperation {
                        path: TaskPath {
                            repo_id: self.workspace.repos()[0].id.clone(),
                            file: Some("a.org".into()),
                            titles: vec![self.title.clone()],
                            occurrence: 1,
                        },
                        modifications: vec![TaskModification::Title(Some(title.into()))],
                    })],
                    file_versions: Vec::<TaskFileVersion>::new(),
                })
                .await
                .unwrap();
            self.title = title.into();
        }
        fn pending(&self) -> (QuerySubscription, Arc<Mutex<Vec<DataChangeEvent>>>) {
            let events = Arc::new(Mutex::new(Vec::new()));
            let capture = events.clone();
            let mut subscription = prepare(self.query(), move |event| {
                capture.lock().unwrap().push(event)
            })
            .unwrap();
            subscription.attach(self.workspace.watch_data_changes(subscription.monitor()));
            (subscription, events)
        }
        async fn snapshot(&self) -> crate::query::QuerySnapshot {
            self.workspace
                .query_snapshot(&[self.query()], true)
                .await
                .unwrap()
        }
        fn finish(
            &self,
            subscription: &QuerySubscription,
            snapshot: crate::query::QuerySnapshot,
        ) -> CoreQueryResult {
            subscription.initialize(snapshot.results[0].clone(), &snapshot, &[self.workspace.repos()[0].id.clone()])
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[tokio::test]
    async fn workspace_start_loads_once_and_modifications_never_requery() {
        let mut f = Fixture::new().await;
        let before = crate::model::test_support::repository_accesses(f.root.to_str().unwrap())[1];
        let started = f
            .workspace
            .subscribe_query(vec![QuerySubscriptionRequest::new(f.query(), |_| {})])
            .await
            .unwrap().remove(0);
        assert_eq!(
            crate::model::test_support::repository_accesses(f.root.to_str().unwrap())[1],
            before + 1
        );
        f.change("B").await;
        f.change("C").await;
        assert_eq!(
            crate::model::test_support::repository_accesses(f.root.to_str().unwrap())[1],
            before + 1
        );
        assert_eq!(
            started.subscription.status(),
            QuerySubscriptionStatus::Current
        );
    }

    #[tokio::test]
    async fn batch_shares_loading_but_keeps_callbacks_results_and_cancellation_independent() {
        let mut f = Fixture::new().await;
        let first = Arc::new(Mutex::new(Vec::new()));
        let second = Arc::new(Mutex::new(Vec::new()));
        let files = Arc::new(Mutex::new(Vec::new()));
        let capture_first = first.clone();
        let capture_second = second.clone();
        let capture_files = files.clone();
        let before = crate::model::test_support::repository_accesses(f.root.to_str().unwrap());
        let mut started = f.workspace.subscribe_query(vec![
            QuerySubscriptionRequest::new(f.query(), move |event| capture_first.lock().unwrap().push(event)),
            QuerySubscriptionRequest::new(TaskQuery { expression: "it.done".into(), ..Default::default() }.into(),
                move |event| capture_second.lock().unwrap().push(event)),
            QuerySubscriptionRequest::new(CoreQuery::File { query: Default::default() },
                move |event| capture_files.lock().unwrap().push(event)),
            QuerySubscriptionRequest::new(f.query(), |_| {}),
        ]).await.unwrap();
        let after = crate::model::test_support::repository_accesses(f.root.to_str().unwrap());
        assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        assert_eq!(started.len(), 4);
        assert_eq!(started[0].data, started[3].data);
        assert_eq!(started[0].data.clone().into_task().unwrap().tasks.len(), 1);
        assert!(started[1].data.clone().into_task().unwrap().tasks.is_empty());
        assert_eq!(started[2].data.clone().into_files().unwrap().len(), 1);
        f.change("B").await;
        assert_eq!(first.lock().unwrap().len(), 1);
        assert!(second.lock().unwrap().is_empty());
        let event = files.lock().unwrap()[0].clone();
        let DataChangeEvent::RepositoryChanged { changes, files: changed_files, .. } = event;
        assert!(changes.is_empty());
        assert_eq!(changed_files.unwrap().len(), 1);
        f.workspace.unsubscribe_query(&mut started[0].subscription);
        f.change("C").await;
        assert_eq!(first.lock().unwrap().len(), 1);
        assert_eq!(files.lock().unwrap().len(), 2);
        assert_eq!(started[0].subscription.status(), QuerySubscriptionStatus::Closed);
        assert_eq!(started[2].subscription.status(), QuerySubscriptionStatus::Current);
        assert_eq!(crate::model::test_support::repository_accesses(f.root.to_str().unwrap())[1], after[1]);
    }

    #[tokio::test]
    async fn inbox_batch_scans_once_and_reads_each_file_once() {
        let f = Fixture::new().await;
        let recent_path = f.root.join("recent.org");
        let today = chrono::Local::now().format("%Y-%m-%d %a %H:%M");
        std::fs::write(&recent_path, format!("* TODO Recent\n:PROPERTIES:\n:CREATED: [{today}]\n:END:\n")).unwrap();
        let reference = OrgFileRef { repo_id: f.workspace.repos()[0].id.clone(), path: "a.org".into() };
        let root = f.root.to_str().unwrap();
        let before = crate::model::test_support::repository_accesses(root);
        let paths = [f.root.join("a.org"), recent_path];
        let reads = paths.each_ref().map(|path| crate::model::test_support::file_accesses(path));
        let started = f.workspace.subscribe_query(vec![
            QuerySubscriptionRequest::new(TaskQuery { include_files: vec![reference.clone()], ..Default::default() }.into(), |_| {}),
            QuerySubscriptionRequest::new(CoreQuery::File { query: crate::FileQuery { include_files: vec![reference.clone()], ..Default::default() } }, |_| {}),
            QuerySubscriptionRequest::new(TaskQuery { expression: "cr.ge.-2d cr.le.today .o.created".into(), exclude_files: vec![reference], ..Default::default() }.into(), |_| {}),
            QuerySubscriptionRequest::new(CoreQuery::File { query: Default::default() }, |_| {}),
        ]).await.unwrap();
        let after = crate::model::test_support::repository_accesses(root);
        assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 1]);
        for (path, before) in paths.iter().zip(reads) {
            let after = crate::model::test_support::file_accesses(path);
            assert_eq!([after[0] - before[0], after[1] - before[1]], [1, 0], "{}", path.display());
        }
        assert_eq!(started.len(), 4);
        assert_eq!(started[0].data.clone().into_task().unwrap().tasks.len(), 1);
        assert_eq!(started[1].data.clone().into_files().unwrap().len(), 1);
        assert_eq!(started[2].data.clone().into_task().unwrap().tasks.len(), 1);
        assert_eq!(started[3].data.clone().into_files().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn batch_initial_categories_and_versions_respect_each_query_file_scope() {
        let f = Fixture::new().await;
        std::fs::write(f.root.join("other.org"), "#+CATEGORY: Other\n* TODO Other\n").unwrap();
        let reference = OrgFileRef { repo_id: f.workspace.repos()[0].id.clone(), path: "a.org".into() };
        let started = f.workspace.subscribe_query(vec![
            QuerySubscriptionRequest::new(TaskQuery { include_files: vec![reference], ..Default::default() }.into(), |_| {}),
            QuerySubscriptionRequest::new(f.query(), |_| {}),
        ]).await.unwrap();
        let scoped = started[0].data.clone().into_task().unwrap();
        let all = started[1].data.clone().into_task().unwrap();
        assert_eq!(scoped.tasks.len(), 1);
        assert_eq!(scoped.categories.iter().map(|category| category.count).sum::<usize>(), 1);
        assert_eq!(all.tasks.len(), 2);
        assert_eq!(all.categories.iter().map(|category| category.count).sum::<usize>(), 2);
        assert_eq!(started[0].subscription.hub.state.lock().unwrap().versions.len(), 1);
        assert_eq!(started[1].subscription.hub.state.lock().unwrap().versions.len(), 2);
    }

    #[tokio::test]
    async fn empty_and_invalid_subscription_batches_do_not_load_files_or_leave_observers() {
        let f = Fixture::new().await;
        let before = crate::model::test_support::repository_accesses(f.root.to_str().unwrap());
        assert!(f.workspace.subscribe_query(vec![]).await.unwrap().is_empty());
        let token = Arc::new(());
        let weak = Arc::downgrade(&token);
        let requests = vec![
            QuerySubscriptionRequest::new(f.query(), move |_| { let _keep_alive = &token; }),
            QuerySubscriptionRequest::new(TaskQuery { expression: "b.invalid".into(), ..Default::default() }.into(), |_| {}),
        ];
        assert!(f.workspace.subscribe_query(requests).await.is_err());
        f.workspace.notifications.flush().await.unwrap();
        assert!(weak.upgrade().is_none());
        assert_eq!(crate::model::test_support::repository_accesses(f.root.to_str().unwrap()), before);
    }

    #[tokio::test]
    async fn events_after_snapshot_are_folded_into_initial_data_before_callbacks_start() {
        let mut f = Fixture::new().await;
        let (subscription, events) = f.pending();
        let snapshot = f.snapshot().await;
        f.change("B").await;
        f.change("C").await;
        assert!(events.lock().unwrap().is_empty());
        let data = f.finish(&subscription, snapshot).into_task().unwrap();
        assert_eq!(data.tasks[0].title(), "C");
        assert!(events.lock().unwrap().is_empty());
        assert_eq!(subscription.status(), QuerySubscriptionStatus::Current);
        f.change("D").await;
        assert_eq!(events.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn startup_discards_the_entire_event_chain_already_in_the_query_snapshot() {
        let mut f = Fixture::new().await;
        let (subscription, events) = f.pending();
        f.change("B").await;
        f.change("C").await;
        let snapshot = f.snapshot().await;
        let data = f.finish(&subscription, snapshot).into_task().unwrap();
        assert_eq!(data.tasks[0].title(), "C");
        assert_eq!(subscription.status(), QuerySubscriptionStatus::Current);
        assert!(events.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn reversed_delivery_waits_for_predecessor_and_duplicate_versions_are_silent() {
        let mut f = Fixture::new().await;
        let events = Arc::new(Mutex::new(Vec::new()));
        let capture = events.clone();
        let subscription =
            prepare(f.query(), move |event| capture.lock().unwrap().push(event)).unwrap();
        let mut data = f.finish(&subscription, f.snapshot().await);
        f.change("B").await;
        f.change("C").await;
        let raw = f.raw.lock().unwrap().clone();
        let monitor = subscription.monitor();
        monitor(raw[1].clone());
        assert_eq!(
            subscription.status(),
            QuerySubscriptionStatus::AwaitingEvents
        );
        assert!(events.lock().unwrap().is_empty());
        monitor(raw[0].clone());
        assert_eq!(subscription.status(), QuerySubscriptionStatus::Current);
        assert_eq!(events.lock().unwrap().len(), 2);
        for event in events.lock().unwrap().iter() {
            apply_initial(&mut data, event);
        }
        assert_eq!(data.into_task().unwrap().tasks[0].title(), "C");
        monitor(raw[1].clone());
        assert_eq!(events.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn invalidation_and_cancel_do_not_read_disk_or_forward_non_data_events() {
        let mut f = Fixture::new().await;
        let events = Arc::new(Mutex::new(Vec::new()));
        let capture = events.clone();
        let mut started = f
            .workspace
            .subscribe_query(vec![QuerySubscriptionRequest::new(f.query(), move |event| capture.lock().unwrap().push(event))])
            .await
            .unwrap().remove(0);
        let accesses = crate::model::test_support::repository_accesses(f.root.to_str().unwrap());
        crate::model::sync_events::publish(&f.workspace.notifications, &f.workspace.repos()[0]);
        f.workspace.notifications.flush().await.unwrap();
        assert_eq!(
            started.subscription.status(),
            QuerySubscriptionStatus::Invalidated
        );
        assert!(events.lock().unwrap().is_empty());
        assert_eq!(
            crate::model::test_support::repository_accesses(f.root.to_str().unwrap()),
            accesses
        );
        let monitor = started.subscription.monitor();
        f.workspace.unsubscribe_query(&mut started.subscription);
        f.change("B").await;
        monitor(f.raw.lock().unwrap().last().unwrap().clone());
        assert_eq!(
            started.subscription.status(),
            QuerySubscriptionStatus::Closed
        );
        assert!(events.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn dropping_handle_releases_the_registered_observer() {
        let f = Fixture::new().await;
        let (subscription, _) = f.pending();
        let weak = Arc::downgrade(&subscription.hub);
        drop(subscription);
        f.workspace.notifications.flush().await.unwrap();
        assert!(weak.upgrade().is_none());
    }

    #[tokio::test]
    async fn unresolved_version_backlog_is_bounded_and_invalidates_without_requery() {
        let mut f = Fixture::new().await;
        let events = Arc::new(Mutex::new(Vec::new()));
        let capture = events.clone();
        let subscription =
            prepare(f.query(), move |event| capture.lock().unwrap().push(event)).unwrap();
        f.finish(&subscription, f.snapshot().await);
        f.change("B").await;
        let mut event = f.raw.lock().unwrap()[0].clone();
        let DataChangeEvent::RepositoryChanged {
            files: Some(files), ..
        } = &mut event
        else {
            unreachable!()
        };
        files[0].before_version = Some("missing-predecessor".into());
        let monitor = subscription.monitor();
        let accesses = crate::model::test_support::repository_accesses(f.root.to_str().unwrap());
        for _ in 0..=MAX_PENDING_EVENTS {
            monitor(event.clone());
        }
        assert_eq!(subscription.status(), QuerySubscriptionStatus::Invalidated);
        assert!(events.lock().unwrap().is_empty());
        assert_eq!(
            crate::model::test_support::repository_accesses(f.root.to_str().unwrap()),
            accesses
        );
    }
    #[tokio::test]
    async fn bootstrap_insertions_preserve_workspace_order_for_equal_sort_keys() {
        let first = Fixture::new().await;
        let second = Fixture::new().await;
        std::fs::write(first.root.join("a.org"), "").unwrap();
        first
            .workspace
            .add_repo(second.workspace.repos()[0].clone()).await
            .unwrap();
        let (subscription, _) = first.pending();
        let snapshot = first.snapshot().await;
        let first_id = first.workspace.repos()[0].id.clone();
        first.workspace.execute_task_operations(&serde_json::from_value(serde_json::json!({"operations":[
            {"type":"Creation","data":{"position":{"parent":{"repoId":first_id,"file":"a.org","titles":[]}},"title":"First","state":"TODO"}}
        ]})).unwrap()).await.unwrap();
        let repo_order = first
            .workspace
            .repos()
            .iter()
            .map(|repo| repo.id.clone())
            .collect::<Vec<_>>();
        let data = subscription
            .initialize(snapshot.results[0].clone(), &snapshot, &repo_order)
            .into_task()
            .unwrap();
        let expected = first
            .workspace
            .query(&[first.query()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(data, expected);
        assert_eq!(data.tasks[0].repo_id(), first_id);
    }
}
