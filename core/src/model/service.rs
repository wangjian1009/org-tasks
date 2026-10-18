use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;

use super::{OrgFile, OrgRepo, OrgRepoId, OrgRepoSyncRecord};
use crate::{CoreError, TimestampMs};

struct OrgRepoSourceFile {
    pub path: String,
    pub source_bytes: Vec<u8>,
}

impl OrgRepoSourceFile {
    pub fn new(path: String, source_bytes: Vec<u8>) -> Result<Self, CoreError> {
        if path.trim().is_empty()
            || path.starts_with('/')
            || path.contains('\\')
            || path
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err(CoreError::InvalidInput("文件路径必须是安全的相对路径"));
        }
        Ok(Self { path, source_bytes })
    }
}

/// 可随同步历史保存的策略级细节。
pub trait SyncContextDetail:
    Serialize + DeserializeOwned + Send + Sync + Clone + Default + 'static
{
}

impl<T> SyncContextDetail for T where
    T: Serialize + DeserializeOwned + Send + Sync + Clone + Default + 'static
{
}

/// 可随单个文件同步结果保存的策略级细节。
pub trait SyncFileDetail:
    Serialize + DeserializeOwned + Send + Sync + Clone + Default + 'static
{
}

impl<T> SyncFileDetail for T where
    T: Serialize + DeserializeOwned + Send + Sync + Clone + Default + 'static
{
}

/// 一次同步的上下文，统一持有仓库、开始时间与同步根路径。
pub struct SyncContext<'a> {
    pub repo: &'a mut OrgRepo,
    pub started_at: TimestampMs,
    pub base: PathBuf,
}

impl<'a> SyncContext<'a> {
    pub fn new(repo: &'a mut OrgRepo, started_at: TimestampMs) -> Self {
        Self {
            base: PathBuf::from(&repo.root_directory),
            repo,
            started_at,
        }
    }
}

/// 仓库同步策略。WebDAV 是该端口的一个实现。
pub trait SyncPolicy: Send + Sync {
    const KIND: &'static str;

    type ContextDetail: SyncContextDetail;
    type FileDetail: SyncFileDetail;

    fn synchronize(
        &self,
        context: &mut SyncContext<'_>,
        history: &[OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>],
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> impl Future<
        Output = Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError>,
    > + Send;
}

/// 同步运行期间可由策略查询的取消信号。
#[derive(Clone, Default)]
pub struct SyncCancellation {
    cancelled: Arc<AtomicBool>,
}

impl SyncCancellation {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
}

/// 同步策略向宿主界面公开的阶段进度。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgRepoSyncProgress {
    pub stage: String,
    pub completed: usize,
    pub total: usize,
    pub current_path: Option<String>,
    pub http_events: Vec<String>,
}

impl Default for OrgRepoSyncProgress {
    fn default() -> Self {
        Self {
            stage: "Idle".into(),
            completed: 0,
            total: 0,
            current_path: None,
            http_events: Vec::new(),
        }
    }
}

/// 策略通过该对象更新当前同步的可读进度。
#[derive(Clone, Default)]
pub struct SyncProgressReporter {
    progress: Arc<Mutex<OrgRepoSyncProgress>>,
}

impl SyncProgressReporter {
    pub fn report(
        &self,
        stage: impl Into<String>,
        completed: usize,
        total: usize,
        current_path: Option<String>,
    ) {
        if let Ok(mut progress) = self.progress.lock() {
            let http_events = progress.http_events.clone();
            *progress = OrgRepoSyncProgress {
                stage: stage.into(),
                completed,
                total,
                current_path,
                http_events,
            };
        }
    }

    pub fn report_http(&self, summary: impl Into<String>) {
        if let Ok(mut progress) = self.progress.lock() {
            let summary = summary.into();
            progress.http_events.push(summary);
        }
    }

