//! HTTP 宿主的 CSV 持久化适配器。
//!
//! 每次提交写入一个完整快照目录，随后原子替换 `current.csv`。读者只根据 manifest
//! 加载已完整写入的快照，因此多张 CSV 文件仍保持 `CoreStore::apply` 的提交边界。

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};

use csv::{ReaderBuilder, StringRecord, Writer};
use org_tasks_core::{
    CoreChangeSet, CoreError, CoreStore, FileSyncRecord, FileSyncState, JobKind, JobPriority,
    JobState, OutboxEntry, SyncJob,
};

const MAX_RECORDS: usize = 100_000;

#[derive(Clone, Default)]
struct CsvState {
    files: BTreeMap<String, FileSyncRecord>,
    jobs: BTreeMap<String, SyncJob>,
    outbox: BTreeMap<String, OutboxEntry>,
}

/// 以目录中的一组 CSV 快照实现的异步 `CoreStore`。
pub struct CsvCoreStore {
    root: PathBuf,
    generation: u64,
    state: CsvState,
}

impl CsvCoreStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, CoreError> {
        let root = root.as_ref().to_path_buf();
        if root.as_os_str().is_empty() {
            return Err(CoreError::InvalidInput("CSV 数据目录不能为空"));
        }
        fs::create_dir_all(root.join("snapshots"))
            .map_err(|error| store_error(format!("无法创建 CSV 数据目录: {error}")))?;
        remove_legacy_task_projections(&root)?;
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

    /// 仅校验现有 CSV 数据目录，不创建目录或写入数据。
    pub fn validate(root: impl AsRef<Path>) -> Result<(), CoreError> {
        let root = root.as_ref();
        if root.as_os_str().is_empty() {
            return Err(CoreError::InvalidInput("CSV 数据目录不能为空"));
        }
        if !root.is_dir() {
            return Err(CoreError::InvalidInput("CSV 数据目录不存在或不是目录"));
        }
        if let Some(generation) = read_generation(root)? {
            read_snapshot(root, generation)?;
        }
        Ok(())
    }

