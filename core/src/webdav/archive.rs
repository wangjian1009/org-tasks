//! 当次同步文件备份、只读历史文件与本地冲突解决；不访问远端。
use super::*;
use crate::{OrgFileMetadata, OrgMergeChange, OrgMergeChoice, OrgRepoWriteIntent};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::fs;

type Record = OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebDavFileArchive {
    pub content_hash: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncConflictComparison {
    pub repo_id: String,
    pub sync_id: String,
    pub path: String,
    pub local_hash: String,
    pub remote_hash: String,
    pub local_missing: bool,
    pub changes: Vec<WebDavTaskMergeChange>,
    pub unchanged_count: usize,
}

pub(crate) fn archive_name(path: &str, resolved: bool) -> Result<String, CoreError> {
    validate_path(path)?;
    let filename = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or(CoreError::InvalidInput("备份文件名无效"))?;
    Ok(if resolved {
        format!(
            "{}.resolved.org",
            filename
                .strip_suffix(".org")
                .ok_or(CoreError::InvalidInput("解决结果必须是 Org 文件"))?
        )
    } else {
        filename.into()
    })
}

// 所有路径组件逐一校验，备份读取也不允许跟随符号链接。
async fn archive_path(
    repo: &OrgRepo,
    time: TimestampMs,
    path: &str,
    resolved: bool,
    create: bool,
) -> Result<PathBuf, CoreError> {
    let name = archive_name(path, resolved)?;
    let mut target = fs::canonicalize(&repo.root_directory)
        .await
        .map_err(archive_io)?;
    for part in format!(".sync/history/{time}/files/{path}").split('/') {
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
    target.push(name);
    match fs::symlink_metadata(&target).await {
        Ok(m) if m.file_type().is_symlink() || !m.is_file() => {
            return Err(CoreError::Store("日志备份不是普通文件".into()));
        }
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(archive_io(e)),
    }
    Ok(target)
}

async fn optional_bytes(path: &Path) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::read(path).await {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(archive_io(e)),
    }
}

pub(crate) async fn save_archive(
    repo: &OrgRepo,
    time: TimestampMs,
    path: &str,
    bytes: &[u8],
) -> Result<WebDavFileArchive, CoreError> {
    let target = archive_path(repo, time, path, false, true).await?;
    crate::model::write_intent::write_new(&target, bytes).await?;
    Ok(WebDavFileArchive {
        content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
    })
}

pub(crate) async fn discard_upload_archive(
    repo: &OrgRepo,
    time: TimestampMs,
    path: &str,
    expected: &[u8],
) -> Result<(), CoreError> {
    let target = archive_path(repo, time, path, false, false).await?;
    if optional_bytes(&target).await?.as_deref() != Some(expected) {
        return Err(CoreError::InvalidState("本次上传备份已改变"));
    }
    fs::remove_file(target).await.map_err(archive_io)
}

impl OrgRepo {
    pub async fn webdav_history(&self) -> Result<Vec<Record>, CoreError> {
        let mut history = self.sync_history::<WebDavSyncPolicy>().await?;
        for record in &mut history {
            for file in &mut record.files {
                if super::history::is_conflict(file) {
                    let target =
                        archive_path(self, record.started_at, &file.relative_path, true, false)
                            .await?;
                    file.detail.resolved = fs::try_exists(target).await.map_err(archive_io)?;
                }
            }
        }
        Ok(history)
    }

    /// 最近一次成功同步；无冲突、已解决和缺少备份均不影响该次记录的定位。
    pub async fn last_effect_sync(&self) -> Result<Option<Record>, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        let history = self.sync_history::<WebDavSyncPolicy>().await?;
        let Some(mut record) = history
            .into_iter()
            .rev()
            .find(|r| r.result == Some(OrgRepoSyncResult::Succeeded))
        else {
            return Ok(None);
        };
        for file in &mut record.files {
            if !super::history::is_conflict(file) {
                continue;
            }
            let resolved =
                archive_path(self, record.started_at, &file.relative_path, true, false).await?;
            file.detail.resolved = fs::try_exists(resolved).await.map_err(archive_io)?;
        }
        Ok(Some(record))
    }

    /// 当前冲突仅来自最近成功同步，更早遗留冲突不参与通知或同步判断。
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
                // 旧日志没有备份时仍提供状态；只有点击读取正文时才提示缺失。
                if let Some(bytes) = self
                    .archive_bytes(record, file, file.detail.resolved)
                    .await?
                {
                    let name = archive_name(&file.relative_path, file.detail.resolved)?;
                    let mut snapshot = self.parse_file(name, bytes)?;
                    let target = archive_path(
                        self,
                        record.started_at,
                        &file.relative_path,
                        file.detail.resolved,
                        false,
                    )
                    .await?;
                    snapshot.modified_at = fs::metadata(target)
                        .await
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_millis() as i64);
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
        let Some(archive) = &file.detail.archive else {
            return Ok(None);
        };
        let target = archive_path(
            self,
            record.started_at,
            &file.relative_path,
            resolved,
            false,
        )
        .await?;
        let bytes = optional_bytes(&target).await?;
        if !resolved && let Some(bytes) = &bytes {
            if LocalFileVersion::from_bytes(bytes).content_hash != archive.content_hash {
                return Err(CoreError::Store("历史备份内容与记录版本不一致".into()));
            }
        }
        Ok(bytes)
    }

    pub async fn history_file(
        &self,
        sync_id: &str,
        path: &str,
        resolved: bool,
    ) -> Result<OrgFile, CoreError> {
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

    pub async fn compare_sync_conflict(
        &mut self,
        sync_id: &str,
        path: &str,
    ) -> Result<SyncConflictComparison, CoreError> {
        self.load::<WebDavSyncPolicy>().await?;
        let history = self.webdav_history().await?;
        let record = history
            .iter()
            .find(|r| r.id == sync_id)
            .ok_or(CoreError::InvalidInput("同步记录不存在"))?;
        let file = record
            .files
            .iter()
            .find(|f| f.relative_path == path && super::history::is_conflict(f))
            .ok_or(CoreError::InvalidInput("该文件不是冲突记录"))?;
        if file.detail.resolved {
            return Err(CoreError::InvalidState("该文件已解决，请刷新后查看结果"));
        }
        let remote = self.history_file(sync_id, path, false).await?;
        let local = self.file(path)?;
        let before = history
            .iter()
            .filter(|r| r.started_at < record.started_at)
            .cloned()
            .collect::<Vec<_>>();
        let baseline =
            latest_file_record(&before, path).and_then(|f| f.detail.task_versions.as_deref());
        let plan = crate::compare_org_tasks(&local, &remote, baseline);
        let mut unchanged_count = 0;
        let mut changes = Vec::new();
        for item in &plan.items {
            if item.change == OrgMergeChange::Unchanged {
                if item.key != "preamble" && item.remote.is_some() {
                    unchanged_count += 1;
                }
                continue;
            }
            changes.push(WebDavTaskMergeChange {
                id: item.key.clone(),
                path: path.into(),
                kind: match (&item.local, &item.remote) {
                    (Some(_), Some(_)) => OrgMergeChange::Modified,
                    (Some(_), None) => OrgMergeChange::Added,
                    _ => OrgMergeChange::Deleted,
                },
                preamble: item.key == "preamble",
                local_change: item.local_change,
                remote_change: item.remote_change,
                local: item.local.clone(),
                remote: item.remote.clone(),
                resolution: None,
            });
        }
        Ok(SyncConflictComparison {
            repo_id: self.id.clone(),
            sync_id: sync_id.into(),
            path: path.into(),
            local_hash: plan.local_hash,
            remote_hash: plan.remote_hash,
            local_missing: !self.files.iter().any(|f| f.path == path),
            changes,
            unchanged_count,
        })
    }

    pub async fn resolve_sync_conflict(
        &mut self,
        comparison: &SyncConflictComparison,
    ) -> Result<(), CoreError> {
        let fresh = self
            .compare_sync_conflict(&comparison.sync_id, &comparison.path)
            .await?;
        let mut immutable = comparison.clone();
        for c in &mut immutable.changes {
            c.resolution = None;
        }
        if serde_json::to_value(&immutable).unwrap() != serde_json::to_value(&fresh).unwrap() {
            return Err(CoreError::InvalidState(
                "本地文件或比较内容已改变，请重新比较",
            ));
        }
        let choices = comparison
            .changes
            .iter()
            .map(|c| {
                Ok(OrgMergeChoice {
                    key: c.id.clone(),
                    side: c
                        .resolution
                        .ok_or(CoreError::InvalidInput("请完成全部选择后保存"))?,
                })
            })
            .collect::<Result<Vec<_>, CoreError>>()?;
        let local = self.file(&comparison.path)?;
        let remote = self
            .history_file(&comparison.sync_id, &comparison.path, false)
            .await?;
        let history = self.webdav_history().await?;
        let record = history.iter().find(|r| r.id == comparison.sync_id).unwrap();
        let before = history
            .iter()
            .filter(|r| r.started_at < record.started_at)
            .cloned()
            .collect::<Vec<_>>();
        let baseline = latest_file_record(&before, &comparison.path)
            .and_then(|f| f.detail.task_versions.as_deref());
        let plan = crate::compare_org_tasks(&local, &remote, baseline);
        let result = crate::merge_org_tasks(&plan, &choices)?;
        let target = archive_path(self, record.started_at, &comparison.path, true, true).await?;
        if fs::try_exists(&target).await.map_err(archive_io)? {
            return Err(CoreError::InvalidState("解决结果已经存在"));
        }
        // 逐项决定均完成后才写回本地；resolved 最后提交。
        self.replace_conflict_file(
            &comparison.path,
            (!comparison.local_missing).then_some(comparison.local_hash.as_str()),
            Some(result.clone()),
        )
        .await?;
        self.queue_sync_upload(&comparison.path, &result).await?;
        let actual =
            crate::model::write_intent::task_target(Path::new(&self.root_directory), &comparison.path)
                .await?;
        if fs::read(&actual).await.map_err(archive_io)? != result {
            return Err(CoreError::InvalidState("本地文件再次改变，请重新比较"));
        }
        let temporary = target.with_file_name(format!(
            ".{}.tmp",
            crate::model::service::generate_repo_id()?
        ));
        crate::model::write_intent::write_new(&temporary, &result).await?;
        if fs::read(&actual).await.map_err(archive_io)? != result {
            let _ = fs::remove_file(&temporary).await;
            return Err(CoreError::InvalidState("本地文件再次改变，请重新比较"));
        }
        // HarmonyOS 应用目录不允许硬链接；同仓库调用由宿主串行化，结果最后原子提交。
        if fs::symlink_metadata(&target).await.is_ok() {
            let _ = fs::remove_file(&temporary).await;
            return Err(CoreError::InvalidState("解决结果已存在，请刷新"));
        }
        fs::rename(&temporary, &target).await.map_err(archive_io)?;
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

    pub(crate) async fn resolved_baseline(
        &self,
        history: &[Record],
        path: &str,
    ) -> Result<Option<OrgRepoSyncFileRecord<WebDavSyncFileDetail>>, CoreError> {
        for record in history.iter().rev() {
            if let Some(file) = record.files.iter().find(|f| f.relative_path == path) {
                if file.state == OrgRepoSyncFileState::Synchronized {
                    return Ok(Some(file.clone()));
                }
                if file.detail.resolved {
                    let result = self
                        .archive_bytes(record, file, true)
                        .await?
                        .ok_or(CoreError::InvalidState("解决结果丢失"))?;
                    let mut baseline = file.clone();
                    baseline.state = OrgRepoSyncFileState::Synchronized;
                    baseline.local_version = Some(LocalFileVersion::from_bytes(&result));
                    return Ok(Some(baseline));
                }
            }
        }
        Ok(None)
    }
}

fn snapshot_metadata(file: &OrgFile) -> OrgFileMetadata {
    use orgize::rowan::ast::AstNode;
    OrgFileMetadata {
        repo_id: file.repo_id.clone(),
        path: file.path.clone(),
        title: file.title(),
        title_parts: file.title_parts(),
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
        let mut comparison = f.repo.compare_sync_conflict(&first, "a.org").await.unwrap();
        assert!(comparison.changes.iter().any(|c| {
            c.local
                .as_ref()
                .is_some_and(|v| v.source.contains("Added after sync"))
        }));
        assert!(f.repo.resolve_sync_conflict(&comparison).await.is_err());
        assert_eq!(fs::read(f.root.join("a.org")).await.unwrap(), edited);
        assert!(
            !f.root
                .join(".sync/history/10/files/a.org/a.resolved.org")
                .exists()
        );
        for change in &mut comparison.changes {
            change.resolution = Some(WebDavMergeResolution::Local);
        }
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = events.clone();
        let workspace = crate::OrgWorkspace::new(vec![f.repo.clone()]).unwrap();
        let subscription = workspace.watch_notifications(move |event| {
            captured.lock().unwrap().push(event);
        });
        f.repo.resolve_sync_conflict(&comparison).await.unwrap();
        assert_eq!(
            events.lock().unwrap().len(),
            1,
            "resolved提交后经通知监控转发更新"
        );
        assert_eq!(events.lock().unwrap()[0].repo_id, f.repo.id);
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
        let mut comparison = f.repo.compare_sync_conflict(&id, "a.org").await.unwrap();
        for change in &mut comparison.changes {
            change.resolution = Some(WebDavMergeResolution::Local);
        }
        fs::write(f.root.join("a.org"), b"* TODO Newest\n")
            .await
            .unwrap();
        assert!(f.repo.resolve_sync_conflict(&comparison).await.is_err());
        assert_eq!(
            fs::read(f.root.join("a.org")).await.unwrap(),
            b"* TODO Newest\n"
        );
        assert!(f.repo.pending_writes().await.unwrap().is_empty());
        let mut tampered = f.repo.compare_sync_conflict(&id, "a.org").await.unwrap();
        tampered.remote_hash = "fake".into();
        assert!(f.repo.resolve_sync_conflict(&tampered).await.is_err());
    }

    #[tokio::test]
    async fn identical_content_has_zero_choices_and_still_requires_explicit_save() {
        let mut f = Fixture::new().await;
        let bytes = b"* TODO Same\r\n";
        let id = f.conflict(1, "same.org", Some(bytes)).await;
        fs::write(f.root.join("same.org"), bytes).await.unwrap();
        let comparison = f.repo.compare_sync_conflict(&id, "same.org").await.unwrap();
        assert!(comparison.changes.is_empty());
        assert_eq!(f.repo.pending_sync_conflicts().await.unwrap().len(), 1);
        f.repo.resolve_sync_conflict(&comparison).await.unwrap();
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
        assert!(f.repo.compare_sync_conflict(&id, "a.org").await.is_err());
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
            .compare_sync_conflict(&current, "a.org")
            .await
            .unwrap();
        f.repo.resolve_sync_conflict(&comparison).await.unwrap();
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
        let crate::CoreNotification::SyncConflict(event) = &notifications[0];
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
        let target = f.root.join(".sync/history/1/files/A.org/A.resolved.org");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(f.root.join("A.org"), &target).unwrap();
            assert!(f.repo.pending_sync_conflicts().await.is_err());
        }
    }
}
