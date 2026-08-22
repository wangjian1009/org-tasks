//! RESTful HTTP 适配层。
//!
//! 该 crate 提供无框架的路由映射。宿主可将 HttpRequest/HttpResponse 对接 axum、
//! hyper 或 HarmonyOS 侧的任意 HTTP server，而不改变 core 业务逻辑。

use org_tasks_core::{
    CoreError, CoreService, CoreStore, CreateSyncJobRequest, CreateTaskRequest, SyncJob,
    TaskCreation,
};

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

    pub fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        match (request.method, request.path.as_str(), request.body) {
            (HttpMethod::Post, "/v1/tasks", Some(HttpBody::CreateTask(body))) => map_result(
                self.core.create_task(body),
                201,
                HttpResponseBody::TaskCreation,
            ),
            (HttpMethod::Post, "/v1/sync-jobs", Some(HttpBody::CreateSyncJob(body))) => map_result(
                self.core.create_sync_job(body),
                201,
                HttpResponseBody::SyncJob,
            ),
            (HttpMethod::Get, path, None) if path.starts_with("/v1/sync-jobs/") => {
                let job_id = &path[14..];
                match self.core.get_job(job_id) {
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
