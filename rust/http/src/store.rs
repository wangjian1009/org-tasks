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
    CoreChangeSet, CoreError, CoreStore, JobKind, JobPriority, JobState, OutboxEntry, Priority,
    SyncJob, TaskRecord, TodoState,
};

const MAX_RECORDS: usize = 100_000;

#[derive(Clone, Default)]
struct CsvState {
    tasks: BTreeMap<String, TaskRecord>,
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

    fn persist(&mut self, state: CsvState) -> Result<(), CoreError> {
        let generation = self.next_generation()?;
        let snapshot_dir = snapshot_dir(&self.root, generation);
        fs::create_dir_all(&snapshot_dir)
            .map_err(|error| store_error(format!("无法创建 CSV 快照目录: {error}")))?;
        write_tasks(&snapshot_dir.join("tasks.csv"), &state.tasks)?;
        write_task_tags(&snapshot_dir.join("task_tags.csv"), &state.tasks)?;
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

impl CoreStore for CsvCoreStore {
    fn find_task(
        &self,
        id: &str,
    ) -> impl Future<Output = Result<Option<TaskRecord>, CoreError>> + Send {
        let value = self.state.tasks.get(id).cloned();
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
        for task in changes.tasks {
            next.tasks.insert(task.id.clone(), task);
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
    let mut tasks = read_tasks(&directory.join("tasks.csv"))?;
    read_task_tags(&directory.join("task_tags.csv"), &mut tasks)?;
    let jobs = read_jobs(&directory.join("jobs.csv"))?;
    let outbox = read_outbox(&directory.join("outbox.csv"))?;
    Ok(CsvState {
        tasks,
        jobs,
        outbox,
    })
}

fn write_tasks(path: &Path, tasks: &BTreeMap<String, TaskRecord>) -> Result<(), CoreError> {
    let mut writer = csv_writer(path)?;
    writer
        .write_record([
            "id",
            "file_path",
            "heading",
            "todo_state",
            "priority",
            "scheduled_at",
            "deadline_at",
            "body",
            "source_revision",
            "updated_at",
        ])
        .map_err(csv_error)?;
    for task in tasks.values() {
        writer
            .write_record([
                task.id.as_str(),
                task.file_path.as_str(),
                task.heading.as_str(),
                todo_state_name(task.todo_state),
                task.priority.map(priority_name).unwrap_or(""),
                optional_i64(task.scheduled_at).as_str(),
                optional_i64(task.deadline_at).as_str(),
                task.body.as_str(),
                task.source_revision.as_str(),
                task.updated_at.to_string().as_str(),
            ])
            .map_err(csv_error)?;
    }
    sync_writer(writer)
}

fn write_task_tags(path: &Path, tasks: &BTreeMap<String, TaskRecord>) -> Result<(), CoreError> {
    let mut writer = csv_writer(path)?;
    writer
        .write_record(["task_id", "position", "tag"])
        .map_err(csv_error)?;
    for task in tasks.values() {
        for (position, tag) in task.tags.iter().enumerate() {
            writer
                .write_record([
                    task.id.as_str(),
                    position.to_string().as_str(),
                    tag.as_str(),
                ])
                .map_err(csv_error)?;
        }
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
            "target_path",
            "org_entry",
            "content_hash",
            "created_at",
        ])
        .map_err(csv_error)?;
    for entry in outbox.values() {
        writer
            .write_record([
                entry.id.as_str(),
                entry.target_path.as_str(),
                entry.org_entry.as_str(),
                entry.content_hash.as_str(),
                entry.created_at.to_string().as_str(),
            ])
            .map_err(csv_error)?;
    }
    sync_writer(writer)
}

fn read_tasks(path: &Path) -> Result<BTreeMap<String, TaskRecord>, CoreError> {
    let mut tasks = BTreeMap::new();
    for record in records(path)? {
        let task = TaskRecord {
            id: required(&record, 0, "id")?.to_owned(),
            file_path: required(&record, 1, "file_path")?.to_owned(),
            heading: required(&record, 2, "heading")?.to_owned(),
            todo_state: parse_todo_state(required(&record, 3, "todo_state")?)?,
            priority: parse_optional_priority(required(&record, 4, "priority")?)?,
            scheduled_at: parse_optional_i64(required(&record, 5, "scheduled_at")?)?,
            deadline_at: parse_optional_i64(required(&record, 6, "deadline_at")?)?,
            tags: Vec::new(),
            body: required(&record, 7, "body")?.to_owned(),
            source_revision: required(&record, 8, "source_revision")?.to_owned(),
            updated_at: parse_i64(required(&record, 9, "updated_at")?)?,
        };
        if task.id.is_empty() || tasks.insert(task.id.clone(), task).is_some() {
            return Err(CoreError::InvalidState("tasks.csv 存在空或重复 ID"));
        }
    }
    Ok(tasks)
}

fn read_task_tags(path: &Path, tasks: &mut BTreeMap<String, TaskRecord>) -> Result<(), CoreError> {
    let mut tags: BTreeMap<String, Vec<(usize, String)>> = BTreeMap::new();
    for record in records(path)? {
        let task_id = required(&record, 0, "task_id")?.to_owned();
        if !tasks.contains_key(&task_id) {
            return Err(CoreError::InvalidState("task_tags.csv 引用了不存在的任务"));
        }
        let position = required(&record, 1, "position")?
            .parse::<usize>()
            .map_err(|_| CoreError::InvalidState("task_tags.csv 位置无效"))?;
        tags.entry(task_id)
            .or_default()
            .push((position, required(&record, 2, "tag")?.to_owned()));
    }
    for (task_id, mut values) in tags {
        values.sort_by_key(|(position, _)| *position);
        if values.windows(2).any(|pair| pair[0].0 == pair[1].0) {
            return Err(CoreError::InvalidState("task_tags.csv 包含重复位置"));
        }
        tasks.get_mut(&task_id).expect("已校验任务存在").tags =
            values.into_iter().map(|(_, tag)| tag).collect();
    }
    Ok(())
}

fn read_jobs(path: &Path) -> Result<BTreeMap<String, SyncJob>, CoreError> {
    let mut jobs = BTreeMap::new();
    for record in records(path)? {
        let job = SyncJob {
            id: required(&record, 0, "id")?.to_owned(),
            idempotency_key: required(&record, 1, "idempotency_key")?.to_owned(),
            kind: parse_job_kind(required(&record, 2, "kind")?)?,
            state: parse_job_state(required(&record, 3, "state")?)?,
            priority: parse_job_priority(required(&record, 4, "priority")?)?,
            reason: required(&record, 5, "reason")?.to_owned(),
            include_calendar: parse_bool(required(&record, 6, "include_calendar")?)?,
            task_id: optional_string(required(&record, 7, "task_id")?),
            attempt_count: required(&record, 8, "attempt_count")?
                .parse()
                .map_err(|_| CoreError::InvalidState("jobs.csv 尝试次数无效"))?,
            next_run_at: parse_optional_i64(required(&record, 9, "next_run_at")?)?,
            created_at: parse_i64(required(&record, 10, "created_at")?)?,
            updated_at: parse_i64(required(&record, 11, "updated_at")?)?,
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
            target_path: required(&record, 1, "target_path")?.to_owned(),
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

fn todo_state_name(value: TodoState) -> &'static str {
    match value {
        TodoState::Todo => "TODO",
        TodoState::Next => "NEXT",
        TodoState::Wait => "WAIT",
        TodoState::Done => "DONE",
        TodoState::Cncl => "CNCL",
    }
}

fn parse_todo_state(value: &str) -> Result<TodoState, CoreError> {
    match value {
        "TODO" => Ok(TodoState::Todo),
        "NEXT" => Ok(TodoState::Next),
        "WAIT" => Ok(TodoState::Wait),
        "DONE" => Ok(TodoState::Done),
        "CNCL" => Ok(TodoState::Cncl),
        _ => Err(CoreError::InvalidState("tasks.csv 状态无效")),
    }
}

fn priority_name(value: Priority) -> &'static str {
    match value {
        Priority::A => "A",
        Priority::B => "B",
        Priority::C => "C",
    }
}

fn parse_optional_priority(value: &str) -> Result<Option<Priority>, CoreError> {
    match value {
        "" => Ok(None),
        "A" => Ok(Some(Priority::A)),
        "B" => Ok(Some(Priority::B)),
        "C" => Ok(Some(Priority::C)),
        _ => Err(CoreError::InvalidState("tasks.csv 优先级无效")),
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
