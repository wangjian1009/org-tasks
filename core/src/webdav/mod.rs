//! WebDAV 仓库同步策略。
//!
//! 模块实现同步决策、认证、条件写入与同步记录构造。

mod archive;
mod history;
mod remote_base;
mod synchronize;
pub(crate) mod session;
pub(crate) mod transaction;
pub use archive::*;
pub mod runtime;
#[cfg(test)]
pub(crate) use history::is_conflict as history_is_conflict;
pub use history::*;
#[cfg(test)]
mod sync_tests;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::model::{
    LocalFileVersion, OrgFile, OrgRepo, OrgRepoSyncErrorCategory, OrgRepoSyncErrorSummary,
    OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState, OrgRepoSyncRecord,
    OrgRepoSyncResult, RemoteFileVersion, SyncCancellation, SyncContext, SyncPolicy,
    SyncProgressReporter,
};
use crate::OrgRepoSyncFileOutcome;
use crate::{CoreError, TimestampMs};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebDavEndpoint {
    pub base_url: String,
}

impl WebDavEndpoint {
    pub fn new(base_url: String) -> Result<Self, CoreError> {
        let Some(authority) = base_url
            .strip_prefix("https://")
            .or_else(|| base_url.strip_prefix("http://"))
        else {
            return Err(CoreError::InvalidInput("WebDAV 地址必须使用 HTTP 或 HTTPS"));
        };
        let host = authority.split('/').next().unwrap_or_default();
        if base_url.trim() != base_url || host.is_empty() || host.contains('@') {
            return Err(CoreError::InvalidInput("WebDAV 地址格式无效"));
        }
        Ok(Self { base_url })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WebDavSyncContextDetail {
    pub format_version: u32,
}

// 旧单元结构序列化为 null；兼容读取，不把旧 files/ 日志当作新布局。
impl<'de> Deserialize<'de> for WebDavSyncContextDetail {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Detail {
            #[serde(default)]
            format_version: u32,
        }
        let detail = Option::<Detail>::deserialize(deserializer)?;
        let format_version = detail.map_or(0, |d| d.format_version);
        if format_version > 4 {
            return Err(serde::de::Error::custom("不支持的同步历史版本"));
        }
        Ok(Self { format_version })
    }
}

impl Default for WebDavSyncContextDetail {
    fn default() -> Self {
        Self { format_version: 2 }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebDavSyncFileDetail {
    pub etag: Option<String>,
    pub modified_at: Option<TimestampMs>,
    pub size: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_versions: Option<Vec<crate::OrgTaskFingerprint>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub synced_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive: Option<WebDavFileArchive>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deleted_archive: Option<WebDavFileArchive>,
}

impl From<RemoteFileVersion> for WebDavSyncFileDetail {
    fn from(version: RemoteFileVersion) -> Self {
        Self {
            etag: version.etag,
            modified_at: version.modified_at,
            size: version.size,
            task_versions: None,
            synced_source: None,
            archive: None,
            deleted_archive: None,
        }
    }
}

impl From<WebDavSyncFileDetail> for RemoteFileVersion {
    fn from(detail: WebDavSyncFileDetail) -> Self {
        Self {
            etag: detail.etag,
            modified_at: detail.modified_at,
            size: detail.size,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebDavRemoteFile {
    pub path: String,
    pub version: RemoteFileVersion,
}

impl WebDavRemoteFile {
    pub fn new(path: String, version: RemoteFileVersion) -> Result<Self, CoreError> {
        validate_path(&path)?;
        Ok(Self { path, version })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WebDavPutCondition {
    CreateOnly,
    Match(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WebDavError {
    Network(String),
    Authentication(String),
    Tls(String),
    Protocol(String),
    Conflict(String),
}

/// WebDAV 同步的脱敏观察事件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WebDavSyncEvent {
    Started {
        repo_id: String,
    },
    ListingStarted,
    Listed {
        files: usize,
    },
    FileStarted {
        path: String,
        index: usize,
        total: usize,
    },
    FileProcessed {
        record: OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
    },
    HttpRequest {
        method: String,
        path: String,
    },
    HttpResponse {
        method: String,
        path: String,
        status: Option<u16>,
    },
    Finished {
        result: OrgRepoSyncResult,
        files: usize,
    },
}

/// 观察一次 WebDAV 同步过程的端口。
pub trait WebDavSyncMonitor: Send + Sync {
    fn on_event(&self, event: WebDavSyncEvent);
}

struct NoopWebDavSyncMonitor;

impl WebDavSyncMonitor for NoopWebDavSyncMonitor {
    fn on_event(&self, _: WebDavSyncEvent) {}
}

impl WebDavError {
    fn summary(&self) -> OrgRepoSyncErrorSummary {
        let (category, retryable, message) = match self {
            Self::Network(message) => (OrgRepoSyncErrorCategory::Network, true, message),
            Self::Authentication(message) => {
                (OrgRepoSyncErrorCategory::Authentication, false, message)
            }
            Self::Tls(message) => (OrgRepoSyncErrorCategory::Tls, false, message),
            Self::Protocol(message) => (OrgRepoSyncErrorCategory::Validation, false, message),
            Self::Conflict(message) => (OrgRepoSyncErrorCategory::Conflict, false, message),
        };
        OrgRepoSyncErrorSummary::new(category, retryable, redact(message))
            .expect("WebDAV 错误摘要必须有效")
    }
}

/// 使用 WebDAV 将仓库文件快照与远端协调的同步策略。
pub struct WebDavSyncPolicy {
    endpoint: WebDavEndpoint,
    client: Client,
    username: String,
    password: String,
    monitor: Arc<dyn WebDavSyncMonitor>,
}

impl WebDavSyncPolicy {
    pub fn new(
        endpoint: WebDavEndpoint,
        username: String,
        password: String,
    ) -> Result<Self, CoreError> {
        if username.trim().is_empty() || password.is_empty() {
            return Err(CoreError::InvalidInput("WebDAV 用户名和密码不能为空"));
        }
        let client = Client::builder()
            .build()
            .map_err(|_| CoreError::InvalidState("无法初始化 WebDAV 客户端"))?;
        Ok(Self {
            endpoint,
            client,
            username,
            password,
            monitor: Arc::new(NoopWebDavSyncMonitor),
        })
    }

    pub fn with_monitor<M>(mut self, monitor: M) -> Self
    where
        M: WebDavSyncMonitor + 'static,
    {
        self.monitor = Arc::new(monitor);
        self
    }

    /// 只检查认证与目录访问，不加载本地仓库或执行同步。
    pub async fn test_connection(&self) -> Result<(), WebDavError> {
        runtime::test_connection(&self.client, &self.username, &self.password, &self.endpoint).await
    }

    fn report(&self, event: WebDavSyncEvent) {
        self.monitor.on_event(event);
    }
}

impl SyncPolicy for WebDavSyncPolicy {
    const KIND: &'static str = "webdav";
    type ContextDetail = WebDavSyncContextDetail;
    type FileDetail = WebDavSyncFileDetail;

    async fn synchronize(
        &self,
        context: &mut SyncContext<'_>,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError> {
        self.synchronize_snapshot(context, cancellation, progress)
            .await
    }
}

fn transfer_failure(error: WebDavError) -> OrgRepoSyncErrorSummary {
    let mut summary = error.summary();
    if summary.category == OrgRepoSyncErrorCategory::Conflict {
        summary.category = OrgRepoSyncErrorCategory::Validation;
        summary.retryable = true;
    }
    summary
}

fn failed_record(
    _repo: &OrgRepo,
    path: String,
    local: LocalFileVersion,
    error: OrgRepoSyncErrorSummary,
) -> OrgRepoSyncFileRecord<WebDavSyncFileDetail> {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Skipped,
        OrgRepoSyncFileState::Failed,
    )
    .expect("失败文件记录应有效")
    .with_local_version(Some(local))
    .with_detail(WebDavSyncFileDetail::default())
    .with_error(error)
    .with_outcome(OrgRepoSyncFileOutcome::Failed)
}

#[cfg(test)]
fn latest_file_record<'a>(
    history: &'a [OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>],
    path: &str,
) -> Option<&'a OrgRepoSyncFileRecord<WebDavSyncFileDetail>> {
    history.iter().rev().find_map(|record| {
        record.files.iter().find(|file| {
            file.relative_path == path && file.state == OrgRepoSyncFileState::Synchronized
        })
    })
}

fn validate_path(path: &str) -> Result<(), CoreError> {
    if path.trim().is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(CoreError::InvalidInput(
            "WebDAV 文件路径必须是安全的相对路径",
        ));
    }
    Ok(())
}

fn redact(message: &str) -> String {
    let mut value = message.replace('\n', " ");
    if value.len() > 200 {
        value.truncate(200);
    }
    if value.trim().is_empty() {
        "WebDAV 操作失败".into()
    } else {
        value
    }
}

fn finished_at() -> Result<TimestampMs, CoreError> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::InvalidState("系统时间早于 Unix epoch"))?;
    i64::try_from(duration.as_millis()).map_err(|_| CoreError::InvalidState("当前时间超出支持范围"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn policy_rejects_empty_credentials() {
        let endpoint = WebDavEndpoint::new("https://dav.example.com/org/".into()).unwrap();
        assert!(WebDavSyncPolicy::new(endpoint, "".into(), "password".into()).is_err());
    }

    #[test]
    fn baseline_ignores_conflicts_and_keeps_successful_files_from_failed_jobs() {
        let mut initial = OrgRepoSyncRecord::new("initial".into(), 1).unwrap();
        initial
            .append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Created,
                    OrgRepoSyncFileState::Synchronized,
                )
                .unwrap()
                .with_local_version(Some(LocalFileVersion::from_bytes(b"old")))
                .with_detail(WebDavSyncFileDetail {
                    etag: Some("old".into()),
                    modified_at: None,
                    size: Some(3),
                    task_versions: None,
                    synced_source: None,
                    ..Default::default()
                }),
            )
            .unwrap();
        initial.finish(OrgRepoSyncResult::Succeeded, 2).unwrap();
        let mut conflict = OrgRepoSyncRecord::new("conflict".into(), 3).unwrap();
        conflict
            .append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Conflicted,
                    OrgRepoSyncFileState::Conflict,
                )
                .unwrap()
                .with_detail(WebDavSyncFileDetail {
                    etag: Some("new".into()),
                    modified_at: None,
                    size: Some(3),
                    task_versions: None,
                    synced_source: None,
                    ..Default::default()
                }),
            )
            .unwrap();
        // 兼容旧历史：旧代码可能将整体冲突错误地标成成功。
        conflict.finish(OrgRepoSyncResult::Succeeded, 4).unwrap();
        let history = vec![initial.clone(), conflict];
        assert_eq!(
            latest_file_record(&history, "inbox.org")
                .unwrap()
                .detail
                .etag
                .as_deref(),
            Some("old")
        );
        let mut partial = OrgRepoSyncRecord::new("partial".into(), 5).unwrap();
        partial
            .append_file(initial.files[0].clone().with_detail(WebDavSyncFileDetail {
                etag: Some("confirmed".into()),
                modified_at: None,
                size: Some(3),
                task_versions: None,
                synced_source: None,
                ..Default::default()
            }))
            .unwrap();
        partial.finish(OrgRepoSyncResult::Failed, 6).unwrap();
        let history = vec![initial, partial];
        assert_eq!(
            latest_file_record(&history, "inbox.org")
                .unwrap()
                .detail
                .etag
                .as_deref(),
            Some("confirmed")
        );
    }

