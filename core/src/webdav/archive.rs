//! 日志中的固定远端冲突原文、只读历史和单文件本地解决；不访问远端。
use super::*;
use crate::{OrgFileMetadata, OrgMergeChange, OrgMergeChoice, OrgRepoWriteIntent};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::fs;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavConflictSync {
    pub sync_id: String,
    pub paths: Vec<String>,
}

type Record = OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebDavFileArchive {
    pub content_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncConflictTarget {
    pub sync_id: String,
    pub path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncConflictChange {
    pub key: String,
    pub kind: OrgMergeChange,
    pub preamble: bool,
    pub local: Option<crate::OrgMergeVersion>,
    pub remote: Option<crate::OrgMergeVersion>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncConflictComparison {
    pub repo_id: String,
    pub target: SyncConflictTarget,
    pub local_hash: String,
    pub remote_hash: String,
    pub local_missing: bool,
    pub changes: Vec<SyncConflictChange>,
    pub unchanged_count: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncConflictResolution {
    pub target: SyncConflictTarget,
    pub expected_local_hash: String,
    pub expected_remote_hash: String,
    pub expected_local_missing: bool,
    pub choices: Vec<OrgMergeChoice>,
}

pub(crate) fn archive_name(path: &str, resolved: bool) -> Result<String, CoreError> {
    validate_path(path)?;
    let filename = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or(CoreError::InvalidInput("备份文件名无效"))?;
    if resolved {
        Ok(format!(
            "{}.resolved.org",
            filename
                .strip_suffix(".org")
                .ok_or(CoreError::InvalidInput("解决结果必须是 Org 文件"))?
        ))
    } else {
        Ok(filename.into())
    }
}

async fn safe_directory(
    repo: &OrgRepo,
    relative: &str,
    create: bool,
) -> Result<PathBuf, CoreError> {
    crate::model::validate_relative_path(relative)?;
    let mut target = fs::canonicalize(&repo.root_directory)
        .await
        .map_err(archive_io)?;
    for part in relative.split('/') {
        target.push(part);
        match fs::symlink_metadata(&target).await {
            Ok(m) if m.file_type().is_symlink() || !m.is_dir() => {
                return Err(CoreError::Store("日志备份路径不是安全目录".into()));
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if create {
                    fs::create_dir(&target).await.map_err(archive_io)?;
                }
            }
            Err(e) => return Err(archive_io(e)),
        }
    }
    Ok(target)
}

async fn checked_file(path: PathBuf) -> Result<PathBuf, CoreError> {
    match fs::symlink_metadata(&path).await {
        Ok(m) if m.file_type().is_symlink() || !m.is_file() => {
            return Err(CoreError::Store("日志备份不是普通文件".into()));
        }
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(archive_io(e)),
    }
    Ok(path)
}

// 读取保留旧 files/ 布局；新写入只能使用 conflicts/。
async fn archive_path(
    repo: &OrgRepo,
    time: TimestampMs,
    path: &str,
    resolved: bool,
) -> Result<PathBuf, CoreError> {
    let name = archive_name(path, resolved)?;
    let directory = safe_directory(
        repo,
        &format!(".sync/history/{time}/conflicts/{path}"),
        false,
    )
    .await?;
    let directory = if fs::try_exists(&directory).await.map_err(archive_io)? {
        directory
    } else {
        safe_directory(repo, &format!(".sync/history/{time}/files/{path}"), false).await?
    };
    checked_file(directory.join(name)).await
}

async fn optional_bytes(path: &Path) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::read(path).await {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(archive_io(e)),
    }
}

#[cfg(test)]
pub(crate) async fn save_archive(
    repo: &OrgRepo,
    time: TimestampMs,
    path: &str,
    bytes: &[u8],
) -> Result<WebDavFileArchive, CoreError> {
    let name = archive_name(path, false)?;
    let log_directory = safe_directory(repo, &format!(".sync/history/{time}"), true).await?;
    let temporary_name = format!(
        ".conflicts-{}.tmp",
        crate::model::service::generate_repo_id()?
    );
    let temporary = log_directory.join(&temporary_name);
    fs::create_dir(&temporary).await.map_err(archive_io)?;
    let result = async {
        // 首个冲突连同完整目录一次发布，保存失败不留下可被误认的 conflicts/ 标记。
        let staged = safe_directory(
            repo,
            &format!(".sync/history/{time}/{temporary_name}/{path}"),
            true,
        )
        .await?;
        crate::model::write_intent::write_new(&staged.join(name), bytes).await?;
        let conflicts =
            safe_directory(repo, &format!(".sync/history/{time}/conflicts"), false).await?;
        if fs::try_exists(&conflicts).await.map_err(archive_io)? {
            let destination = safe_directory(
                repo,
                &format!(".sync/history/{time}/conflicts/{path}"),
                false,
            )
            .await?;
            if fs::symlink_metadata(&destination).await.is_ok() {
                return Err(CoreError::InvalidState("冲突备份已经存在"));
            }
            let relative = Path::new(path).parent().unwrap();
            if !relative.as_os_str().is_empty() {
                safe_directory(
                    repo,
                    &format!(".sync/history/{time}/conflicts/{}", relative.display()),
                    true,
                )
                .await?;
            }
            fs::rename(&staged, &destination).await.map_err(archive_io)
        } else {
            fs::rename(&temporary, &conflicts).await.map_err(archive_io)
        }
    }
    .await;
    // 正式发布之后临时目录已移动；追加到已有冲突目录时清理暂存的空父目录。
    let _ = fs::remove_dir_all(&temporary).await;
    result?;
    Ok(WebDavFileArchive {
        content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
    })
}

impl OrgRepo {
    async fn project_conflict_state(&self, record: &mut Record) -> Result<(), CoreError> {
        if record.context_detail.format_version > 4 {
            return Err(CoreError::InvalidState("不支持的同步历史版本"));
        }
        if record.context_detail.format_version >= 4 {
            for file in &mut record.files {
                if !super::history::is_conflict(file) {
                    continue;
                }
                let source = file
                    .detail
                    .synced_source
                    .as_ref()
                    .ok_or(CoreError::InvalidState("任务冲突历史缺少已上传快照"))?;
                let historical =
                    self.parse_file(file.relative_path.clone(), source.as_bytes().to_vec())?;
                let ids = crate::merge::conflict_ids(&historical);
                let current =
                    super::transaction::read(Path::new(&self.root_directory), &file.relative_path)
                        .await?;
                let current = current
                    .map(|bytes| self.parse_file(file.relative_path.clone(), bytes))
                    .transpose()?;
                file.detail.resolved = current
                    .as_ref()
                    .is_none_or(|current| crate::merge::conflict_ids(current).is_disjoint(&ids));
            }
            return Ok(());
        }
        for file in &mut record.files {
            if record.context_detail.format_version >= 2 && file.relative_path.ends_with(".org") {
                let directory = safe_directory(
                    self,
                    &format!(
                        ".sync/history/{}/conflicts/{}",
                        record.started_at, file.relative_path
                    ),
                    false,
                )
                .await?;
                if fs::try_exists(directory).await.map_err(archive_io)? {
                    file.state = OrgRepoSyncFileState::Conflict;
                }
            }
            if super::history::is_conflict(file) {
                let target =
                    archive_path(self, record.started_at, &file.relative_path, true).await?;
                file.detail.resolved = fs::try_exists(target).await.map_err(archive_io)?;
            }
        }
        Ok(())
    }

    pub async fn webdav_history(&self) -> Result<Vec<Record>, CoreError> {
        let _guard = super::transaction::lock(Path::new(&self.root_directory)).await?;
        super::transaction::recover(Path::new(&self.root_directory)).await?;
        let mut history = self.sync_history::<WebDavSyncPolicy>().await?;
        for record in &mut history {
            self.project_conflict_state(record).await?;
        }
        Ok(history)
    }

    pub async fn last_effect_sync(&self) -> Result<Option<Record>, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        let _guard = super::transaction::lock(Path::new(&self.root_directory)).await?;
        super::transaction::recover(Path::new(&self.root_directory)).await?;
        let history = self.sync_history::<WebDavSyncPolicy>().await?;
        let Some(mut record) = history
            .into_iter()
            .rev()
            .find(|r| r.result == Some(OrgRepoSyncResult::Succeeded))
        else {
            return Ok(None);
        };
        self.project_conflict_state(&mut record).await?;
        Ok(Some(record))
    }

    pub async fn pending_sync_conflicts(&self) -> Result<Vec<WebDavConflictSync>, CoreError> {
        let Some(record) = self.last_effect_sync().await? else {
            return Ok(Vec::new());
        };
        let paths = record
            .files
            .iter()
            .filter(|f| super::history::is_conflict(f) && !f.detail.resolved)
            .map(|f| f.relative_path.clone())
            .collect::<Vec<_>>();
        Ok(if paths.is_empty() {
            Vec::new()
        } else {
            vec![WebDavConflictSync {
                sync_id: record.id,
                paths,
            }]
        })
    }

    pub async fn history_summaries(&self) -> Result<Vec<WebDavSyncRecordSummary>, CoreError> {
        sync_history_summaries(&self.webdav_history().await?)
    }

    pub async fn history_detail(&self, sync_id: &str) -> Result<WebDavSyncRecordDetail, CoreError> {
        let history = self.webdav_history().await?;
        let mut detail = sync_history_detail(&history, sync_id)?;
        let record = history.iter().find(|r| r.id == sync_id).unwrap();
        for (item, file) in detail.files.iter_mut().zip(&record.files) {
            item.section = match item.outcome {
                WebDavSyncFileOutcome::Conflict | WebDavSyncFileOutcome::Resolved => {
                    Some("conflict".into())
                }
                WebDavSyncFileOutcome::Uploaded | WebDavSyncFileOutcome::Created => {
                    Some("upload".into())
                }
                WebDavSyncFileOutcome::Downloaded | WebDavSyncFileOutcome::Deleted => {
                    Some("download".into())
                }
                _ => None,
            };
            if item.section.is_some() && item.outcome != WebDavSyncFileOutcome::Deleted {
                if let Some(bytes) = self
                    .archive_bytes(record, file, file.detail.resolved)
                    .await?
                {
                    let mut snapshot = self.parse_file(
                        archive_name(&file.relative_path, file.detail.resolved)?,
                        bytes,
                    )?;
                    snapshot.modified_at = if file.detail.archive.is_some() {
                        let target = archive_path(
                            self,
                            record.started_at,
                            &file.relative_path,
                            file.detail.resolved,
                        )
                        .await?;
                        fs::metadata(target)
                            .await
                            .ok()
                            .and_then(|m| m.modified().ok())
                            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                            .map(|d| d.as_millis() as i64)
                    } else {
                        record.finished_at
                    };
                    item.backup = Some(snapshot_metadata(&snapshot));
                }
            }
        }
        Ok(detail)
    }

    async fn archive_bytes(
        &self,
        record: &Record,
        file: &OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
        resolved: bool,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        if resolved && record.context_detail.format_version >= 4 {
            if let Some(bytes) = optional_bytes(
                &archive_path(self, record.started_at, &file.relative_path, true).await?,
            )
            .await?
            {
                return Ok(Some(bytes));
            }
        }
        if let Some(archive) = &file.detail.archive {
            let target =
                archive_path(self, record.started_at, &file.relative_path, resolved).await?;
            let bytes = optional_bytes(&target).await?;
            if !resolved
                && bytes.as_deref().is_some_and(|b| {
                    LocalFileVersion::from_bytes(b).content_hash != archive.content_hash
                })
            {
                return Err(CoreError::Store("历史备份内容与记录版本不一致".into()));
            }
            return Ok(bytes);
        }
        if (record.context_detail.format_version >= 4
            && record.result == Some(OrgRepoSyncResult::Succeeded))
            || (!resolved
                && record.context_detail.format_version >= 2
                && !super::history::is_conflict(file)
                && file.state == OrgRepoSyncFileState::Synchronized)
        {
            if let Some(source) = &file.detail.synced_source {
                if file.local_version.as_ref()
                    != Some(&LocalFileVersion::from_bytes(source.as_bytes()))
                {
                    return Err(CoreError::Store("历史快照与记录版本不一致".into()));
                }
                return Ok(Some(source.as_bytes().to_vec()));
            }
        }
        Ok(None)
    }

    pub async fn history_file(
        &self,
        sync_id: &str,
        path: &str,
        resolved: bool,
    ) -> Result<OrgFile, CoreError> {
        validate_path(path)?;
        let history = self.webdav_history().await?;
        let record = history
            .iter()
            .find(|r| r.id == sync_id)
            .ok_or(CoreError::InvalidInput("同步记录不存在"))?;
        let file = record
            .files
            .iter()
            .find(|f| f.relative_path == path)
            .ok_or(CoreError::InvalidInput("同步文件不存在"))?;
        if resolved && !file.detail.resolved {
            return Err(CoreError::InvalidState("此文件尚未解决"));
        }
        let bytes =
            self.archive_bytes(record, file, resolved)
                .await?
                .ok_or(CoreError::InvalidState(
                    "该日志未保存文件备份，无法打开历史内容",
                ))?;
        self.parse_file(archive_name(path, resolved)?, bytes)
    }

    pub async fn compare_conflict(
        &mut self,
        target: &SyncConflictTarget,
    ) -> Result<SyncConflictComparison, CoreError> {
        self.load::<WebDavSyncPolicy>().await?;
        let history = self.webdav_history().await?;
        let record = history
            .iter()
            .find(|r| r.id == target.sync_id)
            .ok_or(CoreError::InvalidInput("同步记录不存在"))?;
        let file = record
            .files
            .iter()
            .find(|f| f.relative_path == target.path && super::history::is_conflict(f))
            .ok_or(CoreError::InvalidInput("该文件不是冲突记录"))?;
        if file.detail.resolved {
            return Err(CoreError::InvalidState("该文件已解决，请刷新后查看结果"));
        }
        if record.context_detail.format_version >= 4 {
            let current = self.file(&target.path)?;
            let changes = crate::merge::versions(&current)?
                .into_iter()
                .map(|v| SyncConflictChange {
                    key: v.key,
                    kind: match (&v.local, &v.remote) {
                        (Some(_), Some(_)) => OrgMergeChange::Modified,
                        (Some(_), None) => OrgMergeChange::Added,
                        _ => OrgMergeChange::Deleted,
                    },
                    preamble: v.preamble,
                    local: v.local,
                    remote: v.remote,
                })
                .collect::<Vec<_>>();
            let remote = file
                .detail
                .synced_source
                .as_ref()
                .ok_or(CoreError::InvalidState("任务冲突历史缺少已上传快照"))?;
            return Ok(SyncConflictComparison {
                repo_id: self.id.clone(),
                target: target.clone(),
                local_hash: LocalFileVersion::from_bytes(current.source_bytes()).content_hash,
                remote_hash: LocalFileVersion::from_bytes(remote.as_bytes()).content_hash,
                local_missing: false,
                unchanged_count: current.node_paths().len().saturating_sub(changes.len()),
                changes,
            });
        }
        let remote = self
            .history_file(&target.sync_id, &target.path, false)
            .await?;
        let local = self.file(&target.path)?;
        let plan = crate::compare_org_tasks(&local, &remote, None);
        let mut changes = Vec::new();
        let mut unchanged_count = 0;
        for item in &plan.items {
            if item.change == OrgMergeChange::Unchanged {
                if item.key != "preamble" && item.remote.is_some() {
                    unchanged_count += 1;
                }
            } else {
                changes.push(SyncConflictChange {
                    key: item.key.clone(),
                    kind: match (&item.local, &item.remote) {
                        (Some(_), Some(_)) => OrgMergeChange::Modified,
                        (Some(_), None) => OrgMergeChange::Added,
                        _ => OrgMergeChange::Deleted,
                    },
                    preamble: item.key == "preamble",
                    local: item.local.clone(),
                    remote: item.remote.clone(),
                });
            }
        }
        Ok(SyncConflictComparison {
            repo_id: self.id.clone(),
            target: target.clone(),
            local_hash: plan.local_hash,
            remote_hash: plan.remote_hash,
            local_missing: !self.files.iter().any(|f| f.path == target.path),
            changes,
            unchanged_count,
        })
    }

    pub async fn resolve_conflict(
        &mut self,
        request: &SyncConflictResolution,
    ) -> Result<(), CoreError> {
        let fresh = self.compare_conflict(&request.target).await?;
        if request.expected_local_hash != fresh.local_hash
            || request.expected_remote_hash != fresh.remote_hash
            || request.expected_local_missing != fresh.local_missing
        {
            return Err(CoreError::InvalidState(
                "本地文件或比较内容已改变，请重新比较",
            ));
        }
        let history = self.webdav_history().await?;
        let record = history
            .iter()
            .find(|r| r.id == request.target.sync_id)
            .ok_or(CoreError::InvalidInput("同步记录不存在"))?;
        if record.context_detail.format_version >= 4 {
            let root = Path::new(&self.root_directory);
            let _guard = super::transaction::lock(root).await?;
            let current = super::transaction::read(root, &request.target.path)
                .await?
                .ok_or(CoreError::InvalidState("本地文件已删除，请重新读取"))?;
            if LocalFileVersion::from_bytes(&current).content_hash != request.expected_local_hash {
                return Err(CoreError::InvalidState("本地文件再次改变，请重新比较"));
            }
            let parsed = self.parse_file(request.target.path.clone(), current.clone())?;
            let result = crate::merge::resolve(&parsed, &request.choices)?;
            let mut file = self.parse_file(request.target.path.clone(), result.clone())?;
            let mut plan = super::transaction::Plan::default();
            plan.set(root, request.target.path.clone(), Some(result.clone()))
                .await?;
            let result_path = format!(
                ".sync/history/{}/conflicts/{}/{}",
                record.started_at,
                request.target.path,
                archive_name(&request.target.path, true)?
            );
            plan.set(root, result_path, Some(result.clone())).await?;
            if result != current {
                let intent = OrgRepoWriteIntent {
                    relative_path: request.target.path.clone(),
                    content_hash: LocalFileVersion::from_bytes(&result).content_hash,
                };
                plan.set(
                    root,
                    format!(
                        ".sync/outbox/{}.json",
                        crate::model::service::generate_repo_id()?
                    ),
                    Some(serde_json::to_vec(&intent).unwrap()),
                )
                .await?;
            }
            plan.commit(root).await?;
            file.modified_at = fs::metadata(root.join(&request.target.path))
                .await
                .ok()
                .and_then(|m| m.modified().ok())
                .map(|t| chrono::DateTime::<chrono::Utc>::from(t).timestamp_millis());
            self.files.retain(|f| f.path != request.target.path);
            self.files.push(file);
            drop(_guard);
            if result != current {
                crate::model::notification::require_sync(&self.id);
            }
            crate::model::sync_events::publish(self);
            return Ok(());
        }
        let local = self.file(&request.target.path)?;
        let remote = self
            .history_file(&request.target.sync_id, &request.target.path, false)
            .await?;
        let result = crate::merge_org_tasks(
            &crate::compare_org_tasks(&local, &remote, None),
            &request.choices,
        )?;
        let history = self.webdav_history().await?;
        let record = history
            .iter()
            .find(|r| r.id == request.target.sync_id)
            .unwrap();
        let target = archive_path(self, record.started_at, &request.target.path, true).await?;
        if fs::try_exists(&target).await.map_err(archive_io)? {
            return Err(CoreError::InvalidState("解决结果已经存在"));
        }
        let needs_upload = result != remote.source_bytes();
        self.replace_conflict_file(
            &request.target.path,
            (!fresh.local_missing).then_some(fresh.local_hash.as_str()),
            Some(result.clone()),
        )
        .await?;
        if needs_upload {
            self.queue_sync_upload(&request.target.path, &result)
                .await?;
        } else {
            self.acknowledge_write(&request.target.path, &LocalFileVersion::from_bytes(&result))
                .await?;
        }
        let actual = crate::model::write_intent::task_target(
            Path::new(&self.root_directory),
            &request.target.path,
        )
        .await?;
        if fs::read(&actual).await.map_err(archive_io)? != result {
            return Err(CoreError::InvalidState("本地文件再次改变，请重新比较"));
        }
        let temporary = target.with_file_name(format!(
            ".{}.tmp",
            crate::model::service::generate_repo_id()?
        ));
        crate::model::write_intent::write_new(&temporary, &result).await?;
        let commit = async {
            if fs::read(&actual).await.map_err(archive_io)? != result {
                return Err(CoreError::InvalidState("本地文件再次改变，请重新比较"));
            }
            if fs::symlink_metadata(&target).await.is_ok() {
                return Err(CoreError::InvalidState("解决结果已存在，请刷新"));
            }
            fs::rename(&temporary, &target).await.map_err(archive_io)
        }
        .await;
        if commit.is_err() {
            let _ = fs::remove_file(&temporary).await;
        }
        commit?;
        // 已解决与需同步是两个独立事实；只有完整结果提交后才能提示同步。
        if needs_upload {
            crate::model::notification::require_sync(&self.id);
        }
        crate::model::sync_events::publish(self);
        Ok(())
    }

    pub(crate) async fn queue_sync_upload(
        &self,
        path: &str,
        bytes: &[u8],
    ) -> Result<(), CoreError> {
        validate_path(path)?;
        let directory = Path::new(&self.root_directory).join(".sync/outbox");
        for component in [
            Path::new(&self.root_directory).join(".sync"),
            directory.clone(),
        ] {
            match fs::symlink_metadata(&component).await {
                Ok(m) if m.file_type().is_symlink() || !m.is_dir() => {
                    return Err(CoreError::Store("待上传目录不安全".into()));
                }
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    fs::create_dir(&component).await.map_err(archive_io)?
                }
                Err(e) => return Err(archive_io(e)),
            }
        }
        let id = crate::model::service::generate_repo_id()?;
        let temporary = directory.join(format!("{id}.tmp"));
        let intent = OrgRepoWriteIntent {
            relative_path: path.into(),
            content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
        };
        crate::model::write_intent::write_new(&temporary, &serde_json::to_vec(&intent).unwrap())
            .await?;
        fs::rename(temporary, directory.join(format!("{id}.json")))
            .await
            .map_err(archive_io)
    }
}

fn snapshot_metadata(file: &OrgFile) -> OrgFileMetadata {
    use orgize::rowan::ast::AstNode;
    OrgFileMetadata {
        repo_id: file.repo_id.clone(),
        path: file.path.clone(),
        title: file.title(),
        title_parts: file.title_parts(),
        tag_options: file.tag_options(),
        tag_groups: file.tag_groups(),
        has_conflict: file.has_conflict(),
        is_ignore: false,
        task_count: file
            .syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(orgize::ast::Headline::cast)
            .count(),
        byte_length: file.source_bytes().len(),
        modified_at: file.modified_at,
    }
}
fn archive_io(e: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法读写同步日志备份：{e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn choose_all(
        comparison: &SyncConflictComparison,
        side: crate::OrgMergeSide,
    ) -> SyncConflictResolution {
        SyncConflictResolution {
            target: comparison.target.clone(),
            expected_local_hash: comparison.local_hash.clone(),
            expected_remote_hash: comparison.remote_hash.clone(),
            expected_local_missing: comparison.local_missing,
            choices: comparison
                .changes
                .iter()
                .map(|c| crate::OrgMergeChoice {
                    key: c.key.clone(),
                    side,
                })
                .collect(),
        }
    }

    struct Fixture {
        repo: OrgRepo,
        root: PathBuf,
    }
    impl Fixture {
        async fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "org-log-archive-{}",
                crate::model::service::generate_repo_id().unwrap()
            ));
            fs::create_dir(&root).await.unwrap();
            let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            repo.load::<WebDavSyncPolicy>().await.unwrap();
            Self { repo, root }
        }
        async fn conflict(&self, time: i64, path: &str, remote: Option<&[u8]>) -> String {
            let mut record = Record::new(format!("sync-{time}"), time)
                .unwrap()
                .with_kind("webdav");
            let mut detail = WebDavSyncFileDetail::from(
                RemoteFileVersion::new(Some(format!("\"v{time}\"")), None, None).unwrap(),
            );
            if let Some(bytes) = remote {
                detail.archive = Some(save_archive(&self.repo, time, path, bytes).await.unwrap());
            }
            record
                .append_file(
                    OrgRepoSyncFileRecord::new(
                        path.into(),
                        OrgRepoSyncFileAction::Conflicted,
                        OrgRepoSyncFileState::Conflict,
                    )
                    .unwrap()
                    .with_detail(detail),
                )
                .unwrap();
            record
                .finish(OrgRepoSyncResult::Succeeded, time + 1)
                .unwrap();
            fs::write(
                self.root.join(format!(".sync/history/{time}.json")),
                serde_json::to_vec(&record).unwrap(),
            )
            .await
            .unwrap();
            record.id
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[tokio::test]
    async fn resolves_latest_local_content_offline_and_preserves_history_and_other_conflicts() {
        let mut f = Fixture::new().await;
        let remote = b"#+TITLE: Remote\r\n* TODO Original\r\n";
        let first = f.conflict(10, "a.org", Some(remote)).await;
        let second = f.conflict(20, "a.org", Some(remote)).await;
        let original_json = fs::read(f.root.join(".sync/history/10.json"))
            .await
            .unwrap();
        // 用户同步之后、打开比较之前的编辑必须参与选择。
        let edited = b"#+TITLE: Latest\r\n* TODO Original\r\n* TODO Added after sync\r\n";
        fs::write(f.root.join("a.org"), edited).await.unwrap();
        let comparison = f
            .repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: first.clone(),
                path: "a.org".into(),
            })
            .await
            .unwrap();
        assert!(comparison.changes.iter().any(|c| {
            c.local
                .as_ref()
                .is_some_and(|v| v.source.contains("Added after sync"))
        }));
        let mut incomplete = choose_all(&comparison, crate::OrgMergeSide::Remote);
        incomplete.choices.clear();
        assert!(f.repo.resolve_conflict(&incomplete).await.is_err());
        assert_eq!(fs::read(f.root.join("a.org")).await.unwrap(), edited);
        assert!(
            !f.root
                .join(".sync/history/10/conflicts/a.org/a.resolved.org")
                .exists()
        );
        let request_comparison = choose_all(&comparison, crate::OrgMergeSide::Local);
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = events.clone();
        let workspace = crate::OrgWorkspace::new(vec![f.repo.clone()]).unwrap();
        let subscription = workspace.watch_notifications(move |event| {
            captured.lock().unwrap().push(event);
        });
        f.repo.resolve_conflict(&request_comparison).await.unwrap();
        assert_eq!(
            events
                .lock()
                .unwrap()
                .iter()
                .filter(|e| matches!(e, crate::NotificationUpdate::RepositoryChanged { .. }))
                .count(),
            1,
            "resolved提交后经通知监控转发更新"
        );
        assert!(events.lock().unwrap().iter().any(|e| *e
            == crate::NotificationUpdate::RepositoryChanged {
                repo_id: f.repo.id.clone()
            }));
        drop(subscription);
        assert_eq!(fs::read(f.root.join("a.org")).await.unwrap(), edited);
        assert_eq!(
            f.repo
                .history_file(&first, "a.org", true)
                .await
                .unwrap()
                .source_bytes(),
            edited
        );
        assert_eq!(
            f.repo
                .history_file(&first, "a.org", false)
                .await
                .unwrap()
                .source_bytes(),
            remote
        );
        assert_eq!(
            fs::read(f.root.join(".sync/history/10.json"))
                .await
                .unwrap(),
            original_json
        );
        assert_eq!(
            f.repo.pending_sync_conflicts().await.unwrap()[0].sync_id,
            second
        );
        assert_eq!(f.repo.pending_writes().await.unwrap().len(), 1);
        fs::write(f.root.join("a.org"), b"* TODO Changed later\n")
            .await
            .unwrap();
        assert_eq!(
            f.repo
                .history_file(&first, "a.org", true)
                .await
                .unwrap()
                .source_bytes(),
            edited
        );
        let detail = f.repo.history_detail(&first).await.unwrap();
        assert_eq!(detail.summary.resolved_conflicts, 1);
        assert_eq!(
            detail.files[0].backup.as_ref().unwrap().title.as_deref(),
            Some("Latest")
        );
        assert_eq!(
            detail.files[0].backup.as_ref().unwrap().path,
            "a.resolved.org"
        );
    }

    #[tokio::test]
    async fn comparison_rejects_external_edits_and_tampered_source_before_any_writes() {
        let mut f = Fixture::new().await;
        let id = f.conflict(1, "a.org", Some(b"* TODO Remote\n")).await;
        fs::write(f.root.join("a.org"), b"* TODO Local\n")
            .await
            .unwrap();
        let comparison = f
            .repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: id.clone(),
                path: "a.org".into(),
            })
            .await
            .unwrap();
        let request_comparison = choose_all(&comparison, crate::OrgMergeSide::Local);
        fs::write(f.root.join("a.org"), b"* TODO Newest\n")
            .await
            .unwrap();
        assert!(f.repo.resolve_conflict(&request_comparison).await.is_err());
        assert_eq!(
            fs::read(f.root.join("a.org")).await.unwrap(),
            b"* TODO Newest\n"
        );
        assert!(f.repo.pending_writes().await.unwrap().is_empty());
        let tampered = f
            .repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: id.clone(),
                path: "a.org".into(),
            })
            .await
            .unwrap();
        let mut request = choose_all(&tampered, crate::OrgMergeSide::Local);
        request.expected_remote_hash = "fake".into();
        assert!(f.repo.resolve_conflict(&request).await.is_err());
    }

    #[tokio::test]
    async fn identical_content_has_zero_choices_and_still_requires_explicit_save() {
        let mut f = Fixture::new().await;
        let bytes = b"* TODO Same\r\n";
        let id = f.conflict(1, "same.org", Some(bytes)).await;
        fs::write(f.root.join("same.org"), bytes).await.unwrap();
        let comparison = f
            .repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: id.clone(),
                path: "same.org".into(),
            })
            .await
            .unwrap();
        assert!(comparison.changes.is_empty());
        assert_eq!(f.repo.pending_sync_conflicts().await.unwrap().len(), 1);
        f.repo
            .resolve_conflict(&choose_all(&comparison, crate::OrgMergeSide::Remote))
            .await
            .unwrap();
        assert!(f.repo.pending_sync_conflicts().await.unwrap().is_empty());
        assert_eq!(
            f.repo
                .history_file(&id, "same.org", true)
                .await
                .unwrap()
                .source_bytes(),
            bytes
        );
    }

    #[tokio::test]
    async fn legacy_missing_backup_reports_error_and_preserves_pending_state() {
        let mut f = Fixture::new().await;
        let id = f.conflict(1, "a.org", None).await;
        fs::write(f.root.join("a.org"), b"* TODO Current is not history\n")
            .await
            .unwrap();
        assert!(
            f.repo
                .compare_conflict(&SyncConflictTarget {
                    sync_id: id.clone(),
                    path: "a.org".into()
                })
                .await
                .is_err()
        );
        assert!(f.repo.history_file(&id, "a.org", false).await.is_err());
        let detail = f.repo.history_detail(&id).await.unwrap();
        assert!(detail.files[0].backup.is_none());
        assert_eq!(detail.files[0].section.as_deref(), Some("conflict"));
        assert_eq!(f.repo.notifications().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn last_effect_sync_uses_latest_success_regardless_of_conflicts_or_backups() {
        let mut f = Fixture::new().await;
        assert!(f.repo.last_effect_sync().await.unwrap().is_none());
        let old = f.conflict(1, "a.org", Some(b"* TODO Old\n")).await;
        assert_eq!(f.repo.last_effect_sync().await.unwrap().unwrap().id, old);
        let latest = f.conflict(3, "a.org", None).await;
        assert_eq!(f.repo.last_effect_sync().await.unwrap().unwrap().id, latest);
        assert_eq!(f.repo.notifications().await.unwrap().len(), 1);
        let current = f.conflict(5, "a.org", Some(b"* TODO Same\n")).await;
        fs::write(f.root.join("a.org"), b"* TODO Same\n")
            .await
            .unwrap();
        let comparison = f
            .repo
            .compare_conflict(&SyncConflictTarget {
                sync_id: current.clone(),
                path: "a.org".into(),
            })
            .await
            .unwrap();
        f.repo
            .resolve_conflict(&choose_all(&comparison, crate::OrgMergeSide::Remote))
            .await
            .unwrap();
        let record = f.repo.last_effect_sync().await.unwrap().unwrap();
        assert_eq!(record.id, current);
        assert!(record.files[0].detail.resolved);
        assert!(f.repo.notifications().await.unwrap().is_empty());
        // 更新的失败和取消记录不应取代最近成功记录。
        for (time, result) in [
            (7, OrgRepoSyncResult::Failed),
            (9, OrgRepoSyncResult::Cancelled),
        ] {
            let mut record = Record::new(format!("later-{time}"), time)
                .unwrap()
                .with_kind("webdav");
            record.finish(result, time + 1).unwrap();
            fs::write(
                f.root.join(format!(".sync/history/{time}.json")),
                serde_json::to_vec(&record).unwrap(),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            f.repo.last_effect_sync().await.unwrap().unwrap().id,
            current
        );
        let mut success = Record::new("clean".into(), 11).unwrap().with_kind("webdav");
        success.finish(OrgRepoSyncResult::Succeeded, 12).unwrap();
        fs::write(
            f.root.join(".sync/history/11.json"),
            serde_json::to_vec(&success).unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(
            f.repo.last_effect_sync().await.unwrap().unwrap().id,
            "clean"
        );
        assert!(f.repo.notifications().await.unwrap().is_empty());
        assert!(f.repo.pending_sync_conflicts().await.unwrap().is_empty());
        assert_eq!(
            f.repo
                .history_detail(&old)
                .await
                .unwrap()
                .summary
                .pending_conflicts,
            1
        );
    }

    #[tokio::test]
    async fn current_sync_with_one_backed_conflict_keeps_unbacked_paths_pending() {
        let f = Fixture::new().await;
        let id = f.conflict(1, "a.org", Some(b"* TODO A\n")).await;
        let path = f.root.join(".sync/history/1.json");
        let mut record: Record = serde_json::from_slice(&fs::read(&path).await.unwrap()).unwrap();
        record.files.push(
            OrgRepoSyncFileRecord::new(
                "missing.org".into(),
                OrgRepoSyncFileAction::Conflicted,
                OrgRepoSyncFileState::Conflict,
            )
            .unwrap(),
        );
        fs::write(path, serde_json::to_vec(&record).unwrap())
            .await
            .unwrap();
        assert_eq!(f.repo.last_effect_sync().await.unwrap().unwrap().id, id);
        let notifications = f.repo.notifications().await.unwrap();
        assert_eq!(notifications.len(), 1);
        let crate::CoreNotification::SyncConflict(event) = &notifications[0] else {
            panic!("应为冲突通知")
        };
        assert_eq!(event.paths, vec!["a.org", "missing.org"]);
        assert_eq!(
            f.repo
                .history_detail(&id)
                .await
                .unwrap()
                .summary
                .pending_conflicts,
            2
        );
    }

    #[tokio::test]
    async fn backup_names_are_isolated_and_resolved_does_not_escape_or_follow_symlinks() {
        let f = Fixture::new().await;
        let a = f.conflict(1, "A.org", Some(b"* TODO A\n")).await;
        // 同次记录的两个原路径可有相同备份文件名，目录仍按原路径隔离。
        save_archive(&f.repo, 1, "A.resolved.org", b"* TODO Real name\n")
            .await
            .unwrap();
        assert_eq!(
            f.repo
                .history_file(&a, "A.org", false)
                .await
                .unwrap()
                .source_bytes(),
            b"* TODO A\n"
        );
        assert!(f.repo.history_file(&a, "../A.org", false).await.is_err());
        let target = f
            .root
            .join(".sync/history/1/conflicts/A.org/A.resolved.org");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(f.root.join("A.org"), &target).unwrap();
            assert!(f.repo.pending_sync_conflicts().await.is_err());
        }
    }
}
