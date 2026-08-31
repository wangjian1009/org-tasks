//! HTTP 宿主的 CSV 仓库同步记录存储。

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::future::Future;
use std::path::{Path, PathBuf};

use csv::{ReaderBuilder, Writer};
use org_tasks_core::{CoreError, OrgRepoId, OrgRepoSyncRecord, OrgRepoSyncRecordStore};

const RECORDS_FILE: &str = "sync_records.csv";
const CURRENT_FILE: &str = "current.csv";
const MAX_RECORDS: usize = 100_000;

#[derive(Clone, Default)]
struct CsvState {
    records: BTreeMap<OrgRepoId, BTreeMap<String, OrgRepoSyncRecord>>,
}

/// 以 generation CSV 快照保存已完成的仓库同步记录。
pub struct CsvOrgRepoSyncRecordStore {
    root: PathBuf,
    generation: u64,
    state: CsvState,
}

impl CsvOrgRepoSyncRecordStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, CoreError> {
        let root = root.as_ref().to_path_buf();
        if root.as_os_str().is_empty() {
            return Err(CoreError::InvalidInput("CSV 数据目录不能为空"));
        }
        fs::create_dir_all(root.join("snapshots"))
            .map_err(|error| store_error(format!("无法创建 CSV 数据目录: {error}")))?;
        let generation = read_generation(&root)?;
        let state = match generation {
            Some(generation) => read_snapshot(&root, generation)?,
            None => CsvState::default(),
        };
        Ok(Self {
            root,
            generation: generation.unwrap_or(0),
            state,
        })
    }

    pub fn validate(root: impl AsRef<Path>) -> Result<(), CoreError> {
        let root = root.as_ref();
        if root.as_os_str().is_empty() || !root.is_dir() {
            return Err(CoreError::InvalidInput("CSV 数据目录不存在或不是目录"));
        }
        if let Some(generation) = read_generation(root)? {
            read_snapshot(root, generation)?;
        }
        Ok(())
    }

    fn persist(&mut self, state: CsvState) -> Result<(), CoreError> {
        let generation = self.next_generation()?;
        let snapshot = snapshot_dir(&self.root, generation);
        fs::create_dir_all(&snapshot)
            .map_err(|error| store_error(format!("无法创建 CSV 快照目录: {error}")))?;
        write_records(&snapshot.join(RECORDS_FILE), &state.records)?;
        write_generation(&self.root, generation)?;
        self.generation = generation;
        self.state = state;
        Ok(())
    }

    fn next_generation(&self) -> Result<u64, CoreError> {
        let mut generation = self
            .generation
            .checked_add(1)
            .ok_or(CoreError::InvalidState("CSV 快照版本已耗尽"))?;
        while snapshot_dir(&self.root, generation).exists() {
            generation = generation
                .checked_add(1)
                .ok_or(CoreError::InvalidState("CSV 快照版本已耗尽"))?;
        }
        Ok(generation)
    }
}

