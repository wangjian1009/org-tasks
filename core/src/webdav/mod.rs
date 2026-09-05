//! WebDAV 仓库同步策略。
//!
//! 模块实现同步决策、认证、条件写入与同步记录构造。

pub mod runtime;

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::sync::Arc;

use reqwest::Client;

use crate::model::{
    LocalFileVersion, OrgFile, OrgRepo, OrgRepoSyncErrorCategory, OrgRepoSyncErrorSummary,
    OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState, OrgRepoSyncRecord,
    OrgRepoSyncResult, RemoteFileVersion, SyncCancellation, SyncPolicy, SyncProgressReporter,
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
        record: OrgRepoSyncFileRecord,
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

    fn report(&self, event: WebDavSyncEvent) {
        self.monitor.on_event(event);
    }

    async fn synchronize_repo(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord, CoreError> {
        let mut record =
            OrgRepoSyncRecord::new(format!("webdav-{}-{started_at}", repo.id), started_at)?;
        self.report(WebDavSyncEvent::Started {
            repo_id: repo.id.clone(),
        });
        if cancellation.is_cancelled() {
            record.finish(OrgRepoSyncResult::Cancelled, started_at)?;
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
                record.finish(OrgRepoSyncResult::Failed, started_at)?;
                self.report(WebDavSyncEvent::Finished {
                    result: OrgRepoSyncResult::Failed,
                    files: 0,
                });
                return Ok(record);
            }
        };
        self.report(WebDavSyncEvent::Listed {
            files: remote_files.len(),
        });
        let mut remote_by_path = BTreeMap::new();
        for remote in remote_files {
            if remote_by_path.insert(remote.path.clone(), remote).is_some() {
                return Err(CoreError::InvalidState("WebDAV 列举结果包含重复文件路径"));
            }
        }

        let mut paths = repo
            .files
            .iter()
            .map(|file| file.path.clone())
            .collect::<BTreeSet<_>>();
        paths.extend(remote_by_path.keys().cloned());
        let mut failed = false;

        let total = paths.len();
        for (index, path) in paths.into_iter().enumerate() {
            if cancellation.is_cancelled() {
                record.finish(OrgRepoSyncResult::Cancelled, started_at)?;
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
            let baseline = latest_file_record(repo, &path).cloned();
            let outcome = match (local, remote, baseline) {
                (Some(local), None, None) => self.create_remote(repo, &local, progress).await,
                (Some(local), Some(remote), None) => Ok(conflict_record(repo, path, local, remote)),
                (None, Some(remote), _) => self.download_remote(repo, remote, progress).await,
                (Some(local), None, Some(baseline)) if baseline.remote_version.is_some() => {
                    Ok(remote_deleted_record(repo, path, local, baseline))
                }
                (Some(local), None, Some(_)) => self.create_remote(repo, &local, progress).await,
                (Some(local), Some(remote), Some(baseline)) => {
                    let local_version = local_version(&local);
                    let local_changed = baseline.local_version.as_ref() != Some(&local_version);
                    let remote_changed = baseline.remote_version.as_ref() != Some(&remote.version);
                    match (local_changed, remote_changed) {
                        (false, false) => {
                            Ok(unchanged_record(repo, path, local_version, remote.version))
                        }
                        (false, true) => self.download_remote(repo, remote, progress).await,
                        (true, false) => {
                            self.replace_remote(repo, &local, baseline, progress).await
                        }
                        (true, true) => Ok(conflict_record(repo, path, local, remote)),
                    }
                }
                (None, None, _) => continue,
            };

            match outcome {
                Ok(file_record) => {
                    failed |= file_record.state == OrgRepoSyncFileState::Failed;
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
        record.finish(result, started_at)?;
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
    ) -> Result<OrgRepoSyncFileRecord, CoreError> {
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
                None,
                error.summary(),
            )),
        }
    }

    async fn replace_remote(
        &self,
        repo: &OrgRepo,
        local: &OrgFile,
        baseline: OrgRepoSyncFileRecord,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord, CoreError> {
        let local_version = local_version(local);
        let Some(etag) = baseline
            .remote_version
            .as_ref()
            .and_then(|version| version.etag.clone())
        else {
            return Ok(failed_record(
                repo,
                local.path.clone(),
                local_version,
                baseline.remote_version,
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
                baseline.remote_version,
                error.summary(),
            )),
        }
    }

    async fn download_remote(
        &self,
        repo: &mut OrgRepo,
        remote: WebDavRemoteFile,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord, CoreError> {
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
                Some(remote.version),
                error.summary(),
            )),
        }
    }
}

