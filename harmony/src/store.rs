//! HarmonyOS 宿主的持久化适配器。
//!
//! 核心层只定义 `CoreStore` 语义。本模块把文件同步元数据、outbox 和同步作业
//! 写入应用私有目录中的版本化二进制快照，并通过临时文件与原子替换保证提交边界。

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};

use org_tasks_core::{
    CoreChangeSet, CoreError, CoreStore, FileSyncRecord, FileSyncState, JobKind, JobPriority,
    JobState, OutboxEntry, Priority, SyncJob, TodoState,
};

const MAGIC: &[u8; 8] = b"ORGCORE1";
const VERSION: u32 = 2;
const MAX_STATE_BYTES: usize = 16 * 1024 * 1024;
const MAX_RECORDS: usize = 100_000;
const MAX_STRING_BYTES: usize = 1024 * 1024;

#[derive(Clone, Default)]
struct PersistedState {
    files: BTreeMap<String, FileSyncRecord>,
    jobs: BTreeMap<String, SyncJob>,
    outbox: BTreeMap<String, OutboxEntry>,
}

/// 使用 HarmonyOS 应用私有目录的持久化 `CoreStore` 实现。
pub struct FileCoreStore {
    state_path: PathBuf,
    state: PersistedState,
}

impl FileCoreStore {
    pub fn open(data_dir: impl AsRef<Path>) -> Result<Self, CoreError> {
        let data_dir = data_dir.as_ref();
        if data_dir.as_os_str().is_empty() {
            return Err(CoreError::InvalidInput("Harmony 数据目录不能为空"));
        }
        fs::create_dir_all(data_dir)
            .map_err(|error| store_error(format!("无法创建数据目录: {error}")))?;
        let state_path = data_dir.join("core-state-v1.bin");
        let (state, needs_migration) = if state_path.exists() {
            let bytes = fs::read(&state_path)
                .map_err(|error| store_error(format!("无法读取核心状态: {error}")))?;
            (decode_state(&bytes)?, state_version(&bytes)? == 1)
        } else {
            (PersistedState::default(), false)
        };
        let store = Self { state_path, state };
        if needs_migration {
            store.persist(&store.state)?;
        }
        Ok(store)
    }

    fn persist(&self, state: &PersistedState) -> Result<(), CoreError> {
        let bytes = encode_state(state)?;
        let temporary_path = self.state_path.with_extension("bin.tmp");
        let mut file = File::create(&temporary_path)
            .map_err(|error| store_error(format!("无法创建状态临时文件: {error}")))?;
        file.write_all(&bytes)
            .map_err(|error| store_error(format!("无法写入状态临时文件: {error}")))?;
        file.sync_all()
            .map_err(|error| store_error(format!("无法同步状态临时文件: {error}")))?;
        drop(file);
        fs::rename(&temporary_path, &self.state_path)
            .map_err(|error| store_error(format!("无法提交核心状态: {error}")))
    }
}

impl CoreStore for FileCoreStore {
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
        let result = self.persist(&next);
        if result.is_ok() {
            self.state = next;
        }
        async move { result }
    }
}

fn store_error(message: String) -> CoreError {
    CoreError::Store(message)
}

fn encode_state(state: &PersistedState) -> Result<Vec<u8>, CoreError> {
    let mut encoder = Encoder::default();
    encoder.write_bytes(MAGIC);
    encoder.write_u32(VERSION);
    encoder.write_u32(checked_count(state.files.len())?);
    for record in state.files.values() {
        encoder.write_file_sync(record)?;
    }
    encoder.write_u32(checked_count(state.jobs.len())?);
    for job in state.jobs.values() {
        encoder.write_job(job)?;
    }
    encoder.write_u32(checked_count(state.outbox.len())?);
    for entry in state.outbox.values() {
        encoder.write_outbox(entry)?;
    }
    if encoder.bytes.len() > MAX_STATE_BYTES {
        return Err(CoreError::InvalidState("核心状态超过允许的存储上限"));
    }
    Ok(encoder.bytes)
}

