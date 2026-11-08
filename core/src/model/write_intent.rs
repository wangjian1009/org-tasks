use super::{LocalFileVersion, OrgRepo};
use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;

/// 待上传文件的写入意图；任务正文只存在于原始 org 文件中。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OrgRepoWriteIntent {
    pub relative_path: String,
    pub content_hash: String,
}

impl LocalFileVersion {
    pub fn from_bytes(source: &[u8]) -> Self {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in source {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Self {
            content_hash: format!("{hash:016x}"),
        }
    }
}

impl OrgRepo {
    pub async fn pending_writes(&self) -> Result<Vec<OrgRepoWriteIntent>, CoreError> {
        Ok(self
            .write_intent_files()
            .await?
            .into_iter()
            .map(|(_, intent)| intent)
            .collect())
    }

    /// 仅在成功同步的版本仍与本地文件一致时确认上传，避免清除较新的保存。
    pub async fn acknowledge_write(
        &self,
        path: &str,
        version: &LocalFileVersion,
    ) -> Result<(), CoreError> {
        validate_task_path(path)?;
        let Some(file) = self.files.iter().find(|file| file.path == path) else {
            return Ok(());
        };
        if LocalFileVersion::from_bytes(file.source_bytes()) != *version {
            return Ok(());
        }
        let current = read_optional(&Path::new(&self.root_directory).join(path)).await?;
        if current
            .as_deref()
            .map(LocalFileVersion::from_bytes)
            .as_ref()
            != Some(version)
        {
            return Ok(());
        }
        for (intent_path, intent) in self.write_intent_files().await? {
            if intent.relative_path == path {
                fs::remove_file(intent_path).await.map_err(store_error)?;
            }
        }
        Ok(())
    }

    pub(crate) async fn acknowledge_deleted_write(&self, path: &str) -> Result<(), CoreError> {
        validate_task_path(path)?;
        if read_optional(&Path::new(&self.root_directory).join(path))
            .await?
            .is_some()
        {
            return Ok(());
        }
        for (intent_path, intent) in self.write_intent_files().await? {
            if intent.relative_path == path {
                fs::remove_file(intent_path).await.map_err(store_error)?;
            }
        }
        Ok(())
    }

    async fn write_intent_files(&self) -> Result<Vec<(PathBuf, OrgRepoWriteIntent)>, CoreError> {
        let directory = Path::new(&self.root_directory).join(".sync/outbox");
        let mut entries = match fs::read_dir(directory).await {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(store_error(error)),
        };
        let mut intents = Vec::new();
        while let Some(entry) = entries.next_entry().await.map_err(store_error)? {
            if !entry.file_type().await.map_err(store_error)?.is_file()
                || entry.path().extension().and_then(|value| value.to_str()) != Some("json")
            {
                continue;
            }
            let intent: OrgRepoWriteIntent =
                serde_json::from_slice(&fs::read(entry.path()).await.map_err(store_error)?)
                    .map_err(|_| CoreError::Store("outbox 写入意图 JSON 无效".into()))?;
            validate_task_path(&intent.relative_path)
                .map_err(|_| CoreError::Store("outbox 路径无效".into()))?;
            if intent.content_hash.len() != 16
                || !intent
                    .content_hash
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(CoreError::Store("outbox 内容哈希无效".into()));
            }
            intents.push((entry.path(), intent));
        }
        Ok(intents)
    }
}
fn validate_task_path(path: &str) -> Result<(), CoreError> {
    super::validate_relative_path(path)?;
    if path.split('/').next() == Some(".sync") || !path.ends_with(".org") {
        return Err(CoreError::InvalidInput(
            "任务目标必须是控制目录外的相对 .org 路径",
        ));
    }
    Ok(())
}