    pub fn snapshot(&self) -> OrgRepoSyncProgress {
        self.progress
            .lock()
            .map(|value| value.clone())
            .unwrap_or_default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OrgRepoSyncLifecycle {
    Idle,
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgRepoSyncSnapshot<C = serde_json::Value, F = serde_json::Value> {
    pub lifecycle: OrgRepoSyncLifecycle,
    pub progress: OrgRepoSyncProgress,
    pub latest_record: Option<OrgRepoSyncRecord<C, F>>,
}

impl<C: Default, F: Default> Default for OrgRepoSyncSnapshot<C, F> {
    fn default() -> Self {
        Self {
            lifecycle: OrgRepoSyncLifecycle::Idle,
            progress: OrgRepoSyncProgress::default(),
            latest_record: None,
        }
    }
}

/// core 持有仓库与 policy，并提供启动、停止和快照读取接口。
pub struct OrgRepoSyncController<P: SyncPolicy> {
    repo: Arc<Mutex<OrgRepo>>,
    history: Arc<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>>,
    policy: Arc<P>,
    snapshot: Arc<Mutex<OrgRepoSyncSnapshot<P::ContextDetail, P::FileDetail>>>,
    cancellation: Arc<Mutex<Option<SyncCancellation>>>,
}

impl<P> OrgRepoSyncController<P>
where
    P: SyncPolicy + 'static,
{
    pub fn new(
        repo: OrgRepo,
        history: Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>,
        policy: P,
    ) -> Self {
        Self {
            repo: Arc::new(Mutex::new(repo)),
            history: Arc::new(history),
            policy: Arc::new(policy),
            snapshot: Arc::new(Mutex::new(OrgRepoSyncSnapshot::default())),
            cancellation: Arc::new(Mutex::new(None)),
        }
    }

    pub async fn start(&self, started_at: TimestampMs) -> Result<(), CoreError> {
        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| CoreError::InvalidState("同步状态锁不可用"))?;
        if matches!(
            snapshot.lifecycle,
            OrgRepoSyncLifecycle::Running | OrgRepoSyncLifecycle::Cancelling
        ) {
            return Err(CoreError::InvalidState("同步正在运行"));
        }
        let cancellation = SyncCancellation::default();
        let progress = SyncProgressReporter::default();
        snapshot.lifecycle = OrgRepoSyncLifecycle::Running;
        snapshot.progress = progress.snapshot();
        drop(snapshot);
        *self
            .cancellation
            .lock()
            .map_err(|_| CoreError::InvalidState("同步取消锁不可用"))? = Some(cancellation.clone());

        let initial_repo = self
            .repo
            .lock()
            .map_err(|_| CoreError::InvalidState("仓库锁不可用"))?
            .clone();
        let repo = Arc::clone(&self.repo);
        let policy = Arc::clone(&self.policy);
        let history = Arc::clone(&self.history);
        let state = Arc::clone(&self.snapshot);
        let active = Arc::clone(&self.cancellation);
        tokio::spawn(async move {
            let mut working_repo = initial_repo;
            let result = working_repo
                .sync(
                    policy.as_ref(),
                    &history,
                    started_at,
                    &cancellation,
                    &progress,
                )
                .await;
            if let Ok(mut stored_repo) = repo.lock() {
                *stored_repo = working_repo;
            }
            if let Ok(mut snapshot) = state.lock() {
                snapshot.progress = progress.snapshot();
                snapshot.latest_record = match &result {
                    Ok(record) => Some(record.clone()),
                    Err(_) => None,
                };
                snapshot.lifecycle = match result {
                    Ok(record) if record.result == Some(crate::OrgRepoSyncResult::Cancelled) => {
                        OrgRepoSyncLifecycle::Cancelled
                    }
                    Ok(record)
                        if matches!(
                            record.result,
                            Some(
                                crate::OrgRepoSyncResult::Failed
                                    | crate::OrgRepoSyncResult::Interrupted
                            )
                        ) =>
                    {
                        OrgRepoSyncLifecycle::Failed
                    }
                    Ok(_) => OrgRepoSyncLifecycle::Succeeded,
                    Err(_) => OrgRepoSyncLifecycle::Failed,
                };
            }
            if let Ok(mut active) = active.lock() {
                *active = None;
            }
        });
        Ok(())
    }

    pub fn cancel(&self) -> Result<(), CoreError> {
        let cancellation = self
            .cancellation
            .lock()
            .map_err(|_| CoreError::InvalidState("同步取消锁不可用"))?
            .clone()
            .ok_or(CoreError::InvalidState("当前没有运行中的同步"))?;
        cancellation.cancel();
        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| CoreError::InvalidState("同步状态锁不可用"))?;
        snapshot.lifecycle = OrgRepoSyncLifecycle::Cancelling;
        Ok(())
    }

    pub fn snapshot(&self) -> OrgRepoSyncSnapshot<P::ContextDetail, P::FileDetail> {
        self.snapshot
            .lock()
            .map(|value| value.clone())
            .unwrap_or_default()
    }

    pub fn repo(&self) -> Option<OrgRepo> {
        self.repo.lock().ok().map(|value| value.clone())
    }
}

pub trait OrgRepoSyncRecordStore: Send {
    fn append(
        &mut self,
        repo_id: &OrgRepoId,
        record: OrgRepoSyncRecord,
    ) -> impl Future<Output = Result<(), CoreError>> + Send;