fn decode_state(bytes: &[u8]) -> Result<PersistedState, CoreError> {
    if bytes.len() > MAX_STATE_BYTES {
        return Err(CoreError::InvalidState("核心状态文件超过允许的存储上限"));
    }
    let mut decoder = Decoder::new(bytes);
    if decoder.read_exact(MAGIC.len())? != MAGIC {
        return Err(CoreError::InvalidState("核心状态文件格式无效"));
    }
    let version = decoder.read_u32()?;
    let mut state = PersistedState::default();
    match version {
        1 => {
            for _ in 0..decoder.read_count()? {
                decoder.skip_legacy_task()?;
            }
        }
        VERSION => {
            for _ in 0..decoder.read_count()? {
                let record = decoder.read_file_sync()?;
                if state
                    .files
                    .insert(record.relative_path.clone(), record)
                    .is_some()
                {
                    return Err(CoreError::InvalidState("核心状态存在重复文件相对路径"));
                }
            }
        }
        _ => return Err(CoreError::InvalidState("核心状态文件版本不受支持")),
    }
    for _ in 0..decoder.read_count()? {
        let job = decoder.read_job(version)?;
        if state.jobs.insert(job.id.clone(), job).is_some() {
            return Err(CoreError::InvalidState("核心状态存在重复作业 ID"));
        }
    }
    for _ in 0..decoder.read_count()? {
        let entry = decoder.read_outbox()?;
        if state.outbox.insert(entry.id.clone(), entry).is_some() {
            return Err(CoreError::InvalidState("核心状态存在重复 outbox ID"));
        }
    }
    if !decoder.is_finished() {
        return Err(CoreError::InvalidState("核心状态文件包含多余数据"));
    }
    Ok(state)
}

fn state_version(bytes: &[u8]) -> Result<u32, CoreError> {
    if bytes.len() < MAGIC.len() + 4 || &bytes[..MAGIC.len()] != MAGIC {
        return Err(CoreError::InvalidState("核心状态文件格式无效"));
    }
    let version: [u8; 4] = bytes[MAGIC.len()..MAGIC.len() + 4]
        .try_into()
        .map_err(|_| CoreError::InvalidState("核心状态文件版本格式无效"))?;
    Ok(u32::from_le_bytes(version))
}

fn checked_count(value: usize) -> Result<u32, CoreError> {
    u32::try_from(value).map_err(|_| CoreError::InvalidState("核心状态记录数量超过允许上限"))
}

#[derive(Default)]
struct Encoder {
    bytes: Vec<u8>,
}

impl Encoder {
    fn write_bytes(&mut self, value: &[u8]) {
        self.bytes.extend_from_slice(value);
    }

    fn write_u8(&mut self, value: u8) {
        self.bytes.push(value);
    }

    fn write_u32(&mut self, value: u32) {
        self.write_bytes(&value.to_le_bytes());
    }

    fn write_i64(&mut self, value: i64) {
        self.write_bytes(&value.to_le_bytes());
    }

    fn write_string(&mut self, value: &str) -> Result<(), CoreError> {
        if value.len() > MAX_STRING_BYTES {
            return Err(CoreError::InvalidState("核心状态字符串超过允许上限"));
        }
        self.write_u32(checked_count(value.len())?);
        self.write_bytes(value.as_bytes());
        Ok(())
    }

    fn write_optional_i64(&mut self, value: Option<i64>) {
        match value {
            Some(value) => {
                self.write_u8(1);
                self.write_i64(value);
            }
            None => self.write_u8(0),
        }
    }

    fn write_optional_string(&mut self, value: &Option<String>) -> Result<(), CoreError> {
        match value {
            Some(value) => {
                self.write_u8(1);
                self.write_string(value)
            }
            None => {
                self.write_u8(0);
                Ok(())
            }
        }
    }

    fn write_job_kind(&mut self, value: JobKind) {
        self.write_u8(match value {
            JobKind::Sync => 0,
            JobKind::AddTask => 1,
            JobKind::Retry => 2,
            JobKind::ResolveConflict => 3,
            JobKind::RebuildCalendar => 4,
            JobKind::RefreshLocalIndex => 5,
        });
    }

    fn write_job_state(&mut self, value: JobState) {
        self.write_u8(match value {
            JobState::Queued => 0,
            JobState::Running => 1,
            JobState::RetryWait => 2,
            JobState::Blocked => 3,
            JobState::Completed => 4,
            JobState::Failed => 5,
        });
    }

    fn write_job_priority(&mut self, value: JobPriority) {
        self.write_u8(match value {
            JobPriority::Foreground => 0,
            JobPriority::Background => 1,
        });
    }

    fn write_file_sync(&mut self, record: &FileSyncRecord) -> Result<(), CoreError> {
        self.write_string(&record.relative_path)?;
        self.write_string(&record.content_hash)?;
        self.write_optional_string(&record.remote_etag)?;
        self.write_optional_i64(record.remote_mtime);
        self.write_optional_i64(record.remote_size);
        self.write_optional_i64(record.last_synced_at);
        self.write_file_sync_state(record.sync_state);
        Ok(())
    }

