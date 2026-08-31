//! HarmonyOS 宿主的仓库同步记录持久化适配器。

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};

use org_tasks_core::{CoreError, OrgRepoId, OrgRepoSyncRecord, OrgRepoSyncRecordStore};
use serde::{Deserialize, Serialize};

const STATE_FILE: &str = "org-repo-sync-records-v1.json";
const MAX_RECORDS: usize = 100_000;

#[derive(Clone, Default, Serialize, Deserialize)]
struct PersistedState {
    records: BTreeMap<String, OrgRepoSyncRecord>,
}

/// 使用 HarmonyOS 应用私有目录保存已完成仓库同步记录。
pub struct FileOrgRepoSyncRecordStore {
    state_path: PathBuf,
    state: PersistedState,
}

impl FileOrgRepoSyncRecordStore {
    pub fn open(data_dir: impl AsRef<Path>) -> Result<Self, CoreError> {
        let data_dir = data_dir.as_ref();
        if data_dir.as_os_str().is_empty() {
            return Err(CoreError::InvalidInput("Harmony 数据目录不能为空"));
        }
        fs::create_dir_all(data_dir)
            .map_err(|error| store_error(format!("无法创建数据目录: {error}")))?;
        let state_path = data_dir.join(STATE_FILE);
        let state = if state_path.exists() {
            let bytes = fs::read(&state_path)
                .map_err(|error| store_error(format!("无法读取同步记录: {error}")))?;
            serde_json::from_slice(&bytes)
                .map_err(|error| CoreError::Store(format!("同步记录格式无效: {error}")))?
        } else {
            PersistedState::default()
        };
        if state.records.len() > MAX_RECORDS {
            return Err(CoreError::InvalidState("同步记录数量超过允许上限"));
        }
        Ok(Self { state_path, state })
    }

    fn persist(&self, state: &PersistedState) -> Result<(), CoreError> {
        let bytes = serde_json::to_vec(state)
            .map_err(|error| CoreError::Store(format!("无法编码同步记录: {error}")))?;
        let temporary_path = self.state_path.with_extension("json.tmp");
        let mut file = File::create(&temporary_path)
            .map_err(|error| store_error(format!("无法创建同步记录临时文件: {error}")))?;
        file.write_all(&bytes)
            .map_err(|error| store_error(format!("无法写入同步记录临时文件: {error}")))?;
        file.sync_all()
            .map_err(|error| store_error(format!("无法同步同步记录临时文件: {error}")))?;
        drop(file);
        fs::rename(&temporary_path, &self.state_path)
            .map_err(|error| store_error(format!("无法提交同步记录: {error}")))
    }
}

impl OrgRepoSyncRecordStore for FileOrgRepoSyncRecordStore {
    fn append(
        &mut self,
        record: OrgRepoSyncRecord,
    ) -> impl Future<Output = Result<(), CoreError>> + Send {
        let result = (|| {
            if record.finished_at.is_none() || record.result.is_none() {
                return Err(CoreError::InvalidState("持久化的同步记录必须已经完成"));
            }
            if self.state.records.len() >= MAX_RECORDS
                && !self.state.records.contains_key(&record.id)
            {
                return Err(CoreError::InvalidState("同步记录数量超过允许上限"));
            }
            if self.state.records.contains_key(&record.id) {
                return Err(CoreError::InvalidState("同步记录 ID 已存在"));
            }
            let mut next = self.state.clone();
            next.records.insert(record.id.clone(), record);
            self.persist(&next)?;
            self.state = next;
            Ok(())
        })();
        async move { result }
    }

    fn list(
        &self,
        repo_id: &OrgRepoId,
        limit: usize,
    ) -> impl Future<Output = Result<Vec<OrgRepoSyncRecord>, CoreError>> + Send {
        let mut records = self
            .state
            .records
            .values()
            .filter(|record| &record.repo_id == repo_id)
            .cloned()
            .collect::<Vec<_>>();
        records.sort_by(|left, right| right.started_at.cmp(&left.started_at));
        records.truncate(limit);
        async move { Ok(records) }
    }
}

fn store_error(message: String) -> CoreError {
    CoreError::Store(message)
}
