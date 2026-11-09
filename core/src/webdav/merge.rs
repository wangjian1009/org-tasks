//! 以一次仓库同步为单位预览、备份并提交任务合并。
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use super::*;
use crate::{OrgMergeChoice, OrgMergePlan, compare_org_tasks, merge_org_tasks};

type History = [OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavConflictSync {
    pub sync_id: String,
    pub paths: Vec<String>,
}

/// 成功文件清除待处理项；普通失败不清除先前已经发现的冲突。
pub fn conflict_syncs(history: &History) -> Vec<WebDavConflictSync> {
    let mut pending = BTreeMap::new();
    for record in history {
        for file in &record.files {
            match file.state {
                OrgRepoSyncFileState::Synchronized => {
                    pending.remove(&file.relative_path);
                }
                OrgRepoSyncFileState::Conflict | OrgRepoSyncFileState::RemoteDeleted => {
                    pending.insert(file.relative_path.clone(), record.id.clone());
                }
                _ => {}
            }
        }
    }
    let mut grouped = BTreeMap::<String, Vec<String>>::new();
    for (path, sync_id) in pending {
        grouped.entry(sync_id).or_default().push(path);
    }
    grouped
        .into_iter()
        .map(|(sync_id, paths)| WebDavConflictSync { sync_id, paths })
        .collect()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavFileMergePreview {
    pub path: String,
    pub remote_etag: Option<String>,
    pub remote_missing: bool,
    pub local_missing: bool,
    pub plan: OrgMergePlan,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavSyncMergePreview {
    pub sync_id: String,
    pub files: Vec<WebDavFileMergePreview>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WebDavMergeMode {
    AcceptRemote,
    MergeTasks,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WebDavMergeFileRequest {
    pub path: String,
    pub local_missing: bool,
    pub local_hash: String,
    pub remote_hash: String,
    pub remote_etag: Option<String>,
    pub choices: Vec<OrgMergeChoice>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WebDavMergeRequest {
    pub sync_id: String,
    pub repository_version: String,
    pub mode: WebDavMergeMode,
    pub files: Vec<WebDavMergeFileRequest>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavMergeBackup {
    pub path: String,
    pub backup_path: String,
}

pub use crate::OrgMergeSide as WebDavMergeResolution;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebDavTaskMergeChange {
    pub id: String,
    pub path: String,
    pub kind: crate::OrgMergeChange,
    pub preamble: bool,
    pub local_change: crate::OrgMergeChange,
    pub remote_change: crate::OrgMergeChange,
    pub local: Option<crate::OrgMergeVersion>,
    pub remote: Option<crate::OrgMergeVersion>,
    pub resolution: Option<WebDavMergeResolution>,
}

/// 比较结果直接往返传递；只有 mode 和各差异的 resolution 由调用方修改。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebDavMergeComparison {
    pub sync_id: String,
    pub repo_id: String,
    pub repository_version: String,
    pub endpoint_version: String,
    pub mode: WebDavMergeMode,
    pub files: Vec<WebDavMergeFileVersion>,
    pub unchanged_count: usize,
    pub changes: Vec<WebDavTaskMergeChange>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebDavMergeFileVersion {
    pub path: String,
    pub local_hash: String,
    pub remote_hash: String,
    pub remote_etag: Option<String>,
    pub remote_missing: bool,
    pub local_missing: bool,
}

pub struct WebDavMergeOutcome {
    pub record: OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
    pub backups: Vec<WebDavMergeBackup>,
}

struct MergeSource {
    preview: WebDavFileMergePreview,
    remote: Option<WebDavRemoteFile>,
    remote_file: OrgFile,
}

fn conflict_paths(history: &History, sync_id: &str) -> Result<Vec<String>, CoreError> {
    conflict_syncs(history)
        .into_iter()
        .find(|sync| sync.sync_id == sync_id)
        .map(|sync| sync.paths)
        .ok_or(CoreError::InvalidState(
            "该次同步的冲突已处理或发生变化，请刷新后重试",
        ))
}

impl WebDavSyncPolicy {
    async fn merge_source(
        &self,
        repo: &OrgRepo,
        path: &str,
        history: &History,
    ) -> Result<MergeSource, CoreError> {
        validate_path(path)?;
        let local = repo.files.iter().find(|file| file.path == path);
        let local_missing = local.is_none();
        let empty_local = repo.parse_file(path.into(), Vec::new())?;
        let local = local.unwrap_or(&empty_local);
        let remote = runtime::list_remote(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            &SyncProgressReporter::default(),
            self.monitor.as_ref(),
        )
        .await
        .map_err(merge_error)?
        .into_iter()
        .find(|file| file.path == path);
        let bytes = if let Some(remote) = &remote {
            let etag = remote
                .version
                .etag
                .as_deref()
                .ok_or(CoreError::InvalidState(
                    "远端未提供文件版本，暂不能安全处理冲突",
                ))?;
            runtime::get_remote_for_merge(
                &self.client,
                &self.username,
                &self.password,
                &self.endpoint,
                path,
                etag,
            )
            .await
            .map_err(merge_error)?
        } else {
            Vec::new()
        };
        let remote_file = repo.parse_file(path.into(), bytes)?;
        let baseline = latest_file_record(history, path)
            .map(|record| {
                if let Some(source) = &record.detail.synced_source {
                    let version = LocalFileVersion::from_bytes(source.as_bytes());
                    if record.local_version.as_ref() != Some(&version) {
                        return Err(CoreError::InvalidState("同步日志中的文件快照与版本不一致"));
                    }
                    let file = repo.parse_file(path.into(), source.as_bytes().to_vec())?;
                    Ok(Some(crate::task_fingerprints(&file)))
                } else if record.local_version.is_none() {
                    Ok(Some(Vec::new()))
                } else {
                    Ok(record.detail.task_versions.clone())
                }
            })
            .transpose()?
            .flatten();
        let preview = WebDavFileMergePreview {
            path: path.into(),
            remote_etag: remote.as_ref().and_then(|file| file.version.etag.clone()),
            remote_missing: remote.is_none(),
            local_missing,
            plan: compare_org_tasks(local, &remote_file, baseline.as_deref()),
        };
        Ok(MergeSource {
            preview,
            remote,
            remote_file,
        })
    }

    fn endpoint_version(&self) -> String {
        LocalFileVersion::from_bytes(
            &serde_json::to_vec(&(&self.endpoint.base_url, &self.username)).unwrap(),
        )
        .content_hash
    }

    pub async fn compare_merge(
        &self,
        repo: &mut OrgRepo,
        sync_id: &str,
    ) -> Result<WebDavMergeComparison, CoreError> {
        let history = repo.load::<Self>().await?;
        Ok(self.comparison(repo, sync_id, &history).await?.0)
    }

    async fn comparison(
        &self,
        repo: &OrgRepo,
        sync_id: &str,
        history: &History,
    ) -> Result<(WebDavMergeComparison, WebDavSyncMergePreview), CoreError> {
        let repository_version = repository_version(repo, history).await?;
        let preview = self.preview_merge(repo, sync_id, history).await?;
        let mut changes = Vec::new();
        let mut unchanged_count = 0;
        let mut files = Vec::new();
        for file in &preview.files {
            files.push(WebDavMergeFileVersion {
                path: file.path.clone(),
                local_hash: file.plan.local_hash.clone(),
                remote_hash: file.plan.remote_hash.clone(),
                remote_etag: file.remote_etag.clone(),
                remote_missing: file.remote_missing,
                local_missing: file.local_missing,
            });
            for item in &file.plan.items {
                if item.change == crate::OrgMergeChange::Unchanged {
                    if item.key != "preamble" && item.remote.is_some() {
                        unchanged_count += 1;
                    }
                    continue;
                }
                let kind = match (&item.local, &item.remote) {
                    (Some(_), Some(_)) => crate::OrgMergeChange::Modified,
                    (Some(_), None) => crate::OrgMergeChange::Added,
                    _ => crate::OrgMergeChange::Deleted,
                };
                changes.push(WebDavTaskMergeChange {
                    id: format!("change-{}", changes.len() + 1),
                    path: file.path.clone(),
                    kind,
                    preamble: item.key == "preamble",
                    local_change: item.local_change,
                    remote_change: item.remote_change,
                    local: item.local.clone(),
                    remote: item.remote.clone(),
                    resolution: None,
                });
            }
        }
        Ok((
            WebDavMergeComparison {
                sync_id: sync_id.into(),
                repo_id: repo.id.clone(),
                repository_version,
                endpoint_version: self.endpoint_version(),
                mode: WebDavMergeMode::MergeTasks,
                files,
                unchanged_count,
                changes,
            },
            preview,
        ))
    }

    pub async fn apply_merge(
        &self,
        repo: &mut OrgRepo,
        comparison: &WebDavMergeComparison,
        started_at: TimestampMs,
    ) -> Result<WebDavMergeOutcome, CoreError> {
        let history = repo.load::<Self>().await?;
        if comparison.repo_id != repo.id
            || comparison.repository_version != repository_version(repo, &history).await?
            || comparison.endpoint_version != self.endpoint_version()
        {
            return Err(CoreError::InvalidState(
                "仓库或远端配置已发生变化，请重新比较",
            ));
        }
        let (fresh, preview) = self.comparison(repo, &comparison.sync_id, &history).await?;
        let mut immutable = comparison.changes.clone();
        for change in &mut immutable {
            change.resolution = None;
        }
        if comparison.files != fresh.files
            || comparison.unchanged_count != fresh.unchanged_count
            || immutable != fresh.changes
        {
            return Err(CoreError::InvalidState(
                "比较内容或远端已发生变化，请重新比较",
            ));
        }
        let mut change_index = 0;
        let mut files = Vec::new();
        for file in preview.files {
            let mut choices = Vec::new();
            for item in &file.plan.items {
                if item.change == crate::OrgMergeChange::Unchanged {
                    continue;
                }
                let change = &comparison.changes[change_index];
                change_index += 1;
                if comparison.mode == WebDavMergeMode::MergeTasks {
                    choices.push(OrgMergeChoice {
                        key: item.key.clone(),
                        side: change
                            .resolution
                            .ok_or(CoreError::InvalidInput("请确认每个新增、修改和删除项"))?,
                    });
                }
            }
            files.push(WebDavMergeFileRequest {
                path: file.path,
                local_missing: file.local_missing,
                local_hash: file.plan.local_hash,
                remote_hash: file.plan.remote_hash,
                remote_etag: file.remote_etag,
                choices,
            });
        }
        self.resolve_merge(
            repo,
            &history,
            &WebDavMergeRequest {
                sync_id: comparison.sync_id.clone(),
                repository_version: comparison.repository_version.clone(),
                mode: comparison.mode,
                files,
            },
            started_at,
        )
        .await
    }

    /// 一次同步内全部尚未解决的冲突。预览不写入本地文件、历史或远端。
    async fn preview_merge(
        &self,
        repo: &OrgRepo,
        sync_id: &str,
        history: &History,
    ) -> Result<WebDavSyncMergePreview, CoreError> {
        let paths = conflict_paths(history, sync_id)?;
        let mut files = Vec::new();
        for path in paths {
            files.push(self.merge_source(repo, &path, history).await?.preview);
        }
        Ok(WebDavSyncMergePreview {
            sync_id: sync_id.into(),
            files,
        })
    }

    /// 全部版本通过预检、全部备份完成后才开始提交；部分失败也保留完整作业记录。
    async fn resolve_merge(
        &self,
        repo: &mut OrgRepo,
        history: &History,
        request: &WebDavMergeRequest,
        started_at: TimestampMs,
    ) -> Result<WebDavMergeOutcome, CoreError> {
        if history.iter().any(|record| record.started_at == started_at) {
            return Err(CoreError::InvalidInput("合并开始时间已有同步记录"));
        }
        let resolution = ResolutionPolicy {
            policy: self,
            request,
            backups: Mutex::new(Vec::new()),
        };
        let record = repo
            .sync(
                &resolution,
                started_at,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await?;
        let backups = resolution
            .backups
            .into_inner()
            .map_err(|_| CoreError::InvalidState("备份结果不可用"))?;
        Ok(WebDavMergeOutcome { record, backups })
    }
}

struct ResolutionPolicy<'a> {
    policy: &'a WebDavSyncPolicy,
    request: &'a WebDavMergeRequest,
    backups: Mutex<Vec<WebDavMergeBackup>>,
}

impl SyncPolicy for ResolutionPolicy<'_> {
    const KIND: &'static str = "webdav";
    type ContextDetail = WebDavSyncContextDetail;
    type FileDetail = WebDavSyncFileDetail;

    async fn synchronize(
        &self,
        context: &mut SyncContext<'_>,
        _cancellation: &SyncCancellation,
        _progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError> {
        let history = context.repo.sync_history::<WebDavSyncPolicy>().await?;
        let paths = conflict_paths(&history, &self.request.sync_id)?;
        let expected = self
            .request
            .files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<BTreeSet<_>>();
        if expected.len() != self.request.files.len()
            || expected != paths.iter().map(String::as_str).collect()
        {
            return Err(CoreError::InvalidInput(
                "必须提交本次同步全部待处理文件，不能重复、遗漏或加入其他文件",
            ));
        }
        let mut prepared = Vec::new();
        for request in &self.request.files {
            let source = self
                .policy
                .merge_source(context.repo, &request.path, &history)
                .await?;
            if source.preview.plan.local_hash != request.local_hash
                || source.preview.plan.remote_hash != request.remote_hash
                || source.preview.remote_etag != request.remote_etag
                || source.preview.local_missing != request.local_missing
            {
                return Err(CoreError::InvalidState(
                    "本地或远端已改变，请重新比较后确认",
                ));
            }
            let merged = match self.request.mode {
                WebDavMergeMode::AcceptRemote => {
                    if !request.choices.is_empty() {
                        return Err(CoreError::InvalidInput("采用远端模式不能提交逐任务选择"));
                    }
                    source.remote_file.source_bytes().to_vec()
                }
                WebDavMergeMode::MergeTasks => {
                    merge_org_tasks(&source.preview.plan, &request.choices)?
                }
            };
            prepared.push((request, source, merged));
        }
        let current_history = context.repo.load::<WebDavSyncPolicy>().await?;
        if repository_version(context.repo, &current_history).await?
            != self.request.repository_version
        {
            return Err(CoreError::InvalidState("仓库已发生变化，请重新比较"));
        }
        // 所有文件均已预检；先完成本次同步的全部备份，再开始覆盖或上传。
        for (request, _, _) in &prepared {
            if request.local_missing {
                continue;
            }
            let backup_path = context
                .repo
                .backup_sync_conflict(&request.path, &request.local_hash, context.started_at)
                .await?;
            self.backups
                .lock()
                .map_err(|_| CoreError::InvalidState("备份结果不可用"))?
                .push(WebDavMergeBackup {
                    path: request.path.clone(),
                    backup_path,
                });
        }
        let mut record = OrgRepoSyncRecord::new(
            format!("webdav-merge-{}-{}", context.repo.id, context.started_at),
            context.started_at,
        )?
        .with_kind("webdav")
        .with_context_detail(WebDavSyncContextDetail);
        let mut failed = false;
        for (request, source, merged) in prepared {
            match self
                .policy
                .apply_merge_file(context.repo, request, source, merged)
                .await
            {
                Ok(file) => record.append_file(file)?,
                Err(error) => {
                    failed = true;
                    record.append_file(failed_record(
                        context.repo,
                        request.path.clone(),
                        LocalFileVersion::new(request.local_hash.clone())?,
                        error,
                    ))?;
                }
            }
        }
        record.finish(
            if failed {
                OrgRepoSyncResult::Failed
            } else {
                OrgRepoSyncResult::Succeeded
            },
            finished_at()?,
        )?;
        Ok(record)
    }
}

impl WebDavSyncPolicy {
    async fn apply_merge_file(
        &self,
        repo: &mut OrgRepo,
        request: &WebDavMergeFileRequest,
        source: MergeSource,
        merged: Vec<u8>,
    ) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, OrgRepoSyncErrorSummary> {
        let remove = source.remote.is_none() && merged.is_empty();
        let upload = !remove && merged != source.remote_file.source_bytes();
        let version = if upload {
            let condition = match &source.remote {
                Some(file) => WebDavPutCondition::Match(file.version.etag.clone().unwrap()),
                None => WebDavPutCondition::CreateOnly,
            };
            runtime::put_remote(
                &self.client,
                &self.username,
                &self.password,
                &self.endpoint,
                &request.path,
                &merged,
                condition,
                &SyncProgressReporter::default(),
                self.monitor.as_ref(),
            )
            .await
            .map_err(|e| e.summary())?
        } else {
            let latest = runtime::list_remote(
                &self.client,
                &self.username,
                &self.password,
                &self.endpoint,
                &SyncProgressReporter::default(),
                self.monitor.as_ref(),
            )
            .await
            .map_err(|e| e.summary())?
            .into_iter()
            .find(|file| file.path == request.path);
            if latest.as_ref().map(|f| &f.version) != source.remote.as_ref().map(|f| &f.version) {
                return Err(WebDavError::Conflict("远端已改变，请重新比较后确认".into()).summary());
            }
            source
                .remote
                .as_ref()
                .map(|file| file.version.clone())
                .unwrap_or(RemoteFileVersion::new(None, None, None).unwrap())
        };
        let hash = LocalFileVersion::from_bytes(&merged);
        repo.replace_conflict_file(
            &request.path,
            (!request.local_missing).then_some(request.local_hash.as_str()),
            (!remove).then_some(merged),
        )
        .await
        .map_err(|_| {
            OrgRepoSyncErrorSummary::new(
                OrgRepoSyncErrorCategory::LocalStorage,
                false,
                "无法提交本地合并文件，原始内容已备份；请重新比较".into(),
            )
            .unwrap()
        })?;
        let action = if remove {
            OrgRepoSyncFileAction::Deleted
        } else if upload && source.remote.is_none() {
            OrgRepoSyncFileAction::Created
        } else if upload {
            OrgRepoSyncFileAction::Uploaded
        } else {
            OrgRepoSyncFileAction::Downloaded
        };
        let mut file =
            success_record(repo, request.path.clone(), action, hash, version).map_err(|_| {
                OrgRepoSyncErrorSummary::new(
                    OrgRepoSyncErrorCategory::LocalStorage,
                    false,
                    "无法生成合并结果".into(),
                )
                .unwrap()
            })?;
        if remove {
            file.local_version = None;
            file.detail.task_versions = Some(Vec::new());
        }
        Ok(file)
    }
}

fn merge_error(error: WebDavError) -> CoreError {
    CoreError::Store(error.summary().message)
}

/// 包含全部 Org 文件、仓库身份、作业历史和待上传意图；不依赖调用方旧的内存快照。
async fn repository_version(repo: &OrgRepo, history: &History) -> Result<String, CoreError> {
    let mut files = repo
        .files
        .iter()
        .map(|file| {
            (
                file.path.as_str(),
                LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            )
        })
        .collect::<Vec<_>>();
    files.sort();
    let mut pending = repo
        .pending_writes()
        .await?
        .into_iter()
        .map(|intent| (intent.relative_path, intent.content_hash))
        .collect::<Vec<_>>();
    pending.sort();
    let bytes = serde_json::to_vec(&(&repo.id, &repo.todo_defaults, files, history, pending))
        .map_err(|_| CoreError::InvalidState("无法计算仓库版本"))?;
    Ok(LocalFileVersion::from_bytes(&bytes).content_hash)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    struct Remote {
        data: Vec<u8>,
        etag: String,
    }
    struct SnapshotMonitor(Arc<Mutex<Vec<bool>>>);
    impl WebDavSyncMonitor for SnapshotMonitor {
        fn on_event(&self, event: WebDavSyncEvent) {
            if let WebDavSyncEvent::FileProcessed { record } = event {
                self.0
                    .lock()
                    .unwrap()
                    .push(record.detail.synced_source.is_some());
            }
        }
    }
    struct Dav {
        files: BTreeMap<String, Remote>,
        reject: BTreeSet<String>,
        requests: Vec<String>,
        backup_group: Option<std::path::PathBuf>,
        backups_on_put: usize,
    }

    async fn server(
        files: &[(&str, &[u8])],
    ) -> (
        WebDavSyncPolicy,
        Arc<Mutex<Dav>>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let state = Arc::new(Mutex::new(Dav {
            files: files
                .iter()
                .map(|(path, data)| {
                    (
                        path.to_string(),
                        Remote {
                            data: data.to_vec(),
                            etag: "\"v1\"".into(),
                        },
                    )
                })
                .collect(),
            reject: BTreeSet::new(),
            requests: Vec::new(),
            backup_group: None,
            backups_on_put: 0,
        }));
        let shared = state.clone();
        let endpoint =
            WebDavEndpoint::new(format!("http://{}/org/", listener.local_addr().unwrap())).unwrap();
        let worker = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                let end = loop {
                    let n = stream.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                    if let Some(offset) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                        break offset + 4;
                    }
                };
                let headers = String::from_utf8_lossy(&bytes[..end]).to_string();
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while bytes.len() < end + length {
                    let n = stream.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                }
                let mut request = headers.split_whitespace();
                let method = request.next().unwrap();
                let path = request
                    .next()
                    .unwrap()
                    .trim_start_matches("/org/")
                    .to_string();
                let (status, body, etag) = {
                    let mut dav = shared.lock().unwrap();
                    dav.requests.push(headers.clone());
                    match method {
                        "PROPFIND" => {
                            let entries = dav.files.iter().map(|(path, file)| format!(
                                "<d:response><d:href>/org/{path}</d:href><d:propstat><d:prop><d:getetag>{}</d:getetag><d:getcontentlength>{}</d:getcontentlength></d:prop></d:propstat></d:response>", file.etag, file.data.len())).collect::<String>();
                            (
                                207,
                                format!(
                                    "<d:multistatus xmlns:d=\"DAV:\">{entries}</d:multistatus>"
                                )
                                .into_bytes(),
                                None,
                            )
                        }
                        "GET" => match dav.files.get(&path) {
                            Some(file)
                                if headers.contains(&format!("if-match: {}", file.etag))
                                    || !headers.contains("if-match:") =>
                            {
                                (200, file.data.clone(), Some(file.etag.clone()))
                            }
                            Some(_) => (412, Vec::new(), None),
                            None => (404, Vec::new(), None),
                        },
                        "PUT" => {
                            dav.backups_on_put = dav
                                .backup_group
                                .as_ref()
                                .and_then(|p| std::fs::read_dir(p).ok())
                                .map(|entries| entries.count())
                                .unwrap_or(0);
                            let valid = if let Some(file) = dav.files.get(&path) {
                                headers.contains(&format!("if-match: {}", file.etag))
                            } else {
                                headers.contains("if-none-match: *")
                            };
                            if dav.reject.contains(&path) || !valid {
                                (412, Vec::new(), None)
                            } else {
                                dav.files.insert(
                                    path.clone(),
                                    Remote {
                                        data: bytes[end..end + length].to_vec(),
                                        etag: "\"v2\"".into(),
                                    },
                                );
                                (204, Vec::new(), Some("\"v2\"".into()))
                            }
                        }
                        _ => (500, Vec::new(), None),
                    }
                };
                let etag = etag.map(|e| format!("ETag: {e}\r\n")).unwrap_or_default();
                stream.write_all(format!("HTTP/1.1 {status} Result\r\nContent-Length: {}\r\n{etag}Connection: close\r\n\r\n", body.len()).as_bytes()).await.unwrap();
                stream.write_all(&body).await.unwrap();
            }
        });
        (
            WebDavSyncPolicy::new(endpoint, "user".into(), "secret".into()).unwrap(),
            state,
            worker,
        )
    }

    async fn repo() -> (OrgRepo, std::path::PathBuf) {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-tasks-merge-sync-{}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir_all(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        (repo, root)
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

    async fn offline(repo: &mut OrgRepo, path: &str) {
        crate::model::test_support::append_fixture(repo,path,"Offline")
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn full_sync_snapshots_drive_three_way_task_review_and_preserve_remote_only_edits() {
        fn task(id: &str, body: &str) -> String {
            format!("* TODO {id}\n:PROPERTIES:\n:ID: {id}\n:END:\n{body}\n")
        }
        for accept in [false, true] {
            let (mut repo, root) = repo().await;
            let base = task("restore", "base") + &task("delete", "base") + &task("remote", "base");
            tokio::fs::write(root.join("inbox.org"), &base)
                .await
                .unwrap();
            let (policy, state, worker) = server(&[("inbox.org", base.as_bytes())]).await;
            let progress_snapshots = Arc::new(Mutex::new(Vec::new()));
            let policy = policy.with_monitor(SnapshotMonitor(progress_snapshots.clone()));
            let first = sync(&mut repo, &policy, 1).await;
            let mut initial = policy.compare_merge(&mut repo, &first.id).await.unwrap();
            initial.mode = WebDavMergeMode::AcceptRemote;
            policy.apply_merge(&mut repo, &initial, 2).await.unwrap();
            // 只保留完整文件快照，确保不是依赖旧指纹字段完成三方比较。
            let history_path = root.join(".sync/history/2.json");
            let mut stored: serde_json::Value =
                serde_json::from_slice(&tokio::fs::read(&history_path).await.unwrap()).unwrap();
            assert_eq!(stored["files"][0]["detail"]["synced_source"], base);
            stored["files"][0]["detail"]
                .as_object_mut()
                .unwrap()
                .remove("task_versions");
            tokio::fs::write(&history_path, serde_json::to_vec(&stored).unwrap())
                .await
                .unwrap();
            let local =
                task("restore", "local edit") + &task("remote", "base") + &task("new", "local new");
            let remote = task("delete", "remote edit")
                + &task("remote", "remote only edit")
                + &task("added-remotely", "remote new");
            tokio::fs::write(root.join("inbox.org"), &local)
                .await
                .unwrap();
            state.lock().unwrap().files.insert(
                "inbox.org".into(),
                Remote {
                    data: remote.as_bytes().to_vec(),
                    etag: "\"v3\"".into(),
                },
            );
            let conflict = sync(&mut repo, &policy, 3).await;
            let mut comparison = policy.compare_merge(&mut repo, &conflict.id).await.unwrap();
            assert_eq!(comparison.changes.len(), 3);
            assert_eq!(comparison.unchanged_count, 2);
            let restore = comparison
                .changes
                .iter()
                .find(|change| {
                    change
                        .local
                        .as_ref()
                        .is_some_and(|version| version.title == "restore")
                })
                .unwrap();
            assert_eq!(restore.kind, crate::OrgMergeChange::Added);
            assert_eq!(restore.local_change, crate::OrgMergeChange::Modified);
            assert_eq!(restore.remote_change, crate::OrgMergeChange::Deleted);
            let delete = comparison
                .changes
                .iter()
                .find(|change| {
                    change
                        .remote
                        .as_ref()
                        .is_some_and(|version| version.title == "delete")
                })
                .unwrap();
            assert_eq!(delete.kind, crate::OrgMergeChange::Deleted);
            assert_eq!(delete.local_change, crate::OrgMergeChange::Deleted);
            assert_eq!(delete.remote_change, crate::OrgMergeChange::Modified);
            let mut tampered = comparison.clone();
            tampered.changes[0].local_change = crate::OrgMergeChange::Unchanged;
            assert!(policy.apply_merge(&mut repo, &tampered, 4).await.is_err());
            for change in &mut comparison.changes {
                change.resolution = Some(if accept {
                    crate::OrgMergeSide::Local
                } else {
                    crate::OrgMergeSide::Remote
                });
            }
            let outcome = policy.apply_merge(&mut repo, &comparison, 5).await.unwrap();
            assert_eq!(outcome.record.result, Some(OrgRepoSyncResult::Succeeded));
            let expected = if accept {
                task("remote", "remote only edit")
                    + &task("added-remotely", "remote new")
                    + &task("restore", "local edit")
                    + &task("new", "local new")
            } else {
                remote
            };
            assert_eq!(
                tokio::fs::read(root.join("inbox.org")).await.unwrap(),
                expected.as_bytes()
            );
            assert_eq!(
                state.lock().unwrap().files["inbox.org"].data,
                expected.as_bytes()
            );
            assert_eq!(
                outcome.record.files[0].detail.synced_source.as_deref(),
                Some(expected.as_str())
            );
            assert_eq!(
                tokio::fs::read(root.join(&outcome.backups[0].backup_path))
                    .await
                    .unwrap(),
                local.as_bytes()
            );
            let unchanged = sync(&mut repo, &policy, 6).await;
            assert_eq!(
                unchanged.files[0].detail.synced_source.as_deref(),
                Some(expected.as_str())
            );
            assert!(!progress_snapshots.lock().unwrap().is_empty());
            assert!(
                progress_snapshots
                    .lock()
                    .unwrap()
                    .iter()
                    .all(|contains_source| !contains_source)
            );
            worker.abort();
            tokio::fs::remove_dir_all(root).await.unwrap();
        }
    }

    #[tokio::test]
    async fn comparison_roundtrips_without_session_id_and_accept_remote_is_readonly_until_apply() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "inbox.org").await;
        let original = tokio::fs::read(root.join("inbox.org")).await.unwrap();
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Remote\r\n")]).await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        assert!(!root.join(".sync/backups").exists());
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        assert!(
            comparison
                .changes
                .iter()
                .any(|c| c.kind == crate::OrgMergeChange::Added)
        );
        assert!(
            comparison
                .changes
                .iter()
                .any(|c| c.kind == crate::OrgMergeChange::Deleted)
        );
        comparison.mode = WebDavMergeMode::AcceptRemote;
        let json = serde_json::to_string(&comparison).unwrap();
        assert!(!json.contains("preparation"));
        let comparison: WebDavMergeComparison = serde_json::from_str(&json).unwrap();
        let mut reopened = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let result = policy
            .apply_merge(&mut reopened, &comparison, 100)
            .await
            .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(
            tokio::fs::read(root.join(&result.backups[0].backup_path))
                .await
                .unwrap(),
            original
        );
        assert!(
            result.backups[0]
                .backup_path
                .starts_with(".sync/backups/100/")
        );
        assert_eq!(
            tokio::fs::read(root.join("inbox.org")).await.unwrap(),
            b"* TODO Remote\r\n"
        );
        assert!(reopened.pending_writes().await.unwrap().is_empty());
        assert_eq!(reopened.files.len(), 1);
        assert!(
            policy
                .apply_merge(&mut reopened, &comparison, 101)
                .await
                .is_err()
        );
        assert!(
            !state
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.starts_with("PUT"))
        );
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn any_repository_change_rejects_apply_before_network_or_backups() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "inbox.org").await;
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Remote\n")]).await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        comparison.mode = WebDavMergeMode::AcceptRemote;
        let count = state.lock().unwrap().requests.len();
        tokio::fs::write(root.join("unrelated.org"), b"* TODO New file\n")
            .await
            .unwrap();
        assert!(
            policy
                .apply_merge(&mut repo, &comparison, 100)
                .await
                .is_err()
        );
        assert_eq!(state.lock().unwrap().requests.len(), count);
        assert!(!root.join(".sync/backups").exists());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn changed_remote_or_mutated_difference_object_cannot_apply() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "inbox.org").await;
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Remote\n")]).await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        comparison.mode = WebDavMergeMode::AcceptRemote;
        let mut edited = comparison.clone();
        edited.changes[0].id = "other".into();
        assert!(policy.apply_merge(&mut repo, &edited, 100).await.is_err());
        state
            .lock()
            .unwrap()
            .files
            .get_mut("inbox.org")
            .unwrap()
            .etag = "\"newer\"".into();
        assert!(
            policy
                .apply_merge(&mut repo, &comparison, 100)
                .await
                .is_err()
        );
        assert!(!root.join(".sync/backups").exists());
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn whole_sync_backs_up_all_files_before_writes_and_records_partial_failure() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "a.org").await;
        offline(&mut repo, "b.org").await;
        let original_b = tokio::fs::read(root.join("b.org")).await.unwrap();
        let (policy, state, worker) =
            server(&[("a.org", b"* TODO A\n"), ("b.org", b"* TODO B\n")]).await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        assert_eq!(comparison.files.len(), 2);
        for change in &mut comparison.changes {
            change.resolution = Some(if change.path == "a.org" {
                WebDavMergeResolution::Remote
            } else {
                WebDavMergeResolution::Local
            });
        }
        {
            let mut s = state.lock().unwrap();
            s.reject.insert("b.org".into());
            s.backup_group = Some(root.join(".sync/backups/100"));
        }
        let result = policy
            .apply_merge(&mut repo, &comparison, 100)
            .await
            .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Failed));
        assert_eq!(result.record.files.len(), 2);
        assert_eq!(result.backups.len(), 2);
        assert_eq!(state.lock().unwrap().backups_on_put, 2);
        assert_eq!(
            tokio::fs::read(root.join("a.org")).await.unwrap(),
            b"* TODO A\n"
        );
        assert_eq!(
            tokio::fs::read(root.join("b.org")).await.unwrap(),
            original_b
        );
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        let history = repo.load::<WebDavSyncPolicy>().await.unwrap();
        let pending = conflict_syncs(&history);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].paths, ["b.org"]);
        let stored = tokio::fs::read_to_string(root.join(".sync/history/100.json"))
            .await
            .unwrap();
        let stored: serde_json::Value = serde_json::from_str(&stored).unwrap();
        assert_eq!(stored["files"][0]["detail"]["synced_source"], "* TODO A\n");
        assert!(stored["files"][1]["detail"].get("synced_source").is_none());
        assert!(!stored.to_string().contains("secret"));
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn unified_choices_preserve_local_changes_and_upload_with_if_match() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "inbox.org").await;
        let original = tokio::fs::read(root.join("inbox.org")).await.unwrap();
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Remote\n")]).await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        assert!(
            policy
                .apply_merge(&mut repo, &comparison, 100)
                .await
                .is_err()
        );
        for change in &mut comparison.changes {
            change.resolution = Some(WebDavMergeResolution::Local);
        }
        let result = policy
            .apply_merge(&mut repo, &comparison, 100)
            .await
            .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(state.lock().unwrap().files["inbox.org"].data, original);
        assert!(
            state
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.starts_with("PUT") && r.contains("if-match: \"v1\""))
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn remote_deletion_directly_removes_modified_local_file_and_consumes_intents() {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Original\n")]).await;
        sync(&mut repo, &policy, 1).await;
        offline(&mut repo, "inbox.org").await;
        state.lock().unwrap().files.clear();
        let result = sync(&mut repo, &policy, 2).await;
        assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(result.files[0].action, OrgRepoSyncFileAction::Deleted);
        assert!(!root.join("inbox.org").exists());
        assert!(repo.pending_writes().await.unwrap().is_empty());
        assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn task_ignore_does_not_change_upload_download_or_write_acknowledgement() {
        let (mut repo, root) = repo().await;
        tokio::fs::write(root.join(".orgzlyignore"), "local.org\nremote.org\n")
            .await
            .unwrap();
        offline(&mut repo, "local.org").await;
        let local = tokio::fs::read(root.join("local.org")).await.unwrap();
        let remote = b"* TODO Remote ignored task\r\n";
        let (policy, state, worker) = server(&[("remote.org", remote)]).await;
        let record = sync(&mut repo, &policy, 1).await;
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(record.files.len(), 2);
        assert_eq!(state.lock().unwrap().files["local.org"].data, local);
        assert_eq!(
            tokio::fs::read(root.join("remote.org")).await.unwrap(),
            remote
        );
        assert_eq!(repo.files().len(), 2);
        assert!(repo.pending_writes().await.unwrap().is_empty());
        assert!(crate::filter::tasks_from_repo(&repo).is_empty());
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        assert_eq!(repo.files().len(), 2);
        assert!(crate::filter::tasks_from_repo(&repo).is_empty());
        tokio::fs::remove_file(root.join(".orgzlyignore"))
            .await
            .unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        assert_eq!(crate::filter::tasks_from_repo(&repo).len(), 2);
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn sync_downloads_root_ignore_rules_and_applies_updates_and_removal() {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[
            (".orgzlyignore", b"\xef\xbb\xbfann.org\r\n"),
            ("nested/.orgzlyignore", b"visible.org\n"),
            ("ann.org", b"* TODO Announcement\n"),
            ("visible.org", b"* TODO Visible\n"),
        ])
        .await;
        let record = sync(&mut repo, &policy, 1).await;
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(repo.files().len(), 2);
        assert!(!root.join("nested/.orgzlyignore").exists());
        assert_eq!(
            tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
            b"\xef\xbb\xbfann.org\r\n"
        );
        let query = crate::TaskQuery {
            expression: "s.none d.none".into(),
            include_done: false,
            ..Default::default()
        };
        let result = crate::OrgWorkspace::new(vec![repo.clone()])
            .unwrap()
            .query(&query)
            .unwrap();
        assert_eq!(result.tasks.len(), 1);
        assert_eq!(result.tasks[0].path, "visible.org");
        assert!(
            repo.file_metadata()
                .iter()
                .find(|file| file.path == "ann.org")
                .unwrap()
                .is_ignore
        );
        let rules = record
            .files
            .iter()
            .find(|file| file.relative_path == ".orgzlyignore")
            .unwrap();
        assert!(rules.detail.task_versions.is_none());
        assert_eq!(
            rules.detail.synced_source.as_deref(),
            Some("\u{feff}ann.org\r\n")
        );
        {
            let mut dav = state.lock().unwrap();
            let rules = dav.files.get_mut(".orgzlyignore").unwrap();
            rules.data = b"visible.org\n".to_vec();
            rules.etag = "\"v2\"".into();
        }
        assert_eq!(
            sync(&mut repo, &policy, 2).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(repo.task_scan_rules.excludes("visible.org"));
        assert!(!repo.task_scan_rules.excludes("ann.org"));
        state.lock().unwrap().files.remove(".orgzlyignore");
        assert_eq!(
            sync(&mut repo, &policy, 3).await.result,
            Some(OrgRepoSyncResult::Succeeded)
        );
        assert!(!root.join(".orgzlyignore").exists());
        assert!(!repo.task_scan_rules.excludes("visible.org"));
        assert!(
            state
                .lock()
                .unwrap()
                .requests
                .iter()
                .all(|request| !request.starts_with("PUT /org/.orgzlyignore"))
        );
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn sync_ignore_rules_preserves_local_edits_and_rejects_invalid_remote_content() {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[(".orgzlyignore", b"ann.org\n")]).await;
        sync(&mut repo, &policy, 1).await;
        tokio::fs::write(root.join(".orgzlyignore"), "local.org\n")
            .await
            .unwrap();
        assert!(
            repo.sync(
                &policy,
                2,
                &SyncCancellation::default(),
                &SyncProgressReporter::default()
            )
            .await
            .is_err()
        );
        assert_eq!(
            tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
            b"local.org\n"
        );
        assert!(repo.task_scan_rules.excludes("local.org"));
        tokio::fs::write(root.join(".orgzlyignore"), "ann.org\n")
            .await
            .unwrap();
        for invalid in [vec![0xff], b"[z-a]\n".to_vec()] {
            state
                .lock()
                .unwrap()
                .files
                .get_mut(".orgzlyignore")
                .unwrap()
                .data = invalid;
            assert!(
                repo.sync(
                    &policy,
                    3,
                    &SyncCancellation::default(),
                    &SyncProgressReporter::default()
                )
                .await
                .is_err()
            );
            assert_eq!(
                tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
                b"ann.org\n"
            );
            assert!(repo.task_scan_rules.excludes("ann.org"));
        }
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn sync_directory_filters_skip_transfers_and_can_be_overridden_per_call() {
        let (mut repo, root) = repo().await;
        let original = b"* TODO Local archive\r\n";
        tokio::fs::create_dir_all(root.join("archive"))
            .await
            .unwrap();
        tokio::fs::write(root.join("archive/local.org"), original)
            .await
            .unwrap();
        let (policy, state, worker) = server(&[
            ("archive/remote.org", b"* TODO Remote archive\n"),
            ("nested/archive/remote.org", b"* TODO Nested archive\n"),
            ("private/remote.org", b"* TODO Private\n"),
            ("archives/keep.org", b"* TODO Keep similar name\n"),
            ("keep.org", b"* TODO Keep\n"),
        ])
        .await;
        let first = sync(&mut repo, &policy, 1).await;
        assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(first.files.len(), 3);
        assert!(!root.join("archive/remote.org").exists());
        assert!(!root.join("nested/archive/remote.org").exists());
        assert!(root.join("private/remote.org").is_file());
        assert!(root.join("archives/keep.org").is_file());
        assert_eq!(
            tokio::fs::read(root.join("archive/local.org"))
                .await
                .unwrap(),
            original
        );
        assert!(
            !state
                .lock()
                .unwrap()
                .files
                .contains_key("archive/local.org")
        );
        assert!(
            state
                .lock()
                .unwrap()
                .requests
                .iter()
                .filter(|r| !r.starts_with("PROPFIND"))
                .all(|r| !r
                    .split_whitespace()
                    .nth(1)
                    .unwrap()
                    .split('/')
                    .any(|part| part == "archive"))
        );

        // 自定义参数替换默认规则，仅对本次调用生效。
        let second = repo
            .sync_with_options(
                &policy,
                2,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
                crate::SyncOptions {
                    excluded_directories: vec!["private".into()],
                },
            )
            .await
            .unwrap();
        assert_eq!(second.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(second.files.len(), 5);
        assert!(
            second
                .files
                .iter()
                .all(|file| !file.relative_path.starts_with("private/"))
        );
        assert!(root.join("archive/remote.org").is_file());
        assert!(root.join("nested/archive/remote.org").is_file());
        assert_eq!(
            state.lock().unwrap().files["archive/local.org"].data,
            original
        );

        // 已有基线和待上传意图的目录被排除后也不能发生传输或误报远端删除。
        offline(&mut repo, "archive/local.org").await;
        state.lock().unwrap().files.remove("archive/local.org");
        let third = sync(&mut repo, &policy, 3).await;
        assert_eq!(third.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(third.files.len(), 3);
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        assert!(
            !state
                .lock()
                .unwrap()
                .files
                .contains_key("archive/local.org")
        );

        let fourth = repo
            .sync_with_options(
                &policy,
                4,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
                crate::SyncOptions {
                    excluded_directories: Vec::new(),
                },
            )
            .await
            .unwrap();
        assert_eq!(fourth.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(fourth.files.len(), 6);
        assert_eq!(
            fourth
                .files
                .iter()
                .find(|file| file.relative_path == "archive/local.org")
                .unwrap()
                .state,
            OrgRepoSyncFileState::Synchronized
        );
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn first_sync_syncs_one_sided_files_and_keeps_two_sided_files_for_confirmation() {
        let (mut repo, root) = repo().await;
        tokio::fs::write(root.join("local.org"), b"* TODO Local\n")
            .await
            .unwrap();
        tokio::fs::write(root.join("same.org"), b"* TODO Same\n")
            .await
            .unwrap();
        let (policy, state, worker) = server(&[
            ("remote.org", b"* TODO Remote\r\n"),
            ("same.org", b"* TODO Same\n"),
        ])
        .await;
        let initial = sync(&mut repo, &policy, 1).await;
        assert_eq!(initial.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(initial.files.len(), 3);
        assert_eq!(
            initial
                .files
                .iter()
                .find(|file| file.relative_path == "local.org")
                .unwrap()
                .state,
            OrgRepoSyncFileState::Synchronized
        );
        assert_eq!(
            initial
                .files
                .iter()
                .find(|file| file.relative_path == "remote.org")
                .unwrap()
                .state,
            OrgRepoSyncFileState::Synchronized
        );
        assert_eq!(
            initial
                .files
                .iter()
                .find(|file| file.relative_path == "same.org")
                .unwrap()
                .state,
            OrgRepoSyncFileState::Conflict
        );
        assert!(root.join("remote.org").is_file());
        assert_eq!(state.lock().unwrap().files.len(), 3);
        assert!(
            state
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|request| request.starts_with("PUT") && request.contains("local.org"))
        );
        let request_count = state.lock().unwrap().requests.len();
        let repeated = repo.sync(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default()).await;
        assert!(matches!(repeated, Err(CoreError::InvalidState(_))));
        assert_eq!(state.lock().unwrap().requests.len(), request_count);
        assert!(!root.join(".sync/history/2.json").exists());
        let mut comparison = policy.compare_merge(&mut repo, &initial.id).await.unwrap();
        assert_eq!(comparison.unchanged_count, 1);
        for change in &mut comparison.changes {
            change.resolution = Some(WebDavMergeResolution::Remote);
        }
        let result = policy
            .apply_merge(&mut repo, &comparison, 100)
            .await
            .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(result.backups.len(), 1);
        assert_eq!(result.backups[0].path, "same.org");
        assert_eq!(
            tokio::fs::read(root.join("remote.org")).await.unwrap(),
            b"* TODO Remote\r\n"
        );
        assert_eq!(
            state.lock().unwrap().files["local.org"].data,
            b"* TODO Local\n"
        );
        let next = sync(&mut repo, &policy, 101).await;
        assert_eq!(next.result, Some(OrgRepoSyncResult::Succeeded));
        assert!(
            next.files
                .iter()
                .all(|file| file.action == OrgRepoSyncFileAction::Unchanged)
        );
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn failed_merge_does_not_bypass_latest_successful_conflicts() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "a.org").await;
        offline(&mut repo, "b.org").await;
        let (policy, state, worker) = server(&[
            ("a.org", b"* TODO Remote A\n"),
            ("b.org", b"* TODO Remote B\n"),
        ])
        .await;
        let failed = sync(&mut repo, &policy, 1).await;
        let mut comparison = policy.compare_merge(&mut repo, &failed.id).await.unwrap();
        for change in &mut comparison.changes {
            change.resolution = Some(if change.path == "a.org" {
                WebDavMergeResolution::Remote
            } else {
                WebDavMergeResolution::Local
            });
        }
        state.lock().unwrap().reject.insert("b.org".into());
        let partial = policy
            .apply_merge(&mut repo, &comparison, 100)
            .await
            .unwrap();
        assert_eq!(partial.record.result, Some(OrgRepoSyncResult::Failed));
        assert_eq!(
            partial
                .record
                .files
                .iter()
                .find(|file| file.relative_path == "a.org")
                .unwrap()
                .state,
            OrgRepoSyncFileState::Synchronized
        );
        offline(&mut repo, "a.org").await;
        let count = state.lock().unwrap().requests.len();
        let local_a = tokio::fs::read(root.join("a.org")).await.unwrap();
        let pending = repo.pending_writes().await.unwrap();
        let retry = repo.sync(&policy, 101, &SyncCancellation::default(), &SyncProgressReporter::default()).await;
        assert!(matches!(retry, Err(CoreError::InvalidState(_))));
        assert_eq!(state.lock().unwrap().requests.len(), count);
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), local_a);
        assert_eq!(repo.pending_writes().await.unwrap(), pending);
        assert!(!root.join(".sync/history/101.json").exists());
        assert_eq!(repo.last_effect_sync().await.unwrap().unwrap().id, failed.id);
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn first_sync_uploads_local_only_and_downloads_remote_only_files() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "local.org").await;
        let original = tokio::fs::read(root.join("local.org")).await.unwrap();
        let (policy, _, worker) = server(&[("remote.org", b"* TODO Remote\n")]).await;
        let first = sync(&mut repo, &policy, 1).await;
        assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(
            tokio::fs::read(root.join("local.org")).await.unwrap(),
            original
        );
        assert_eq!(
            tokio::fs::read(root.join("remote.org")).await.unwrap(),
            b"* TODO Remote\n"
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn external_todo_default_change_invalidates_pending_merge_without_writing() {
        let (mut repo, root) = repo().await;
        offline(&mut repo, "inbox.org").await;
        let (policy, state, worker) = server(&[("inbox.org", b"* TODO Remote\n")]).await;
        let first = sync(&mut repo, &policy, 1).await;
        let comparison = policy.compare_merge(&mut repo, &first.id).await.unwrap();
        let count = state.lock().unwrap().requests.len();
        repo.set_todo_defaults(
            crate::TodoConfig::from_settings("#+TODO: NEXT | FINISHED").unwrap(),
        )
        .unwrap();
        assert!(
            policy
                .apply_merge(&mut repo, &comparison, 100)
                .await
                .is_err()
        );
        assert_eq!(state.lock().unwrap().requests.len(), count);
        assert!(!root.join(".sync/backups").exists());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn downloaded_file_todo_declarations_override_external_defaults_and_survive_reload() {
        let (mut repo, root) = repo().await;
        repo.set_todo_defaults(
            crate::TodoConfig::from_settings("#+TODO: GLOBAL | CLOSED").unwrap(),
        )
        .unwrap();
        let bytes = b"#+TODO: OPEN(o) | FINISHED(f!)\r\n* OPEN Pending\r\n* FINISHED Complete\r\n";
        let (policy, _, worker) = server(&[("inbox.org", bytes)]).await;
        let first = sync(&mut repo, &policy, 1).await;
        assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let file = &repo.files[0];
        assert_eq!(file.source_bytes(), bytes);
        assert_eq!(file.todo.source, crate::TodoSource::InBuffer);
        assert_eq!(file.todo.initial_state.as_deref(), Some("OPEN"));
        assert_eq!(file.todo.done_keywords, ["FINISHED"]);
        let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        assert_eq!(workspace.query(&crate::TaskQuery { expression: "it.done".into(), ..Default::default() }).unwrap().tasks.len(), 1);
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn archive_conflict_resolves_offline_then_uploads_with_version_check() {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("a.org", b"* TODO Base\n")]).await;
        let downloaded = sync(&mut repo, &policy, 1).await;
        assert!(downloaded.files[0].detail.archive.is_some());
        tokio::fs::write(root.join("a.org"), b"* TODO Base\n* TODO Local\n").await.unwrap();
        { let mut s = state.lock().unwrap(); s.files.insert("a.org".into(), Remote { data: b"* TODO Base\n* TODO Remote\n".to_vec(), etag: "\"v2\"".into() }); }
        let conflict = sync(&mut repo, &policy, 2).await;
        assert_eq!(conflict.files[0].state, OrgRepoSyncFileState::Conflict);
        assert_eq!(repo.history_file(&conflict.id, "a.org", false).await.unwrap().source_bytes(), b"* TODO Base\n* TODO Remote\n");
        tokio::fs::write(root.join("a.org"), b"* TODO Base\n* TODO Local\n* TODO After sync\n").await.unwrap();
        let mut comparison = repo.compare_sync_conflict(&conflict.id, "a.org").await.unwrap();
        for change in &mut comparison.changes { change.resolution = Some(WebDavMergeResolution::Local); }
        let count = state.lock().unwrap().requests.len();
        repo.resolve_sync_conflict(&comparison).await.unwrap();
        assert_eq!(state.lock().unwrap().requests.len(), count, "解决时不得联网");
        let final_bytes = tokio::fs::read(root.join("a.org")).await.unwrap();
        assert!(String::from_utf8_lossy(&final_bytes).contains("After sync"));
        assert_eq!(repo.history_file(&conflict.id, "a.org", true).await.unwrap().source_bytes(), final_bytes);
        assert!(repo.notifications().await.unwrap().is_empty());
        let upload = sync(&mut repo, &policy, 3).await;
        assert_eq!(upload.files[0].action, OrgRepoSyncFileAction::Uploaded);
        assert_eq!(state.lock().unwrap().files["a.org"].data, final_bytes);
        assert!(repo.pending_writes().await.unwrap().is_empty());
        assert!(state.lock().unwrap().requests[count..].iter().any(|r| r.starts_with("PUT") && r.contains("if-match: \"v2\"")));
        worker.abort(); tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn changed_remote_after_local_resolution_creates_new_independent_conflict() {
        let (mut repo, root) = repo().await;
        tokio::fs::write(root.join("a.org"), b"* TODO Local\n").await.unwrap();
        let (policy, state, worker) = server(&[("a.org", b"* TODO Remote\n")]).await;
        let first = sync(&mut repo, &policy, 1).await;
        let mut comparison = repo.compare_sync_conflict(&first.id, "a.org").await.unwrap();
        for c in &mut comparison.changes { c.resolution = Some(WebDavMergeResolution::Local); }
        repo.resolve_sync_conflict(&comparison).await.unwrap();
        { let mut s = state.lock().unwrap(); s.files.insert("a.org".into(), Remote { data: b"* TODO New remote\n".to_vec(), etag: "\"new\"".into() }); }
        let count = state.lock().unwrap().requests.len();
        let second = sync(&mut repo, &policy, 2).await;
        assert_eq!(second.files[0].state, OrgRepoSyncFileState::Conflict);
        assert!(state.lock().unwrap().requests[count..].iter().all(|r| !r.starts_with("PUT")));
        assert_eq!(repo.history_file(&first.id, "a.org", false).await.unwrap().source_bytes(), b"* TODO Remote\n");
        assert_eq!(repo.history_file(&second.id, "a.org", false).await.unwrap().source_bytes(), b"* TODO New remote\n");
        let count = state.lock().unwrap().requests.len();
        let third = repo.sync(&policy, 3, &SyncCancellation::default(), &SyncProgressReporter::default()).await;
        assert!(matches!(third, Err(CoreError::InvalidState(_))));
        assert_eq!(state.lock().unwrap().requests.len(), count);
        let pending = repo.pending_sync_conflicts().await.unwrap();
        assert_eq!(pending.iter().map(|c| c.sync_id.as_str()).collect::<Vec<_>>(), vec![second.id.as_str()]);
        assert!(repo.history_detail(&first.id).await.unwrap().files[0].outcome == WebDavSyncFileOutcome::Resolved);
        worker.abort(); tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn backup_failure_prevents_upload_and_local_deletion_downloads_remote() {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("a.org", b"* TODO Remote\n")]).await;
        sync(&mut repo, &policy, 1).await;
        tokio::fs::write(root.join("a.org"), b"* TODO Local\n").await.unwrap();
        tokio::fs::write(root.join(".sync/history/2"), b"not a directory").await.unwrap();
        let count = state.lock().unwrap().requests.len();
        let failure = sync(&mut repo, &policy, 2).await;
        assert_eq!(failure.files[0].state, OrgRepoSyncFileState::Failed);
        assert!(state.lock().unwrap().requests[count..].iter().all(|r| !r.starts_with("PUT")));
        tokio::fs::remove_file(root.join("a.org")).await.unwrap();
        let downloaded = sync(&mut repo, &policy, 3).await;
        assert_eq!(downloaded.files[0].action, OrgRepoSyncFileAction::Downloaded);
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), b"* TODO Remote\n");
        worker.abort(); tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn failed_sync_keeps_all_local_downloads_deletions_and_rules_unchanged() {
        let (mut repo,root)=repo().await;
        let (policy,state,worker)=server(&[(".orgzlyignore",b"old.org\n"),("a.org",b"* TODO Old A\n"),("b.org",b"* TODO Old B\n"),("z.org",b"* TODO Old Z\n")]).await;
        let first=sync(&mut repo,&policy,1).await;
        offline(&mut repo,"b.org").await;
        let before_b=tokio::fs::read(root.join("b.org")).await.unwrap();
        {let mut dav=state.lock().unwrap();
         dav.files.get_mut("a.org").unwrap().data=b"* TODO New A\n".to_vec();
         dav.files.get_mut("a.org").unwrap().etag="\"a-new\"".into();
         dav.files.remove("b.org");
         dav.files.get_mut(".orgzlyignore").unwrap().data=b"new.org\n".to_vec();
         dav.files.get_mut(".orgzlyignore").unwrap().etag="\"rules-new\"".into();
         dav.files.get_mut("z.org").unwrap().data=vec![0xff];
         dav.files.get_mut("z.org").unwrap().etag="\"z-bad\"".into();}
        let events=std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured=events.clone();
        let workspace=crate::OrgWorkspace::new(vec![repo.clone()]).unwrap();
        let subscription=workspace.watch_notifications(move |event|{captured.lock().unwrap().push(event);});
        let failed=sync(&mut repo,&policy,2).await;
        assert_eq!(events.lock().unwrap().len(),1,"失败日志提交也应广播通知更新");
        drop(subscription);
        assert_eq!(failed.result,Some(OrgRepoSyncResult::Failed));
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(),b"* TODO Old A\n");
        assert_eq!(tokio::fs::read(root.join("b.org")).await.unwrap(),before_b);
        assert_eq!(tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),b"old.org\n");
        assert!(repo.task_scan_rules.excludes("old.org"));
        assert!(!repo.task_scan_rules.excludes("new.org"));
        assert_eq!(repo.last_effect_sync().await.unwrap().unwrap().id,first.id);
        assert_eq!(repo.history_file(&failed.id,"a.org",false).await.unwrap().source_bytes(),b"* TODO New A\n");
        assert_eq!(failed.files.iter().find(|f|f.relative_path=="a.org").unwrap().state,OrgRepoSyncFileState::Failed);
        assert_eq!(repo.pending_writes().await.unwrap().len(),1);
        {let mut dav=state.lock().unwrap();dav.files.get_mut("z.org").unwrap().data=b"* TODO Fixed\n".to_vec();dav.files.get_mut("z.org").unwrap().etag="\"z-good\"".into();}
        let success=sync(&mut repo,&policy,3).await;
        assert_eq!(success.result,Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(),b"* TODO New A\n");
        assert!(!root.join("b.org").exists());
        assert_eq!(tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),b"new.org\n");
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.abort();tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn history_persist_failure_rolls_back_local_sync_changes() {
        struct RejectHistory { target: std::path::PathBuf }
        impl WebDavSyncMonitor for RejectHistory {
            fn on_event(&self,event:WebDavSyncEvent) {
                if matches!(event,WebDavSyncEvent::Finished {result:OrgRepoSyncResult::Succeeded,..}) {
                    std::fs::write(&self.target,b"occupied").unwrap();
                }
            }
        }
        let (mut repo,root)=repo().await;
        let (policy,_,worker)=server(&[("a.org",b"* TODO Download\n")]).await;
        let policy=policy.with_monitor(RejectHistory {target:root.join(".sync/history/1.json")});
        let result=repo.sync(&policy,1,&SyncCancellation::default(),&SyncProgressReporter::default()).await;
        assert!(result.is_err());
        assert!(!root.join("a.org").exists());
        assert!(root.join(".sync/history/1/files/a.org/a.org").is_file());
        worker.abort();tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn cancelled_sync_does_not_apply_downloaded_files() {
        struct CancelAfterDownload { token: SyncCancellation }
        impl WebDavSyncMonitor for CancelAfterDownload {
            fn on_event(&self,event:WebDavSyncEvent) {
                if matches!(event,WebDavSyncEvent::FileProcessed {..}) {self.token.cancel();}
            }
        }
        let (mut repo,root)=repo().await;
        let (policy,_,worker)=server(&[("a.org",b"* TODO A\n"),("b.org",b"* TODO B\n")]).await;
        let token=SyncCancellation::default();
        let policy=policy.with_monitor(CancelAfterDownload {token:token.clone()});
        let record=repo.sync(&policy,1,&token,&SyncProgressReporter::default()).await.unwrap();
        assert_eq!(record.result,Some(OrgRepoSyncResult::Cancelled));
        assert!(!root.join("a.org").exists());assert!(!root.join("b.org").exists());
        assert!(repo.last_effect_sync().await.unwrap().is_none());
        worker.abort();tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn unresolved_conflicts_block_all_sync_entries_before_network_and_writes() {
        let (mut repo, root) = repo().await;
        tokio::fs::create_dir(root.join("blocked")).await.unwrap();
        tokio::fs::write(root.join("blocked/a.org"), b"* TODO Local A\n").await.unwrap();
        tokio::fs::write(root.join("blocked/b.org"), b"* TODO Local B\n").await.unwrap();
        let (policy, state, worker) = server(&[("blocked/a.org", b"* TODO Remote A\n"), ("blocked/b.org", b"* TODO Remote B\n")]).await;
        let first = sync(&mut repo, &policy, 1).await;
        offline(&mut repo, "blocked/a.org").await;
        let before = tokio::fs::read(root.join("blocked/a.org")).await.unwrap();
        let intents = repo.pending_writes().await.unwrap();
        let history = tokio::fs::read(root.join(".sync/history/1.json")).await.unwrap();
        let count = state.lock().unwrap().requests.len();
        let updates = Arc::new(Mutex::new(Vec::new()));
        let captured = updates.clone();
        let workspace = crate::OrgWorkspace::new(vec![repo.clone()]).unwrap();
        let _subscription = workspace.watch_notifications(move |event| captured.lock().unwrap().push(event));
        // 缺少备份的未解决冲突同样阻止同步，目录过滤不能绕过检查。
        let backup = root.join(".sync/history/1/files/blocked/b.org/b.org");
        let remote_b = tokio::fs::read(&backup).await.unwrap();
        tokio::fs::remove_file(&backup).await.unwrap();
        for filtered in [false, true] {
            let result = if filtered {
                repo.sync_with_options(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default(),
                    crate::SyncOptions { excluded_directories: vec!["blocked".into()] }).await
            } else { repo.sync(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default()).await };
            assert!(matches!(result, Err(CoreError::InvalidState("存在未解决的同步冲突，请先解决后再同步"))));
        }
        let mut context = SyncContext::new(&mut repo, 2);
        assert!(policy.synchronize(&mut context, &SyncCancellation::default(), &SyncProgressReporter::default()).await.is_err());
        assert_eq!(state.lock().unwrap().requests.len(), count);
        assert_eq!(tokio::fs::read(root.join("blocked/a.org")).await.unwrap(), before);
        assert_eq!(repo.pending_writes().await.unwrap(), intents);
        assert_eq!(tokio::fs::read(root.join(".sync/history/1.json")).await.unwrap(), history);
        assert!(!root.join(".sync/history/2.json").exists());
        assert!(!root.join(".sync/history/2").exists());
        assert!(updates.lock().unwrap().is_empty(), "被拒绝的同步不应发出数据更新通知");
        tokio::fs::write(backup, remote_b).await.unwrap();
        // 本地解决接口不受阻拦；部分解决仍拒绝，全部完成后允许正常同步。
        let mut a = repo.compare_sync_conflict(&first.id, "blocked/a.org").await.unwrap();
        for change in &mut a.changes { change.resolution = Some(WebDavMergeResolution::Local); }
        repo.resolve_sync_conflict(&a).await.unwrap();
        assert!(repo.sync(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default()).await.is_err());
        assert_eq!(state.lock().unwrap().requests.len(), count);
        let mut b = repo.compare_sync_conflict(&first.id, "blocked/b.org").await.unwrap();
        for change in &mut b.changes { change.resolution = Some(WebDavMergeResolution::Remote); }
        repo.resolve_sync_conflict(&b).await.unwrap();
        assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
        let next = sync(&mut repo, &policy, 2).await;
        assert_eq!(next.result, Some(OrgRepoSyncResult::Succeeded));
        assert!(state.lock().unwrap().requests.len() > count);
        worker.abort(); tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn old_conflicts_do_not_block_when_latest_success_is_clean() {
        let (mut repo, root) = repo().await;
        tokio::fs::write(root.join("a.org"), b"* TODO Local\n").await.unwrap();
        let (policy, state, worker) = server(&[("a.org", b"* TODO Remote\n")]).await;
        let first = sync(&mut repo, &policy, 1).await;
        let mut clean = OrgRepoSyncRecord::<WebDavSyncContextDetail, WebDavSyncFileDetail>::new("clean".into(), 2).unwrap().with_kind("webdav");
        clean.finish(OrgRepoSyncResult::Succeeded, 3).unwrap();
        tokio::fs::write(root.join(".sync/history/2.json"), serde_json::to_vec(&clean).unwrap()).await.unwrap();
        assert_eq!(repo.history_detail(&first.id).await.unwrap().summary.pending_conflicts, 1);
        let count = state.lock().unwrap().requests.len();
        let next = sync(&mut repo, &policy, 4).await;
        assert_eq!(next.result, Some(OrgRepoSyncResult::Succeeded));
        assert!(state.lock().unwrap().requests.len() > count);
        worker.abort(); tokio::fs::remove_dir_all(root).await.unwrap();
    }

}