    fn write_file_sync_state(&mut self, value: FileSyncState) {
        self.write_u8(match value {
            FileSyncState::Synced => 0,
            FileSyncState::LocalChanged => 1,
            FileSyncState::RemoteChanged => 2,
            FileSyncState::RemoteDeleted => 3,
            FileSyncState::Conflict => 4,
        });
    }

    fn write_job(&mut self, job: &SyncJob) -> Result<(), CoreError> {
        self.write_string(&job.id)?;
        self.write_string(&job.idempotency_key)?;
        self.write_job_kind(job.kind);
        self.write_job_state(job.state);
        self.write_job_priority(job.priority);
        self.write_string(&job.reason)?;
        self.write_u8(u8::from(job.include_calendar));
        self.write_optional_string(&job.task_id)?;
        self.write_optional_string(&job.outbox_entry_id)?;
        self.write_u32(job.attempt_count);
        self.write_optional_i64(job.next_run_at);
        self.write_i64(job.created_at);
        self.write_i64(job.updated_at);
        Ok(())
    }

    fn write_outbox(&mut self, entry: &OutboxEntry) -> Result<(), CoreError> {
        self.write_string(&entry.id)?;
        self.write_string(&entry.relative_path)?;
        self.write_string(&entry.org_entry)?;
        self.write_string(&entry.content_hash)?;
        self.write_i64(entry.created_at);
        Ok(())
    }
}

