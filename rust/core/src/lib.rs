//! 平台与持久化无关的 Org Tasks 领域核心。

use std::fmt::{Display, Formatter};
use std::future::Future;

pub type TimestampMs = i64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreError {
    InvalidInput(&'static str),
    Store(String),
    InvalidState(&'static str),
}

impl Display for CoreError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput(message) | Self::InvalidState(message) => {
                formatter.write_str(message)
            }
            Self::Store(message) => write!(formatter, "存储操作失败: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TodoState {
    Todo,
    Next,
    Wait,
    Done,
    Cncl,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Priority {
    A,
    B,
    C,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskRecord {
    pub id: String,
    pub file_path: String,
    pub heading: String,
    pub todo_state: TodoState,
    pub priority: Option<Priority>,
    pub scheduled_at: Option<TimestampMs>,
    pub deadline_at: Option<TimestampMs>,
    pub tags: Vec<String>,
    pub body: String,
    pub source_revision: String,
    pub updated_at: TimestampMs,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRecord {
    pub path: String,
    pub content_hash: String,
    pub remote_etag: Option<String>,
    pub remote_mtime: Option<TimestampMs>,
    pub remote_size: Option<i64>,
    pub last_synced_at: Option<TimestampMs>,
    pub sync_state: FileSyncState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileSyncState {
    Synced,
    LocalChanged,
    RemoteChanged,
    RemoteDeleted,
    Conflict,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutboxEntry {
    pub id: String,
    pub target_path: String,
    pub org_entry: String,
    pub content_hash: String,
    pub created_at: TimestampMs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobKind {
    Sync,
    AddTask,
    Retry,
    ResolveConflict,
    RebuildCalendar,
    RefreshLocalIndex,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    RetryWait,
    Blocked,
    Completed,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobPriority {
    Foreground,
    Background,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncJob {
    pub id: String,
    pub idempotency_key: String,
    pub kind: JobKind,
    pub state: JobState,
    pub priority: JobPriority,
    pub reason: String,
    pub include_calendar: bool,
    pub task_id: Option<String>,
    pub attempt_count: u32,
    pub next_run_at: Option<TimestampMs>,
    pub created_at: TimestampMs,
    pub updated_at: TimestampMs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictState {
    Open,
    Resolved,
    Dismissed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConflictRecord {
    pub id: String,
    pub file_path: String,
    pub local_revision: Option<String>,
    pub remote_revision: Option<String>,
    pub state: ConflictState,
    pub message: String,
    pub created_at: TimestampMs,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewTask {
    pub id: String,
    pub heading: String,
    pub target_path: String,
    pub scheduled_at: Option<TimestampMs>,
    pub deadline_at: Option<TimestampMs>,
    pub tags: Vec<String>,
    pub priority: Option<Priority>,
    pub org_entry: String,
    pub content_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateTaskRequest {
    pub idempotency_key: String,
    pub job_id: String,
    pub outbox_entry_id: String,
    pub reason: String,
    pub priority: JobPriority,
    pub now: TimestampMs,
    pub task: NewTask,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateSyncJobRequest {
    pub idempotency_key: String,
    pub job_id: String,
    pub reason: String,
    pub priority: JobPriority,
    pub include_calendar: bool,
    pub now: TimestampMs,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskCreation {
    pub task: TaskRecord,
    pub job: SyncJob,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CoreChangeSet {
    pub tasks: Vec<TaskRecord>,
    pub outbox_entries: Vec<OutboxEntry>,
    pub jobs: Vec<SyncJob>,
}

/// 持久化端口。实现者必须保证 apply 是一个原子提交。
pub trait CoreStore: Send {
    fn find_task(
        &self,
        id: &str,
    ) -> impl Future<Output = Result<Option<TaskRecord>, CoreError>> + Send;
    fn find_job(&self, id: &str)
    -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send;
    fn find_job_by_idempotency(
        &self,
        idempotency_key: &str,
    ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send;
    fn find_active_sync_job(
        &self,
    ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send;
    fn apply(
        &mut self,
        changes: CoreChangeSet,
    ) -> impl Future<Output = Result<(), CoreError>> + Send;
}

pub struct CoreService<S> {
    store: S,
}

impl<S> CoreService<S>
where
    S: CoreStore,
{
    pub fn new(store: S) -> Self {
        Self { store }
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut S {
        &mut self.store
    }

    pub fn into_store(self) -> S {
        self.store
    }

    pub async fn get_job(&self, id: &str) -> Result<Option<SyncJob>, CoreError> {
        self.store.find_job(id).await
    }

    pub async fn create_task(
        &mut self,
        request: CreateTaskRequest,
    ) -> Result<TaskCreation, CoreError> {
        validate_id(&request.idempotency_key)?;
        validate_id(&request.job_id)?;
        validate_id(&request.outbox_entry_id)?;
        validate_task(&request.task)?;

        if let Some(existing_job) = self
            .store
            .find_job_by_idempotency(&request.idempotency_key)
            .await?
        {
            let task_id = existing_job
                .task_id
                .as_deref()
                .ok_or(CoreError::InvalidState("幂等键已绑定到非任务作业"))?;
            let task = self
                .store
                .find_task(task_id)
                .await?
                .ok_or(CoreError::InvalidState("幂等任务缺少任务记录"))?;
            return Ok(TaskCreation {
                task,
                job: existing_job,
            });
        }

        let task = TaskRecord {
            id: request.task.id.clone(),
            file_path: request.task.target_path.clone(),
            heading: request.task.heading.trim().to_owned(),
            todo_state: TodoState::Todo,
            priority: request.task.priority,
            scheduled_at: request.task.scheduled_at,
            deadline_at: request.task.deadline_at,
            tags: request.task.tags.clone(),
            body: String::new(),
            source_revision: request.task.content_hash.clone(),
            updated_at: request.now,
        };
        let outbox_entry = OutboxEntry {
            id: request.outbox_entry_id,
            target_path: request.task.target_path,
            org_entry: request.task.org_entry,
            content_hash: request.task.content_hash,
            created_at: request.now,
        };
        let job = queued_job(
            request.job_id,
            request.idempotency_key,
            JobKind::AddTask,
            request.priority,
            request.reason,
            true,
            Some(task.id.clone()),
            request.now,
        );
        self.store
            .apply(CoreChangeSet {
                tasks: vec![task.clone()],
                outbox_entries: vec![outbox_entry],
                jobs: vec![job.clone()],
            })
            .await?;
        Ok(TaskCreation { task, job })
    }

    pub async fn create_sync_job(
        &mut self,
        request: CreateSyncJobRequest,
    ) -> Result<SyncJob, CoreError> {
        validate_id(&request.idempotency_key)?;
        validate_id(&request.job_id)?;
        if let Some(job) = self
            .store
            .find_job_by_idempotency(&request.idempotency_key)
            .await?
        {
            return Ok(job);
        }
        if let Some(job) = self.store.find_active_sync_job().await? {
            return Ok(job);
        }
        let job = queued_job(
            request.job_id,
            request.idempotency_key,
            JobKind::Sync,
            request.priority,
            request.reason,
            request.include_calendar,
            None,
            request.now,
        );
        self.store
            .apply(CoreChangeSet {
                jobs: vec![job.clone()],
                ..CoreChangeSet::default()
            })
            .await?;
        Ok(job)
    }

    /// 写入当前活跃同步作业的最终状态。
    ///
    /// 平台 I/O 由外层执行，完成后必须回传结果，避免已完成作业持续参与后续合并。
    pub async fn finish_active_sync(
        &mut self,
        succeeded: bool,
        now: TimestampMs,
    ) -> Result<Option<SyncJob>, CoreError> {
        let Some(mut job) = self.store.find_active_sync_job().await? else {
            return Ok(None);
        };
        job.state = if succeeded {
            JobState::Completed
        } else {
            JobState::Failed
        };
        job.updated_at = now;
        self.store
            .apply(CoreChangeSet {
                jobs: vec![job.clone()],
                ..CoreChangeSet::default()
            })
            .await?;
        Ok(Some(job))
    }

    pub fn plan_execution(job: &SyncJob) -> Result<Vec<PlatformAction>, CoreError> {
        match job.kind {
            JobKind::Sync | JobKind::AddTask => Ok(vec![PlatformAction::RefreshRepository {
                include_calendar: job.include_calendar,
            }]),
            JobKind::RebuildCalendar => Ok(vec![PlatformAction::RebuildCalendar]),
            JobKind::RefreshLocalIndex => Ok(vec![PlatformAction::RefreshLocalIndex]),
            JobKind::Retry | JobKind::ResolveConflict => Err(CoreError::InvalidState(
                "作业需要补充目标资源后才能生成执行计划",
            )),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlatformAction {
    RefreshRepository { include_calendar: bool },
    RebuildCalendar,
    RefreshLocalIndex,
}

fn queued_job(
    id: String,
    idempotency_key: String,
    kind: JobKind,
    priority: JobPriority,
    reason: String,
    include_calendar: bool,
    task_id: Option<String>,
    now: TimestampMs,
) -> SyncJob {
    SyncJob {
        id,
        idempotency_key,
        kind,
        state: JobState::Queued,
        priority,
        reason,
        include_calendar,
        task_id,
        attempt_count: 0,
        next_run_at: None,
        created_at: now,
        updated_at: now,
    }
}

fn validate_id(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        return Err(CoreError::InvalidInput("ID 不能为空"));
    }
    Ok(())
}

fn validate_task(task: &NewTask) -> Result<(), CoreError> {
    validate_id(&task.id)?;
    if task.heading.trim().is_empty() {
        return Err(CoreError::InvalidInput("任务标题不能为空"));
    }
    if !task.target_path.ends_with(".org") || task.target_path.contains("..") {
        return Err(CoreError::InvalidInput(
            "任务目标文件必须是安全的 .org 路径",
        ));
    }
    if task.org_entry.is_empty() || task.content_hash.is_empty() {
        return Err(CoreError::InvalidInput("任务内容和哈希不能为空"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::future::Future;
    use std::task::{Context, Poll, Waker};

    #[derive(Default)]
    struct MemoryStore {
        tasks: HashMap<String, TaskRecord>,
        jobs: HashMap<String, SyncJob>,
        outbox: HashMap<String, OutboxEntry>,
    }

    impl CoreStore for MemoryStore {
        fn find_task(
            &self,
            id: &str,
        ) -> impl Future<Output = Result<Option<TaskRecord>, CoreError>> + Send {
            let value = self.tasks.get(id).cloned();
            async move { Ok(value) }
        }

        fn find_job(
            &self,
            id: &str,
        ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
            let value = self.jobs.get(id).cloned();
            async move { Ok(value) }
        }

        fn find_job_by_idempotency(
            &self,
            key: &str,
        ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
            let value = self
                .jobs
                .values()
                .find(|job| job.idempotency_key == key)
                .cloned();
            async move { Ok(value) }
        }

        fn find_active_sync_job(
            &self,
        ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
            let value = self
                .jobs
                .values()
                .find(|job| {
                    job.kind == JobKind::Sync
                        && matches!(job.state, JobState::Queued | JobState::Running)
                })
                .cloned();
            async move { Ok(value) }
        }

        fn apply(
            &mut self,
            changes: CoreChangeSet,
        ) -> impl Future<Output = Result<(), CoreError>> + Send {
            for task in changes.tasks {
                self.tasks.insert(task.id.clone(), task);
            }
            for entry in changes.outbox_entries {
                self.outbox.insert(entry.id.clone(), entry);
            }
            for job in changes.jobs {
                self.jobs.insert(job.id.clone(), job);
            }
            async { Ok(()) }
        }
    }

    fn block_on<F: Future>(future: F) -> F::Output {
        let waker = Waker::noop();
        let mut context = Context::from_waker(waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("内存仓储不应产生挂起的 Future"),
        }
    }

    fn create_task_request() -> CreateTaskRequest {
        CreateTaskRequest {
            idempotency_key: "request-1".into(),
            job_id: "job-1".into(),
            outbox_entry_id: "outbox-1".into(),
            reason: "user".into(),
            priority: JobPriority::Foreground,
            now: 1,
            task: NewTask {
                id: "task-1".into(),
                heading: "整理设计".into(),
                target_path: "inbox.org".into(),
                scheduled_at: None,
                deadline_at: None,
                tags: vec!["work".into()],
                priority: Some(Priority::A),
                org_entry: "* TODO 整理设计\n".into(),
                content_hash: "abc".into(),
            },
        }
    }

    #[test]
    fn creating_a_task_persists_task_outbox_and_job() {
        let mut service = CoreService::new(MemoryStore::default());
        let created = block_on(service.create_task(create_task_request())).unwrap();
        assert_eq!(created.task.heading, "整理设计");
        assert_eq!(created.job.kind, JobKind::AddTask);
        assert_eq!(service.store().tasks.len(), 1);
        assert_eq!(service.store().outbox.len(), 1);
        assert_eq!(service.store().jobs.len(), 1);
    }

    #[test]
    fn repeated_task_request_is_idempotent() {
        let mut service = CoreService::new(MemoryStore::default());
        block_on(service.create_task(create_task_request())).unwrap();
        let repeated = block_on(service.create_task(create_task_request())).unwrap();
        assert_eq!(repeated.job.id, "job-1");
        assert_eq!(service.store().outbox.len(), 1);
    }

    #[test]
    fn active_sync_job_is_coalesced() {
        let mut service = CoreService::new(MemoryStore::default());
        let first = block_on(service.create_sync_job(CreateSyncJobRequest {
            idempotency_key: "sync-1".into(),
            job_id: "sync-job-1".into(),
            reason: "scheduler".into(),
            priority: JobPriority::Background,
            include_calendar: true,
            now: 1,
        }))
        .unwrap();
        let second = block_on(service.create_sync_job(CreateSyncJobRequest {
            idempotency_key: "sync-2".into(),
            job_id: "sync-job-2".into(),
            reason: "foreground".into(),
            priority: JobPriority::Foreground,
            include_calendar: true,
            now: 2,
        }))
        .unwrap();
        assert_eq!(first.id, second.id);
        assert_eq!(service.store().jobs.len(), 1);
    }

    #[test]
    fn completed_sync_job_does_not_block_a_new_sync_job() {
        let mut service = CoreService::new(MemoryStore::default());
        let first = block_on(service.create_sync_job(CreateSyncJobRequest {
            idempotency_key: "sync-1".into(),
            job_id: "sync-job-1".into(),
            reason: "scheduler".into(),
            priority: JobPriority::Background,
            include_calendar: true,
            now: 1,
        }))
        .unwrap();
        let completed = block_on(service.finish_active_sync(true, 2))
            .unwrap()
            .expect("应完成活跃同步作业");
        let second = block_on(service.create_sync_job(CreateSyncJobRequest {
            idempotency_key: "sync-2".into(),
            job_id: "sync-job-2".into(),
            reason: "foreground".into(),
            priority: JobPriority::Foreground,
            include_calendar: true,
            now: 3,
        }))
        .unwrap();

        assert_eq!(completed.id, first.id);
        assert_eq!(completed.state, JobState::Completed);
        assert_eq!(second.id, "sync-job-2");
    }
}
