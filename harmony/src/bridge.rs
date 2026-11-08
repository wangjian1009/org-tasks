use std::collections::BTreeMap;
use std::ffi::CString;
use std::sync::{Arc, Mutex, OnceLock};

use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavError, WebDavMergeComparison, WebDavSyncEvent, WebDavSyncMonitor,
    WebDavSyncPolicy,
};
use org_tasks_core::{
    CoreError, Filter, FilterTask, NewTask, OrgRepo, OrgRepoSyncResult, OrgWorkspace,
    SyncCancellation, SyncOptions, SyncProgressReporter, TimestampMs,
};
use serde::Serialize;

struct WorkspaceSession {
    workspace: Arc<Mutex<OrgWorkspace>>,
    references: usize,
}

#[derive(Default)]
struct WorkspaceSessions {
    next_handle: u64,
    sessions: BTreeMap<u64, WorkspaceSession>,
}

static WORKSPACE_SESSIONS: OnceLock<Mutex<WorkspaceSessions>> = OnceLock::new();

fn workspace_sessions() -> &'static Mutex<WorkspaceSessions> {
    WORKSPACE_SESSIONS.get_or_init(|| Mutex::new(WorkspaceSessions::default()))
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeRepository {
    pub id: String,
    pub files: Vec<HarmonyBridgeFile>,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeFile {
    #[serde(rename = "repoId")]
    pub repo_id: String,
    pub path: String,
    pub source: String,
    pub byte_length: usize,
    pub todo: org_tasks_core::TodoMetadata,
    pub category: Option<String>,
    #[serde(rename = "fileVersion")]
    pub file_version: String,
    pub title: Option<String>,
    #[serde(rename = "titleParts")]
    pub title_parts: Vec<org_tasks_core::TitlePart>,
    #[serde(rename = "renderedHtml")]
    pub rendered_html: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarmonyBridgeTask {
    pub id: String,
    pub source: org_tasks_core::TaskSource,
    pub repo_id: String,
    pub heading: String,
    pub category: Option<String>,
    // 包含 Core 生成的链接与分数计数；保留原始 heading 供复制、路由和查询。
    pub heading_parts: Vec<org_tasks_core::TitlePart>,
    pub todo_state: String,
    pub todo_kind: Option<org_tasks_core::TodoStateKind>,
    pub is_done: bool,
    pub is_cancelled: bool,
    pub created_at: Option<TimestampMs>,
    pub priority: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub body: String,
    #[serde(rename = "addressLinks")]
    pub address_links: Vec<org_tasks_core::filter::AddressLink>,
    pub body_html: String,
    pub logbook_html: String,
    pub progress: i32,
    pub has_list: bool,
    pub has_text: bool,
    pub is_repeating: bool,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSync {
    pub id: String,
    pub result: String,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub files: usize,
    #[serde(rename = "downloadedFiles")]
    pub downloaded_files: usize,
    #[serde(rename = "uploadedFiles")]
    pub uploaded_files: usize,
    pub conflicts: Vec<String>,
    #[serde(rename = "executionResult")]
    pub execution_result: String,
    pub transfer: org_tasks_core::webdav::WebDavSyncTransfer,
    #[serde(rename = "pendingConflicts")]
    pub pending_conflicts: usize,
    #[serde(rename = "resolvedConflicts")]
    pub resolved_conflicts: usize,
    #[serde(rename = "errorCategory")]
    pub error_category: Option<org_tasks_core::OrgRepoSyncErrorCategory>,
    #[serde(rename = "errorMessage")]
    pub error_message: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSyncDetail {
    pub summary: HarmonyBridgeSync,
    pub files: Vec<org_tasks_core::webdav::WebDavSyncFileSummary>,
    pub errors: Vec<org_tasks_core::webdav::WebDavSyncHistoryError>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum HarmonyBridgeWebDavSyncEvent {
    Started {
        repo_id: String,
    },
    ListingStarted,
    Listed {
        files: usize,
    },
    FileStarted {
        path: String,
        index: usize,
        total: usize,
    },
    FileProcessed {
        path: String,
        action: String,
        state: String,
    },
    HttpRequest {
        method: String,
        path: String,
    },
    HttpResponse {
        method: String,
        path: String,
        status: Option<u16>,
    },
    Finished {
        result: String,
        files: usize,
    },
}

#[derive(Clone, Copy)]
struct HarmonyWebDavSyncMonitor {
    handle: u64,
}

#[cfg(not(test))]
unsafe extern "C" {
    fn org_tasks_harmony_webdav_sync_monitor_event(
        handle: u64,
        event_json: *const std::ffi::c_char,
    );
}

fn report_webdav_sync_event(handle: u64, event: &CString) {
    #[cfg(not(test))]
    unsafe {
        org_tasks_harmony_webdav_sync_monitor_event(handle, event.as_ptr());
    }
    #[cfg(test)]
    let _ = (handle, event);
}

impl WebDavSyncMonitor for HarmonyWebDavSyncMonitor {
    fn on_event(&self, event: WebDavSyncEvent) {
        let event = match event {
            WebDavSyncEvent::Started { repo_id } => {
                HarmonyBridgeWebDavSyncEvent::Started { repo_id }
            }
            WebDavSyncEvent::ListingStarted => HarmonyBridgeWebDavSyncEvent::ListingStarted,
            WebDavSyncEvent::Listed { files } => HarmonyBridgeWebDavSyncEvent::Listed { files },
            WebDavSyncEvent::FileStarted { path, index, total } => {
                HarmonyBridgeWebDavSyncEvent::FileStarted { path, index, total }
            }
            WebDavSyncEvent::FileProcessed { record } => {
                HarmonyBridgeWebDavSyncEvent::FileProcessed {
                    path: record.relative_path,
                    action: format!("{:?}", record.action),
                    state: format!("{:?}", record.state),
                }
            }
            WebDavSyncEvent::HttpRequest { method, path } => {
                HarmonyBridgeWebDavSyncEvent::HttpRequest { method, path }
            }
            WebDavSyncEvent::HttpResponse {
                method,
                path,
                status,
            } => HarmonyBridgeWebDavSyncEvent::HttpResponse {
                method,
                path,
                status,
            },
            WebDavSyncEvent::Finished { result, files } => HarmonyBridgeWebDavSyncEvent::Finished {
                result: sync_result_label(Some(result)).unwrap_or_else(|_| "failed".into()),
                files,
            },
        };
        let Ok(event) = serde_json::to_string(&event) else {
            return;
        };
        let Ok(event) = CString::new(event) else {
            return;
        };
        report_webdav_sync_event(self.handle, &event);
    }
}

fn task_snapshot(
    workspace: &OrgWorkspace,
    filter: &Filter,
) -> Result<Vec<HarmonyBridgeTask>, CoreError> {
    Ok(workspace
        .search(filter)
        .into_iter()
        .map(|task| task_from_filter(task, workspace))
        .collect::<Result<Vec<_>, _>>()?)
}

fn task_from_filter(task: FilterTask, workspace: &OrgWorkspace) -> Result<HarmonyBridgeTask, CoreError> {
    let source = workspace.task_source_for(&task)?;
    let is_done = task.is_done();
    let is_cancelled = task.is_cancelled();
    let heading_parts = task.title_parts();
    let content = task.render_content();
    let mut tags = task.own_tags;
    for inherited in task.inherited_tags {
        if !tags.contains(&inherited) {
            tags.push(inherited);
        }
    }
    Ok(HarmonyBridgeTask {
        source,
        id: task.id,
        repo_id: task.repo_id,
        heading: task.title,
        category: task.category,
        heading_parts,
        todo_state: task.state.unwrap_or_default(),
        todo_kind: match task.state_type {
            org_tasks_core::FilterStateType::Todo => Some(org_tasks_core::TodoStateKind::Pending),
            org_tasks_core::FilterStateType::Done => Some(org_tasks_core::TodoStateKind::Done),
            _ => None,
        },
        is_done,
        is_cancelled,
        created_at: task.created_at,
        priority: task.priority.unwrap_or_default(),
        scheduled: task
            .scheduled
            .map(|date| date.date.to_string())
            .unwrap_or_default(),
        deadline: task
            .deadline
            .map(|date| date.date.to_string())
            .unwrap_or_default(),
        tags,
        file_name: task.path.rsplit('/').next().unwrap_or(&task.path).into(),
        file_path: task.path,
        level: task.level,
        body: task.body,
        address_links: task.address_links,
        body_html: content.body_html,
        logbook_html: content.logbook_html,
        progress: -1,
        has_list: content.has_list,
        has_text: content.has_text,
        is_repeating: task.is_repeating,
    })
}

/// 创建持久的空 workspace session。仓库必须经 add_repo 后再 load。
pub fn create_workspace() -> Result<u64, CoreError> {
    let workspace = OrgWorkspace::new(Vec::new())?;
    let mut sessions = workspace_sessions()
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace session 锁不可用".into()))?;
    sessions.next_handle = sessions
        .next_handle
        .checked_add(1)
        .ok_or(CoreError::InvalidState("workspace handle 已耗尽"))?;
    let handle = sessions.next_handle;
    sessions.sessions.insert(
        handle,
        WorkspaceSession {
            workspace: Arc::new(Mutex::new(workspace)),
            references: 1,
        },
    );
    Ok(handle)
}

pub fn retain_workspace(handle: u64) -> Result<(), CoreError> {
    let mut sessions = workspace_sessions()
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace session 锁不可用".into()))?;
    let session = sessions
        .sessions
        .get_mut(&handle)
        .ok_or(CoreError::InvalidInput("workspace handle 无效"))?;
    session.references = session
        .references
        .checked_add(1)
        .ok_or(CoreError::InvalidState("workspace 引用已耗尽"))?;
    Ok(())
}

pub fn release_workspace(handle: u64) {
    if let Ok(mut sessions) = workspace_sessions().lock() {
        if let Some(session) = sessions.sessions.get_mut(&handle) {
            session.references = session.references.saturating_sub(1);
            if session.references == 0 {
                sessions.sessions.remove(&handle);
            }
        }
    }
}

pub fn workspace_repo_roots(handle: u64) -> Result<Vec<String>, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    Ok(workspace
        .repos()
        .iter()
        .map(|repo| repo.root_directory.clone())
        .collect())
}

pub fn workspace_remove_repo(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    workspace.remove_repo_by_root_directory(&root_directory)?;
    Ok(())
}

pub fn workspace_add_repo(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let repository = OrgRepo::new(root_directory)?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    workspace.add_repo(repository)
}

pub fn repo_load(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repository.load::<WebDavSyncPolicy>())?;
    Ok(())
}

/// 读取仓库已完成的同步记录。历史由 core 从 `.sync/history` 恢复，宿主只接收展示投影。
pub fn repo_history_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let history = runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    encode(
        &org_tasks_core::webdav::sync_history_summaries(&history)?
            .into_iter()
            .map(bridge_sync_summary)
            .collect::<Result<Vec<_>, CoreError>>()?,
    )
}

pub fn repo_history_detail_json(
    handle: u64,
    root_directory: String,
    sync_id: String,
) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let history = runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    let detail = org_tasks_core::webdav::sync_history_detail(&history, &sync_id)?;
    encode(&HarmonyBridgeSyncDetail {
        summary: bridge_sync_summary(detail.summary)?,
        files: detail.files,
        errors: detail.errors,
    })
}

pub fn repo_create_task(
    handle: u64,
    root_directory: String,
    path: String,
    task_json: String,
    queue_upload: bool,
) -> Result<(), CoreError> {
    let task: NewTask = serde_json::from_str(&task_json)
        .map_err(|_| CoreError::InvalidInput("任务创建参数无效"))?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repository.load::<WebDavSyncPolicy>())?;
    runtime.block_on(repository.create_task(&path, &task, queue_upload))
}

