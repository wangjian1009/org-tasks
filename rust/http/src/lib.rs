//! RESTful HTTP 适配层。
//!
//! 该 crate 提供无框架的路由映射。宿主可将 HttpRequest/HttpResponse 对接 axum、
//! hyper 或 HarmonyOS 侧的任意 HTTP server，而不改变 core 业务逻辑。

pub mod server;
mod store;

use org_tasks_core::{
    CoreError, CoreService, CoreStore, CreateSyncJobRequest, CreateTaskRequest, SyncJob,
    TaskCreation,
};

pub use store::CsvCoreStore;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
}

pub enum HttpBody {
    CreateTask(CreateTaskRequest),
    CreateSyncJob(CreateSyncJobRequest),
}

pub struct HttpRequest {
    pub method: HttpMethod,
    pub path: String,
    pub body: Option<HttpBody>,
}

pub enum HttpResponseBody {
    TaskCreation(TaskCreation),
    SyncJob(SyncJob),
    Error(CoreError),
}

pub struct HttpResponse {
    pub status: u16,
    pub body: Option<HttpResponseBody>,
}

pub struct HttpApi<S> {
    core: CoreService<S>,
}

impl<S> HttpApi<S>
where
    S: CoreStore,
{
    pub fn new(store: S) -> Self {
        Self {
            core: CoreService::new(store),
        }
    }

    pub async fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        match (request.method, request.path.as_str(), request.body) {
            (HttpMethod::Post, "/v1/tasks", Some(HttpBody::CreateTask(body))) => map_result(
                self.core.create_task(body).await,
                201,
                HttpResponseBody::TaskCreation,
            ),
            (HttpMethod::Post, "/v1/sync-jobs", Some(HttpBody::CreateSyncJob(body))) => map_result(
                self.core.create_sync_job(body).await,
                201,
                HttpResponseBody::SyncJob,
            ),
            (HttpMethod::Get, path, None) if path.starts_with("/v1/sync-jobs/") => {
                let job_id = &path[14..];
                match self.core.get_job(job_id).await {
                    Ok(Some(job)) => HttpResponse {
                        status: 200,
                        body: Some(HttpResponseBody::SyncJob(job)),
                    },
                    Ok(None) => error_response(CoreError::InvalidInput("同步作业不存在"), 404),
                    Err(error) => error_response(error, 500),
                }
            }
            _ => error_response(CoreError::InvalidInput("不支持的 REST 资源或请求体"), 400),
        }
    }

    pub fn into_store(self) -> S {
        self.core.into_store()
    }
}

fn map_result<T>(
    result: Result<T, CoreError>,
    success: u16,
    map: fn(T) -> HttpResponseBody,
) -> HttpResponse {
    match result {
        Ok(value) => HttpResponse {
            status: success,
            body: Some(map(value)),
        },
        Err(error) => {
            let status = if matches!(error, CoreError::Store(_)) {
                500
            } else {
                400
            };
            error_response(error, status)
        }
    }
}