    fn persist(&mut self, state: CsvState) -> Result<(), CoreError> {
        let generation = self.next_generation()?;
        let snapshot_dir = snapshot_dir(&self.root, generation);
        fs::create_dir_all(&snapshot_dir)
            .map_err(|error| store_error(format!("无法创建 CSV 快照目录: {error}")))?;
        write_files(&snapshot_dir.join("files.csv"), &state.files)?;
        write_jobs(&snapshot_dir.join("jobs.csv"), &state.jobs)?;
        write_outbox(&snapshot_dir.join("outbox.csv"), &state.outbox)?;
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

fn remove_legacy_task_projections(root: &Path) -> Result<(), CoreError> {
    let snapshots = root.join("snapshots");
    for entry in fs::read_dir(&snapshots)
        .map_err(|error| store_error(format!("无法读取 CSV 快照目录: {error}")))?
    {
        let entry =
            entry.map_err(|error| store_error(format!("无法读取 CSV 快照条目: {error}")))?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        for name in ["tasks.csv", "task_tags.csv"] {
            let legacy_path = path.join(name);
            if legacy_path.exists() {
                fs::remove_file(&legacy_path).map_err(|error| {
                    store_error(format!("无法移除已废弃的任务投影文件: {error}"))
                })?;
            }
        }
    }
    Ok(())
}

impl CoreStore for CsvCoreStore {
    fn find_file_sync(
        &self,
        relative_path: &str,
    ) -> impl Future<Output = Result<Option<FileSyncRecord>, CoreError>> + Send {
        let value = self.state.files.get(relative_path).cloned();
        async move { Ok(value) }
    }

    fn find_outbox(
        &self,
        id: &str,
    ) -> impl Future<Output = Result<Option<OutboxEntry>, CoreError>> + Send {
        let value = self.state.outbox.get(id).cloned();
        async move { Ok(value) }
    }

    fn find_job(
        &self,
        id: &str,
    ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
        let value = self.state.jobs.get(id).cloned();
        async move { Ok(value) }
    }

    fn find_job_by_idempotency(
        &self,
        idempotency_key: &str,
    ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
        let value = self
            .state
            .jobs
            .values()
            .find(|job| job.idempotency_key == idempotency_key)
            .cloned();
        async move { Ok(value) }
    }

    fn find_active_sync_job(
        &self,
    ) -> impl Future<Output = Result<Option<SyncJob>, CoreError>> + Send {
        let value = self
            .state
            .jobs
            .values()
            .find(|job| {
                job.kind == JobKind::Sync
                    && matches!(job.state, JobState::Queued | JobState::Running)
            })
            .cloned();
        async move { Ok(value) }
    }

    fn apply(
        &mut self,
        changes: CoreChangeSet,
    ) -> impl Future<Output = Result<(), CoreError>> + Send {
        let mut next = self.state.clone();
        for record in changes.file_sync_records {
            next.files.insert(record.relative_path.clone(), record);
        }
        for entry in changes.outbox_entries {
            next.outbox.insert(entry.id.clone(), entry);
        }
        for job in changes.jobs {
            next.jobs.insert(job.id.clone(), job);
        }
        let result = self.persist(next);
        async move { result }
    }
}

fn snapshot_dir(root: &Path, generation: u64) -> PathBuf {
    root.join("snapshots").join(format!("{generation:020}"))
}

fn read_generation(root: &Path) -> Result<Option<u64>, CoreError> {
    let path = root.join("current.csv");
    if !path.exists() {
        return Ok(None);
    }
    let mut reader = ReaderBuilder::new()
        .has_headers(true)
        .from_path(path)
        .map_err(csv_error)?;
    let mut records = reader.records();
    let Some(record) = records.next() else {
        return Err(CoreError::InvalidState("CSV manifest 缺少当前快照版本"));
    };
    let record = record.map_err(csv_error)?;
    if records.next().is_some() {
        return Err(CoreError::InvalidState("CSV manifest 包含多余记录"));
    }
    required(&record, 0, "generation")?
        .parse::<u64>()
        .map(Some)
        .map_err(|_| CoreError::InvalidState("CSV manifest 版本无效"))
}

fn write_generation(root: &Path, generation: u64) -> Result<(), CoreError> {
    let temporary_path = root.join("current.csv.tmp");
    let final_path = root.join("current.csv");
    let file = File::create(&temporary_path)
        .map_err(|error| store_error(format!("无法创建 CSV manifest: {error}")))?;
    let mut writer = Writer::from_writer(file);
    writer.write_record(["generation"]).map_err(csv_error)?;
    writer
        .write_record([generation.to_string()])
        .map_err(csv_error)?;
    sync_writer(writer)?;
    fs::rename(temporary_path, final_path)
        .map_err(|error| store_error(format!("无法提交 CSV manifest: {error}")))
}

fn read_snapshot(root: &Path, generation: u64) -> Result<CsvState, CoreError> {
    let directory = snapshot_dir(root, generation);
    let files_path = directory.join("files.csv");
    let files = if files_path.exists() {
        read_files(&files_path)?
    } else {
        BTreeMap::new()
    };
    let jobs = read_jobs(&directory.join("jobs.csv"))?;
    let outbox = read_outbox(&directory.join("outbox.csv"))?;
    Ok(CsvState {
        files,
        jobs,
        outbox,
    })
}

fn write_files(path: &Path, files: &BTreeMap<String, FileSyncRecord>) -> Result<(), CoreError> {
    let mut writer = csv_writer(path)?;
    writer
        .write_record([
            "relative_path",
            "content_hash",
            "remote_etag",
            "remote_mtime",
            "remote_size",
            "last_synced_at",
            "sync_state",
        ])
        .map_err(csv_error)?;
    for record in files.values() {
        writer
            .write_record([
                record.relative_path.as_str(),
                record.content_hash.as_str(),
                record.remote_etag.as_deref().unwrap_or(""),
                optional_i64(record.remote_mtime).as_str(),
                optional_i64(record.remote_size).as_str(),
                optional_i64(record.last_synced_at).as_str(),
                file_sync_state_name(record.sync_state),
            ])
            .map_err(csv_error)?;
    }
    sync_writer(writer)
}

fn write_jobs(path: &Path, jobs: &BTreeMap<String, SyncJob>) -> Result<(), CoreError> {
    let mut writer = csv_writer(path)?;
    writer
        .write_record([
            "id",
            "idempotency_key",
            "kind",
            "state",
            "priority",
            "reason",
            "include_calendar",
            "task_id",
            "outbox_entry_id",
            "attempt_count",
            "next_run_at",
            "created_at",
            "updated_at",
        ])
        .map_err(csv_error)?;
    for job in jobs.values() {
        writer
            .write_record([
                job.id.as_str(),
                job.idempotency_key.as_str(),
                job_kind_name(job.kind),
                job_state_name(job.state),
                job_priority_name(job.priority),
                job.reason.as_str(),
                if job.include_calendar {
                    "true"
                } else {
                    "false"
                },
                job.task_id.as_deref().unwrap_or(""),
                job.outbox_entry_id.as_deref().unwrap_or(""),
                job.attempt_count.to_string().as_str(),
                optional_i64(job.next_run_at).as_str(),
                job.created_at.to_string().as_str(),
                job.updated_at.to_string().as_str(),
            ])
            .map_err(csv_error)?;
    }
    sync_writer(writer)
}

fn write_outbox(path: &Path, outbox: &BTreeMap<String, OutboxEntry>) -> Result<(), CoreError> {
    let mut writer = csv_writer(path)?;
    writer
        .write_record([
            "id",
            "relative_path",
            "org_entry",
            "content_hash",
            "created_at",
        ])
        .map_err(csv_error)?;
    for entry in outbox.values() {
        writer
            .write_record([
                entry.id.as_str(),
                entry.relative_path.as_str(),
                entry.org_entry.as_str(),
                entry.content_hash.as_str(),
                entry.created_at.to_string().as_str(),
            ])
            .map_err(csv_error)?;
    }
    sync_writer(writer)
}

fn read_files(path: &Path) -> Result<BTreeMap<String, FileSyncRecord>, CoreError> {
    let mut files = BTreeMap::new();
    for record in records(path)? {
        let file = FileSyncRecord {
            relative_path: required(&record, 0, "relative_path")?.to_owned(),
            content_hash: required(&record, 1, "content_hash")?.to_owned(),
            remote_etag: optional_string(required(&record, 2, "remote_etag")?),
            remote_mtime: parse_optional_i64(required(&record, 3, "remote_mtime")?)?,
            remote_size: parse_optional_i64(required(&record, 4, "remote_size")?)?,
            last_synced_at: parse_optional_i64(required(&record, 5, "last_synced_at")?)?,
            sync_state: parse_file_sync_state(required(&record, 6, "sync_state")?)?,
        };
        if file.relative_path.is_empty() || files.insert(file.relative_path.clone(), file).is_some()
        {
            return Err(CoreError::InvalidState("files.csv 存在空或重复相对路径"));
        }
    }
    Ok(files)
}

fn read_jobs(path: &Path) -> Result<BTreeMap<String, SyncJob>, CoreError> {
    let mut jobs = BTreeMap::new();
    for record in records(path)? {
        let (outbox_entry_id, offset) = if record.len() == 12 {
            (None, 8)
        } else {
            (record.get(8).map(optional_string).unwrap_or(None), 9)
        };
        let job = SyncJob {
            id: required(&record, 0, "id")?.to_owned(),
            idempotency_key: required(&record, 1, "idempotency_key")?.to_owned(),
            kind: parse_job_kind(required(&record, 2, "kind")?)?,
            state: parse_job_state(required(&record, 3, "state")?)?,
            priority: parse_job_priority(required(&record, 4, "priority")?)?,
            reason: required(&record, 5, "reason")?.to_owned(),
            include_calendar: parse_bool(required(&record, 6, "include_calendar")?)?,
            task_id: optional_string(required(&record, 7, "task_id")?),
            outbox_entry_id,
            attempt_count: required(&record, offset, "attempt_count")?
                .parse()
                .map_err(|_| CoreError::InvalidState("jobs.csv 尝试次数无效"))?,
            next_run_at: parse_optional_i64(required(&record, offset + 1, "next_run_at")?)?,
            created_at: parse_i64(required(&record, offset + 2, "created_at")?)?,
            updated_at: parse_i64(required(&record, offset + 3, "updated_at")?)?,
        };
        if job.id.is_empty() || jobs.insert(job.id.clone(), job).is_some() {
            return Err(CoreError::InvalidState("jobs.csv 存在空或重复 ID"));
        }
    }
    Ok(jobs)
}

fn read_outbox(path: &Path) -> Result<BTreeMap<String, OutboxEntry>, CoreError> {
    let mut outbox = BTreeMap::new();
    for record in records(path)? {
        let entry = OutboxEntry {
            id: required(&record, 0, "id")?.to_owned(),
            relative_path: required(&record, 1, "relative_path")?.to_owned(),
            org_entry: required(&record, 2, "org_entry")?.to_owned(),
            content_hash: required(&record, 3, "content_hash")?.to_owned(),
            created_at: parse_i64(required(&record, 4, "created_at")?)?,
        };
        if entry.id.is_empty() || outbox.insert(entry.id.clone(), entry).is_some() {
            return Err(CoreError::InvalidState("outbox.csv 存在空或重复 ID"));
        }
    }
    Ok(outbox)
}

fn csv_writer(path: &Path) -> Result<Writer<File>, CoreError> {
    File::create(path)
        .map(Writer::from_writer)
        .map_err(|error| store_error(format!("无法创建 CSV 文件: {error}")))
}

fn sync_writer(writer: Writer<File>) -> Result<(), CoreError> {
    let mut file = writer
        .into_inner()
        .map_err(|error| store_error(format!("无法完成 CSV 写入: {error}")))?;
    file.flush()
        .map_err(|error| store_error(format!("无法刷新 CSV 文件: {error}")))?;
    file.sync_all()
        .map_err(|error| store_error(format!("无法同步 CSV 文件: {error}")))
}

fn records(path: &Path) -> Result<Vec<StringRecord>, CoreError> {
    let mut reader = ReaderBuilder::new()
        .has_headers(true)
        .from_path(path)
        .map_err(csv_error)?;
    reader
        .records()
        .take(MAX_RECORDS + 1)
        .collect::<Result<Vec<_>, _>>()
        .map_err(csv_error)
        .and_then(|records| {
            if records.len() > MAX_RECORDS {
                Err(CoreError::InvalidState("CSV 记录数量超过允许上限"))
            } else {
                Ok(records)
            }
        })
}

fn required<'a>(
    record: &'a StringRecord,
    index: usize,
    _: &'static str,
) -> Result<&'a str, CoreError> {
    record
        .get(index)
        .ok_or(CoreError::InvalidState("CSV 记录缺少必填字段"))
}

