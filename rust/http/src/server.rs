//! `org-tasks-httpd` 的 HTTP 宿主实现。
//!
//! 网络、命令行和运行时依赖仅位于此模块；领域服务通过单写入者 actor 调用。

use std::fs::{self, File, OpenOptions};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{Path as AxumPath, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::{Args, Subcommand, ValueEnum};
use org_tasks_core::{
    CoreError, CreateSyncJobRequest, CreateTaskRequest, JobKind, JobPriority, JobState, NewTask,
    Priority, SyncJob, TaskCreation, TaskRecord, TodoState,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tracing::info;

use crate::{
    CsvCoreStore, HttpApi, HttpBody, HttpMethod, HttpRequest, HttpResponse, HttpResponseBody,
};

const API_VERSION: u8 = 1;
const ACTOR_CHANNEL_CAPACITY: usize = 128;

#[derive(clap::Parser)]
#[command(name = "org-tasks-httpd", version, about = "Org Tasks HTTP 数据服务")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// 打开 CSV 仓储并启动 HTTP 服务。
    Serve(ServeArgs),
    /// 只校验 CSV 仓储，不监听端口也不修改数据。
    Check(CheckArgs),
}

#[derive(Args)]
pub struct ServeArgs {
    /// CSV 数据目录。
    #[arg(long)]
    pub data_dir: PathBuf,
    /// HTTP 监听地址。
    #[arg(long, default_value = "127.0.0.1:8787")]
    pub listen: SocketAddr,
    /// 收到退出信号后等待在途请求的最长秒数。
    #[arg(long, default_value_t = 10)]
    pub shutdown_timeout_secs: u64,
    /// 日志详细程度；首版仅用于启动诊断。
    #[arg(long, value_enum, default_value_t = LogLevel::Info)]
    pub log_level: LogLevel,
    /// 可选的 Bearer Token 文件。
    #[arg(long)]
    pub access_token_file: Option<PathBuf>,
    /// 显式允许监听非回环地址。
    #[arg(long)]
    pub allow_non_loopback: bool,
}

#[derive(Args)]
pub struct CheckArgs {
    /// CSV 数据目录。
    #[arg(long)]
    pub data_dir: PathBuf,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl LogLevel {
    fn as_tracing_level(self) -> tracing::Level {
        match self {
            Self::Error => tracing::Level::ERROR,
            Self::Warn => tracing::Level::WARN,
            Self::Info => tracing::Level::INFO,
            Self::Debug => tracing::Level::DEBUG,
            Self::Trace => tracing::Level::TRACE,
        }
    }
}

pub fn init_logging(level: LogLevel) {
    let _ = tracing_subscriber::fmt()
        .with_max_level(level.as_tracing_level())
        .with_target(false)
        .try_init();
}

pub async fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Serve(args) => serve(args).await,
        Command::Check(args) => check(&args.data_dir),
    }
}

fn check(data_dir: &Path) -> Result<(), String> {
    CsvCoreStore::validate(data_dir).map_err(|error| format!("CSV 仓储校验失败: {error}"))?;
    println!("CSV 仓储校验通过: {}", data_dir.display());
    Ok(())
}

async fn serve(args: ServeArgs) -> Result<(), String> {
    validate_serve_args(&args)?;
    let token = read_token(args.access_token_file.as_deref())?;
    let _data_lock = DataDirectoryLock::acquire(&args.data_dir)?;
    let store = CsvCoreStore::open(&args.data_dir)
        .map_err(|error| format!("无法打开 CSV 仓储: {error}"))?;
    let actor = CoreActor::start(store)?;
    let app = router(AppState { actor, token });
    let listener = tokio::net::TcpListener::bind(args.listen)
        .await
        .map_err(|error| format!("无法监听 {}: {error}", args.listen))?;

    info!(listen = %args.listen, "org-tasks-httpd 已启动");
    let server = axum::serve(listener, app).with_graceful_shutdown(shutdown_signal());
    match tokio::time::timeout(Duration::from_secs(args.shutdown_timeout_secs), server).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err(format!("HTTP 服务异常退出: {error}")),
        Err(_) => Err("HTTP 服务未能在优雅退出时限内停止".into()),
    }
}

fn validate_serve_args(args: &ServeArgs) -> Result<(), String> {
    if args.shutdown_timeout_secs == 0 {
        return Err("--shutdown-timeout-secs 必须大于 0".into());
    }
    if !is_loopback(args.listen.ip())
        && (!args.allow_non_loopback || args.access_token_file.is_none())
    {
        return Err("非回环监听必须同时指定 --allow-non-loopback 和 --access-token-file".into());
    }
    Ok(())
}