    #[derive(Clone)]
    struct RecordingMonitor {
        events: Arc<Mutex<Vec<WebDavSyncEvent>>>,
    }

    impl WebDavSyncMonitor for RecordingMonitor {
        fn on_event(&self, event: WebDavSyncEvent) {
            self.events.lock().unwrap().push(event);
        }
    }

    #[tokio::test]
    async fn monitor_receives_failed_listing_lifecycle() {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-webdav-monitor-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir_all(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let monitor = RecordingMonitor {
            events: Arc::clone(&events),
        };
        let policy = WebDavSyncPolicy::new(
            WebDavEndpoint::new("http://127.0.0.1:0/org/".into()).unwrap(),
            "user".into(),
            "password".into(),
        )
        .unwrap()
        .with_monitor(monitor);

        let record = repo
            .sync(
                &policy,
                1,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await
            .unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Failed));
        let events = events.lock().unwrap();
        assert!(matches!(events[0], WebDavSyncEvent::Started { .. }));
        assert!(matches!(events[1], WebDavSyncEvent::ListingStarted));
        assert!(matches!(events[2], WebDavSyncEvent::HttpRequest { .. }));
        assert!(matches!(
            events[3],
            WebDavSyncEvent::HttpResponse { status: None, .. }
        ));
        assert!(matches!(
            events[4],
            WebDavSyncEvent::Finished {
                result: OrgRepoSyncResult::Failed,
                files: 0,
            }
        ));
        drop(events);
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}

#[cfg(test)]
mod write_tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct Exchange {
        method: &'static str,
        condition: Option<&'static str>,
        body: Option<Vec<u8>>,
        status: u16,
        response: String,
    }

