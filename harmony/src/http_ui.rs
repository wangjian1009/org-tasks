//! Harmony 自有导航和仓库配置路由。
use axum::{
    Json,
    extract::{OriginalUri, State, rejection::JsonRejection},
    http::{Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{MethodRouter, get},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::oneshot;

#[derive(Deserialize)]
struct HostResponse {
    status: u16,
    body: Value,
}
struct Pending {
    owner: u64,
    sender: oneshot::Sender<HostResponse>,
}
static PENDING: OnceLock<Mutex<HashMap<u64, Pending>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
const NAVIGATION_PATH: &str = "/api/v1/ui/navigation";
const REPOSITORIES_PATH: &str = "/api/v1/repositories";
fn pending() -> &'static Mutex<HashMap<u64, Pending>> {
    PENDING.get_or_init(Default::default)
}

pub(crate) struct UiBridge {
    owner: u64,
    monitor: u64,
}
#[cfg(not(test))]
unsafe extern "C" {
    fn org_tasks_harmony_http_ui_request(monitor: u64, id: u64, request: *const std::ffi::c_char);
    fn org_tasks_harmony_http_monitor_release(monitor: u64);
}
impl Drop for UiBridge {
    fn drop(&mut self) {
        #[cfg(not(test))]
        if self.monitor != 0 {
            unsafe {
                org_tasks_harmony_http_monitor_release(self.monitor);
            }
        }
    }
}
impl UiBridge {
    pub(crate) fn new(owner: u64, monitor: u64) -> Arc<Self> {
        Arc::new(Self { owner, monitor })
    }
    pub(crate) fn register(
        self: &Arc<Self>,
        server: &mut org_tasks_core::http_server::EmbeddedHttpServer,
    ) -> Result<(), org_tasks_core::CoreError> {
        if self.monitor != 0 {
            let handler: MethodRouter = get(read).put(write).with_state(self.clone());
            server.register_handler(NAVIGATION_PATH, handler)?;
            let handler = get(read)
                .post(write)
                .patch(write)
                .delete(write)
                .with_state(self.clone());
            server.register_handler(REPOSITORIES_PATH, handler)?;
        }
        Ok(())
    }
    async fn dispatch(&self, path: &str, method: &str, body: Value) -> Response {
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        pending().lock().unwrap().insert(
            id,
            Pending {
                owner: self.owner,
                sender,
            },
        );
        let _cleanup = PendingGuard(id);
        let request = json!({"path":path,"method":method,"body":body.to_string()}).to_string();
        #[cfg(not(test))]
        {
            let request = std::ffi::CString::new(request).expect("JSON 不包含 NUL 字节");
            unsafe {
                org_tasks_harmony_http_ui_request(self.monitor, id, request.as_ptr());
            }
        }
        #[cfg(test)]
        if self.monitor == 1 {
            respond(
                id,
                &json!({"status":200,"body":serde_json::from_str::<Value>(&request).unwrap()})
                    .to_string(),
            );
        }
        match tokio::time::timeout(Duration::from_secs(15), receiver).await {
            Ok(Ok(response)) => {
                let body = match response.body {
                    Value::String(value) => serde_json::from_str(&value).unwrap_or(Value::Null),
                    value => value,
                };
                (
                    StatusCode::from_u16(response.status)
                        .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
                    Json(body),
                )
                    .into_response()
            }
            _ => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "unavailable",
                "界面请求已停止或超时",
            ),
        }
    }
}
struct PendingGuard(u64);
impl Drop for PendingGuard {
    fn drop(&mut self) {
        pending().lock().unwrap().remove(&self.0);
    }
}
pub(crate) fn respond(id: u64, response: &str) {
    let response =
        serde_json::from_str::<HostResponse>(response).unwrap_or_else(|_| HostResponse {
            status: 500,
            body: json!({"error":{"code":"store","message":"界面响应格式无效"}}),
        });
    if let Some(request) = pending().lock().unwrap().remove(&id) {
        let _ = request.sender.send(response);
    }
}
pub(crate) fn cancel(owner: u64) {
    pending()
        .lock()
        .unwrap()
        .retain(|_, value| value.owner != owner);
}
fn error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}
async fn read(State(bridge): State<Arc<UiBridge>>, OriginalUri(uri): OriginalUri) -> Response {
    bridge.dispatch(uri.path(), "GET", Value::Null).await
}
async fn write(
    State(bridge): State<Arc<UiBridge>>,
    OriginalUri(uri): OriginalUri,
    method: Method,
    body: Result<Json<Value>, JsonRejection>,
) -> Response {
    match body {
        Ok(Json(body)) => bridge.dispatch(uri.path(), method.as_str(), body).await,
        Err(_) => error(
            StatusCode::BAD_REQUEST,
            "invalidInput",
            "请求必须为符合接口定义的 JSON",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn responses_and_cancellation_do_not_mix_requests_or_leave_pending_entries() {
        let bridge = UiBridge::new(100, 1);
        let response = bridge
            .dispatch(
                NAVIGATION_PATH,
                "PUT",
                json!({"pages":[{"url":"pages/Files"}]}),
            )
            .await;
        assert_eq!(response.status(), StatusCode::OK);
        let blocked = UiBridge::new(101, 2);
        let running =
            tokio::spawn(
                async move { blocked.dispatch(NAVIGATION_PATH, "GET", Value::Null).await },
            );
        tokio::task::yield_now().await;
        cancel(101);
        assert_eq!(
            running.await.unwrap().status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert!(
            !pending()
                .lock()
                .unwrap()
                .values()
                .any(|value| value.owner == 101)
        );
        respond(u64::MAX, "{}");
    }
}