impl OrgRepoSyncRecordStore for CsvOrgRepoSyncRecordStore {
    fn append(
        &mut self,
        repo_id: &OrgRepoId,
        record: OrgRepoSyncRecord,
    ) -> impl Future<Output = Result<(), CoreError>> + Send {
        let result = (|| {
            if record.finished_at.is_none() || record.result.is_none() {
                return Err(CoreError::InvalidState("持久化的同步记录必须已经完成"));
            }
            let records = self.state.records.get(repo_id);
            if records.is_some_and(|records| records.contains_key(&record.id)) {
                return Err(CoreError::InvalidState("同步记录 ID 已存在"));
            }
            if self
                .state
                .records
                .values()
                .map(BTreeMap::len)
                .sum::<usize>()
                >= MAX_RECORDS
            {
                return Err(CoreError::InvalidState("同步记录数量超过允许上限"));
            }
            let mut next = self.state.clone();
            next.records
                .entry(repo_id.clone())
                .or_default()
                .insert(record.id.clone(), record);
            self.persist(next)
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
            .get(repo_id)
            .into_iter()
            .flat_map(|records| records.values())
            .cloned()
            .collect::<Vec<_>>();
        records.sort_by(|left, right| right.started_at.cmp(&left.started_at));
        records.truncate(limit);
        async move { Ok(records) }
    }
}

fn snapshot_dir(root: &Path, generation: u64) -> PathBuf {
    root.join("snapshots").join(format!("{generation:020}"))
}

fn read_generation(root: &Path) -> Result<Option<u64>, CoreError> {
    let path = root.join(CURRENT_FILE);
    if !path.exists() {
        return Ok(None);
    }
    let mut reader = ReaderBuilder::new()
        .has_headers(true)
        .from_path(&path)
        .map_err(|error| store_error(format!("无法读取 CSV manifest: {error}")))?;
    let mut records = reader.records();
    let record = records
        .next()
        .ok_or(CoreError::InvalidState("CSV manifest 缺少版本"))?
        .map_err(|error| store_error(format!("CSV manifest 格式无效: {error}")))?;
    if records.next().is_some() {
        return Err(CoreError::InvalidState("CSV manifest 只能包含一个版本"));
    }
    record
        .get(0)
        .ok_or(CoreError::InvalidState("CSV manifest 缺少版本字段"))?
        .parse()
        .map(Some)
        .map_err(|_| CoreError::InvalidState("CSV manifest 版本格式无效"))
}

fn read_snapshot(root: &Path, generation: u64) -> Result<CsvState, CoreError> {
    let path = snapshot_dir(root, generation).join(RECORDS_FILE);
    if !path.exists() {
        return Err(CoreError::InvalidState("CSV 快照缺少同步记录文件"));
    }
    let mut reader = ReaderBuilder::new()
        .has_headers(true)
        .from_path(&path)
        .map_err(|error| store_error(format!("无法读取同步记录 CSV: {error}")))?;
    let mut state = CsvState::default();
    for row in reader.records() {
        let row = row.map_err(|error| store_error(format!("同步记录 CSV 格式无效: {error}")))?;
        let repo_id = row
            .get(0)
            .ok_or(CoreError::InvalidState("同步记录 CSV 缺少仓库 ID"))?;
        let id = row
            .get(1)
            .ok_or(CoreError::InvalidState("同步记录 CSV 缺少 ID"))?;
        let payload = row
            .get(2)
            .ok_or(CoreError::InvalidState("同步记录 CSV 缺少内容"))?;
        let record: OrgRepoSyncRecord = serde_json::from_str(payload)
            .map_err(|error| CoreError::Store(format!("同步记录 JSON 格式无效: {error}")))?;
        if repo_id.is_empty()
            || id != record.id
            || record.finished_at.is_none()
            || record.result.is_none()
        {
            return Err(CoreError::InvalidState("同步记录 CSV 内容无效"));
        }
        if state
            .records
            .entry(repo_id.into())
            .or_default()
            .insert(record.id.clone(), record)
            .is_some()
        {
            return Err(CoreError::InvalidState("同步记录 CSV 包含重复 ID"));
        }
        if state.records.values().map(BTreeMap::len).sum::<usize>() > MAX_RECORDS {
            return Err(CoreError::InvalidState("同步记录数量超过允许上限"));
        }
    }
    Ok(state)
}

fn write_records(
    path: &Path,
    records: &BTreeMap<OrgRepoId, BTreeMap<String, OrgRepoSyncRecord>>,
) -> Result<(), CoreError> {
    let mut writer = Writer::from_path(path)
        .map_err(|error| store_error(format!("无法创建同步记录 CSV: {error}")))?;
    writer
        .write_record(["repo_id", "id", "record_json"])
        .map_err(|error| store_error(format!("无法写入同步记录 CSV 表头: {error}")))?;
    for (repo_id, repo_records) in records {
        for record in repo_records.values() {
            let payload = serde_json::to_string(record)
                .map_err(|error| CoreError::Store(format!("无法编码同步记录 JSON: {error}")))?;
            writer
                .write_record([repo_id.as_str(), record.id.as_str(), payload.as_str()])
                .map_err(|error| store_error(format!("无法写入同步记录 CSV: {error}")))?;
        }
    }
    writer
        .flush()
        .map_err(|error| store_error(format!("无法刷新同步记录 CSV: {error}")))?;
    Ok(())
}

fn write_generation(root: &Path, generation: u64) -> Result<(), CoreError> {
    let temporary = root.join("current.csv.tmp");
    let mut writer = Writer::from_path(&temporary)
        .map_err(|error| store_error(format!("无法创建 CSV manifest 临时文件: {error}")))?;
    writer
        .write_record(["generation"])
        .map_err(|error| store_error(format!("无法写入 CSV manifest 表头: {error}")))?;
    writer
        .write_record([generation.to_string()])
        .map_err(|error| store_error(format!("无法写入 CSV manifest: {error}")))?;
    writer
        .flush()
        .map_err(|error| store_error(format!("无法刷新 CSV manifest: {error}")))?;
    let file = File::open(&temporary)
        .map_err(|error| store_error(format!("无法打开 CSV manifest 临时文件: {error}")))?;
    file.sync_all()
        .map_err(|error| store_error(format!("无法同步 CSV manifest: {error}")))?;
    fs::rename(temporary, root.join(CURRENT_FILE))
        .map_err(|error| store_error(format!("无法提交 CSV manifest: {error}")))
}

fn store_error(message: String) -> CoreError {
    CoreError::Store(message)
}