struct Decoder<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Decoder<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn read_exact(&mut self, length: usize) -> Result<&'a [u8], CoreError> {
        let end = self
            .offset
            .checked_add(length)
            .filter(|end| *end <= self.bytes.len())
            .ok_or(CoreError::InvalidState("核心状态文件被截断"))?;
        let value = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(value)
    }

    fn read_u8(&mut self) -> Result<u8, CoreError> {
        Ok(self.read_exact(1)?[0])
    }

    fn read_u32(&mut self) -> Result<u32, CoreError> {
        let bytes: [u8; 4] = self
            .read_exact(4)?
            .try_into()
            .map_err(|_| CoreError::InvalidState("核心状态整数格式无效"))?;
        Ok(u32::from_le_bytes(bytes))
    }

    fn read_i64(&mut self) -> Result<i64, CoreError> {
        let bytes: [u8; 8] = self
            .read_exact(8)?
            .try_into()
            .map_err(|_| CoreError::InvalidState("核心状态整数格式无效"))?;
        Ok(i64::from_le_bytes(bytes))
    }

    fn read_count(&mut self) -> Result<usize, CoreError> {
        let count = self.read_u32()? as usize;
        if count > MAX_RECORDS {
            return Err(CoreError::InvalidState("核心状态记录数量超过允许上限"));
        }
        Ok(count)
    }

    fn read_string(&mut self) -> Result<String, CoreError> {
        let length = self.read_u32()? as usize;
        if length > MAX_STRING_BYTES {
            return Err(CoreError::InvalidState("核心状态字符串超过允许上限"));
        }
        let bytes = self.read_exact(length)?;
        let value = std::str::from_utf8(bytes)
            .map_err(|_| CoreError::InvalidState("核心状态包含无效 UTF-8"))?;
        Ok(value.to_owned())
    }

    fn read_optional_i64(&mut self) -> Result<Option<i64>, CoreError> {
        match self.read_u8()? {
            0 => Ok(None),
            1 => self.read_i64().map(Some),
            _ => Err(CoreError::InvalidState("核心状态可选值格式无效")),
        }
    }

    fn read_optional_string(&mut self) -> Result<Option<String>, CoreError> {
        match self.read_u8()? {
            0 => Ok(None),
            1 => self.read_string().map(Some),
            _ => Err(CoreError::InvalidState("核心状态可选值格式无效")),
        }
    }

    fn read_optional_priority(&mut self) -> Result<Option<Priority>, CoreError> {
        match self.read_u8()? {
            0 => Ok(None),
            1 => Ok(Some(Priority::A)),
            2 => Ok(Some(Priority::B)),
            3 => Ok(Some(Priority::C)),
            _ => Err(CoreError::InvalidState("核心状态优先级格式无效")),
        }
    }

    fn read_todo_state(&mut self) -> Result<TodoState, CoreError> {
        match self.read_u8()? {
            0 => Ok(TodoState::Todo),
            1 => Ok(TodoState::Next),
            2 => Ok(TodoState::Wait),
            3 => Ok(TodoState::Done),
            4 => Ok(TodoState::Cncl),
            _ => Err(CoreError::InvalidState("核心状态任务状态格式无效")),
        }
    }

    fn read_job_kind(&mut self) -> Result<JobKind, CoreError> {
        match self.read_u8()? {
            0 => Ok(JobKind::Sync),
            1 => Ok(JobKind::AddTask),
            2 => Ok(JobKind::Retry),
            3 => Ok(JobKind::ResolveConflict),
            4 => Ok(JobKind::RebuildCalendar),
            5 => Ok(JobKind::RefreshLocalIndex),
            _ => Err(CoreError::InvalidState("核心状态作业类型格式无效")),
        }
    }

    fn read_job_state(&mut self) -> Result<JobState, CoreError> {
        match self.read_u8()? {
            0 => Ok(JobState::Queued),
            1 => Ok(JobState::Running),
            2 => Ok(JobState::RetryWait),
            3 => Ok(JobState::Blocked),
            4 => Ok(JobState::Completed),
            5 => Ok(JobState::Failed),
            _ => Err(CoreError::InvalidState("核心状态作业状态格式无效")),
        }
    }

    fn read_job_priority(&mut self) -> Result<JobPriority, CoreError> {
        match self.read_u8()? {
            0 => Ok(JobPriority::Foreground),
            1 => Ok(JobPriority::Background),
            _ => Err(CoreError::InvalidState("核心状态作业优先级格式无效")),
        }
    }

    fn read_bool(&mut self) -> Result<bool, CoreError> {
        match self.read_u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(CoreError::InvalidState("核心状态布尔值格式无效")),
        }
    }

    fn read_file_sync_state(&mut self) -> Result<FileSyncState, CoreError> {
        match self.read_u8()? {
            0 => Ok(FileSyncState::Synced),
            1 => Ok(FileSyncState::LocalChanged),
            2 => Ok(FileSyncState::RemoteChanged),
            3 => Ok(FileSyncState::RemoteDeleted),
            4 => Ok(FileSyncState::Conflict),
            _ => Err(CoreError::InvalidState("核心状态文件同步状态格式无效")),
        }
    }

    fn read_file_sync(&mut self) -> Result<FileSyncRecord, CoreError> {
        Ok(FileSyncRecord {
            relative_path: self.read_string()?,
            content_hash: self.read_string()?,
            remote_etag: self.read_optional_string()?,
            remote_mtime: self.read_optional_i64()?,
            remote_size: self.read_optional_i64()?,
            last_synced_at: self.read_optional_i64()?,
            sync_state: self.read_file_sync_state()?,
        })
    }

    fn skip_legacy_task(&mut self) -> Result<(), CoreError> {
        let _ = self.read_string()?;
        let _ = self.read_string()?;
        let _ = self.read_string()?;
        let _ = self.read_todo_state()?;
        let _ = self.read_optional_priority()?;
        let _ = self.read_optional_i64()?;
        let _ = self.read_optional_i64()?;
        for _ in 0..self.read_count()? {
            let _ = self.read_string()?;
        }
        let _ = self.read_string()?;
        let _ = self.read_string()?;
        let _ = self.read_i64()?;
        Ok(())
    }

    fn read_job(&mut self, version: u32) -> Result<SyncJob, CoreError> {
        let id = self.read_string()?;
        Ok(SyncJob {
            id,
            idempotency_key: self.read_string()?,
            kind: self.read_job_kind()?,
            state: self.read_job_state()?,
            priority: self.read_job_priority()?,
            reason: self.read_string()?,
            include_calendar: self.read_bool()?,
            task_id: self.read_optional_string()?,
            outbox_entry_id: if version == 1 {
                None
            } else {
                self.read_optional_string()?
            },
            attempt_count: self.read_u32()?,
            next_run_at: self.read_optional_i64()?,
            created_at: self.read_i64()?,
            updated_at: self.read_i64()?,
        })
    }

    fn read_outbox(&mut self) -> Result<OutboxEntry, CoreError> {
        Ok(OutboxEntry {
            id: self.read_string()?,
            relative_path: self.read_string()?,
            org_entry: self.read_string()?,
            content_hash: self.read_string()?,
            created_at: self.read_i64()?,
        })
    }

    fn is_finished(&self) -> bool {
        self.offset == self.bytes.len()
    }
}