pub(super) async fn task_target(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
    let mut target = root.to_path_buf();
    let parts = path.split('/').collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        target.push(part);
        match fs::symlink_metadata(&target).await {
            Ok(metadata)
                if metadata.file_type().is_symlink()
                    || (index + 1 < parts.len() && !metadata.is_dir())
                    || (index + 1 == parts.len() && !metadata.is_file()) =>
            {
                return Err(CoreError::InvalidInput(
                    "任务目标不能包含符号链接或非普通文件",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if index + 1 < parts.len() {
                    fs::create_dir(&target).await.map_err(store_error)?;
                }
            }
            Err(error) => return Err(store_error(error)),
        }
    }
    Ok(target)
}

pub(super) async fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::read(path).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(store_error(error)),
    }
}

pub(super) async fn write_new(path: &Path, content: &[u8]) -> Result<(), CoreError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .await
        .map_err(store_error)?;
    let result = async {
        file.write_all(content).await.map_err(store_error)?;
        file.sync_all().await.map_err(store_error)
    }
    .await;
    if result.is_err() {
        let _ = fs::remove_file(path).await;
    }
    result
}

fn store_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法保存任务或维护 outbox: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::webdav::WebDavSyncPolicy;
    async fn repo() -> OrgRepo {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-create-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        repo
    }

    #[tokio::test]
    async fn corrupt_outbox_fails_load_and_temporary_intents_are_ignored() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        fs::create_dir(root.join(".sync/outbox")).await.unwrap();
        fs::write(root.join(".sync/outbox/interrupted.tmp"), b"{")
            .await
            .unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        fs::write(root.join(".sync/outbox/invalid.json"), b"{")
            .await
            .unwrap();
        assert!(repo.load::<WebDavSyncPolicy>().await.is_err());
        fs::remove_dir_all(root).await.unwrap();
    }

    struct ConfirmingPolicy {
        success: bool,
    }

    impl super::super::SyncPolicy for ConfirmingPolicy {
        const KIND: &'static str = "webdav";
        type ContextDetail = serde_json::Value;
        type FileDetail = serde_json::Value;

        async fn synchronize(
            &self,
            context: &mut super::super::SyncContext<'_>,
            _cancellation: &super::super::SyncCancellation,
            _progress: &super::super::SyncProgressReporter,
        ) -> Result<super::super::OrgRepoSyncRecord, CoreError> {
            use super::super::{
                OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState,
                OrgRepoSyncRecord, OrgRepoSyncResult,
            };
            let mut record =
                OrgRepoSyncRecord::new(format!("mock-{}", context.started_at), context.started_at)?;
            record.append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Uploaded,
                    if self.success {
                        OrgRepoSyncFileState::Synchronized
                    } else {
                        OrgRepoSyncFileState::Failed
                    },
                )?
                .with_local_version(Some(LocalFileVersion::from_bytes(
                    context.repo.files[0].source_bytes(),
                ))),
            )?;
            record.finish(
                if self.success {
                    OrgRepoSyncResult::Succeeded
                } else {
                    OrgRepoSyncResult::Failed
                },
                context.started_at,
            )?;
            Ok(record)
        }
    }

    #[tokio::test]
    async fn intent_is_consumed_only_after_success_and_history_commit() {
        use super::super::{SyncCancellation, SyncProgressReporter};
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        super::super::test_support::append_fixture(&mut repo, "inbox.org", "Offline")
            .await
            .unwrap();
        let cancellation = SyncCancellation::default();
        let progress = SyncProgressReporter::default();
        repo.sync(
            &ConfirmingPolicy { success: false },
            1,
            &cancellation,
            &progress,
        )
        .await
        .unwrap();
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        // 即使上传成功，历史提交失败也不能消费意图。
        assert!(
            repo.sync(
                &ConfirmingPolicy { success: true },
                1,
                &cancellation,
                &progress
            )
            .await
            .is_err()
        );
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        repo.sync(
            &ConfirmingPolicy { success: true },
            2,
            &cancellation,
            &progress,
        )
        .await
        .unwrap();
        assert!(root.join(".sync/history/2.json").exists());
        assert!(repo.pending_writes().await.unwrap().is_empty());
        fs::remove_dir_all(root).await.unwrap();
    }
}
