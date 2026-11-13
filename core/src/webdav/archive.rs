//! 不可变历史与删除备份的只读访问；不访问远端。
use super::*;
use crate::OrgFileMetadata;
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

impl OrgRepo {
    pub async fn webdav_history(&self) -> Result<Vec<Record>, CoreError> {
        let _guard = crate::model::access::enter(Path::new(&self.root_directory), &self.id).await?;
        self.sync_history::<WebDavSyncPolicy>().await
    }

    pub async fn last_effect_sync(&self) -> Result<Option<Record>, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        let _guard = crate::model::access::enter(Path::new(&self.root_directory), &self.id).await?;
        let history = self.sync_history::<WebDavSyncPolicy>().await?;
        let Some(record) = history
            .into_iter()
            .rev()
            .find(|r| r.result == Some(OrgRepoSyncResult::Succeeded))
        else {
            return Ok(None);
        };
        Ok(Some(record))
    }

    pub async fn pending_sync_conflicts(&self) -> Result<Vec<WebDavConflictSync>, CoreError> {
        Ok(self
            .load_files(&[])
            .await?
            .iter()
            .filter(|file| file.has_conflict())
            .map(|file| WebDavConflictSync {
                sync_id: String::new(),
                paths: vec![file.path.clone()],
            })
            .collect())
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
                WebDavSyncFileOutcome::Conflict => Some("conflict".into()),
                WebDavSyncFileOutcome::Uploaded | WebDavSyncFileOutcome::Created => {
                    Some("upload".into())
                }
                WebDavSyncFileOutcome::Downloaded | WebDavSyncFileOutcome::Deleted => {
                    Some("download".into())
                }
                WebDavSyncFileOutcome::Updated => Some("download".into()),
                WebDavSyncFileOutcome::Merged => Some("merge".into()),
                WebDavSyncFileOutcome::Unchanged => Some("unchanged".into()),
                _ => None,
            };
            if item.outcome == WebDavSyncFileOutcome::Deleted
                && file.detail.deleted_archive.is_some()
            {
                if let Some(bytes) = self.archive_bytes(record, file, false).await? {
                    let mut snapshot =
                        self.parse_file(archive_name(&file.relative_path, false)?, bytes)?;
                    snapshot.modified_at = record.finished_at;
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
        if !resolved {
            if let Some(archive) = &file.detail.deleted_archive {
                let directory = safe_directory(
                    self,
                    &format!(
                        ".sync/history/{}/deleted/{}",
                        record.started_at, file.relative_path
                    ),
                    false,
                )
                .await?;
                let path =
                    checked_file(directory.join(archive_name(&file.relative_path, false)?)).await?;
                let bytes = optional_bytes(&path)
                    .await?
                    .ok_or(CoreError::InvalidState("删除备份缺失"))?;
                if LocalFileVersion::from_bytes(&bytes).content_hash != archive.content_hash {
                    return Err(CoreError::Store("删除备份内容与记录版本不一致".into()));
                }
                return Ok(Some(bytes));
            }
        }
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
        let bytes =
            self.archive_bytes(record, file, resolved)
                .await?
                .ok_or(CoreError::InvalidState(
                    "该日志未保存文件备份，无法打开历史内容",
                ))?;
        self.parse_file(archive_name(path, resolved)?, bytes)
    }
}

fn snapshot_metadata(file: &OrgFile) -> OrgFileMetadata {
    file.metadata(false)
}
fn archive_io(e: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法读写同步日志备份：{e}"))
}