    fn list(
        &self,
        repo_id: &OrgRepoId,
        limit: usize,
    ) -> impl Future<Output = Result<Vec<OrgRepoSyncRecord>, CoreError>> + Send;
}

impl OrgRepo {
    /// 初始化仓库标识并扫描本地根目录，生成完整文件快照。
    pub async fn load<P: SyncPolicy>(
        &mut self,
    ) -> Result<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>, CoreError> {
        self.id = load_or_create_repo_id(Path::new(&self.root_directory)).await?;
        let history = load_sync_history::<P>(Path::new(&self.root_directory)).await?;
        let sources = scan_org_files(Path::new(&self.root_directory)).await?;
        let mut files = Vec::with_capacity(sources.len());
        for source in sources {
            let file = self.parse_file(source.path, source.source_bytes)?;
            if files
                .iter()
                .any(|existing: &OrgFile| existing.path == file.path)
            {
                return Err(CoreError::InvalidState("扫描结果包含重复文件路径"));
            }
            files.push(file);
        }
        self.pending_writes().await?;
        self.files = files;
        Ok(history)
    }

    pub(crate) fn parse_file(
        &self,
        path: String,
        source_bytes: Vec<u8>,
    ) -> Result<OrgFile, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        if !self.contains_path(&path) {
            return Err(CoreError::InvalidInput("扫描结果包含非法文件路径"));
        }
        OrgFile::new(self.id.clone(), path, source_bytes)
    }

    /// 执行同步策略，并将已完成的记录追加到仓库历史。
    pub async fn sync<P>(
        &mut self,
        policy: &P,
        history: &[OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>],
        started_at: TimestampMs,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>, CoreError>
    where
        P: SyncPolicy,
    {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        let mut context = SyncContext::new(self, started_at);
        let mut record = policy
            .synchronize(&mut context, history, cancellation, progress)
            .await?;
        if record.kind.is_empty() {
            record.kind = P::KIND.into();
        }
        if record.kind != P::KIND {
            return Err(CoreError::InvalidState("同步记录 kind 与策略不一致"));
        }
        if record.finished_at.is_none() || record.result.is_none() {
            return Err(CoreError::InvalidState(
                "同步策略必须返回当前仓库已完成的同步记录",
            ));
        }
        if history.iter().any(|existing| existing.id == record.id) {
            return Err(CoreError::InvalidState("同步记录 ID 已存在"));
        }
        persist_sync_record(Path::new(&self.root_directory), &record).await?;
        for file in &record.files {
            if file.state == super::OrgRepoSyncFileState::Synchronized
                && file.action == super::OrgRepoSyncFileAction::Deleted
            {
                self.acknowledge_deleted_write(&file.relative_path).await?;
                continue;
            }
            if file.state == super::OrgRepoSyncFileState::Synchronized
                && let Some(version) = &file.local_version
            {
                self.acknowledge_write(&file.relative_path, version).await?;
            }
        }
        Ok(record)
    }
}

async fn load_or_create_repo_id(root: &Path) -> Result<OrgRepoId, CoreError> {
    if !fs::metadata(root)
        .await
        .map(|metadata| metadata.is_dir())
        .unwrap_or(false)
    {
        return Err(CoreError::Store("仓库根目录不存在或不是目录".into()));
    }
    let control_directory = root.join(".sync");
    fs::create_dir_all(&control_directory)
        .await
        .map_err(|error| CoreError::Store(format!("无法创建 .sync 目录: {error}")))?;
    let id_path = control_directory.join("id");
    match read_repo_id(&id_path).await {
        Ok(id) => Ok(id),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let id = generate_repo_id()?;
            let mut file = match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&id_path)
                .await
            {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    return read_repo_id(&id_path).await.map_err(repo_id_read_error);
                }
                Err(error) => return Err(repo_id_write_error(error)),
            };
            file.write_all(format!("{id}\n").as_bytes())
                .await
                .map_err(repo_id_write_error)?;
            file.sync_all().await.map_err(repo_id_write_error)?;
            Ok(id)
        }
        Err(error) => Err(repo_id_read_error(error)),
    }
}