pub fn repo_create_task_at_top(
    handle: u64,
    root_directory: String,
    path: String,
    task_json: String,
    queue_upload: bool,
) -> Result<(), CoreError> {
    let task: NewTask = serde_json::from_str(&task_json)
        .map_err(|_| CoreError::InvalidInput("任务创建参数无效"))?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repository.load::<WebDavSyncPolicy>())?;
    runtime.block_on(repository.create_task_at_top(&path, &task, queue_upload))
}

pub fn repo_update_task_location(
    handle: u64,
    root_directory: String,
    path: String,
    heading: String,
    old_uri: String,
    new_uri: String,
    queue_upload: bool,
) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace.repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repository.load::<WebDavSyncPolicy>())?;
    let task = runtime.block_on(repository.update_task_location(&path, &heading, &old_uri, &new_uri, queue_upload))?;
    let task = task_from_filter(task, &workspace)?;
    serde_json::to_string(&task)
        .map_err(|_| CoreError::InvalidState("无法序列化更新后的任务"))
}

pub fn repo_id(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    Ok(repository.id.clone())
}

pub fn workspace_search_json(handle: u64, expression: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos {
        runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    }
    encode(&task_snapshot(&workspace, &Filter::parse(&expression))?)
}

pub fn workspace_query_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let query: org_tasks_core::TaskQuery = serde_json::from_str(&query_json)
        .map_err(|_| CoreError::InvalidInput("任务查询参数无效"))?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos {
        runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    }
    let result = workspace.query(&query)?;
    encode(&serde_json::json!({
        "tasks": result.tasks.into_iter().map(|task| task_from_filter(task, &workspace)).collect::<Result<Vec<_>, _>>()?,
        "categories": result.categories,
    }))
}