    async fn server(exchanges: Vec<Exchange>) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/org/", listener.local_addr().unwrap());
        let worker = tokio::spawn(async move {
            for exchange in exchanges {
                let (mut stream, _) =
                    tokio::time::timeout(std::time::Duration::from_secs(5), listener.accept())
                        .await
                        .unwrap()
                        .unwrap();
                let mut request = Vec::new();
                let mut buffer = [0; 4096];
                let header_end;
                loop {
                    let count = stream.read(&mut buffer).await.unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&buffer[..count]);
                    if let Some(offset) =
                        request.windows(4).position(|window| window == b"\r\n\r\n")
                    {
                        header_end = offset + 4;
                        break;
                    }
                }
                let headers = String::from_utf8(request[..header_end].to_vec())
                    .unwrap()
                    .to_lowercase();
                assert!(headers.starts_with(&exchange.method.to_lowercase()));
                if let Some(condition) = exchange.condition {
                    assert!(headers.contains(condition));
                }
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("content-length: ")
                            .and_then(|value| value.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while request.len() < header_end + length {
                    let count = stream.read(&mut buffer).await.unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&buffer[..count]);
                }
                if let Some(body) = exchange.body {
                    assert_eq!(&request[header_end..], &body);
                }
                let response = format!(
                    "HTTP/1.1 {} Result\r\nContent-Length: {}\r\nETag: {}\r\nConnection: close\r\n\r\n{}",
                    exchange.status,
                    exchange.response.len(),
                    if exchange.method == "GET" {
                        exchange
                            .condition
                            .and_then(|c| c.strip_prefix("if-match: "))
                            .unwrap_or("\"v1\"")
                    } else {
                        "\"v1\""
                    },
                    exchange.response
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
        });
        (url, worker)
    }

