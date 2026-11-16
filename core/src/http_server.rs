//! APP 进程内的查询与批量修改接口；与界面共享同一个 Workspace。
use crate::{CoreError, CoreQuery, CoreQueryResult, OrgWorkspace, TaskOperationGroup};
use axum::{
    Json, Router,
    extract::Request,
    extract::{State, rejection::JsonRejection},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{MethodRouter, post},
};
use serde_json::{Value, json};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tokio::{net::TcpListener, sync::oneshot};
use tower::ServiceExt;

type SharedWorkspace = OrgWorkspace;

pub struct EmbeddedHttpServer {
    address: SocketAddr,
    handlers: Arc<Mutex<Router>>,
    paths: std::collections::HashSet<String>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Arc<crate::workspace_tasks::Task>,
}
impl EmbeddedHttpServer {
    pub(crate) async fn start(
        workspace: SharedWorkspace,
        address: SocketAddr,
    ) -> Result<Self, CoreError> {
        if !address.ip().is_loopback() {
            return Err(CoreError::InvalidInput("APP 内嵌接口仅允许回环监听"));
        }
        let tasks = workspace.tasks.clone();
        tasks.ensure_running()?;
        let listener = TcpListener::bind(address)
            .await
            .map_err(|error| CoreError::Store(format!("无法启动 APP HTTP 接口: {error}")))?;
        let address = listener
            .local_addr()
            .map_err(|error| CoreError::Store(error.to_string()))?;
        let handlers = Arc::new(Mutex::new(Router::new()));
        let registry = handlers.clone();
        let router = Router::new()
            .route("/api/v1/queries", post(queries))
            .route("/api/v1/task-operation-groups", post(modify))
            .with_state(workspace)
            .fallback(move |request: Request| {
                let routes = registry
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .clone();
                async move {
                    routes
                        .oneshot(request)
                        .await
                        .unwrap_or_else(|error| match error {})
                }
            });
        let (shutdown, stopped) = oneshot::channel();
        let task = tasks.spawn(move |mut stopping| async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(async move {
                    tokio::select! {
                        _ = stopped => {},
                        _ = async {
                            while !*stopping.borrow_and_update() {
                                if stopping.changed().await.is_err() { break; }
                            }
                        } => {},
                    }
                })
                .await
                .map_err(|error| CoreError::Store(format!("APP HTTP 接口运行失败: {error}")))
        })?;
        Ok(Self {
            address,
            handlers,
            paths: Default::default(),
            shutdown: Some(shutdown),
            task,
        })
    }
    /// 为当前测试服务注册宿主路径；请求与处理器均保持通用 HTTP 语义。
    pub fn register_handler(&mut self, path: &str, handler: MethodRouter) -> Result<(), CoreError> {
        if self.shutdown.is_none() {
            return Err(CoreError::InvalidState("HTTP 服务已停止"));
        }
        if !path.starts_with('/')
            || path.contains(['?', '#', ':', '*'])
            || matches!(path, "/api/v1/queries" | "/api/v1/task-operation-groups")
            || self.paths.contains(path)
        {
            return Err(CoreError::InvalidInput("HTTP 挂载路径无效或已被占用"));
        }
        let mut routes = self
            .handlers
            .lock()
            .map_err(|_| CoreError::Store("HTTP 路由锁不可用".into()))?;
        *routes = routes.clone().route(path, handler);
        self.paths.insert(path.to_owned());
        Ok(())
    }
    pub fn address(&self) -> SocketAddr {
        self.address
    }
    pub(crate) async fn stop(&mut self) -> Result<(), CoreError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.wait().await?;
        *self
            .handlers
            .lock()
            .map_err(|_| CoreError::Store("HTTP 路由锁不可用".into()))? = Router::new();
        self.paths.clear();
        Ok(())
    }
}
impl Drop for EmbeddedHttpServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

struct ApiError(CoreError);
impl From<CoreError> for ApiError {
    fn from(error: CoreError) -> Self {
        Self(error)
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match &self.0 {
            CoreError::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalidInput"),
            CoreError::InvalidState(_) | CoreError::Preview { .. } => {
                (StatusCode::CONFLICT, "invalidState")
            }
            CoreError::Store(_) => (StatusCode::INTERNAL_SERVER_ERROR, "store"),
        };
        (
            status,
            Json(json!({"error":{"code":code,"message":self.0.to_string()}})),
        )
            .into_response()
    }
}
fn invalid_json(_: JsonRejection) -> ApiError {
    ApiError(CoreError::InvalidInput("请求必须为符合接口定义的 JSON"))
}
async fn queries(
    State(workspace): State<SharedWorkspace>,
    body: Result<Json<Vec<CoreQuery>>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(queries) = body.map_err(invalid_json)?;
    let results = workspace.query(&queries).await?;
    let results = results.into_iter().map(|result| match result {
        CoreQueryResult::Task(result) => json!({"type":"task","result":{"tasks":result.tasks,"categories":result.categories,"fullFiles":result.full_files.iter().map(full_file_value).collect::<Vec<_>>()}}),
        CoreQueryResult::File(files) => json!({"type":"file","result":files}),
        CoreQueryResult::Notification(notifications) => json!({"type":"notification","result":notifications}),
    }).collect::<Vec<_>>();
    Ok(Json(json!(results)))
}
// HTTP 只编组 Core 的完整文件快照，不重新读取或解析原文。
fn full_file_value(file: &crate::OrgFile) -> Value {
    json!({
        "repoId": file.repo_id, "path": file.path,
        "source": std::str::from_utf8(file.source_bytes()).expect("Org 文件已验证 UTF-8"),
        "fileVersion": crate::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        "todo": file.todo, "title": file.title(), "category": file.category(),
        "projectName": file.project(), "hasConflict": file.has_conflict(),
        "fileTags": file.file_tags(), "specialTags": file.special_tags(),
        "documentSections": file.document_sections(), "nodes": file.nodes(),
    })
}
async fn modify(
    State(workspace): State<SharedWorkspace>,
    body: Result<Json<TaskOperationGroup>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(mut group) = body.map_err(invalid_json)?;
    if group.operation_id.is_none() {
        group.operation_id = Some(format!(
            "http/{}",
            crate::model::service::generate_repo_id()?
        ));
    }
    let operation_id = group.operation_id.clone();
    workspace.execute_task_operations(&group).await?;
    Ok(Json(
        json!({"operationId":operation_id,"status":"committed"}),
    ))
}