fn is_loopback(address: IpAddr) -> bool {
    address.is_loopback()
}

fn read_token(path: Option<&Path>) -> Result<Option<Arc<str>>, String> {
    let Some(path) = path else {
        return Ok(None);
    };
    let token = fs::read_to_string(path)
        .map_err(|error| format!("无法读取访问令牌文件 {}: {error}", path.display()))?;
    let token = token.trim();
    if token.is_empty() {
        return Err("访问令牌文件不能为空".into());
    }
    Ok(Some(Arc::from(token)))
}

struct DataDirectoryLock {
    _file: File,
}

impl DataDirectoryLock {
    fn acquire(data_dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(data_dir)
            .map_err(|error| format!("无法创建 CSV 数据目录 {}: {error}", data_dir.display()))?;
        let lock_path = data_dir.join(".org-tasks-httpd.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&lock_path)
            .map_err(|error| format!("无法打开数据目录锁 {}: {error}", lock_path.display()))?;
        file.try_lock()
            .map_err(|error| format!("CSV 数据目录已被其他服务占用: {error}"))?;
        Ok(Self { _file: file })
    }
}

#[derive(Clone)]
struct AppState {
    actor: CoreActor,
    token: Option<Arc<str>>,
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/tasks", post(create_task))
        .route("/v1/sync-jobs", post(create_sync_job))
        .route("/v1/sync-jobs/:id", get(get_sync_job))
        .with_state(state)
}

async fn health() -> Response {
    (
        StatusCode::OK,
        Json(json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION") })),
    )
        .into_response()
}

async fn create_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateTaskPayload>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let request_id = request_id(&headers);
    let request = HttpRequest {
        method: HttpMethod::Post,
        path: "/v1/tasks".into(),
        body: Some(HttpBody::CreateTask(payload.into_core())),
    };
    dispatch(&state.actor, request, request_id).await
}

async fn create_sync_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateSyncJobPayload>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let request_id = request_id(&headers);
    let request = HttpRequest {
        method: HttpMethod::Post,
        path: "/v1/sync-jobs".into(),
        body: Some(HttpBody::CreateSyncJob(payload.into_core())),
    };
    dispatch(&state.actor, request, request_id).await
}

async fn get_sync_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let request_id = request_id(&headers);
    let request = HttpRequest {
        method: HttpMethod::Get,
        path: format!("/v1/sync-jobs/{id}"),
        body: None,
    };
    dispatch(&state.actor, request, request_id).await
}

fn authorize(state: &AppState, headers: &HeaderMap) -> Result<(), Response> {
    let Some(expected_token) = &state.token else {
        return Ok(());
    };
    let expected = format!("Bearer {expected_token}");
    let authorized = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value == expected);
    if authorized {
        Ok(())
    } else {
        Err(json_error(
            StatusCode::UNAUTHORIZED,
            request_id(headers),
            "unauthorized",
            "缺少或无效的访问令牌",
            false,
        ))
    }
}

fn request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            let millis = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis();
            format!("request-{millis}")
        })
}

async fn dispatch(actor: &CoreActor, request: HttpRequest, request_id: String) -> Response {
    match actor.call(request).await {
        Ok(response) => response_to_json(response, request_id),
        Err(message) => json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            request_id,
            "service_unavailable",
            &message,
            true,
        ),
    }
}