async fn read_repo_id(path: &Path) -> Result<OrgRepoId, std::io::Error> {
    let contents = fs::read_to_string(path).await?;
    let Some(id) = contents.strip_suffix('\n') else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            ".sync/id 必须以换行结束",
        ));
    };
    if id.contains('\n') || !is_uuid(id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            ".sync/id 不是合法 UUID",
        ));
    }
    Ok(id.to_owned())
}

async fn load_sync_history<P: SyncPolicy>(
    root: &Path,
) -> Result<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>, CoreError> {
    let history_directory = root.join(".sync/history");
    fs::create_dir_all(&history_directory)
        .await
        .map_err(|error| CoreError::Store(format!("无法创建 .sync/history 目录: {error}")))?;
    let mut entries = fs::read_dir(&history_directory)
        .await
        .map_err(|error| CoreError::Store(format!("无法读取 .sync/history 目录: {error}")))?;
    let mut records = Vec::new();
    while let Some(entry) = entries
        .next_entry()
        .await
        .map_err(|error| CoreError::Store(format!("无法读取同步历史目录项: {error}")))?
    {
        let path = entry.path();
        let metadata = entry
            .metadata()
            .await
            .map_err(|error| CoreError::Store(format!("无法读取同步历史文件属性: {error}")))?;
        if !metadata.is_file() || path.extension().and_then(|value| value.to_str()) != Some("json")
        {
            continue;
        }
        let started_at = path
            .file_stem()
            .and_then(|value| value.to_str())
            .and_then(|value| value.parse::<TimestampMs>().ok())
            .ok_or_else(|| CoreError::Store("同步历史文件名必须是开始时间戳".into()))?;
        let source = fs::read(&path)
            .await
            .map_err(|error| CoreError::Store(format!("无法读取同步历史文件: {error}")))?;
        let record: OrgRepoSyncRecord<P::ContextDetail, P::FileDetail> =
            serde_json::from_slice(&source)
                .map_err(|_| CoreError::Store("同步历史 JSON 无效".into()))?;
        if record.kind != P::KIND {
            return Err(CoreError::Store("同步历史 kind 与策略不一致".into()));
        }
        if record.started_at != started_at
            || record.finished_at.is_none()
            || record.result.is_none()
            || records.iter().any(
                |existing: &OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>| {
                    existing.id == record.id || existing.started_at == record.started_at
                },
            )
        {
            return Err(CoreError::Store("同步历史记录无效或重复".into()));
        }
        records.push(record);
    }
    records.sort_by_key(|record| record.started_at);
    Ok(records)
}

async fn persist_sync_record<C, F>(
    root: &Path,
    record: &OrgRepoSyncRecord<C, F>,
) -> Result<(), CoreError>
where
    C: SyncContextDetail,
    F: SyncFileDetail,
{
    if record.finished_at.is_none() || record.result.is_none() {
        return Err(CoreError::InvalidState("未完成的同步记录不能持久化"));
    }
    let history_directory = root.join(".sync/history");
    fs::create_dir_all(&history_directory)
        .await
        .map_err(|error| CoreError::Store(format!("无法创建 .sync/history 目录: {error}")))?;
    let target = history_directory.join(format!("{}.json", record.started_at));
    if fs::try_exists(&target)
        .await
        .map_err(|error| CoreError::Store(format!("无法检查同步历史文件: {error}")))?
    {
        return Err(CoreError::Store("同步历史开始时间戳已存在".into()));
    }
    let temporary = history_directory.join(format!(".{}.tmp", generate_repo_id()?));
    let source = serde_json::to_vec(record)
        .map_err(|_| CoreError::Store("无法序列化同步历史记录".into()))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .await
        .map_err(|error| CoreError::Store(format!("无法创建同步历史临时文件: {error}")))?;
    file.write_all(&source)
        .await
        .map_err(|error| CoreError::Store(format!("无法写入同步历史临时文件: {error}")))?;
    file.sync_all()
        .await
        .map_err(|error| CoreError::Store(format!("无法刷新同步历史临时文件: {error}")))?;
    fs::rename(&temporary, &target)
        .await
        .map_err(|error| CoreError::Store(format!("无法提交同步历史记录: {error}")))?;
    Ok(())
}

