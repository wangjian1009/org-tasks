//! WebDAV 仓库同步策略。
//!
//! 模块实现同步决策、认证、条件写入与同步记录构造。

mod merge;
pub mod runtime;
pub use merge::*;

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
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

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebDavSyncContextDetail;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebDavSyncFileDetail {
    pub etag: Option<String>,
    pub modified_at: Option<TimestampMs>,
    pub size: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_versions: Option<Vec<crate::OrgTaskFingerprint>>,
}

impl From<RemoteFileVersion> for WebDavSyncFileDetail {
    fn from(version: RemoteFileVersion) -> Self {
        Self {
            etag: version.etag,
            modified_at: version.modified_at,
            size: version.size,
            task_versions: None,
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

    async fn synchronize_repo(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
        options: &crate::SyncOptions,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>, CoreError> {
        let history = repo.sync_history::<Self>().await?;
        let mut record =
            OrgRepoSyncRecord::new(format!("webdav-{}-{started_at}", repo.id), started_at)?
                .with_kind(Self::KIND)
                .with_context_detail(WebDavSyncContextDetail::default());
        self.report(WebDavSyncEvent::Started {
            repo_id: repo.id.clone(),
        });
        if cancellation.is_cancelled() {
            record.finish(OrgRepoSyncResult::Cancelled, finished_at()?)?;
            self.report(WebDavSyncEvent::Finished {
                result: OrgRepoSyncResult::Cancelled,
                files: 0,
            });
            return Ok(record);
        }
        progress.report("Listing", 0, 0, None);
        self.report(WebDavSyncEvent::ListingStarted);
        let remote_files = match runtime::list_remote(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            progress,
            self.monitor.as_ref(),
        )
        .await
        {
            Ok(files) => files,
            Err(_) => {
                record.finish(OrgRepoSyncResult::Failed, finished_at()?)?;
                self.report(WebDavSyncEvent::Finished {
                    result: OrgRepoSyncResult::Failed,
                    files: 0,
                });
                return Ok(record);
            }
        };
        let remote_files = remote_files
            .into_iter()
            .filter(|file| !options.excludes_path(&file.path))
            .collect::<Vec<_>>();
        self.report(WebDavSyncEvent::Listed {
            files: remote_files.len(),
        });
        let mut remote_by_path = BTreeMap::new();
        for remote in remote_files {
            if remote_by_path.insert(remote.path.clone(), remote).is_some() {
                return Err(CoreError::InvalidState("WebDAV 列举结果包含重复文件路径"));
            }
        }

        let pending = repo.pending_writes().await?;
        let mut paths = repo
            .files
            .iter()
            .filter(|file| !options.excludes_path(&file.path))
            .map(|file| file.path.clone())
            .collect::<BTreeSet<_>>();
        paths.extend(remote_by_path.keys().cloned());
        let mut failed = false;

        // 空的失败/取消记录不代表已经建立过仓库基准。
        let initial_sync = !history.iter().any(|record| {
            record.result == Some(OrgRepoSyncResult::Succeeded) || !record.files.is_empty()
        });
        let unresolved_paths = conflict_syncs(&history)
            .into_iter()
            .flat_map(|sync| sync.paths)
            .collect::<BTreeSet<_>>();
        let total = paths.len();
        for (index, path) in paths.into_iter().enumerate() {
            if cancellation.is_cancelled() {
                record.finish(OrgRepoSyncResult::Cancelled, finished_at()?)?;
                progress.report("Cancelled", index, total, None);
                self.report(WebDavSyncEvent::Finished {
                    result: OrgRepoSyncResult::Cancelled,
                    files: record.files.len(),
                });
                return Ok(record);
            }
            progress.report("Synchronizing", index, total, Some(path.clone()));
            self.report(WebDavSyncEvent::FileStarted {
                path: path.clone(),
                index,
                total,
            });
            let local = repo.files.iter().find(|file| file.path == path).cloned();
            let remote = remote_by_path.get(&path).cloned();
            let baseline = latest_file_record(&history, &path).cloned();
            let unresolved_without_baseline =
                baseline.is_none() && unresolved_paths.contains(&path);
            let outcome = if unresolved_without_baseline {
                Ok(conflict_record(repo, path, local, remote))
            } else if initial_sync {
                // 首次同步没有可用基线。单端文件没有“双方都修改”的可能，
                // 可以直接建立同步基线；只有两端都存在的文件需要用户确认。
                match (local, remote) {
                    (Some(local), None) => self.create_remote(repo, &local, progress).await,
                    (None, Some(remote)) => self.download_remote(repo, remote, progress).await,
                    (Some(local), Some(remote)) => {
                        Ok(conflict_record(repo, path, Some(local), Some(remote)))
                    }
                    (None, None) => continue,
                }
            } else {
                match (local, remote, baseline) {
                    (Some(local), None, None) => self.create_remote(repo, &local, progress).await,
                    (Some(local), Some(remote), None) => {
                        Ok(conflict_record(repo, path, Some(local), Some(remote)))
                    }
                    (None, Some(remote), _) => self.download_remote(repo, remote, progress).await,
                    (Some(local), None, Some(baseline))
                        if remote_version_for(&baseline).is_some() =>
                    {
                        Ok(remote_deleted_record(repo, path, local, baseline))
                    }
                    (Some(local), None, Some(_)) => {
                        self.create_remote(repo, &local, progress).await
                    }
                    (Some(local), Some(remote), Some(baseline)) => {
                        let local_version = local_version(&local);
                        let local_changed = baseline.local_version.as_ref() != Some(&local_version)
                            || pending.iter().any(|intent| intent.relative_path == path);
                        let remote_changed =
                            remote_version_for(&baseline).as_ref() != Some(&remote.version);
                        match (local_changed, remote_changed) {
                            (false, false) => {
                                Ok(unchanged_record(repo, path, local_version, remote.version))
                            }
                            (false, true) => self.download_remote(repo, remote, progress).await,
                            (true, false) => {
                                self.replace_remote(repo, &local, baseline, progress).await
                            }
                            (true, true) => {
                                Ok(conflict_record(repo, path, Some(local), Some(remote)))
                            }
                        }
                    }
                    (None, None, _) => continue,
                }
            };

            match outcome {
                Ok(file_record) => {
                    failed |= matches!(
                        file_record.state,
                        OrgRepoSyncFileState::Failed
                            | OrgRepoSyncFileState::Conflict
                            | OrgRepoSyncFileState::RemoteDeleted
                    );
                    record.append_file(file_record.clone())?;
                    self.report(WebDavSyncEvent::FileProcessed {
                        record: file_record,
                    });
                }
                Err(error) => return Err(error),
            }
        }
        let result = if failed {
            OrgRepoSyncResult::Failed
        } else {
            OrgRepoSyncResult::Succeeded
        };
        record.finish(result, finished_at()?)?;
        progress.report("Finished", total, total, None);
        self.report(WebDavSyncEvent::Finished {
            result,
            files: record.files.len(),
        });
        Ok(record)
    }

    async fn create_remote(
        &self,
        repo: &OrgRepo,
        local: &OrgFile,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, CoreError> {
        let local_version = local_version(local);
        match runtime::put_remote(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            &local.path,
            &local.source_bytes,
            WebDavPutCondition::CreateOnly,
            progress,
            self.monitor.as_ref(),
        )
        .await
        {
            Ok(remote_version) => success_record(
                repo,
                local.path.clone(),
                OrgRepoSyncFileAction::Created,
                local_version,
                remote_version,
            ),
            Err(error) => Ok(failed_record(
                repo,
                local.path.clone(),
                local_version,
                error.summary(),
            )),
        }
    }

    async fn replace_remote(
        &self,
        repo: &OrgRepo,
        local: &OrgFile,
        baseline: OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, CoreError> {
        let local_version = local_version(local);
        let Some(etag) = remote_version_for(&baseline)
            .as_ref()
            .and_then(|version| version.etag.clone())
        else {
            return Ok(failed_record(
                repo,
                local.path.clone(),
                local_version,
                WebDavError::Conflict("远端缺少 ETag，不能条件更新".into()).summary(),
            ));
        };
        match runtime::put_remote(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            &local.path,
            &local.source_bytes,
            WebDavPutCondition::Match(etag),
            progress,
            self.monitor.as_ref(),
        )
        .await
        {
            Ok(remote_version) => success_record(
                repo,
                local.path.clone(),
                OrgRepoSyncFileAction::Uploaded,
                local_version,
                remote_version,
            ),
            Err(error) => Ok(failed_record(
                repo,
                local.path.clone(),
                local_version,
                error.summary(),
            )),
        }
    }

    async fn download_remote(
        &self,
        repo: &mut OrgRepo,
        remote: WebDavRemoteFile,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, CoreError> {
        match runtime::get_remote(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            &remote.path,
            progress,
            self.monitor.as_ref(),
        )
        .await
        {
            Ok(source_bytes) => {
                let file = repo.parse_file(remote.path.clone(), source_bytes)?;
                runtime::write_downloaded_file(repo, &file.path, &file.source_bytes).await?;
                let local_version = local_version(&file);
                if let Some(index) = repo.files.iter().position(|item| item.path == file.path) {
                    repo.files[index] = file;
                } else {
                    repo.files.push(file);
                }
                success_record(
                    repo,
                    remote.path,
                    OrgRepoSyncFileAction::Downloaded,
                    local_version,
                    remote.version,
                )
            }
            Err(error) => Ok(failed_record(
                repo,
                remote.path,
                LocalFileVersion::new("unavailable".into())?,
                error.summary(),
            )),
        }
    }
}

impl SyncPolicy for WebDavSyncPolicy {
    const KIND: &'static str = "webdav";
    type ContextDetail = WebDavSyncContextDetail;
    type FileDetail = WebDavSyncFileDetail;

    fn synchronize(
        &self,
        context: &mut SyncContext<'_>,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> impl Future<
        Output = Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError>,
    > + Send {
        self.synchronize_repo(
            context.repo,
            context.started_at,
            &context.options,
            cancellation,
            progress,
        )
    }
}

fn success_record(
    repo: &OrgRepo,
    path: String,
    action: OrgRepoSyncFileAction,
    local: LocalFileVersion,
    remote: RemoteFileVersion,
) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, CoreError> {
    let mut detail = WebDavSyncFileDetail::from(remote);
    detail.task_versions = repo
        .files
        .iter()
        .find(|file| file.path == path)
        .map(crate::task_fingerprints);
    Ok(OrgRepoSyncFileRecord::<WebDavSyncFileDetail>::new(
        path,
        action,
        OrgRepoSyncFileState::Synchronized,
    )?
    .with_local_version(Some(local))
    .with_detail(detail))
}

fn unchanged_record(
    repo: &OrgRepo,
    path: String,
    local: LocalFileVersion,
    remote: RemoteFileVersion,
) -> OrgRepoSyncFileRecord<WebDavSyncFileDetail> {
    let mut detail = WebDavSyncFileDetail::from(remote);
    detail.task_versions = repo
        .files
        .iter()
        .find(|file| file.path == path)
        .map(crate::task_fingerprints);
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Unchanged,
        OrgRepoSyncFileState::Synchronized,
    )
    .expect("未变化文件记录应有效")
    .with_local_version(Some(local))
    .with_detail(detail)
}

fn conflict_record(
    _repo: &OrgRepo,
    path: String,
    local: Option<OrgFile>,
    remote: Option<WebDavRemoteFile>,
) -> OrgRepoSyncFileRecord<WebDavSyncFileDetail> {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Conflicted,
        OrgRepoSyncFileState::Conflict,
    )
    .expect("冲突文件记录应有效")
    .with_local_version(local.as_ref().map(local_version))
    .with_detail(
        remote
            .map(|file| WebDavSyncFileDetail::from(file.version))
            .unwrap_or_default(),
    )
    .with_error(WebDavError::Conflict("本地与远端均有未确认变更".into()).summary())
}

fn remote_deleted_record(
    _repo: &OrgRepo,
    path: String,
    local: OrgFile,
    baseline: OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
) -> OrgRepoSyncFileRecord<WebDavSyncFileDetail> {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Skipped,
        OrgRepoSyncFileState::RemoteDeleted,
    )
    .expect("远端删除文件记录应有效")
    .with_local_version(Some(local_version(&local)))
    .with_detail(baseline.detail)
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
}

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

fn remote_version_for(
    file: &OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
) -> Option<RemoteFileVersion> {
    if file.detail.etag.is_some() {
        Some(RemoteFileVersion::from(file.detail.clone()))
    } else {
        None
    }
}

fn local_version(file: &OrgFile) -> LocalFileVersion {
    LocalFileVersion::from_bytes(file.source_bytes())
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
    use crate::NewTask;
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
                    "HTTP/1.1 {} Result\r\nContent-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n{}",
                    exchange.status,
                    exchange.response.len(),
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
            put(second, "if-match: \"v1\"", 412),
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
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "First".into(),
                ..Default::default()
            },
            true,
        )
        .await
        .unwrap();
        assert_eq!(
            sync(&mut repo, &policy, 1).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "Second".into(),
                ..Default::default()
            },
            true,
        )
        .await
        .unwrap();
        assert_eq!(
            sync(&mut repo, &policy, 2).await.result,
            Some(OrgRepoSyncResult::Failed)
        );
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        assert_eq!(repo.files[0].source_bytes(), second);
        assert_eq!(
            sync(&mut repo, &policy, 3).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn repeated_remote_conflict_keeps_local_task_and_does_not_upload() {
        let first = b"* TODO First\n";
        let (url, worker) = server(vec![
            propfind("<multistatus xmlns=\"DAV:\"/>".into()),
            propfind("<multistatus xmlns=\"DAV:\"/>".into()),
            put(first, "if-none-match: *", 201),
            propfind(listing("\"v2\"", first.len())),
            propfind(listing("\"v2\"", first.len())),
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
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "First".into(),
                ..Default::default()
            },
            true,
        )
        .await
        .unwrap();
        sync(&mut repo, &policy, 1).await;
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "Second".into(),
                ..Default::default()
            },
            true,
        )
        .await
        .unwrap();
        for time in [2, 3] {
            let record = sync(&mut repo, &policy, time).await;
            assert_eq!(record.result, Some(OrgRepoSyncResult::Failed));
            assert_eq!(record.files[0].state, OrgRepoSyncFileState::Conflict);
            assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
            assert_eq!(
                repo.files[0].source_bytes(),
                b"* TODO First\n* TODO Second\n"
            );
        }
        worker.await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