impl SyncPolicy for WebDavSyncPolicy {
    fn synchronize(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> impl Future<Output = Result<OrgRepoSyncRecord, CoreError>> + Send {
        self.synchronize_repo(repo, started_at, cancellation, progress)
    }
}

fn success_record(
    _repo: &OrgRepo,
    path: String,
    action: OrgRepoSyncFileAction,
    local: LocalFileVersion,
    remote: RemoteFileVersion,
) -> Result<OrgRepoSyncFileRecord, CoreError> {
    Ok(
        OrgRepoSyncFileRecord::new(path, action, OrgRepoSyncFileState::Synchronized)?
            .with_versions(Some(local), Some(remote)),
    )
}

fn unchanged_record(
    _repo: &OrgRepo,
    path: String,
    local: LocalFileVersion,
    remote: RemoteFileVersion,
) -> OrgRepoSyncFileRecord {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Unchanged,
        OrgRepoSyncFileState::Synchronized,
    )
    .expect("未变化文件记录应有效")
    .with_versions(Some(local), Some(remote))
}

fn conflict_record(
    _repo: &OrgRepo,
    path: String,
    local: OrgFile,
    remote: WebDavRemoteFile,
) -> OrgRepoSyncFileRecord {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Conflicted,
        OrgRepoSyncFileState::Conflict,
    )
    .expect("冲突文件记录应有效")
    .with_versions(Some(local_version(&local)), Some(remote.version))
    .with_error(WebDavError::Conflict("本地与远端均有未确认变更".into()).summary())
}

fn remote_deleted_record(
    _repo: &OrgRepo,
    path: String,
    local: OrgFile,
    baseline: OrgRepoSyncFileRecord,
) -> OrgRepoSyncFileRecord {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Skipped,
        OrgRepoSyncFileState::RemoteDeleted,
    )
    .expect("远端删除文件记录应有效")
    .with_versions(Some(local_version(&local)), baseline.remote_version)
}

fn failed_record(
    _repo: &OrgRepo,
    path: String,
    local: LocalFileVersion,
    remote: Option<RemoteFileVersion>,
    error: OrgRepoSyncErrorSummary,
) -> OrgRepoSyncFileRecord {
    OrgRepoSyncFileRecord::new(
        path,
        OrgRepoSyncFileAction::Skipped,
        OrgRepoSyncFileState::Failed,
    )
    .expect("失败文件记录应有效")
    .with_versions(Some(local), remote)
    .with_error(error)
}

fn latest_file_record<'a>(repo: &'a OrgRepo, path: &str) -> Option<&'a OrgRepoSyncFileRecord> {
    repo.sync_records
        .iter()
        .rev()
        .filter(|record| record.result == Some(OrgRepoSyncResult::Succeeded))
        .find_map(|record| record.files.iter().find(|file| file.relative_path == path))
}

fn local_version(file: &OrgFile) -> LocalFileVersion {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in &file.source_bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    LocalFileVersion::new(format!("{hash:016x}")).expect("FNV-1a 哈希应有效")
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn policy_rejects_empty_credentials() {
        let endpoint = WebDavEndpoint::new("https://dav.example.com/org/".into()).unwrap();
        assert!(WebDavSyncPolicy::new(endpoint, "".into(), "password".into()).is_err());
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
        repo.load().await.unwrap();
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