pub(super) fn generate_repo_id() -> Result<OrgRepoId, CoreError> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| CoreError::Store("无法生成仓库 ID".into()))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    ))
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            matches!(index, 8 | 13 | 18 | 23) && byte == b'-'
                || !matches!(index, 8 | 13 | 18 | 23) && byte.is_ascii_hexdigit()
        })
}

fn repo_id_read_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法读取 .sync/id: {error}"))
}

fn repo_id_write_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法写入 .sync/id: {error}"))
}

async fn scan_org_files(root: &Path) -> Result<Vec<OrgRepoSourceFile>, CoreError> {
    let mut files = Vec::new();
    let mut directories = vec![std::path::PathBuf::new()];
    while let Some(relative) = directories.pop() {
        let mut entries = fs::read_dir(root.join(&relative))
            .await
            .map_err(|error| CoreError::Store(format!("无法读取仓库目录: {error}")))?;
        while let Some(entry) = entries
            .next_entry()
            .await
            .map_err(|error| CoreError::Store(format!("无法读取仓库目录项: {error}")))?
        {
            let name = entry.file_name();
            let child = relative.join(&name);
            let metadata = fs::symlink_metadata(entry.path())
                .await
                .map_err(|error| CoreError::Store(format!("无法读取仓库文件属性: {error}")))?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                if relative.as_os_str().is_empty() && name == ".sync" {
                    continue;
                }
                directories.push(child);
            } else if metadata.is_file()
                && child.extension().and_then(|value| value.to_str()) == Some("org")
            {
                let path = relative_path(&child)?;
                let source_bytes = fs::read(entry.path())
                    .await
                    .map_err(|error| CoreError::Store(format!("无法读取 org 文件: {error}")))?;
                files.push(OrgRepoSourceFile::new(path, source_bytes)?);
            }
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(files)
}

fn relative_path(path: &Path) -> Result<String, CoreError> {
    let value = path
        .to_str()
        .ok_or(CoreError::InvalidInput("文件路径必须是 UTF-8"))?
        .replace(std::path::MAIN_SEPARATOR, "/");
    if value.starts_with(".sync/") {
        return Err(CoreError::InvalidInput(".sync 不属于仓库内容"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OrgRepoSyncResult;
    use std::time::Duration;

    struct CompletedSync;

    impl SyncPolicy for CompletedSync {
        const KIND: &'static str = "test";
        type ContextDetail = serde_json::Value;
        type FileDetail = serde_json::Value;

        fn synchronize(
            &self,
            context: &mut SyncContext<'_>,
            _: &[OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>],
            _: &SyncCancellation,
            _: &SyncProgressReporter,
        ) -> impl Future<
            Output = Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError>,
        > + Send {
            let mut record =
                OrgRepoSyncRecord::new("sync-1".into(), context.started_at).expect("记录应有效");
            assert_eq!(
                context.base,
                std::path::PathBuf::from(&context.repo.root_directory)
            );
            record
                .finish(OrgRepoSyncResult::Succeeded, context.started_at + 1)
                .expect("记录应完成");
            async move { Ok(record) }
        }
    }

    struct FailedSync;

    impl SyncPolicy for FailedSync {
        const KIND: &'static str = "test";
        type ContextDetail = serde_json::Value;
        type FileDetail = serde_json::Value;

        fn synchronize(
            &self,
            context: &mut SyncContext<'_>,
            _: &[OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>],
            _: &SyncCancellation,
            _: &SyncProgressReporter,
        ) -> impl Future<
            Output = Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError>,
        > + Send {
            let mut record = OrgRepoSyncRecord::new("failed-sync-1".into(), context.started_at)
                .expect("记录应有效");
            record
                .finish(OrgRepoSyncResult::Failed, context.started_at + 1)
                .expect("记录应完成");
            async move { Ok(record) }
        }
    }

    #[tokio::test]
    async fn repo_loads_local_org_files() {
        let root = std::env::temp_dir().join(format!("org-tasks-core-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), b"plain text\n").unwrap();
        std::fs::write(root.join("ignored.txt"), b"ignored\n").unwrap();
        std::fs::create_dir(root.join(".sync")).unwrap();
        std::fs::write(root.join(".sync/history.org"), b"hidden\n").unwrap();

        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let history = repo.load::<CompletedSync>().await.unwrap();
        assert!(history.is_empty());
        assert_eq!(repo.files()[0].path, "inbox.org");
        let initial_id = repo.id.clone();

        let mut reloaded_repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        reloaded_repo.load::<CompletedSync>().await.unwrap();
        assert_eq!(reloaded_repo.id, initial_id);
        assert_eq!(
            std::fs::read_to_string(root.join(".sync/id")).unwrap(),
            format!("{initial_id}\n")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parser_preserves_orgize_headline_structure() {
        use orgize::SyntaxKind;
        use orgize::rowan::ast::AstNode;

        let file = OrgFile::new(
            "repo-1".into(),
            "inbox.org".into(),
            b"* TODO [#A] Parent :work:urgent:\n** DONE Child\n* Plain heading\n".to_vec(),
        )
        .unwrap();
        let document = file.syntax().document();
        let syntax = document.syntax();
        assert_eq!(
            syntax
                .descendants()
                .filter(|node| node.kind() == SyntaxKind::HEADLINE)
                .count(),
            3
        );
        assert_eq!(file.syntax().to_org().as_bytes(), file.source_bytes());
    }

    #[tokio::test]
    async fn repo_sync_appends_completed_record() {
        let root = test_root("sync");
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let history = repo.load::<CompletedSync>().await.unwrap();
        let record = repo
            .sync(
                &CompletedSync,
                &history,
                10,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await
            .unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert!(
            tokio::fs::try_exists(root.join(".sync/history/10.json"))
                .await
                .unwrap()
        );
        let mut reloaded_repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        reloaded_repo.load::<CompletedSync>().await.unwrap();
        assert_eq!(
            reloaded_repo.load::<CompletedSync>().await.unwrap(),
            vec![record]
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn controller_exposes_completed_sync_snapshot() {
        let root = test_root("controller");
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let history = repo.load::<CompletedSync>().await.unwrap();
        let controller = OrgRepoSyncController::new(repo, history, CompletedSync);
        controller.start(10).await.unwrap();
        for _ in 0..100 {
            let snapshot = controller.snapshot();
            if snapshot.lifecycle == OrgRepoSyncLifecycle::Succeeded {
                assert_eq!(
                    snapshot.latest_record.unwrap().result,
                    Some(OrgRepoSyncResult::Succeeded)
                );
                std::fs::remove_dir_all(root).unwrap();
                return;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        panic!("同步控制器未在预期时间内完成");
    }

    #[tokio::test]
    async fn controller_exposes_failed_sync_snapshot() {
        let root = test_root("failed-controller");
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let history = repo.load::<CompletedSync>().await.unwrap();
        let controller = OrgRepoSyncController::new(repo, history, FailedSync);
        controller.start(10).await.unwrap();
        for _ in 0..100 {
            let snapshot = controller.snapshot();
            if snapshot.lifecycle == OrgRepoSyncLifecycle::Failed {
                assert_eq!(
                    snapshot.latest_record.unwrap().result,
                    Some(OrgRepoSyncResult::Failed)
                );
                std::fs::remove_dir_all(root).unwrap();
                return;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        panic!("同步控制器未在预期时间内失败");
    }

    #[tokio::test]
    async fn repo_rejects_history_kind_mismatch() {
        let root = test_root("kind-mismatch");
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        let mut record = OrgRepoSyncRecord::<serde_json::Value, serde_json::Value>::new(
            "kind-mismatch-record".into(),
            10,
        )
        .unwrap()
        .with_kind("other");
        record.finish(OrgRepoSyncResult::Succeeded, 11).unwrap();
        tokio::fs::write(
            root.join(".sync/history/10.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .await
        .unwrap();

        let mut reloaded = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let error = reloaded.load::<CompletedSync>().await.unwrap_err();
        assert!(error.to_string().contains("kind 与策略不一致"));
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    fn test_root(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-core-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }
}
