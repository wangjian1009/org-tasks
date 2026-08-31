//! `org-tasks-httpd` 的仓库同步记录 HTTP 宿主。

use std::fs::{self, File, OpenOptions};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path as AxumPath, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::{Args, Subcommand, ValueEnum};
use org_tasks_core::OrgRepoSyncRecord;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tracing::info;

use crate::{
    CsvOrgRepoSyncRecordStore, HttpApi, HttpBody, HttpMethod, HttpRequest, HttpResponse,
    HttpResponseBody,
};

const ACTOR_CHANNEL_CAPACITY: usize = 128;

#[derive(clap::Parser)]
#[command(
    name = "org-tasks-httpd",
    version,
    about = "Org Tasks HTTP 同步记录服务"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    Serve(ServeArgs),
    Check(CheckArgs),
}

#[derive(Args)]
pub struct ServeArgs {
    #[arg(long)]
    pub data_dir: PathBuf,
    #[arg(long, default_value = "127.0.0.1:8787")]
    pub listen: SocketAddr,
    #[arg(long, default_value_t = 10)]
    pub shutdown_timeout_secs: u64,
    #[arg(long, value_enum, default_value_t = LogLevel::Info)]
    pub log_level: LogLevel,
    #[arg(long)]
    pub access_token_file: Option<PathBuf>,
    #[arg(long)]
    pub allow_non_loopback: bool,
}

#[derive(Args)]
pub struct CheckArgs {
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
    CsvOrgRepoSyncRecordStore::validate(data_dir)
        .map_err(|error| format!("CSV 仓储校验失败: {error}"))?;
    println!("CSV 仓储校验通过: {}", data_dir.display());
    Ok(())
}

async fn serve(args: ServeArgs) -> Result<(), String> {
    validate_serve_args(&args)?;
    let token = read_token(args.access_token_file.as_deref())?;
    let _data_lock = DataDirectoryLock::acquire(&args.data_dir)?;
    let store = CsvOrgRepoSyncRecordStore::open(&args.data_dir)
        .map_err(|error| format!("无法打开 CSV 仓储: {error}"))?;
    let actor = SyncRecordActor::start(store);
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
    if !args.listen.ip().is_loopback()
        && (!args.allow_non_loopback || args.access_token_file.is_none())
    {
        return Err("非回环监听必须同时指定 --allow-non-loopback 和 --access-token-file".into());
    }
    Ok(())
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
        let path = data_dir.join(".org-tasks-httpd.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&path)
            .map_err(|error| format!("无法打开数据目录锁 {}: {error}", path.display()))?;
        file.try_lock()
            .map_err(|error| format!("CSV 数据目录已被其他服务占用: {error}"))?;
        Ok(Self { _file: file })
    }
}

#[derive(Clone)]
struct AppState {
    actor: SyncRecordActor,
    token: Option<Arc<str>>,
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route(
            "/v1/repos/:repo_id/sync-records",
            post(append_sync_record).get(list_sync_records),
        )
        .with_state(state)
}

async fn health() -> Response {
    (
        StatusCode::OK,
        Json(json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION") })),
    )
        .into_response()
}

async fn append_sync_record(
    State(state): State<AppState>,
    AxumPath(repo_id): AxumPath<String>,
    headers: HeaderMap,
    Json(record): Json<OrgRepoSyncRecord>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    dispatch(
        &state.actor,
        HttpRequest {
            method: HttpMethod::Post,
            path: format!("/v1/repos/{repo_id}/sync-records"),
            body: Some(HttpBody::SyncRecord(record)),
        },
    )
    .await
}

async fn list_sync_records(
    State(state): State<AppState>,
    AxumPath(repo_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    dispatch(
        &state.actor,
        HttpRequest {
            method: HttpMethod::Get,
            path: format!("/v1/repos/{repo_id}/sync-records"),
            body: None,
        },
    )
    .await
}

fn authorize(state: &AppState, headers: &HeaderMap) -> Result<(), Response> {
    let Some(token) = &state.token else {
        return Ok(());
    };
    let expected = format!("Bearer {token}");
    if headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        == Some(expected.as_str())
    {
        Ok(())
    } else {
        Err((StatusCode::UNAUTHORIZED, Json(json!({ "error": "未授权" }))).into_response())
    }
}

async fn dispatch(actor: &SyncRecordActor, request: HttpRequest) -> Response {
    match actor.handle(request).await {
        Ok(response) => response_to_http(response),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "服务 actor 不可用", "detail": error })),
        )
            .into_response(),
    }
}

fn response_to_http(response: HttpResponse) -> Response {
    let status = StatusCode::from_u16(response.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let body = match response.body {
        Some(HttpResponseBody::SyncRecord(record)) => json!({ "data": record }),
        Some(HttpResponseBody::SyncRecords(records)) => json!({ "data": records }),
        Some(HttpResponseBody::Error(error)) => json!({ "error": error.to_string() }),
        None => Value::Null,
    };
    (status, Json(body)).into_response()
}

struct SyncRecordActor {
    sender: mpsc::Sender<ActorCommand>,
}

impl Clone for SyncRecordActor {
    fn clone(&self) -> Self {
        Self {
            sender: self.sender.clone(),
        }
    }
}

struct ActorCommand {
    request: HttpRequest,
    response: oneshot::Sender<HttpResponse>,
}

impl SyncRecordActor {
    fn start(store: CsvOrgRepoSyncRecordStore) -> Self {
        let (sender, mut receiver) = mpsc::channel::<ActorCommand>(ACTOR_CHANNEL_CAPACITY);
        tokio::spawn(async move {
            let mut api = HttpApi::new(store);
            while let Some(command) = receiver.recv().await {
                let response = api.handle(command.request).await;
                let _ = command.response.send(response);
            }
        });
        Self { sender }
    }

    async fn handle(&self, request: HttpRequest) -> Result<HttpResponse, String> {
        let (sender, receiver) = oneshot::channel();
        self.sender
            .send(ActorCommand {
                request,
                response: sender,
            })
            .await
            .map_err(|_| "服务 actor 已停止".to_string())?;
        receiver
            .await
            .map_err(|_| "服务 actor 未返回响应".to_string())
    }
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unprotected_non_loopback_listener() {
        let args = ServeArgs {
            data_dir: PathBuf::from("/tmp/org-tasks"),
            listen: "0.0.0.0:8787".parse().unwrap(),
            shutdown_timeout_secs: 10,
            log_level: LogLevel::Info,
            access_token_file: None,
            allow_non_loopback: false,
        };
        assert!(validate_serve_args(&args).is_err());
    }

    #[test]
    fn loopback_listener_is_allowed_without_token() {
        let args = ServeArgs {
            data_dir: PathBuf::from("/tmp/org-tasks"),
            listen: "127.0.0.1:8787".parse().unwrap(),
            shutdown_timeout_secs: 10,
            log_level: LogLevel::Info,
            access_token_file: None,
            allow_non_loopback: false,
        };
        assert!(validate_serve_args(&args).is_ok());
    }
}
