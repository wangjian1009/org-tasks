//! APP 进程内的查询与批量修改接口；与界面共享同一个 Workspace。
use crate::{CoreError, CoreQuery, CoreQueryResult, OrgWorkspace, TaskOperationGroup};
use axum::{
    Json, Router,
    extract::{State, rejection::JsonRejection},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use serde_json::{Value, json};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tokio::{net::TcpListener, sync::oneshot, task::JoinHandle};

type SharedWorkspace = Arc<Mutex<OrgWorkspace>>;

pub struct EmbeddedHttpServer {
    address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<Result<(), CoreError>>>,
}
impl EmbeddedHttpServer {
    pub(crate) async fn start(
        workspace: SharedWorkspace,
        address: SocketAddr,
    ) -> Result<Self, CoreError> {
        if !address.ip().is_loopback() {
            return Err(CoreError::InvalidInput("APP 内嵌接口仅允许回环监听"));
        }
        let listener = TcpListener::bind(address)
            .await
            .map_err(|error| CoreError::Store(format!("无法启动 APP HTTP 接口: {error}")))?;
        let address = listener
            .local_addr()
            .map_err(|error| CoreError::Store(error.to_string()))?;
        let router = Router::new()
            .route("/api/v1/queries", post(queries))
            .route("/api/v1/task-operation-groups", post(modify))
            .with_state(workspace);
        let (shutdown, stopped) = oneshot::channel();
        let task = tokio::spawn(async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(async {
                    let _ = stopped.await;
                })
                .await
                .map_err(|error| CoreError::Store(format!("APP HTTP 接口运行失败: {error}")))
        });
        Ok(Self {
            address,
            shutdown: Some(shutdown),
            task: Some(task),
        })
    }
    pub fn address(&self) -> SocketAddr {
        self.address
    }
    pub(crate) async fn stop(&mut self) -> Result<(), CoreError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.await
                .map_err(|error| CoreError::Store(format!("停止 APP HTTP 接口失败: {error}")))??;
        }
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
    let runtime = tokio::runtime::Handle::current();
    let results = tokio::task::spawn_blocking(move || {
        let workspace = workspace
            .lock()
            .map_err(|_| CoreError::Store("Workspace 锁不可用".into()))?;
        runtime.block_on(workspace.query(&queries))
    })
    .await
    .map_err(|_| CoreError::Store("查询请求执行失败".into()))??;
    let results = results.into_iter().map(|result| match result {
        CoreQueryResult::Task(result) => json!({"type":"task","result":{"tasks":result.tasks,"categories":result.categories}}),
        CoreQueryResult::File(files) => json!({"type":"file","result":files}),
        CoreQueryResult::Notification(notifications) => json!({"type":"notification","result":notifications}),
    }).collect::<Vec<_>>();
    Ok(Json(json!(results)))
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
    let runtime = tokio::runtime::Handle::current();
    tokio::task::spawn_blocking(move || {
        let mut workspace = workspace
            .lock()
            .map_err(|_| CoreError::Store("Workspace 锁不可用".into()))?;
        runtime.block_on(workspace.execute_task_operations(&group))
    })
    .await
    .map_err(|_| CoreError::Store("修改请求执行失败".into()))??;
    Ok(Json(
        json!({"operationId":operation_id,"status":"committed"}),
    ))
}
