//! RESTful HTTP 适配层。
//!
//! 该 crate 提供无框架的路由映射。宿主可将 HttpRequest/HttpResponse 对接 axum、
//! hyper 或 HarmonyOS 侧的任意 HTTP server，而不改变 core 业务逻辑。

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
        Err(error) => error_response(error, 400),
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
    use org_tasks_core::{CoreChangeSet, JobKind, JobPriority, JobState, TaskRecord};
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
    }

    impl CoreStore for MemoryStore {
        fn find_task(
            &self,
            _: &str,
        ) -> impl Future<Output = Result<Option<TaskRecord>, CoreError>> + Send {
            async { Ok(None) }
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
                    target_path: "inbox.org".into(),
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
    fn csv_store_restores_task_tags_and_outbox_after_reopen() {
        let data_dir = test_data_dir();
        let store = CsvCoreStore::open(&data_dir).expect("应创建 CSV 仓储");
        let mut first_api = HttpApi::new(store);
        let first = block_on(first_api.handle(task_request()));
        drop(first_api);
        let snapshot = data_dir.join("snapshots/00000000000000000001");
        assert!(snapshot.join("tasks.csv").exists());
        assert!(snapshot.join("task_tags.csv").exists());
        assert!(snapshot.join("outbox.csv").exists());

        let store = CsvCoreStore::open(&data_dir).expect("应恢复 CSV 仓储");
        let mut second_api = HttpApi::new(store);
        let second = block_on(second_api.handle(task_request()));

        match (first.body, second.body) {
            (
                Some(HttpResponseBody::TaskCreation(first)),
                Some(HttpResponseBody::TaskCreation(second)),
            ) => {
                assert_eq!(first.task.id, second.task.id);
                assert_eq!(second.task.tags, vec!["work", "csv"]);
            }
            _ => panic!("CSV 任务恢复后返回了错误响应"),
        }
        fs::remove_dir_all(data_dir).expect("应移除 CSV 测试仓储");
    }
}