    fn listing(etag: &str, size: usize) -> String {
        format!(
            "<multistatus xmlns=\"DAV:\"><response><href>/org/inbox.org</href><propstat><prop><getetag>{etag}</getetag><getcontentlength>{size}</getcontentlength></prop></propstat></response></multistatus>"
        )
    }

    fn propfind(response: String) -> Exchange {
        Exchange {
            method: "PROPFIND",
            condition: None,
            body: None,
            status: 207,
            response,
        }
    }

    fn put(body: &[u8], condition: &'static str, status: u16) -> Exchange {
        Exchange {
            method: "PUT",
            condition: Some(condition),
            body: Some(body.to_vec()),
            status,
            response: String::new(),
        }
    }

    async fn repository() -> OrgRepo {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-tasks-upload-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        repo
    }

    async fn sync(
        repo: &mut OrgRepo,
        policy: &WebDavSyncPolicy,
        time: i64,
    ) -> OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail> {
        repo.sync(
            policy,
            time,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn offline_tasks_upload_with_conditions_and_retry_without_losing_intents() {
        let first = b"* TODO First\n";
        let second = b"* TODO First\n* TODO Second\n";
        let (url, worker) = server(vec![
            propfind("<multistatus xmlns=\"DAV:\"/>".into()),
            propfind("<multistatus xmlns=\"DAV:\"/>".into()),
            put(first, "if-none-match: *", 201),
            propfind(listing("\"v1\"", first.len())),
            put(second, "if-match: \"v1\"", 500),
            propfind(listing("\"v1\"", first.len())),
            put(second, "if-match: \"v1\"", 204),
        ])
        .await;
        let policy = WebDavSyncPolicy::new(
            WebDavEndpoint::new(url).unwrap(),
            "user".into(),
            "secret".into(),
        )
        .unwrap();
        let mut repo = repository().await;
        let root = repo.root_directory.clone();
        assert_eq!(
            sync(&mut repo, &policy, 0).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        crate::model::test_support::append_fixture(&mut repo, "inbox.org", "First")
            .await
            .unwrap();
        assert_eq!(
            sync(&mut repo, &policy, 1).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        crate::model::test_support::append_fixture(&mut repo, "inbox.org", "Second")
            .await
            .unwrap();
        assert_eq!(
            sync(&mut repo, &policy, 2).await.result,
            Some(OrgRepoSyncResult::Failed)
        );
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        assert_eq!(repo.load_files(&[]).await.unwrap()[0].source_bytes(), second);
        assert_eq!(
            sync(&mut repo, &policy, 3).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn same_content_new_etag_replays_local_changes_and_updates_the_confirmed_base() {
        let first = b"* TODO First\n";
        let second = b"* TODO First\n* TODO Second\n";
        let (url, worker) = server(vec![
            propfind("<multistatus xmlns=\"DAV:\"/>".into()),
            put(first, "if-none-match: *", 201),
            propfind(listing("\"v2\"", first.len())),
            Exchange {
                method: "GET",
                condition: Some("if-match: \"v2\""),
                body: None,
                status: 200,
                response: String::from_utf8(first.to_vec()).unwrap(),
            },
            put(second, "if-match: \"v2\"", 204),
        ])
        .await;
        let policy = WebDavSyncPolicy::new(
            WebDavEndpoint::new(url).unwrap(),
            "user".into(),
            "secret".into(),
        )
        .unwrap();
        let mut repo = repository().await;
        let root = repo.root_directory.clone();
        crate::model::test_support::append_fixture(&mut repo, "inbox.org", "First")
            .await
            .unwrap();
        assert_eq!(
            sync(&mut repo, &policy, 1).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        crate::model::test_support::append_fixture(&mut repo, "inbox.org", "Second")
            .await
            .unwrap();
        let record = sync(&mut repo, &policy, 2).await;
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(repo.load_files(&[]).await.unwrap()[0].source_bytes(), second);
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