fn error_response(error: CoreError, status: u16) -> HttpResponse {
    HttpResponse {
        status,
        body: Some(HttpResponseBody::Error(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use org_tasks_core::{
        CoreChangeSet, CoreService, FileSyncRecord, FileSyncState, JobKind, JobPriority, JobState,
        OutboxEntry,
    };
    use std::collections::HashMap;
    use std::fs;
    use std::future::Future;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::task::{Context, Poll, Waker};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[derive(Default)]
    struct MemoryStore {
        jobs: HashMap<String, SyncJob>,
        outbox: HashMap<String, OutboxEntry>,
    }

    impl CoreStore for MemoryStore {
        fn find_file_sync(
            &self,
            _: &str,
        ) -> impl Future<Output = Result<Option<FileSyncRecord>, CoreError>> + Send {
            async { Ok(None) }
        }

        fn find_outbox(
            &self,
            id: &str,
        ) -> impl Future<Output = Result<Option<OutboxEntry>, CoreError>> + Send {
            let value = self.outbox.get(id).cloned();
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
            idempotency_key: &str,
        ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
            let value = self
                .jobs
                .values()
                .find(|job| job.idempotency_key == idempotency_key)
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

    fn test_data_dir() -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("系统时间应晚于 Unix epoch")
            .as_nanos();
        let sequence = TEST_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("org-tasks-http-{timestamp}-{sequence}"))
    }

    fn sync_request(idempotency_key: &str, job_id: &str) -> HttpRequest {
        HttpRequest {
            method: HttpMethod::Post,
            path: "/v1/sync-jobs".into(),
            body: Some(HttpBody::CreateSyncJob(CreateSyncJobRequest {
                idempotency_key: idempotency_key.into(),
                job_id: job_id.into(),
                reason: "manual".into(),
                priority: JobPriority::Foreground,
                include_calendar: true,
                now: 1,
            })),
        }
    }

    fn task_request() -> HttpRequest {
        HttpRequest {
            method: HttpMethod::Post,
            path: "/v1/tasks".into(),
            body: Some(HttpBody::CreateTask(CreateTaskRequest {
                idempotency_key: "task-request-1".into(),
                job_id: "task-job-1".into(),
                outbox_entry_id: "outbox-1".into(),
                reason: "manual".into(),
                priority: JobPriority::Foreground,
                now: 1,
                task: org_tasks_core::NewTask {
                    id: "task-1".into(),
                    heading: "CSV 恢复测试".into(),
                    relative_path: "inbox.org".into(),
                    scheduled_at: None,
                    deadline_at: Some(2),
                    tags: vec!["work".into(), "csv".into()],
                    priority: Some(org_tasks_core::Priority::A),
                    org_entry: "* TODO CSV 恢复测试\n".into(),
                    content_hash: "abc".into(),
                },
            })),
        }
    }

    #[test]
    fn creates_sync_job_through_async_route() {
        let mut api = HttpApi::new(MemoryStore::default());
        let response = block_on(api.handle(sync_request("request-1", "job-1")));

        assert_eq!(response.status, 201);
        match response.body {
            Some(HttpResponseBody::SyncJob(job)) => assert_eq!(job.id, "job-1"),
            _ => panic!("HTTP 路由返回了错误响应"),
        }
    }

    #[test]
    fn csv_store_restores_sync_job_after_reopen() {
        let data_dir = test_data_dir();
        let store = CsvCoreStore::open(&data_dir).expect("应创建 CSV 仓储");
        let mut first_api = HttpApi::new(store);
        let first = block_on(first_api.handle(sync_request("request-1", "job-1")));
        drop(first_api);
        assert!(data_dir.join("current.csv").exists());
        assert!(
            data_dir
                .join("snapshots/00000000000000000001/jobs.csv")
                .exists()
        );

        let store = CsvCoreStore::open(&data_dir).expect("应恢复 CSV 仓储");
        let mut second_api = HttpApi::new(store);
        let second = block_on(second_api.handle(sync_request("request-2", "job-2")));

        match (first.body, second.body) {
            (Some(HttpResponseBody::SyncJob(first)), Some(HttpResponseBody::SyncJob(second))) => {
                assert_eq!(first.id, second.id);
            }
            _ => panic!("CSV 仓储恢复后返回了错误响应"),
        }
        fs::remove_dir_all(data_dir).expect("应移除 CSV 测试仓储");
    }

    #[test]
    fn csv_store_restores_outbox_without_persisting_task_projection() {
        let data_dir = test_data_dir();
        let store = CsvCoreStore::open(&data_dir).expect("应创建 CSV 仓储");
        let mut first_api = HttpApi::new(store);
        let first = block_on(first_api.handle(task_request()));
        drop(first_api);
        let snapshot = data_dir.join("snapshots/00000000000000000001");
        assert!(!snapshot.join("tasks.csv").exists());
        assert!(!snapshot.join("task_tags.csv").exists());
        assert!(snapshot.join("outbox.csv").exists());

        let store = CsvCoreStore::open(&data_dir).expect("应恢复 CSV 仓储");
        let mut second_api = HttpApi::new(store);
        let second = block_on(second_api.handle(task_request()));

        match (first.body, second.body) {
            (
                Some(HttpResponseBody::TaskCreation(first)),
                Some(HttpResponseBody::TaskCreation(second)),
            ) => {
                assert_eq!(first.task_id, second.task_id);
                assert_eq!(second.outbox_entry.id, "outbox-1");
            }
            _ => panic!("CSV 任务恢复后返回了错误响应"),
        }
        fs::remove_dir_all(data_dir).expect("应移除 CSV 测试仓储");
    }

    #[test]
    fn csv_store_restores_relative_file_sync_metadata_without_task_files() {
        let data_dir = test_data_dir();
        let mut service = CoreService::new(CsvCoreStore::open(&data_dir).expect("应创建 CSV 仓储"));
        block_on(service.record_file_sync(FileSyncRecord {
            relative_path: "projects/inbox.org".into(),
            content_hash: "abc".into(),
            remote_etag: Some("etag-1".into()),
            remote_mtime: Some(1),
            remote_size: Some(2),
            last_synced_at: Some(3),
            sync_state: FileSyncState::Synced,
        }))
        .expect("应保存同步元数据");
        drop(service);

        let snapshot = data_dir.join("snapshots/00000000000000000001");
        assert!(snapshot.join("files.csv").exists());
        assert!(!snapshot.join("tasks.csv").exists());
        assert!(!snapshot.join("task_tags.csv").exists());

        let store = CsvCoreStore::open(&data_dir).expect("应恢复 CSV 仓储");
        let restored = block_on(store.find_file_sync("projects/inbox.org"))
            .expect("应查询同步元数据")
            .expect("应恢复同步元数据");
        assert_eq!(restored.relative_path, "projects/inbox.org");
        assert_eq!(restored.remote_etag.as_deref(), Some("etag-1"));
        fs::remove_dir_all(data_dir).expect("应移除 CSV 测试仓储");
    }

    #[test]
    fn opening_csv_store_removes_legacy_task_projection_files() {
        let data_dir = test_data_dir();
        let store = CsvCoreStore::open(&data_dir).expect("应创建 CSV 仓储");
        let mut api = HttpApi::new(store);
        let _ = block_on(api.handle(sync_request("request-1", "job-1")));
        drop(api);
        let snapshot = data_dir.join("snapshots/00000000000000000001");
        fs::write(snapshot.join("tasks.csv"), "legacy").expect("应写入旧任务投影");
        fs::write(snapshot.join("task_tags.csv"), "legacy").expect("应写入旧任务标签");

        let _ = CsvCoreStore::open(&data_dir).expect("应迁移 CSV 仓储");
        assert!(!snapshot.join("tasks.csv").exists());
        assert!(!snapshot.join("task_tags.csv").exists());
        fs::remove_dir_all(data_dir).expect("应移除 CSV 测试仓储");
    }
}