pub fn repo_sync_json(
    workspace_handle: u64,
    root_directory: String,
    webdav_url: String,
    username: String,
    password: String,
    options_json: String,
    monitor_handle: u64,
    started_at: TimestampMs,
) -> Result<String, CoreError> {
    let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(webdav_url)?, username, password)?;
    let policy = if monitor_handle == 0 {
        policy
    } else {
        policy.with_monitor(HarmonyWebDavSyncMonitor {
            handle: monitor_handle,
        })
    };
    let workspace = workspace_for_handle(workspace_handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    let options = if options_json.trim().is_empty() {
        SyncOptions::default()
    } else {
        serde_json::from_str::<SyncOptions>(&options_json)
            .map_err(|_| CoreError::InvalidInput("同步参数无效"))?
    };
    let record = runtime.block_on(repository.sync_with_options(
        &policy,
        started_at,
        &SyncCancellation::default(),
        &SyncProgressReporter::default(),
        options,
    ))?;
    encode(&bridge_sync_summary(
        org_tasks_core::webdav::WebDavSyncRecordSummary::from_record(&record)?,
    )?)
}

fn bridge_sync_summary(
    summary: org_tasks_core::webdav::WebDavSyncRecordSummary,
) -> Result<HarmonyBridgeSync, CoreError> {
    Ok(HarmonyBridgeSync {
        id: summary.id,
        result: sync_result_label(Some(summary.result))?,
        execution_result: sync_result_label(Some(summary.execution_result))?,
        started_at: summary.started_at,
        finished_at: summary.finished_at,
        files: summary.files,
        downloaded_files: summary.downloaded_files,
        uploaded_files: summary.uploaded_files,
        conflicts: summary.conflicts,
        transfer: summary.transfer,
        pending_conflicts: summary.pending_conflicts,
        resolved_conflicts: summary.resolved_conflicts,
        error_category: summary.error_category,
        error_message: summary.error_message,
    })
}

