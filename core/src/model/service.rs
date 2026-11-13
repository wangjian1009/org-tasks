use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use orgize::rowan::ast::AstNode;
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;

use super::{OrgFile, OrgRepo, OrgRepoId, OrgRepoSyncRecord};
use crate::{CoreError, TimestampMs};

struct OrgRepoSourceFile {
    pub path: String,
    pub source_bytes: Vec<u8>,
    pub modified_at: Option<TimestampMs>,
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
        Ok(Self {
            path,
            source_bytes,
            modified_at: None,
        })
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
    pub options: SyncOptions,
}

impl<'a> SyncContext<'a> {
    pub fn new(repo: &'a mut OrgRepo, started_at: TimestampMs) -> Self {
        Self::with_options(repo, started_at, SyncOptions::default())
    }

    pub fn with_options(
        repo: &'a mut OrgRepo,
        started_at: TimestampMs,
        options: SyncOptions,
    ) -> Self {
        Self {
            base: PathBuf::from(&repo.root_directory),
            repo,
            started_at,
            options,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct SyncOptions {
    pub excluded_directories: Vec<String>,
    pub trigger_reason: SyncTriggerReason,
}

/// 宿主发起本轮同步的原因，与同步策略和执行结果独立。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncTriggerReason {
    AppStartup,
    AppBackground,
    #[default]
    Manual,
}

pub fn default_sync_options() -> SyncOptions {
    SyncOptions::default()
}

impl Default for SyncOptions {
    fn default() -> Self {
        Self {
            excluded_directories: vec!["archive".into()],
            trigger_reason: SyncTriggerReason::Manual,
        }
    }
}

impl SyncOptions {
    pub fn normalized(mut self) -> Result<Self, CoreError> {
        self.excluded_directories = self
            .excluded_directories
            .into_iter()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .collect();
        for value in &self.excluded_directories {
            if value.contains('/')
                || value.contains('\\')
                || value == "."
                || value == ".."
                || value.chars().any(char::is_control)
            {
                return Err(CoreError::InvalidInput("过滤目录必须是单个相对目录名"));
            }
        }
        self.excluded_directories.sort();
        self.excluded_directories.dedup();
        Ok(self)
    }

    pub fn excludes_path(&self, path: &str) -> bool {
        path.rsplit_once('/').is_some_and(|(directories, _)| {
            directories.split('/').any(|component| {
                self.excluded_directories
                    .iter()
                    .any(|item| item == component)
            })
        })
    }
}

#[cfg(test)]
mod sync_options_tests {
    use super::{SyncOptions, SyncTriggerReason};

    #[test]
    fn trigger_reason_uses_stable_wire_values_and_rejects_unknown_values() {
        for (trigger_reason, value) in [
            (SyncTriggerReason::AppStartup, "appStartup"),
            (SyncTriggerReason::AppBackground, "appBackground"),
            (SyncTriggerReason::Manual, "manual"),
        ] {
            let options: SyncOptions = serde_json::from_value(serde_json::json!({
                "triggerReason": value,
            }))
            .unwrap();
            assert_eq!(options.trigger_reason, trigger_reason);
            assert_eq!(
                serde_json::to_value(options).unwrap()["triggerReason"],
                value
            );
        }
        assert!(serde_json::from_str::<SyncOptions>(r#"{"triggerReason":"scheduled"}"#).is_err());
    }

    #[test]
    fn default_and_directory_component_filtering() {
        let options = SyncOptions::default();
        assert!(options.excludes_path("archive/home.org"));
        assert!(options.excludes_path("work/archive/old/home.org"));
        assert!(!options.excludes_path("work/archive.org"));
        assert!(!options.excludes_path("archive"));
        assert!(!options.excludes_path("archives/home.org"));
        assert!(!options.excludes_path("Archive/home.org"));
        assert!(!options.excludes_path("home.org"));
    }

    #[test]
    fn missing_options_use_defaults_but_empty_list_disables_filtering() {
        assert_eq!(
            serde_json::from_str::<SyncOptions>("{}").unwrap(),
            SyncOptions::default()
        );
        let empty: SyncOptions = serde_json::from_str(r#"{"excludedDirectories":[]}"#).unwrap();
        assert!(!empty.excludes_path("archive/home.org"));
        let normalized = SyncOptions {
            excluded_directories: vec![
                " archive ".into(),
                "".into(),
                "archive".into(),
                "私有".into(),
            ],
            ..SyncOptions::default()
        }
        .normalized()
        .unwrap();
        assert_eq!(normalized.excluded_directories, ["archive", "私有"]);
        for value in ["/archive", "../archive", "a/b", "a\\b", ".", "..", "a\0b"] {
            assert!(
                SyncOptions {
                    excluded_directories: vec![value.into()],
                    ..SyncOptions::default()
                }
                .normalized()
                .is_err()
            );
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
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> impl Future<
        Output = Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError>,
    > + Send;

    /// 仓库已持久化完成记录并释放锁后调用；默认不处理，不得在此修改同步结果。
    fn on_record_persisted(
        &self,
        _record: &OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>,
    ) {
    }
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
    policy: Arc<P>,
    snapshot: Arc<Mutex<OrgRepoSyncSnapshot<P::ContextDetail, P::FileDetail>>>,
    cancellation: Arc<Mutex<Option<SyncCancellation>>>,
}

impl<P> OrgRepoSyncController<P>
where
    P: SyncPolicy + 'static,
{
    pub fn new(repo: OrgRepo, policy: P) -> Self {
        Self {
            repo: Arc::new(Mutex::new(repo)),
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
        let state = Arc::clone(&self.snapshot);
        let active = Arc::clone(&self.cancellation);
        tokio::spawn(async move {
            let mut working_repo = initial_repo;
            let result = working_repo
                .sync(policy.as_ref(), started_at, &cancellation, &progress)
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
    pub(crate) async fn sync_history<P: SyncPolicy>(
        &self,
    ) -> Result<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>, CoreError> {
        load_sync_history::<P>(Path::new(&self.root_directory)).await
    }

    /// 只恢复稳定身份；不检查控制标记或加载业务内容。
    pub async fn load<P: SyncPolicy>(
        &mut self,
    ) -> Result<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>, CoreError> {
        let _guard = crate::webdav::transaction::lock(Path::new(&self.root_directory)).await?;
        self.id = load_or_create_repo_id(Path::new(&self.root_directory)).await?;
        Ok(Vec::new())
    }

    /// 本次操作独立拥有文件集合；相对路径在读取正文之前排除，不写入仓库缓存。
    pub async fn load_files(&self, ignore_files: &[String]) -> Result<Vec<OrgFile>, CoreError> {
        validate_ignored_files(ignore_files)?;
        let _guard = super::access::enter(Path::new(&self.root_directory), &self.id).await?;
        self.load_files_unlocked(ignore_files).await
    }

    pub(crate) async fn load_files_unlocked(
        &self,
        ignore_files: &[String],
    ) -> Result<Vec<OrgFile>, CoreError> {
        self.load_files_in_unlocked(ignore_files, None).await
    }

    pub(crate) async fn load_files_in_unlocked(
        &self,
        ignore_files: &[String],
        included_files: Option<&std::collections::BTreeSet<String>>,
    ) -> Result<Vec<OrgFile>, CoreError> {
        validate_ignored_files(ignore_files)?;
        if let Some(paths) = included_files {
            for path in paths {
                super::validate_relative_path(path)?;
            }
        }
        #[cfg(test)]
        super::test_support::record_access(Path::new(&self.root_directory), 1);
        let root = Path::new(&self.root_directory);
        let rules = super::TaskScanRules::load(root).await?;
        let sources = scan_org_files(root, ignore_files, included_files).await?;
        let mut setup_cache = sources
            .iter()
            .map(|source| (source.path.clone(), Some(source.source_bytes.clone())))
            .collect();
        let mut files = Vec::with_capacity(sources.len());
        for source in sources {
            let setup = load_setup_settings_cached(
                root,
                &source.path,
                &source.source_bytes,
                &mut setup_cache,
            )
            .await?;
            let mut file = self.parse_file_with_setup(source.path, source.source_bytes, setup)?;
            file.modified_at = source.modified_at;
            file.scan_ignored = rules.excludes(&file.path);
            files.push(file);
        }
        Ok(files)
    }

    /// 指定文件按需读盘；不存在时返回未落盘的空值对象，供新增读取默认元信息。
    pub async fn file(&self, path: &str) -> Result<OrgFile, CoreError> {
        if !self.contains_path(path) || path.split('/').any(|part| part == ".sync") {
            return Err(CoreError::InvalidInput("Org 文件路径无效"));
        }
        let _guard = super::access::enter(Path::new(&self.root_directory), &self.id).await?;
        self.file_unlocked(path).await
    }

    pub(crate) async fn file_unlocked(&self, path: &str) -> Result<OrgFile, CoreError> {
        let root = Path::new(&self.root_directory);
        let source = crate::webdav::transaction::read(root, path)
            .await?
            .unwrap_or_default();
        let setup = load_setup_settings(root, path, &source).await?;
        let mut file = self.parse_file_with_setup(path.into(), source, setup)?;
        file.scan_ignored = super::TaskScanRules::load(root).await?.excludes(path);
        file.modified_at = fs::metadata(root.join(path))
            .await
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|time| chrono::DateTime::<chrono::Utc>::from(time).timestamp_millis());
        Ok(file)
    }

    pub(crate) fn parse_file(
        &self,
        path: String,
        source_bytes: Vec<u8>,
    ) -> Result<OrgFile, CoreError> {
        self.parse_file_with_setup(path, source_bytes, String::new())
    }

    pub(crate) fn parse_file_with_setup(
        &self,
        path: String,
        source_bytes: Vec<u8>,
        setup_settings: String,
    ) -> Result<OrgFile, CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        if !self.contains_path(&path) {
            return Err(CoreError::InvalidInput("扫描结果包含非法文件路径"));
        }
        OrgFile::with_todo_defaults_and_setup(
            self.id.clone(),
            path,
            source_bytes,
            self.todo_defaults.clone(),
            setup_settings,
        )
    }

    /// 自行恢复当前仓库与历史，执行策略并追加本次记录。
    pub async fn sync<P>(
        &mut self,
        policy: &P,
        started_at: TimestampMs,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>, CoreError>
    where
        P: SyncPolicy,
    {
        self.sync_with_options(
            policy,
            started_at,
            cancellation,
            progress,
            SyncOptions::default(),
        )
        .await
    }

    pub async fn sync_with_options<P>(
        &mut self,
        policy: &P,
        started_at: TimestampMs,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
        options: SyncOptions,
    ) -> Result<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>, CoreError>
    where
        P: SyncPolicy,
    {
        let options = options.normalized()?;
        let guard = crate::webdav::transaction::lock(Path::new(&self.root_directory)).await?;
        let root_directory = self.root_directory.clone();
        let id = load_or_create_repo_id(Path::new(&root_directory)).await?;
        if !self.id.is_empty() && self.id != id {
            return Err(CoreError::InvalidState("仓库身份已改变，请重新打开"));
        }
        self.id = id;
        super::access::recover(Path::new(&root_directory), &self.id).await?;
        let history = self.sync_history::<P>().await?;
        if history.iter().any(|record| record.started_at == started_at) {
            return Err(CoreError::InvalidInput("同步开始时间已有同步记录"));
        }
        let session = crate::webdav::session::Session::begin(
            Path::new(&root_directory),
            &self.id,
            started_at,
        )
        .await?;
        drop(guard);
        let completion_notice = super::sync_events::CompletionNotice::new(self);
        let slot = crate::webdav::transaction::CommitSlot::new(
            Path::new(&self.root_directory),
            started_at,
        );
        let trigger_reason = options.trigger_reason;
        let mut context = SyncContext::with_options(self, started_at, options);
        let mut record = policy
            .synchronize(&mut context, cancellation, progress)
            .await?;
        drop(context);
        record.trigger_reason = Some(trigger_reason);
        let guard = crate::webdav::session::enter(
            Path::new(&root_directory),
            &self.id,
            started_at,
            crate::webdav::session::Phase::Committing,
        )
        .await?;
        let pending_commit = slot.take();
        drop(slot);
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
        let root = Path::new(&self.root_directory);
        let committed_transaction = pending_commit.is_some();
        if let Some(mut plan) = pending_commit {
            if record.result != Some(super::OrgRepoSyncResult::Succeeded) {
                return Err(CoreError::InvalidState("失败同步不能包含本地提交"));
            }
            let history_path = format!(".sync/history/{}.json", record.started_at);
            if crate::webdav::transaction::read(root, &history_path)
                .await?
                .is_some()
            {
                return Err(CoreError::InvalidState("同步历史开始时间已存在"));
            }
            plan.set(
                root,
                history_path,
                Some(
                    serde_json::to_vec(&record)
                        .map_err(|_| CoreError::InvalidState("无法编码同步记录"))?,
                ),
            )
            .await?;
            plan.commit(root).await?;
        } else {
            persist_sync_record(root, &record).await?;
        }
        for file in &record.files {
            if committed_transaction {
                break;
            }
            // 忽略配置没有任务编辑产生的 outbox，也不属于 Org 文件快照。
            if file.relative_path == super::TASK_SCAN_RULES_PATH {
                continue;
            }
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
        drop(guard);
        // 正式结果已持久化；收尾失败留下标记由下一次访问恢复，不推翻提交结果。
        let _ = session.finish().await;
        drop(completion_notice);
        progress.report("Finished", record.files.len(), record.files.len(), None);
        policy.on_record_persisted(&record);

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

pub(crate) async fn read_repo_id(path: &Path) -> Result<OrgRepoId, std::io::Error> {
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

pub(crate) fn generate_repo_id() -> Result<OrgRepoId, CoreError> {
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

async fn scan_org_files(
    root: &Path,
    ignore_files: &[String],
    included_files: Option<&std::collections::BTreeSet<String>>,
) -> Result<Vec<OrgRepoSourceFile>, CoreError> {
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
                if name == ".sync" {
                    continue;
                }
                directories.push(child);
            } else if metadata.is_file()
                && child.extension().and_then(|value| value.to_str()) == Some("org")
            {
                let path = relative_path(&child)?;
                if ignore_files.iter().any(|ignored| ignored == &path)
                    || included_files.is_some_and(|files| !files.contains(&path))
                {
                    continue;
                }
                let source_bytes = fs::read(entry.path())
                    .await
                    .map_err(|error| CoreError::Store(format!("无法读取 org 文件: {error}")))?;
                let mut file = OrgRepoSourceFile::new(path, source_bytes)?;
                file.modified_at = metadata
                    .modified()
                    .ok()
                    .map(|time| chrono::DateTime::<chrono::Utc>::from(time).timestamp_millis());
                files.push(file);
            }
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(files)
}

pub(crate) async fn load_setup_settings(
    root: &Path,
    source_path: &str,
    source_bytes: &[u8],
) -> Result<String, CoreError> {
    load_setup_settings_cached(root, source_path, source_bytes, &mut Default::default()).await
}

async fn load_setup_settings_cached(
    root: &Path,
    source_path: &str,
    source_bytes: &[u8],
    cache: &mut std::collections::BTreeMap<String, Option<Vec<u8>>>,
) -> Result<String, CoreError> {
    let mut settings = Vec::new();
    let mut pending = vec![(PathBuf::from(source_path), source_bytes.to_vec())];
    let mut visited = std::collections::BTreeSet::new();
    while let Some((current_path, current_bytes)) = pending.pop() {
        let current_dir = current_path.parent().unwrap_or_else(|| Path::new(""));
        for (key, value) in file_keywords(&current_bytes)? {
            if matches!(
                key.as_str(),
                "TODO" | "SEQ_TODO" | "TYP_TODO" | "TASK_STATE_CATEGORY" | "STARTUP" | "PROPERTY" | "PRIORITIES"
            ) {
                settings.push(format!("#+{key}: {value}"));
                continue;
            }
            if key != "SETUPFILE" {
                continue;
            }
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .unwrap_or(value);
            let value = value.strip_prefix("file:").unwrap_or(value).trim();
            let relative = Path::new(value);
            if relative.is_absolute()
                || relative
                    .components()
                    .any(|component| matches!(component, std::path::Component::ParentDir))
            {
                continue;
            }
            let setup_path = current_dir.join(relative);
            let setup_path = setup_path
                .components()
                .filter(|part| !matches!(part, std::path::Component::CurDir))
                .collect::<PathBuf>();
            let normalized = setup_path
                .to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/");
            if normalized.split('/').any(|part| part == ".sync")
                || !visited.insert(normalized.clone())
            {
                continue;
            }
            if !cache.contains_key(&normalized) {
                let bytes = crate::webdav::transaction::read(root, &normalized).await?;
                cache.insert(normalized.clone(), bytes);
            }
            let Some(bytes) = &cache[&normalized] else {
                continue;
            };
            pending.push((setup_path, bytes.clone()));
        }
    }
    Ok(settings.join("\n"))
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
        assert_eq!(repo.load_files(&[]).await.unwrap()[0].path, "inbox.org");
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

    #[tokio::test]
    async fn file_metadata_contains_counts_bytes_and_disk_modification_time() {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-file-info-{}",
            generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let source = "#+TITLE: 文件信息\r\n* TODO Pending\r\n* DONE Completed\r\n* Plain\r\n";
        let path = root.join("work.org");
        fs::write(&path, source).await.unwrap();
        let modified = std::time::UNIX_EPOCH + Duration::from_millis(1_700_000_000_123);
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(modified))
            .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        let info = &crate::model::test_support::query_files(&repo)
            .await
            .unwrap()[0];
        assert_eq!(info.task_state_counts, vec![
            crate::TaskStateCount { state: "TODO".into(), category: Some(crate::TaskStateCategory::Todo), count: 1 },
            crate::TaskStateCount { state: "DONE".into(), category: Some(crate::TaskStateCategory::Done), count: 1 },
        ]);
        assert!(!info.is_ignore);
        assert_eq!(info.byte_length, source.len());
        assert_eq!(info.modified_at, Some(1_700_000_000_123));
        assert_eq!(
            repo.file("work.org").await.unwrap().modified_at,
            info.modified_at
        );
        repo.set_todo_defaults(crate::TodoConfig::default())
            .unwrap();
        assert_eq!(
            crate::model::test_support::query_files(&repo)
                .await
                .unwrap()[0]
                .modified_at,
            info.modified_at
        );
        fs::write(root.join(".orgzlyignore"), "work.org\n")
            .await
            .unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        let ignored = &crate::model::test_support::query_files(&repo)
            .await
            .unwrap()[0];
        assert!(ignored.task_state_counts.is_empty());
        assert!(ignored.is_ignore);
        assert_eq!(ignored.byte_length, source.len());
        assert_eq!(ignored.modified_at, Some(1_700_000_000_123));
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn repo_loads_todo_states_from_setupfile_for_each_org_file() {
        let root = std::env::temp_dir().join(format!("org-tasks-setupfile-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join(".setup.org"),
            b"#+TODO: TODO(t) NEXT(n) WAIT(w) STOP | DONE(d!)\n#+TODO: | CNCL(c!)\n#+TASK_STATE_CATEGORY: Cancel STOP\n",
        )
        .unwrap();
        std::fs::write(
            root.join("inbox.org"),
            b"#+SETUPFILE: ./.setup.org\n* TODO Pending\n* CNCL Cancelled\n* STOP Custom cancelled\n",
        )
        .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        let tasks = crate::filter::tasks_from_repo(&repo).await.unwrap();
        assert_eq!(tasks[0].state_type, crate::filter::FilterStateType::Todo);
        assert_eq!(tasks[1].state_type, crate::filter::FilterStateType::Done);
        assert!(tasks[2].is_done());
        assert_eq!(
            tasks[2].state().and_then(|state| state.category),
            Some(crate::TaskStateCategory::Cancel)
        );
        assert_eq!(
            repo.load_files(&[]).await.unwrap()[0].todo.done_keywords,
            ["STOP", "DONE", "CNCL"]
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn task_ignore_is_repo_local_reloadable_and_keeps_complete_file_snapshots() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-ignore-{}", generate_repo_id().unwrap()));
        fs::create_dir_all(root.join("private")).await.unwrap();
        for (path, source) in [
            ("visible.org", "#+CATEGORY: Work\n* TODO Visible\n"),
            (
                "hidden.org",
                "#+CATEGORY: Hidden\n* TODO Hidden\n** TODO Child\n",
            ),
            ("private/old.org", "* TODO Private\n"),
            ("private/keep.org", "* TODO Keep\n"),
        ] {
            fs::write(root.join(path), source).await.unwrap();
        }
        fs::write(
            root.join(".orgzlyignore"),
            "hidden.org\nprivate/\n!private/keep.org\n",
        )
        .await
        .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        assert_eq!(repo.load_files(&[]).await.unwrap().len(), 4);
        assert!(
            repo.file("hidden.org")
                .await
                .unwrap()
                .source_bytes()
                .starts_with(b"#+CATEGORY")
        );
        let other_root = root.with_extension("other");
        fs::create_dir(&other_root).await.unwrap();
        fs::write(other_root.join("hidden.org"), "* TODO Other repository\n")
            .await
            .unwrap();
        let mut other = OrgRepo::new(other_root.to_string_lossy().into()).unwrap();
        other.load::<CompletedSync>().await.unwrap();
        let mut workspace = crate::OrgWorkspace::new(vec![repo, other]).unwrap();
        let result = workspace
            .query(&[(crate::TaskQuery::default()).into()])
            .await
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap();
        assert_eq!(result.tasks.len(), 3);
        assert!(
            result
                .tasks
                .iter()
                .all(|task| !["Hidden", "Child", "Private"].contains(&task.title.as_str()))
        );
        assert!(
            result
                .categories
                .iter()
                .all(|category| category.category.as_deref() != Some("Hidden"))
        );
        assert_eq!(
            workspace
                .query(&[(crate::TaskQuery {
                    expression: "\"Hidden\"".into(),
                    ..Default::default()
                })
                .into()])
                .await
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks,
            []
        );

        // 规则变更与删除在下一次 load 生效；已有完整字节不受影响。
        let repo = &mut workspace.repos[0];
        let original = repo
            .file("hidden.org")
            .await
            .unwrap()
            .source_bytes()
            .to_vec();
        fs::write(root.join(".orgzlyignore"), "visible.org\n")
            .await
            .unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        assert!(
            crate::filter::tasks_from_repo(repo)
                .await
                .unwrap()
                .iter()
                .all(|task| task.path() != "visible.org")
        );
        assert!(
            crate::filter::tasks_from_repo(repo)
                .await
                .unwrap()
                .iter()
                .any(|task| task.title == "Hidden")
        );
        fs::remove_file(root.join(".orgzlyignore")).await.unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        let count = crate::filter::tasks_from_repo(repo).await.unwrap().len();
        assert_eq!(count, 5);
        assert_eq!(fs::read(root.join("hidden.org")).await.unwrap(), original);

        // 无效配置明确失败，不能静默伪装为空任务集合。
        fs::write(root.join(".orgzlyignore"), [0xff]).await.unwrap();
        repo.load::<CompletedSync>().await.unwrap();
        assert!(crate::filter::tasks_from_repo(repo).await.is_err());
        fs::write(root.join(".orgzlyignore"), b"").await.unwrap();
        assert_eq!(
            crate::filter::tasks_from_repo(repo).await.unwrap().len(),
            count
        );
        fs::remove_dir_all(root).await.unwrap();
        fs::remove_dir_all(other_root).await.unwrap();
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
        let record = repo
            .sync(
                &CompletedSync,
                10,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await
            .unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(record.trigger_reason, Some(SyncTriggerReason::Manual));
        assert!(
            tokio::fs::try_exists(root.join(".sync/history/10.json"))
                .await
                .unwrap()
        );
        let mut reloaded_repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        reloaded_repo.load::<CompletedSync>().await.unwrap();
        assert_eq!(
            reloaded_repo.sync_history::<CompletedSync>().await.unwrap(),
            vec![record]
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn sync_trigger_reason_survives_failure_and_history_reload() {
        for trigger_reason in [
            SyncTriggerReason::AppStartup,
            SyncTriggerReason::AppBackground,
            SyncTriggerReason::Manual,
        ] {
            let root = test_root(&format!("sync-trigger-{trigger_reason:?}"));
            let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            let record = repo
                .sync_with_options(
                    &FailedSync,
                    10,
                    &SyncCancellation::default(),
                    &SyncProgressReporter::default(),
                    SyncOptions {
                        trigger_reason,
                        ..SyncOptions::default()
                    },
                )
                .await
                .unwrap();
            assert_eq!(record.result, Some(OrgRepoSyncResult::Failed));
            assert_eq!(record.trigger_reason, Some(trigger_reason));
            let reloaded = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            assert_eq!(
                reloaded.sync_history::<FailedSync>().await.unwrap(),
                vec![record]
            );
            std::fs::remove_dir_all(root).unwrap();
        }
    }

    #[tokio::test]
    async fn controller_exposes_completed_sync_snapshot() {
        let root = test_root("controller");
        let repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let controller = OrgRepoSyncController::new(repo, CompletedSync);
        controller.start(10).await.unwrap();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while tokio::time::Instant::now() < deadline {
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
        let repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let controller = OrgRepoSyncController::new(repo, FailedSync);
        controller.start(10).await.unwrap();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while tokio::time::Instant::now() < deadline {
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
        tokio::fs::create_dir_all(root.join(".sync/history"))
            .await
            .unwrap();
        tokio::fs::write(
            root.join(".sync/history/10.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .await
        .unwrap();

        let mut reloaded = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        reloaded.load::<CompletedSync>().await.unwrap();
        let error = reloaded
            .sync(
                &CompletedSync,
                20,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await
            .unwrap_err();
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
    struct HistoryReadingSync;

    impl SyncPolicy for HistoryReadingSync {
        const KIND: &'static str = "test";
        type ContextDetail = serde_json::Value;
        type FileDetail = serde_json::Value;

        async fn synchronize(
            &self,
            context: &mut SyncContext<'_>,
            _: &SyncCancellation,
            _: &SyncProgressReporter,
        ) -> Result<OrgRepoSyncRecord<Self::ContextDetail, Self::FileDetail>, CoreError> {
            let history = context.repo.sync_history::<Self>().await.unwrap();
            assert_eq!(history.len(), context.started_at as usize);
            if context.started_at == 1 {
                assert_eq!(
                    context.repo.load_files(&[]).await.unwrap()[0].source_bytes(),
                    b"* TODO External edit\n"
                );
                assert_eq!(history[0].id, "history-0");
            }
            let mut record = OrgRepoSyncRecord::new(
                format!("history-{}", context.started_at),
                context.started_at,
            )?;
            record.finish(OrgRepoSyncResult::Succeeded, context.started_at + 1)?;
            Ok(record)
        }
    }

    #[tokio::test]
    async fn repeated_controller_syncs_restore_latest_history_and_external_file_edits_internally() {
        let root = test_root("controller-history");
        let repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        let controller = OrgRepoSyncController::new(repo, HistoryReadingSync);
        for time in [0, 1] {
            if time == 1 {
                tokio::fs::write(root.join("inbox.org"), b"* TODO External edit\n")
                    .await
                    .unwrap();
            }
            controller.start(time).await.unwrap();
            let mut completed = false;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            while tokio::time::Instant::now() < deadline {
                let snapshot = controller.snapshot();
                if snapshot.lifecycle == OrgRepoSyncLifecycle::Succeeded {
                    assert_eq!(
                        snapshot.latest_record.unwrap().id,
                        format!("history-{time}")
                    );
                    completed = true;
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            assert!(completed, "同步控制器没有使用正确历史完成同步");
        }
        let mut repo = controller.repo().unwrap();
        assert_eq!(
            repo.sync_history::<HistoryReadingSync>()
                .await
                .unwrap()
                .len(),
            2
        );
        assert!(
            repo.sync(
                &HistoryReadingSync,
                1,
                &SyncCancellation::default(),
                &SyncProgressReporter::default()
            )
            .await
            .is_err()
        );
        tokio::fs::write(root.join(".sync/history/2.json"), b"{")
            .await
            .unwrap();
        assert!(
            repo.sync(
                &HistoryReadingSync,
                2,
                &SyncCancellation::default(),
                &SyncProgressReporter::default()
            )
            .await
            .is_err()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}

fn validate_ignored_files(paths: &[String]) -> Result<(), CoreError> {
    for path in paths {
        super::validate_relative_path(path)?;
        if Path::new(path).is_absolute() || path.split('/').any(|part| part == ".sync") {
            return Err(CoreError::InvalidInput(
                "排除文件必须是当前仓库的安全相对路径",
            ));
        }
    }
    Ok(())
}

pub(crate) fn file_keywords(source: &[u8]) -> Result<Vec<(String, String)>, CoreError> {
    let source = std::str::from_utf8(source)
        .map_err(|_| CoreError::InvalidInput("Org 与 SETUPFILE 内容必须是 UTF-8"))?;
    let syntax = orgize::Org::parse(source);
    Ok(syntax
        .document()
        .syntax()
        .descendants()
        .filter_map(orgize::ast::Keyword::cast)
        .filter(|keyword| !keyword.key().eq_ignore_ascii_case("PRIORITIES") ||
            syntax.document().keywords().any(|header| header.start() == keyword.start()))
        .map(|keyword| {
            (
                keyword.key().to_ascii_uppercase(),
                keyword.value().trim().to_owned(),
            )
        })
        .collect())
}
