//! 下载仓库根目录的任务扫描配置；规则不参与 Org 任务解析或上传。
use std::path::Path;

use tokio::fs;

use super::*;
use crate::TaskScanRules;
use crate::model::TASK_SCAN_RULES_PATH;

impl WebDavSyncPolicy {
    pub(super) async fn sync_task_scan_rules(
        &self,
        repo: &mut OrgRepo,
        remote: Option<WebDavRemoteFile>,
        baseline: Option<&OrgRepoSyncFileRecord<WebDavSyncFileDetail>>,
        started_at: TimestampMs,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncFileRecord<WebDavSyncFileDetail>, CoreError> {
        let target = Path::new(&repo.root_directory).join(TASK_SCAN_RULES_PATH);
        let original = read_rules(&target).await?;
        let (bytes, version) = match remote {
            Some(remote) => {
                let bytes = runtime::get_remote(
                    &self.client,
                    &self.username,
                    &self.password,
                    &self.endpoint,
                    TASK_SCAN_RULES_PATH,
                    remote.version.etag.as_deref(),
                    progress,
                    self.monitor.as_ref(),
                )
                .await
                .map_err(|error| CoreError::Store(error.summary().message))?;
                (Some(bytes), remote.version)
            }
            None => (None, RemoteFileVersion::new(None, None, None)?),
        };
        let source = bytes
            .as_deref()
            .map(std::str::from_utf8)
            .transpose()
            .map_err(|_| CoreError::Store("远端 .orgzlyignore 必须是 UTF-8 编码".into()))?;
        let rules = TaskScanRules::parse(source.unwrap_or_default())?;
        let local_version = original.as_deref().map(LocalFileVersion::from_bytes);
        if original != bytes
            && local_version.is_some()
            && baseline.and_then(|file| file.local_version.as_ref()) != local_version.as_ref()
        {
            return Err(CoreError::Store(
                "本地 .orgzlyignore 与远端规则不一致，请先统一规则后重新同步".into(),
            ));
        }
        let action = if original == bytes {
            OrgRepoSyncFileAction::Unchanged
        } else if let Some(bytes) = &bytes {
            let _ = (bytes, started_at); // 整次同步成功后统一提交规则文件。
            OrgRepoSyncFileAction::Downloaded
        } else {
            if read_rules(&target).await? != original {
                return Err(CoreError::Store(
                    "本地 .orgzlyignore 已改变，请重新同步".into(),
                ));
            }

            OrgRepoSyncFileAction::Deleted
        };
        repo.task_scan_rules = rules;
        Ok(OrgRepoSyncFileRecord::new(
            TASK_SCAN_RULES_PATH.into(),
            action,
            OrgRepoSyncFileState::Synchronized,
        )?
        .with_local_version(bytes.as_deref().map(LocalFileVersion::from_bytes))
        .with_detail(WebDavSyncFileDetail {
            synced_source: source.map(str::to_owned),
            ..version.into()
        }))
    }
}

async fn read_rules(target: &Path) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::symlink_metadata(target).await {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(store_error(error)),
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
            Err(CoreError::Store(".orgzlyignore 必须是普通文件".into()))
        }
        Ok(_) => fs::read(target).await.map(Some).map_err(store_error),
    }
}

fn store_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法更新 .orgzlyignore: {error}"))
}