fn optional_string(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_owned())
}

fn optional_i64(value: Option<i64>) -> String {
    value.map(|value| value.to_string()).unwrap_or_default()
}

fn parse_i64(value: &str) -> Result<i64, CoreError> {
    value
        .parse()
        .map_err(|_| CoreError::InvalidState("CSV 时间戳无效"))
}

fn parse_optional_i64(value: &str) -> Result<Option<i64>, CoreError> {
    if value.is_empty() {
        Ok(None)
    } else {
        parse_i64(value).map(Some)
    }
}

fn parse_bool(value: &str) -> Result<bool, CoreError> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(CoreError::InvalidState("CSV 布尔值无效")),
    }
}

fn file_sync_state_name(value: FileSyncState) -> &'static str {
    match value {
        FileSyncState::Synced => "synced",
        FileSyncState::LocalChanged => "local_changed",
        FileSyncState::RemoteChanged => "remote_changed",
        FileSyncState::RemoteDeleted => "remote_deleted",
        FileSyncState::Conflict => "conflict",
    }
}

fn parse_file_sync_state(value: &str) -> Result<FileSyncState, CoreError> {
    match value {
        "synced" => Ok(FileSyncState::Synced),
        "local_changed" => Ok(FileSyncState::LocalChanged),
        "remote_changed" => Ok(FileSyncState::RemoteChanged),
        "remote_deleted" => Ok(FileSyncState::RemoteDeleted),
        "conflict" => Ok(FileSyncState::Conflict),
        _ => Err(CoreError::InvalidState("files.csv 同步状态无效")),
    }
}