pub fn repo_snapshot_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let mut files = Vec::with_capacity(repository.files().len());
    for file in repository.files() {
        files.push(file_snapshot(file)?);
    }
    encode(&HarmonyBridgeRepository {
        id: repository.id.clone(),
        files,
    })
}

pub fn repo_file_metadata_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repo.load::<WebDavSyncPolicy>())?;
    encode(&repo.file_metadata())
}

fn file_snapshot(file: &org_tasks_core::OrgFile) -> Result<HarmonyBridgeFile, CoreError> {
    Ok(HarmonyBridgeFile {
        repo_id: file.repo_id.clone(),
        path: file.path.clone(),
        source: std::str::from_utf8(file.source_bytes())
            .map_err(|_| CoreError::InvalidState("已加载 Org 文件不是 UTF-8"))?
            .into(),
        byte_length: file.source_bytes().len(),
        file_version: org_tasks_core::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        todo: file.todo.clone(),
        category: file.category(),
        title: file.title(),
        title_parts: file.title_parts(),
        rendered_html: file.render_html(),
    })
}

fn workspace_for_handle(handle: u64) -> Result<Arc<Mutex<OrgWorkspace>>, CoreError> {
    let sessions = workspace_sessions()
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace session 锁不可用".into()))?;
    sessions
        .sessions
        .get(&handle)
        .map(|session| Arc::clone(&session.workspace))
        .ok_or(CoreError::InvalidInput("workspace handle 无效"))
}

fn runtime() -> Result<tokio::runtime::Runtime, CoreError> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| CoreError::Store(format!("无法创建 Harmony runtime: {error}")))
}

pub fn test_webdav_connection(
    url: String,
    username: String,
    password: String,
) -> Result<(), CoreError> {
    let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(url)?, username, password)?;
    runtime()?
        .block_on(policy.test_connection())
        .map_err(|error| match error {
            WebDavError::Authentication(_) => {
                CoreError::InvalidInput("WebDAV 认证或访问被拒绝，请检查用户名、密码和目录权限")
            }
            WebDavError::Network(_) | WebDavError::Tls(_) => {
                CoreError::InvalidState("WebDAV 连接失败或超时，请检查网络、地址和服务器证书")
            }
            WebDavError::Protocol(_) | WebDavError::Conflict(_) => {
                CoreError::InvalidState("WebDAV 目录检查失败，请确认地址指向支持 WebDAV 的目录")
            }
        })
}

fn encode<T: Serialize>(value: &T) -> Result<String, CoreError> {
    serde_json::to_string(value)
        .map_err(|error| CoreError::Store(format!("无法编码 Harmony bridge 响应: {error}")))
}