fn response_to_json(response: HttpResponse, request_id: String) -> Response {
    let status = StatusCode::from_u16(response.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    match response.body {
        Some(HttpResponseBody::TaskCreation(creation)) => {
            json_success(status, request_id, task_creation_json(creation))
        }
        Some(HttpResponseBody::SyncJob(job)) => {
            json_success(status, request_id, sync_job_json(job))
        }
        Some(HttpResponseBody::Error(error)) => {
            let (code, message, retryable) = core_error_json(&error);
            json_error(status, request_id, code, &message, retryable)
        }
        None => (
            status,
            Json(json!({ "apiVersion": API_VERSION, "requestId": request_id })),
        )
            .into_response(),
    }
}

fn json_success(status: StatusCode, request_id: String, data: Value) -> Response {
    (
        status,
        Json(json!({
            "apiVersion": API_VERSION,
            "requestId": request_id,
            "data": data,
        })),
    )
        .into_response()
}

fn json_error(
    status: StatusCode,
    request_id: String,
    code: &str,
    message: &str,
    retryable: bool,
) -> Response {
    (
        status,
        Json(json!({
            "apiVersion": API_VERSION,
            "requestId": request_id,
            "error": {
                "code": code,
                "message": message,
                "retryable": retryable,
            }
        })),
    )
        .into_response()
}

fn core_error_json(error: &CoreError) -> (&'static str, String, bool) {
    match error {
        CoreError::InvalidInput(message) => ("invalid_input", (*message).into(), false),
        CoreError::InvalidState(message) => ("invalid_state", (*message).into(), false),
        CoreError::Store(_) => ("store_failure", "存储操作失败".into(), true),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateTaskPayload {
    idempotency_key: String,
    job_id: String,
    outbox_entry_id: String,
    reason: String,
    priority: ApiJobPriority,
    now: i64,
    task: NewTaskPayload,
}

impl CreateTaskPayload {
    fn into_core(self) -> CreateTaskRequest {
        CreateTaskRequest {
            idempotency_key: self.idempotency_key,
            job_id: self.job_id,
            outbox_entry_id: self.outbox_entry_id,
            reason: self.reason,
            priority: self.priority.into_core(),
            now: self.now,
            task: self.task.into_core(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewTaskPayload {
    id: String,
    heading: String,
    target_path: String,
    scheduled_at: Option<i64>,
    deadline_at: Option<i64>,
    #[serde(default)]
    tags: Vec<String>,
    priority: Option<ApiPriority>,
    org_entry: String,
    content_hash: String,
}

impl NewTaskPayload {
    fn into_core(self) -> NewTask {
        NewTask {
            id: self.id,
            heading: self.heading,
            target_path: self.target_path,
            scheduled_at: self.scheduled_at,
            deadline_at: self.deadline_at,
            tags: self.tags,
            priority: self.priority.map(ApiPriority::into_core),
            org_entry: self.org_entry,
            content_hash: self.content_hash,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateSyncJobPayload {
    idempotency_key: String,
    job_id: String,
    reason: String,
    priority: ApiJobPriority,
    include_calendar: bool,
    now: i64,
}

impl CreateSyncJobPayload {
    fn into_core(self) -> CreateSyncJobRequest {
        CreateSyncJobRequest {
            idempotency_key: self.idempotency_key,
            job_id: self.job_id,
            reason: self.reason,
            priority: self.priority.into_core(),
            include_calendar: self.include_calendar,
            now: self.now,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ApiJobPriority {
    Foreground,
    Background,
}

impl ApiJobPriority {
    fn into_core(self) -> JobPriority {
        match self {
            Self::Foreground => JobPriority::Foreground,
            Self::Background => JobPriority::Background,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "UPPERCASE")]
enum ApiPriority {
    A,
    B,
    C,
}

impl ApiPriority {
    fn into_core(self) -> Priority {
        match self {
            Self::A => Priority::A,
            Self::B => Priority::B,
            Self::C => Priority::C,
        }
    }
}

fn task_creation_json(creation: TaskCreation) -> Value {
    json!({ "task": task_json(creation.task), "job": sync_job_json(creation.job) })
}

fn task_json(task: TaskRecord) -> Value {
    json!({
        "id": task.id,
        "filePath": task.file_path,
        "heading": task.heading,
        "todoState": todo_state_name(task.todo_state),
        "priority": task.priority.map(priority_name),
        "scheduledAt": task.scheduled_at,
        "deadlineAt": task.deadline_at,
        "tags": task.tags,
        "body": task.body,
        "sourceRevision": task.source_revision,
        "updatedAt": task.updated_at,
    })
}

fn sync_job_json(job: SyncJob) -> Value {
    json!({
        "id": job.id,
        "idempotencyKey": job.idempotency_key,
        "kind": job_kind_name(job.kind),
        "state": job_state_name(job.state),
        "priority": job_priority_name(job.priority),
        "reason": job.reason,
        "includeCalendar": job.include_calendar,
        "taskId": job.task_id,
        "attemptCount": job.attempt_count,
        "nextRunAt": job.next_run_at,
        "createdAt": job.created_at,
        "updatedAt": job.updated_at,
    })
}

fn todo_state_name(value: TodoState) -> &'static str {
    match value {
        TodoState::Todo => "TODO",
        TodoState::Next => "NEXT",
        TodoState::Wait => "WAIT",
        TodoState::Done => "DONE",
        TodoState::Cncl => "CNCL",
    }
}

fn priority_name(value: Priority) -> &'static str {
    match value {
        Priority::A => "A",
        Priority::B => "B",
        Priority::C => "C",
    }
}

fn job_kind_name(value: JobKind) -> &'static str {
    match value {
        JobKind::Sync => "sync",
        JobKind::AddTask => "add_task",
        JobKind::Retry => "retry",
        JobKind::ResolveConflict => "resolve_conflict",
        JobKind::RebuildCalendar => "rebuild_calendar",
        JobKind::RefreshLocalIndex => "refresh_local_index",
    }
}

fn job_state_name(value: JobState) -> &'static str {
    match value {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::RetryWait => "retry_wait",
        JobState::Blocked => "blocked",
        JobState::Completed => "completed",
        JobState::Failed => "failed",
    }
}

fn job_priority_name(value: JobPriority) -> &'static str {
    match value {
        JobPriority::Foreground => "foreground",
        JobPriority::Background => "background",
    }
}

#[derive(Clone)]
struct CoreActor {
    sender: mpsc::Sender<CoreCommand>,
}

struct CoreCommand {
    request: HttpRequest,
    reply: oneshot::Sender<HttpResponse>,
}

impl CoreActor {
    fn start(store: CsvCoreStore) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("无法创建服务 actor 运行时: {error}"))?;
        let (sender, mut receiver) = mpsc::channel::<CoreCommand>(ACTOR_CHANNEL_CAPACITY);
        std::thread::Builder::new()
            .name("org-tasks-core-writer".into())
            .spawn(move || {
                let mut api = HttpApi::new(store);
                while let Some(command) = receiver.blocking_recv() {
                    let response = runtime.block_on(api.handle(command.request));
                    let _ = command.reply.send(response);
                }
            })
            .map_err(|error| format!("无法启动服务 actor: {error}"))?;
        Ok(Self { sender })
    }

    async fn call(&self, request: HttpRequest) -> Result<HttpResponse, String> {
        let (reply, receiver) = oneshot::channel();
        self.sender
            .send(CoreCommand { request, reply })
            .await
            .map_err(|_| "核心服务不可用".to_owned())?;
        receiver.await.map_err(|_| "核心服务未返回响应".to_owned())
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("无法监听 Ctrl-C 退出信号");
    };
    #[cfg(unix)]
    {
        let terminate = async {
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("无法监听 SIGTERM 退出信号")
                .recv()
                .await;
        };
        tokio::select! {
            _ = ctrl_c => {},
            _ = terminate => {},
        }
    }
    #[cfg(not(unix))]
    ctrl_c.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    #[test]
    fn rejects_unprotected_non_loopback_listener() {
        let args = ServeArgs {
            data_dir: PathBuf::from("/tmp/org-tasks-http-test"),
            listen: "0.0.0.0:8787".parse().expect("地址应有效"),
            shutdown_timeout_secs: 10,
            log_level: LogLevel::Info,
            access_token_file: None,
            allow_non_loopback: false,
        };
        assert!(validate_serve_args(&args).is_err());
    }

    #[tokio::test]
    async fn health_check_does_not_require_access_token() {
        let data_dir = std::env::temp_dir().join(format!(
            "org-tasks-http-server-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("系统时间应有效")
                .as_nanos()
        ));
        let actor = CoreActor::start(CsvCoreStore::open(&data_dir).expect("应打开仓储"))
            .expect("应启动 actor");
        let app = router(AppState {
            actor,
            token: Some(Arc::from("test-token")),
        });
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .expect("应创建请求"),
            )
            .await
            .expect("路由应返回响应");
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("应读取响应体");
        assert_eq!(
            json!(serde_json::from_slice::<Value>(&body).expect("应为 JSON"))["status"],
            "ok"
        );
        fs::remove_dir_all(data_dir).expect("应移除测试数据目录");
    }

    #[tokio::test]
    async fn creates_sync_job_from_json_request() {
        let data_dir = std::env::temp_dir().join(format!(
            "org-tasks-http-request-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("系统时间应有效")
                .as_nanos()
        ));
        let actor = CoreActor::start(CsvCoreStore::open(&data_dir).expect("应打开仓储"))
            .expect("应启动 actor");
        let app = router(AppState { actor, token: None });
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/sync-jobs")
                    .header("content-type", "application/json")
                    .header("x-request-id", "test-request-1")
                    .body(Body::from(
                        r#"{
                            "idempotencyKey":"request-1",
                            "jobId":"job-1",
                            "reason":"manual",
                            "priority":"foreground",
                            "includeCalendar":true,
                            "now":1
                        }"#,
                    ))
                    .expect("应创建请求"),
            )
            .await
            .expect("路由应返回响应");
        assert_eq!(response.status(), StatusCode::CREATED);
        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("应读取响应体");
        let response: Value = serde_json::from_slice(&body).expect("应为 JSON");
        assert_eq!(response["requestId"], "test-request-1");
        assert_eq!(response["data"]["id"], "job-1");
        fs::remove_dir_all(data_dir).expect("应移除测试数据目录");
    }
}