fn job_kind_name(value: JobKind) -> &'static str {
    match value {
        JobKind::Sync => "sync",
        JobKind::AddTask => "add_task",
        JobKind::Retry => "retry",
        JobKind::ResolveConflict => "resolve_conflict",
        JobKind::RebuildCalendar => "rebuild_calendar",
        JobKind::RefreshLocalIndex => "refresh_local_index",
    }
}

fn parse_job_kind(value: &str) -> Result<JobKind, CoreError> {
    match value {
        "sync" => Ok(JobKind::Sync),
        "add_task" => Ok(JobKind::AddTask),
        "retry" => Ok(JobKind::Retry),
        "resolve_conflict" => Ok(JobKind::ResolveConflict),
        "rebuild_calendar" => Ok(JobKind::RebuildCalendar),
        "refresh_local_index" => Ok(JobKind::RefreshLocalIndex),
        _ => Err(CoreError::InvalidState("jobs.csv 类型无效")),
    }
}

fn job_state_name(value: JobState) -> &'static str {
    match value {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::RetryWait => "retry_wait",
        JobState::Blocked => "blocked",
        JobState::Completed => "completed",
        JobState::Failed => "failed",
    }
}

fn parse_job_state(value: &str) -> Result<JobState, CoreError> {
    match value {
        "queued" => Ok(JobState::Queued),
        "running" => Ok(JobState::Running),
        "retry_wait" => Ok(JobState::RetryWait),
        "blocked" => Ok(JobState::Blocked),
        "completed" => Ok(JobState::Completed),
        "failed" => Ok(JobState::Failed),
        _ => Err(CoreError::InvalidState("jobs.csv 状态无效")),
    }
}

fn job_priority_name(value: JobPriority) -> &'static str {
    match value {
        JobPriority::Foreground => "foreground",
        JobPriority::Background => "background",
    }
}

fn parse_job_priority(value: &str) -> Result<JobPriority, CoreError> {
    match value {
        "foreground" => Ok(JobPriority::Foreground),
        "background" => Ok(JobPriority::Background),
        _ => Err(CoreError::InvalidState("jobs.csv 优先级无效")),
    }
}

fn csv_error(error: csv::Error) -> CoreError {
    store_error(format!("CSV 操作失败: {error}"))
}

fn store_error(message: String) -> CoreError {
    CoreError::Store(message)
}