fn sync_result_label(result: Option<OrgRepoSyncResult>) -> Result<String, CoreError> {
    match result {
        Some(OrgRepoSyncResult::Succeeded) => Ok("succeeded".into()),
        Some(OrgRepoSyncResult::Failed) => Ok("failed".into()),
        Some(OrgRepoSyncResult::Cancelled) => Ok("cancelled".into()),
        Some(OrgRepoSyncResult::Interrupted) => Ok("interrupted".into()),
        None => Err(CoreError::InvalidState("同步记录尚未完成")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_history_projects_conflict_resolution_without_rewriting_original_results() {
        use org_tasks_core::webdav::{WebDavSyncContextDetail, WebDavSyncFileDetail};
        use org_tasks_core::{
            OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState, OrgRepoSyncRecord,
        };
        let root =
            std::env::temp_dir().join(format!("org-tasks-history-summary-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let directory = root.to_string_lossy().to_string();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory.clone()).unwrap();
        let mut conflict = OrgRepoSyncRecord::<WebDavSyncContextDetail, WebDavSyncFileDetail>::new(
            "conflict".into(),
            10,
        )
        .unwrap()
        .with_kind("webdav");
        for path in ["a.org", "b.org"] {
            conflict
                .append_file(
                    OrgRepoSyncFileRecord::new(
                        path.into(),
                        OrgRepoSyncFileAction::Conflicted,
                        OrgRepoSyncFileState::Conflict,
                    )
                    .unwrap(),
                )
                .unwrap();
        }
        conflict.finish(OrgRepoSyncResult::Failed, 11).unwrap();
        let original = serde_json::to_vec(&conflict).unwrap();
        std::fs::write(root.join(".sync/history/10.json"), &original).unwrap();
        let mut resolved = OrgRepoSyncRecord::<WebDavSyncContextDetail, WebDavSyncFileDetail>::new(
            "resolved".into(),
            20,
        )
        .unwrap()
        .with_kind("webdav");
        resolved
            .append_file(
                OrgRepoSyncFileRecord::new(
                    "a.org".into(),
                    OrgRepoSyncFileAction::Downloaded,
                    OrgRepoSyncFileState::Synchronized,
                )
                .unwrap(),
            )
            .unwrap();
        resolved.finish(OrgRepoSyncResult::Succeeded, 21).unwrap();
        std::fs::write(
            root.join(".sync/history/20.json"),
            serde_json::to_vec(&resolved).unwrap(),
        )
        .unwrap();
        let history: serde_json::Value =
            serde_json::from_str(&repo_history_json(handle, directory.clone()).unwrap()).unwrap();
        assert_eq!(history[0]["result"], "failed");
        assert_eq!(history[0]["executionResult"], "succeeded");
        assert_eq!(history[0]["transfer"], "unchanged");
        assert_eq!(history[0]["pendingConflicts"], 1);
        assert_eq!(history[0]["resolvedConflicts"], 1);
        assert!(history[0]["errorCategory"].is_null());
        assert_eq!(history[1]["transfer"], "download");
        assert_eq!(history[1]["downloadedFiles"], 1);
        assert_eq!(history[1]["uploadedFiles"], 0);
        let detail: serde_json::Value = serde_json::from_str(
            &repo_history_detail_json(handle, directory.clone(), "conflict".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(detail["summary"]["pendingConflicts"], 1);
        assert_eq!(detail["files"][0]["outcome"], "resolved");
        assert_eq!(detail["files"][1]["outcome"], "conflict");
        assert_eq!(detail["errors"].as_array().unwrap().len(), 0);
        assert!(repo_history_detail_json(handle, directory.clone(), "missing".into()).is_err());
        assert_eq!(
            std::fs::read(root.join(".sync/history/10.json")).unwrap(),
            original
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn lightweight_file_metadata_reloads_titles_without_full_content() {
        let root = std::env::temp_dir().join(format!("org-tasks-metadata-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("work.org"), "#+TITLE: 工作计划\n* TODO Task\n").unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let metadata: serde_json::Value =
            serde_json::from_str(&repo_file_metadata_json(handle, directory.clone()).unwrap())
                .unwrap();
        assert_eq!(metadata[0]["title"], "工作计划");
        assert_eq!(metadata[0]["path"], "work.org");
        assert_eq!(metadata[0]["isIgnore"], false);
        assert!(metadata[0].get("source").is_none());
        assert!(metadata[0].get("renderedHtml").is_none());
        let full: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "work.org".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(full["title"], metadata[0]["title"]);
        assert!(
            full["renderedHtml"]
                .as_str()
                .unwrap()
                .contains("todo pending")
        );
        std::fs::write(root.join("work.org"), "#+TITLE:\n").unwrap();
        let changed: serde_json::Value =
            serde_json::from_str(&repo_file_metadata_json(handle, directory).unwrap()).unwrap();
        assert_eq!(changed[0]["title"], "");
        std::fs::write(root.join(".orgzlyignore"), "work.org\n").unwrap();
        let ignored: serde_json::Value = serde_json::from_str(
            &repo_file_metadata_json(handle, root.to_string_lossy().into()).unwrap(),
        )
        .unwrap();
        assert_eq!(ignored[0]["isIgnore"], true);
        assert_eq!(ignored[0]["taskCount"], 0);
        assert_eq!(metadata[0]["title"], "工作计划");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn category_is_nullable_in_file_snapshot_and_accessor() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-category-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("work.org"), "#+CATEGORY: 工作\n* TODO Task\n").unwrap();
        std::fs::write(root.join("empty.org"), "#+CATEGORY:\n").unwrap();
        std::fs::write(root.join("missing-category.org"), "* Task\n").unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        for (path, expected) in [
            ("work.org", serde_json::json!("工作")),
            ("empty.org", serde_json::json!("")),
            ("missing-category.org", serde_json::Value::Null),
        ] {
            let category: serde_json::Value = serde_json::from_str(
                &repo_file_json(handle, directory.clone(), path.into()).unwrap(),
            )
            .unwrap();
            assert_eq!(category["category"], expected);
            let snapshot: serde_json::Value =
                serde_json::from_str(&repo_snapshot_json(handle, directory.clone()).unwrap())
                    .unwrap();
            let file = snapshot["files"]
                .as_array()
                .unwrap()
                .iter()
                .find(|file| file["path"] == path)
                .unwrap();
            assert_eq!(file["category"], expected);
        }
        std::fs::write(root.join("work.org"), "#+CATEGORY: Updated\n").unwrap();
        let updated: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "work.org".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(updated["category"], "Updated");
        let absent: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "absent.org".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(absent["source"], "");
        assert!(absent["category"].is_null());
        assert!(repo_file_json(handle, directory.clone(), "../work.org".into()).is_err());
        assert!(!root.join("absent.org").exists());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn workspace_search_reloads_task_ignore_rules_before_projection() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-ignore-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("visible.org"), "* TODO Visible\n").unwrap();
        std::fs::write(root.join("ann.org"), "* TODO Announcement\n").unwrap();
        std::fs::write(root.join(".orgzlyignore"), "ann.org\n").unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory).unwrap();
        let tasks: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "".into()).unwrap()).unwrap();
        assert_eq!(tasks.as_array().unwrap().len(), 1);
        assert_eq!(tasks[0]["heading"], "Visible");
        let query = serde_json::json!({
            "expression": "s.none d.none",
            "includeDone": false,
            "includeComposeTasks": true
        })
        .to_string();
        let queried: serde_json::Value =
            serde_json::from_str(&workspace_query_json(handle, query).unwrap()).unwrap();
        assert_eq!(queried["tasks"].as_array().unwrap().len(), 1);
        assert_eq!(queried["tasks"][0]["heading"], "Visible");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn location_update_returns_a_fresh_task_for_the_editor() {
        let root = std::env::temp_dir().join(format!("org-tasks-location-editor-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("work.org"), "* TODO Visit\n[[addr:old][Place]]\n").unwrap();
        let directory = root.to_string_lossy().to_string();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let result = repo_update_task_location(handle, directory, "work.org".into(), "Visit".into(), "addr:old".into(), "geo:39.9,116.4".into(), false).unwrap();
        let task: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(task["heading"], "Visit");
        assert_eq!(task["addressLinks"][0]["uri"], "geo:39.9,116.4");
        assert!(task["bodyHtml"].as_str().unwrap().contains("geo:39.9,116.4"));
        assert_eq!(task["isDone"], false);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn task_identity_survives_remote_deletions_and_passes_through_core() {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-id-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("inbox.org");
        std::fs::write(
            &file,
            "* TODO Alpha\n* TODO Bravo\n* TODO Charlie\n* TODO Delta\n",
        )
        .unwrap();
        let root_directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root_directory.clone()).unwrap();
        let query = || -> serde_json::Value {
            serde_json::from_str(
                &workspace_query_json(handle, r#"{"expression":"b.\"inbox.org\""}"#.into())
                    .unwrap(),
            )
            .unwrap()
        };
        let before = query();
        std::fs::write(&file, "* DONE Charlie [1/1]\n新正文\n* TODO Delta\n").unwrap();
        let after = query();
        assert_eq!(after["tasks"].as_array().unwrap().len(), 2);
        assert_eq!(before["tasks"][2]["id"], after["tasks"][0]["id"]);
        assert_eq!(before["tasks"][3]["id"], after["tasks"][1]["id"]);
        assert_ne!(before["tasks"][0]["id"], after["tasks"][0]["id"]);
        assert_eq!(after["tasks"][0]["heading"], "Charlie [1/1]");
        assert_eq!(after["tasks"][0]["todoKind"], "done");
        assert_eq!(after["tasks"][0]["body"], "新正文\n");
        assert_eq!(before["tasks"][2]["todoKind"], "pending");
        let session = workspace_for_handle(handle).unwrap();
        let core_tasks = session.lock().unwrap().search(&Filter::parse(""));
        assert_eq!(after["tasks"][0]["id"], core_tasks[0].id);
        assert_eq!(core_tasks[0].id.len(), 32);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn created_date_expression_and_cancelled_projection_cross_existing_query_bridge() {
        let root = std::env::temp_dir().join(format!("org-created-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("tasks.org"), "#+TODO: TODO | DONE CNCL\n* CNCL Cancelled\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 10:00]\n:END:\n* DONE Finished\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 11:00]\n:END:\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let all: serde_json::Value = serde_json::from_str(&workspace_query_json(handle, r#"{"expression":".o.created"}"#.into()).unwrap()).unwrap();
        let tasks = all["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["heading"], "Finished");
        assert_eq!(tasks[1]["heading"], "Cancelled");
        assert_eq!(tasks[0]["isCancelled"], false);
        assert_eq!(tasks[1]["isCancelled"], true);
        assert!(tasks[0]["createdAt"].as_i64().is_some());
        let query = serde_json::json!({ "expression": "cr.ge.-2d cr.le.today .o.created", "includeDone": true });
        let result: serde_json::Value = serde_json::from_str(&workspace_query_json(handle, query.to_string()).unwrap()).unwrap();
        // 固定样例只在其创建日期落入最近三个自然日时匹配。
        let projection = workspace_for_handle(handle).unwrap();
        let expected = projection.lock().unwrap().query(&org_tasks_core::TaskQuery {
            expression: "cr.ge.-2d cr.le.today .o.created".into(), ..Default::default()
        }).unwrap().tasks.len();
        assert_eq!(result["tasks"].as_array().unwrap().len(), expected);
        let excluded = serde_json::json!({ "excludedFiles": [{ "repoId":tasks[0]["repoId"], "path":"tasks.org" }] });
        let result: serde_json::Value = serde_json::from_str(&workspace_query_json(handle, excluded.to_string()).unwrap()).unwrap();
        assert!(result["tasks"].as_array().unwrap().is_empty());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refile_categories_and_versioned_task_edits_cross_bridge() {
        let root = std::env::temp_dir().join(format!("org-inbox-edit-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("inbox.org"),
            "* TODO Move me\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n",
        )
        .unwrap();
        std::fs::write(
            root.join("targets.org"),
            "#+CATEGORY: Work\n* Parent :REFILE:\n** Existing\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let tasks: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "".into()).unwrap()).unwrap();
        let task = tasks
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["heading"] == "Move me")
            .unwrap();
        let targets: serde_json::Value =
            serde_json::from_str(&workspace_refile_targets_json(handle).unwrap()).unwrap();
        let target = &targets[0];
        assert_eq!(target["category"], "Work");
        let request = serde_json::json!({ "source": task["source"], "destination": {
            "repoId": target["repoId"], "path": target["path"], "fileVersion": target["fileVersion"],
            "parent": target["position"], "clearTodo": false }, "queueRepoIds": [task["repoId"]] });
        workspace_edit_task(handle, request.to_string()).unwrap();
        assert!(workspace_edit_task(handle, request.to_string()).is_err());
        assert_eq!(std::fs::read_to_string(root.join("inbox.org")).unwrap(), "");
        let source = std::fs::read_to_string(root.join("targets.org")).unwrap();
        assert!(source.contains("* Parent :REFILE:\n** TODO Move me\n:PROPERTIES:\n"));
        assert!(source.ends_with(":END:\n** Existing\n"));
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn capture_creation_flag_reaches_core_and_survives_reload() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-capture-created-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let original = "* TODO Existing\n:PROPERTIES:\n:CREATED: [2020-01-02 Thu 03:04]\n:END:\n";
        std::fs::write(root.join("inbox.org"), original).unwrap();
        let directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_create_task_at_top(handle, directory.clone(), "inbox.org".into(),
            r#"{"heading":"Captured","scheduled":"","deadline":"","tags":[],"priority":"","recordCreated":true}"#.into(), true).unwrap();
        let source = std::fs::read_to_string(root.join("inbox.org")).unwrap();
        assert!(source.starts_with("* TODO Captured\n:PROPERTIES:\n:CREATED: ["));
        assert!(source.ends_with(original));
        repo_load(handle, directory.clone()).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_str(&repo_snapshot_json(handle, directory).unwrap()).unwrap();
        assert_eq!(snapshot["files"][0]["source"], source);
        let tasks: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "".into()).unwrap()).unwrap();
        let captured = tasks
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["heading"] == "Captured")
            .unwrap();
        assert_eq!(captured["bodyHtml"], "");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn repository_object_returns_core_file_snapshot() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), "* TODO bridge\n").unwrap();

        let root_directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root_directory.clone()).unwrap();
        repo_load(handle, root_directory.clone()).unwrap();
        repo_create_task(
            handle,
            root_directory.clone(),
            "inbox.org".into(),
            serde_json::to_string(&NewTask {
                heading: "created from bridge".into(),
                ..Default::default()
            })
            .unwrap(),
            true,
        )
        .unwrap();
        let tasks: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "i.todo".into()).unwrap()).unwrap();
        assert_eq!(tasks.as_array().unwrap().len(), 2);
        assert_eq!(tasks[0]["level"], 1);
        assert_eq!(
            tasks[0]["repoId"],
            repo_id(handle, root_directory.clone()).unwrap()
        );
        let response = repo_snapshot_json(handle, root_directory).unwrap();
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["files"][0]["path"], "inbox.org");
        assert_eq!(
            response["files"][0]["source"],
            "* TODO bridge\n* TODO created from bridge\n"
        );

        let second_root = root.with_extension("second");
        std::fs::create_dir_all(&second_root).unwrap();
        std::fs::write(
            second_root.join("inbox.org"),
            "* TODO other\n** TODO child\n",
        )
        .unwrap();
        let second_directory = second_root.to_string_lossy().into_owned();
        workspace_add_repo(handle, second_directory.clone()).unwrap();
        repo_load(handle, second_directory.clone()).unwrap();
        let second_id = repo_id(handle, second_directory).unwrap();
        let tasks: Vec<serde_json::Value> =
            serde_json::from_str(&workspace_search_json(handle, "".into()).unwrap()).unwrap();
        let second_tasks = tasks
            .iter()
            .filter(|task| task["repoId"] == second_id)
            .collect::<Vec<_>>();
        assert_eq!(second_tasks.len(), 2);
        assert_eq!(second_tasks[0]["filePath"], "inbox.org");
        assert_eq!(second_tasks[0]["level"], 1);
        assert_eq!(second_tasks[1]["level"], 2);
        assert_eq!(second_tasks[1]["heading"], "child");
        assert_eq!(tasks.len(), 4);

        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
        std::fs::remove_dir_all(second_root).unwrap();
    }
}

pub fn repo_conflicts_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let history = runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    encode(&org_tasks_core::webdav::conflict_syncs(&history))
}

pub fn repo_merge_json(
    handle: u64,
    root_directory: String,
    webdav_url: String,
    username: String,
    password: String,
    sync_id: String,
    comparison_json: String,
    started_at: TimestampMs,
) -> Result<String, CoreError> {
    let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(webdav_url)?, username, password)?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    let runtime = runtime()?;
    if comparison_json.is_empty() {
        // 保留 Core 的任务粒度及两端变更状态，宿主不从文件内容重算差异。
        return encode(&runtime.block_on(policy.compare_merge(repository, &sync_id))?);
    }
    let comparison: WebDavMergeComparison = serde_json::from_str(&comparison_json)
        .map_err(|_| CoreError::InvalidInput("任务合并对象无效"))?;
    let outcome = runtime.block_on(policy.apply_merge(repository, &comparison, started_at))?;
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ResultDto {
        sync_id: String,
        result: String,
        backups: Vec<org_tasks_core::webdav::WebDavMergeBackup>,
    }
    encode(&ResultDto {
        sync_id: outcome.record.id,
        result: sync_result_label(outcome.record.result)?,
        backups: outcome.backups,
    })
}

pub fn workspace_set_todo_defaults(handle: u64, settings: String) -> Result<(), CoreError> {
    let defaults = org_tasks_core::TodoConfig::from_settings(&settings)?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    workspace.set_todo_defaults(defaults)
}

pub fn repo_file_json(
    handle: u64,
    root_directory: String,
    path: String,
) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repo.load::<WebDavSyncPolicy>())?;
    encode(&file_snapshot(&repo.file(&path)?)?)
}

#[cfg(test)]
mod todo_tests {
    use super::*;

    #[test]
    fn external_defaults_and_per_file_metadata_are_projected_through_bridge() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-todo-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("global.org"), b"* OPEN Pending\n* FINISHED End\n").unwrap();
        std::fs::write(
            root.join("override.org"),
            b"#+TODO: OWN | CLOSED\n* CLOSED Done\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        workspace_set_todo_defaults(handle, "#+TODO: OPEN(o) | FINISHED(f!)".into()).unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory.clone()).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_str(&repo_snapshot_json(handle, directory.clone()).unwrap()).unwrap();
        let global = snapshot["files"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["path"] == "global.org")
            .unwrap();
        assert_eq!(global["todo"]["source"], "globalDefault");
        assert_eq!(global["todo"]["doneKeywords"][0], "FINISHED");
        let existing: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "override.org".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(existing["todo"]["source"], "inBuffer");
        assert_eq!(existing["todo"]["initialState"], "OWN");
        let missing: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "new.org".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(missing["todo"]["initialState"], "OPEN");
        let done: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "it.done".into()).unwrap())
                .unwrap();
        assert_eq!(done.as_array().unwrap().len(), 2);
        assert_eq!(done[0]["todoKind"], "done");
        assert_eq!(done[0]["isDone"], true);
        assert!(workspace_set_todo_defaults(handle, "invalid".into()).is_err());
        workspace_set_todo_defaults(handle, "#+TODO: OTHER | END".into()).unwrap();
        let done: serde_json::Value =
            serde_json::from_str(&workspace_search_json(handle, "it.done".into()).unwrap())
                .unwrap();
        assert_eq!(done.as_array().unwrap().len(), 1);
        assert_eq!(done[0]["isDone"], true);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn task_list_display_hints_are_serialized_without_parsing_in_host() {
        let mut repo = OrgRepo::new("/tmp/harmony-display-hints".into()).unwrap();
        repo.id = "display".into();
        repo.files.push(
            org_tasks_core::OrgFile::new(
                repo.id.clone(),
                "tasks.org".into(),
                b"#+CATEGORY: Work\n* TODO Task [1/2] :work:\nSCHEDULED: <2026-11-06 Fri +1d>\n- [ ] First\n"
                    .to_vec(),
            )
            .unwrap(),
        );
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let task = task_from_filter(workspace.search(&Filter::parse("")).remove(0), &workspace).unwrap();
        let value = serde_json::to_value(task).unwrap();
        assert_eq!(value["heading"], "Task [1/2]");
        assert_eq!(value["headingParts"][1]["count"]["completed"], 1);
        assert_eq!(value["headingParts"][1]["count"]["total"], 2);
        assert_eq!(value["todoKind"], "pending");
        assert_eq!(value["hasList"], true);
        assert_eq!(value["hasText"], false);
        assert_eq!(value["isRepeating"], true);
        assert_eq!(value["category"], "Work");
        assert_eq!(value["scheduled"], "2026-11-06");
        assert!(value["bodyHtml"].as_str().unwrap().contains("<ul>"));
        assert_eq!(value["tags"][0], "work");
    }
}

/// 放置目标和任务整理均由 Core 求值，bridge 只持有会话锁并调度运行时。
pub fn workspace_refile_targets_json(handle: u64) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let mut workspace = session.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos { runtime.block_on(repo.load::<WebDavSyncPolicy>())?; }
    encode(&workspace.refile_targets())
}

pub fn workspace_edit_task(handle: u64, request: String) -> Result<(), CoreError> {
    let edit: org_tasks_core::TaskEdit = serde_json::from_str(&request)
        .map_err(|_| CoreError::InvalidInput("任务整理参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    runtime()?.block_on(workspace.edit_task(&edit))
}
