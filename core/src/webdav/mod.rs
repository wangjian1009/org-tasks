//! WebDAV 仓库同步策略。
//!
//! 模块实现同步决策、条件写入与同步记录构造。HTTP、认证和 TLS 由
//! `WebDavTransport` 的宿主实现提供，因此领域 core 不依赖具体网络库。

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;

use crate::model::{
    LocalFileVersion, OrgFile, OrgRepo, OrgRepoParser, OrgRepoSourceFile, OrgRepoSyncErrorCategory,
    OrgRepoSyncErrorSummary, OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState,
    OrgRepoSyncRecord, OrgRepoSyncResult, RemoteFileVersion, SyncPolicy,
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

/// WebDAV HTTP 端口。实现必须分别执行 ~PROPFIND~ 、 ~GET~ 和条件 ~PUT~ 。
pub trait WebDavTransport: Send + Sync {
    fn list(
        &self,
        endpoint: &WebDavEndpoint,
    ) -> impl Future<Output = Result<Vec<WebDavRemoteFile>, WebDavError>> + Send;

    fn get(
        &self,
        endpoint: &WebDavEndpoint,
        path: &str,
    ) -> impl Future<Output = Result<Vec<u8>, WebDavError>> + Send;

    fn put(
        &self,
        endpoint: &WebDavEndpoint,
        path: &str,
        source_bytes: &[u8],
        condition: WebDavPutCondition,
    ) -> impl Future<Output = Result<RemoteFileVersion, WebDavError>> + Send;
}

/// 使用 WebDAV 将仓库文件快照与远端协调的同步策略。
pub struct WebDavSyncPolicy<T, P> {
    endpoint: WebDavEndpoint,
    transport: T,
    parser: P,
}

impl<T, P> WebDavSyncPolicy<T, P>
where
    T: WebDavTransport,
    P: OrgRepoParser,
{
    pub fn new(endpoint: WebDavEndpoint, transport: T, parser: P) -> Self {
        Self {
            endpoint,
            transport,
            parser,
        }
    }

    async fn synchronize_repo(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
    ) -> Result<OrgRepoSyncRecord, CoreError> {
        let mut record =
            OrgRepoSyncRecord::new(format!("webdav-{}-{started_at}", repo.id), started_at)?;
        let remote_files = match self.transport.list(&self.endpoint).await {
            Ok(files) => files,
            Err(_) => {
                record.finish(OrgRepoSyncResult::Failed, started_at)?;
                return Ok(record);
            }
        };
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

        for path in paths {
            let local = repo.files.iter().find(|file| file.path == path).cloned();
            let remote = remote_by_path.get(&path).cloned();
            let baseline = latest_file_record(repo, &path).cloned();
            let outcome = match (local, remote, baseline) {
                (Some(local), None, None) => self.create_remote(repo, &local).await,
                (Some(local), Some(remote), None) => Ok(conflict_record(repo, path, local, remote)),
                (None, Some(remote), _) => self.download_remote(repo, remote).await,
                (Some(local), None, Some(baseline)) if baseline.remote_version.is_some() => {
                    Ok(remote_deleted_record(repo, path, local, baseline))
                }
                (Some(local), None, Some(_)) => self.create_remote(repo, &local).await,
                (Some(local), Some(remote), Some(baseline)) => {
                    let local_version = local_version(&local);
                    let local_changed = baseline.local_version.as_ref() != Some(&local_version);
                    let remote_changed = baseline.remote_version.as_ref() != Some(&remote.version);
                    match (local_changed, remote_changed) {
                        (false, false) => {
                            Ok(unchanged_record(repo, path, local_version, remote.version))
                        }
                        (false, true) => self.download_remote(repo, remote).await,
                        (true, false) => self.replace_remote(repo, &local, baseline).await,
                        (true, true) => Ok(conflict_record(repo, path, local, remote)),
                    }
                }
                (None, None, _) => continue,
            };

            match outcome {
                Ok(file_record) => {
                    failed |= file_record.state == OrgRepoSyncFileState::Failed;
                    record.append_file(file_record)?;
                }
                Err(error) => return Err(error),
            }
        }
        record.finish(
            if failed {
                OrgRepoSyncResult::Failed
            } else {
                OrgRepoSyncResult::Succeeded
            },
            started_at,
        )?;
        Ok(record)
    }

    async fn create_remote(
        &self,
        repo: &OrgRepo,
        local: &OrgFile,
    ) -> Result<OrgRepoSyncFileRecord, CoreError> {
        let local_version = local_version(local);
        match self
            .transport
            .put(
                &self.endpoint,
                &local.path,
                &local.source_bytes,
                WebDavPutCondition::CreateOnly,
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
        match self
            .transport
            .put(
                &self.endpoint,
                &local.path,
                &local.source_bytes,
                WebDavPutCondition::Match(etag),
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
    ) -> Result<OrgRepoSyncFileRecord, CoreError> {
        match self.transport.get(&self.endpoint, &remote.path).await {
            Ok(source_bytes) => {
                let file = self.parser.parse_file(
                    &repo.id,
                    OrgRepoSourceFile::new(remote.path.clone(), source_bytes)?,
                )?;
                if file.repo_id != repo.id || file.path != remote.path {
                    return Err(CoreError::InvalidState(
                        "WebDAV 下载解析结果必须属于当前仓库且保持文件路径",
                    ));
                }
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

impl<T, P> SyncPolicy for WebDavSyncPolicy<T, P>
where
    T: WebDavTransport,
    P: OrgRepoParser,
{
    fn synchronize(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
    ) -> impl Future<Output = Result<OrgRepoSyncRecord, CoreError>> + Send {
        self.synchronize_repo(repo, started_at)
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
    OrgRepoSourceFile::new(path.to_owned(), Vec::new()).map(|_| ())
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
    use crate::model::OrgRepoParser;
    use std::task::{Context, Poll, Waker};

    struct Parser;

    impl OrgRepoParser for Parser {
        fn parse_file(
            &self,
            repo_id: &String,
            source: OrgRepoSourceFile,
        ) -> Result<OrgFile, CoreError> {
            OrgFile::new(
                repo_id.clone(),
                source.path,
                source.source_bytes,
                Vec::new(),
            )
        }
    }

    struct EmptyRemote;

    impl WebDavTransport for EmptyRemote {
        fn list(
            &self,
            _: &WebDavEndpoint,
        ) -> impl Future<Output = Result<Vec<WebDavRemoteFile>, WebDavError>> + Send {
            async { Ok(Vec::new()) }
        }

        fn get(
            &self,
            _: &WebDavEndpoint,
            _: &str,
        ) -> impl Future<Output = Result<Vec<u8>, WebDavError>> + Send {
            async { Err(WebDavError::Protocol("不应下载".into())) }
        }

        fn put(
            &self,
            _: &WebDavEndpoint,
            _: &str,
            _: &[u8],
            condition: WebDavPutCondition,
        ) -> impl Future<Output = Result<RemoteFileVersion, WebDavError>> + Send {
            assert_eq!(condition, WebDavPutCondition::CreateOnly);
            async { Ok(RemoteFileVersion::new(Some("etag-1".into()), None, Some(4)).unwrap()) }
        }
    }

    struct DownloadRemote;

    impl WebDavTransport for DownloadRemote {
        fn list(
            &self,
            _: &WebDavEndpoint,
        ) -> impl Future<Output = Result<Vec<WebDavRemoteFile>, WebDavError>> + Send {
            async {
                Ok(vec![
                    WebDavRemoteFile::new(
                        "remote.org".into(),
                        RemoteFileVersion::new(Some("etag-1".into()), None, Some(9)).unwrap(),
                    )
                    .unwrap(),
                ])
            }
        }

        fn get(
            &self,
            _: &WebDavEndpoint,
            path: &str,
        ) -> impl Future<Output = Result<Vec<u8>, WebDavError>> + Send {
            assert_eq!(path, "remote.org");
            async { Ok(b"download\n".to_vec()) }
        }

        fn put(
            &self,
            _: &WebDavEndpoint,
            _: &str,
            _: &[u8],
            _: WebDavPutCondition,
        ) -> impl Future<Output = Result<RemoteFileVersion, WebDavError>> + Send {
            async { Err(WebDavError::Protocol("不应上传".into())) }
        }
    }

    struct ConflictRemote;

    impl WebDavTransport for ConflictRemote {
        fn list(
            &self,
            _: &WebDavEndpoint,
        ) -> impl Future<Output = Result<Vec<WebDavRemoteFile>, WebDavError>> + Send {
            async {
                Ok(vec![
                    WebDavRemoteFile::new(
                        "inbox.org".into(),
                        RemoteFileVersion::new(Some("new-etag".into()), None, Some(4)).unwrap(),
                    )
                    .unwrap(),
                ])
            }
        }

        fn get(
            &self,
            _: &WebDavEndpoint,
            _: &str,
        ) -> impl Future<Output = Result<Vec<u8>, WebDavError>> + Send {
            async { Err(WebDavError::Protocol("不应下载".into())) }
        }

        fn put(
            &self,
            _: &WebDavEndpoint,
            _: &str,
            _: &[u8],
            _: WebDavPutCondition,
        ) -> impl Future<Output = Result<RemoteFileVersion, WebDavError>> + Send {
            async { Err(WebDavError::Protocol("冲突时不应上传".into())) }
        }
    }

    fn block_on<F: Future>(future: F) -> F::Output {
        let waker = Waker::noop();
        let mut context = Context::from_waker(waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("测试 Future 不应挂起"),
        }
    }

    fn endpoint() -> WebDavEndpoint {
        WebDavEndpoint::new("https://dav.example.com/org/".into()).unwrap()
    }

    #[test]
    fn uploads_new_local_file_with_create_condition() {
        let mut repo = OrgRepo::new("repo-1".into(), "/data/org".into()).unwrap();
        repo.files.push(
            OrgFile::new(
                repo.id.clone(),
                "inbox.org".into(),
                b"TODO".to_vec(),
                Vec::new(),
            )
            .unwrap(),
        );
        let policy = WebDavSyncPolicy::new(endpoint(), EmptyRemote, Parser);
        let record = block_on(repo.sync(&policy, 1)).unwrap();
        assert_eq!(record.files[0].action, OrgRepoSyncFileAction::Created);
        assert_eq!(repo.sync_records.len(), 1);
    }

    #[test]
    fn downloads_remote_file_into_repository_snapshot() {
        let mut repo = OrgRepo::new("repo-1".into(), "/data/org".into()).unwrap();
        let policy = WebDavSyncPolicy::new(endpoint(), DownloadRemote, Parser);
        let record = block_on(repo.sync(&policy, 1)).unwrap();
        assert_eq!(record.files[0].action, OrgRepoSyncFileAction::Downloaded);
        assert_eq!(repo.files[0].path, "remote.org");
        assert_eq!(repo.files[0].source_bytes, b"download\n");
    }

    #[test]
    fn records_conflict_when_both_versions_changed() {
        let mut repo = OrgRepo::new("repo-1".into(), "/data/org".into()).unwrap();
        repo.files.push(
            OrgFile::new(
                repo.id.clone(),
                "inbox.org".into(),
                b"current".to_vec(),
                Vec::new(),
            )
            .unwrap(),
        );
        let mut previous = OrgRepoSyncRecord::new("previous".into(), 0).unwrap();
        previous
            .append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Uploaded,
                    OrgRepoSyncFileState::Synchronized,
                )
                .unwrap()
                .with_versions(
                    Some(LocalFileVersion::new("old-local".into()).unwrap()),
                    Some(RemoteFileVersion::new(Some("old-etag".into()), None, Some(3)).unwrap()),
                ),
            )
            .unwrap();
        previous.finish(OrgRepoSyncResult::Succeeded, 1).unwrap();
        repo.sync_records.push(previous);

        let policy = WebDavSyncPolicy::new(endpoint(), ConflictRemote, Parser);
        let record = block_on(repo.sync(&policy, 2)).unwrap();
        assert_eq!(record.files[0].action, OrgRepoSyncFileAction::Conflicted);
        assert_eq!(record.files[0].state, OrgRepoSyncFileState::Conflict);
    }
}
