use std::collections::BTreeMap;
use std::ffi::CString;
use std::sync::{Arc, Mutex, OnceLock};

use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavError, WebDavSyncEvent, WebDavSyncMonitor,
    WebDavSyncPolicy,
};
use org_tasks_core::{
    CoreError, FilterTask, OrgRepo, OrgRepoSyncResult, OrgWorkspace,
    SyncCancellation, SyncOptions, SyncProgressReporter, TimestampMs,
};
use serde::Serialize;

struct WorkspaceSession {
    workspace: Arc<Mutex<OrgWorkspace>>,
    references: usize,
    previews: BTreeMap<String,org_tasks_core::ConflictPreview>,
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
    #[serde(rename = "fullPath")]
    pub full_path: org_tasks_core::TaskPath,
    pub source: String,
    pub byte_length: usize,
    pub todo: org_tasks_core::TodoMetadata,
    #[serde(rename = "hasConflict")]
    pub has_conflict: bool,
    #[serde(rename = "conflictIds")]
    pub conflict_ids: Vec<String>,
    pub category: Option<String>,
    #[serde(rename = "fileVersion")]
    pub file_version: String,
    pub title: Option<String>,
    #[serde(rename = "titleParts")]
    pub title_parts: Vec<org_tasks_core::TitlePart>,
    #[serde(rename = "renderedHtml")]
    pub rendered_html: String,
    pub conflicts: Vec<org_tasks_core::FileConflict>,
    #[serde(rename="conflictError")]
    pub conflict_error: Option<serde_json::Value>,
    pub nodes: Vec<HarmonyBridgeTask>,
    #[serde(rename="editableNodePaths")]
    pub editable_node_paths: Vec<org_tasks_core::TaskPath>,
    #[serde(rename="insertionPositions")]
    pub insertion_positions: Vec<org_tasks_core::TaskPosition>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarmonyBridgeTask {
    pub id: String,
    pub full_path: org_tasks_core::TaskPath,
    pub task_id: Option<String>,
    pub file_version: String,
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
    pub modified_at: Option<TimestampMs>,
    pub priority: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub own_tags: Vec<String>,
    pub inherited_tags: Vec<String>,
    pub support_tags: Option<org_tasks_core::SupportTags>,
    pub edit_content: org_tasks_core::TaskEditContent,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub body: String,
    pub body_first_line: Option<String>,
    #[serde(rename = "addressLinks")]
    pub address_links: Vec<org_tasks_core::AddressLink>,
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

fn task_from_filter(
    task: FilterTask,
    workspace: &OrgWorkspace,
) -> Result<HarmonyBridgeTask, CoreError> {
    let repo_id = task.repo_id().to_owned();
    let path = task.path().to_owned();
    let file = workspace
        .repo(&repo_id)
        .and_then(|repo| repo.files().iter().find(|file| file.path == path))
        .ok_or(CoreError::InvalidState("任务文件不存在"))?;
    task_from_file(task,file)
}

fn task_from_file(task:FilterTask,file:&org_tasks_core::OrgFile)->Result<HarmonyBridgeTask,CoreError> {
    let repo_id=task.repo_id().to_owned();
    let path=task.path().to_owned();
    let file_version =
        org_tasks_core::LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
    let task_id = task.task_id().map(str::to_owned);
    let is_done = task.is_done();
    let is_cancelled = task.is_cancelled();
    let heading_parts = task.title_parts();
    let content = task.render_content();
    let edit_content = file.task_edit_content(task.full_path())?;
    let mut tags = task.own_tags().to_vec();
    for inherited in task.inherited_tags() {
        if !tags.contains(inherited) {
            tags.push(inherited.clone());
        }
    }
    Ok(HarmonyBridgeTask {
        full_path: task.full_path().clone(),
        task_id,
        file_version,
        id: task.id().to_owned(),
        repo_id,
        heading: task.title().to_owned(),
        category: task.category().map(str::to_owned),
        heading_parts,
        todo_state: task.state().unwrap_or_default().to_owned(),
        todo_kind: match task.state_type() {
            org_tasks_core::FilterStateType::Todo => Some(org_tasks_core::TodoStateKind::Pending),
            org_tasks_core::FilterStateType::Done => Some(org_tasks_core::TodoStateKind::Done),
            _ => None,
        },
        is_done,
        is_cancelled,
        created_at: task.created_at(),
        modified_at: task.modified_at(),
        priority: task.priority().unwrap_or_default().to_owned(),
        scheduled: task
            .scheduled()
            .map(|date| date.date().to_string())
            .unwrap_or_default(),
        deadline: task
            .deadline()
            .map(|date| date.date().to_string())
            .unwrap_or_default(),
        own_tags: edit_content.own_tags.clone(),
        inherited_tags: task.inherited_tags().to_vec(),
        support_tags: task.support_tags().cloned(),
        edit_content,
        tags,
        file_name: path.rsplit('/').next().unwrap_or(&path).into(),
        file_path: path,
        level: task.level(),
        body: task.body().to_owned(),
        body_first_line: task.body_first_line(),
        address_links: task.address_links().to_vec(),
        body_html: content.body_html,
        logbook_html: content.logbook_html,
        progress: -1,
        has_list: content.has_list,
        has_text: content.has_text,
        is_repeating: task.is_repeating(),
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
            previews: BTreeMap::new(),
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

pub fn repo_reset(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace.repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repository.reset())?;
    let repo_id = repository.id.clone();
    // 重置后不保留这个仓库的旧操作回退原文。
    workspace.task_operation_history.entries.retain(|entry| !entry.fallback_group.files.iter().any(|file| file.repo_id == repo_id));
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
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    encode(
        &runtime()?.block_on(repository.history_summaries())?
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
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    let detail = runtime()?.block_on(repository.history_detail(&sync_id))?;
    encode(&HarmonyBridgeSyncDetail {
        summary: bridge_sync_summary(detail.summary)?,
        files: detail.files,
        errors: detail.errors,
    })
}

pub fn repo_full_path_json(handle:u64,root_directory:String)->Result<String,CoreError>{
    let session=workspace_for_handle(handle)?;
    let workspace=session.lock().map_err(|_|CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo=workspace.repo_by_root_directory(&root_directory).ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    encode(&repo.full_path())
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


#[cfg(test)]
fn query_tasks_json(handle: u64, expression: String) -> Result<String, CoreError> {
    let response = workspace_query_json(handle, serde_json::json!({ "expression": expression }).to_string())?;
    let result: serde_json::Value = serde_json::from_str(&response).unwrap();
    encode(&result["tasks"])
}

pub fn workspace_notifications_json(handle: u64) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos {
        runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    }
    // 冲突通知的宿主定位信息随通知一次返回，展示层无需额外查询仓库列表。
    let notifications = runtime.block_on(workspace.notifications())?;
    let mut values = Vec::new();
    for notification in notifications {
        let mut value = serde_json::to_value(&notification).map_err(|_| CoreError::InvalidState("无法编码通知"))?;
        if let org_tasks_core::CoreNotification::SyncConflict(ref conflict) = notification {
            let repo = workspace.repos().iter().find(|repo| repo.id == conflict.repo_id)
                .ok_or(CoreError::InvalidState("通知所属仓库不存在"))?;
            value["rootDirectory"] = repo.root_directory.clone().into();
        }
        values.push(value);
    }
    encode(&values)
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
    let (conflicts,conflict_error)=match file.conflicts() {
        Ok(conflicts)=>(conflicts,None),
        Err(error)=>{
            let code=match &error {CoreError::InvalidInput(_)=>"invalidInput",CoreError::InvalidState(_)=>"invalidState",CoreError::Store(_)=>"store",CoreError::Preview{code,..}=>code};
            (Vec::new(),Some(serde_json::json!({"code":code,"message":error.to_string()})))
        }
    };
    Ok(HarmonyBridgeFile {
        full_path: file.full_path(),
        repo_id: file.repo_id.clone(),
        path: file.path.clone(),
        source: std::str::from_utf8(file.source_bytes())
            .map_err(|_| CoreError::InvalidState("已加载 Org 文件不是 UTF-8"))?
            .into(),
        byte_length: file.source_bytes().len(),
        file_version: org_tasks_core::LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        todo: file.todo.clone(),
        has_conflict: file.has_conflict(),
        conflict_ids: file.conflict_ids(),
        category: file.category(),
        title: file.title(),
        title_parts: file.title_parts(),
        rendered_html: file.render_html(),
        conflicts,
        conflict_error,
        nodes: file.nodes().into_iter().map(|task|task_from_file(task,file)).collect::<Result<Vec<_>,_>>()?,
        editable_node_paths: file.editable_node_paths(),
        insertion_positions:file.insertion_positions(),
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
    fn task_supported_tags_preserve_groups_empty_and_missing_configuration() {
        for (source, expected) in [
            ("#+TAGS: { iOS(i) Android(a) } 工作\n* TODO Task\n", serde_json::json!({"tags":["iOS","Android","工作"],"groups":[["iOS","Android"]]})),
            ("#+TAGS:\n* TODO Task\n", serde_json::json!({"tags":[],"groups":[]})),
            ("* TODO Task\n", serde_json::Value::Null),
        ] {
            let mut repo = OrgRepo::new("/unused/supported-tags".into()).unwrap();
            repo.id = "repo".into();
            repo.files.push(org_tasks_core::OrgFile::new(repo.id.clone(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap());
            let workspace = OrgWorkspace::new(vec![repo]).unwrap();
            let task = workspace.query(&org_tasks_core::TaskQuery::default()).unwrap().tasks.remove(0);
            let projection = serde_json::to_value(task_from_filter(task, &workspace).unwrap()).unwrap();
            assert_eq!(projection["supportTags"], expected);
        }
    }

    #[test]
    fn workspace_notifications_reload_files_and_project_one_event_per_conflict_file() {
        let root=std::env::temp_dir().join(format!("org-notification-bridge-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();
        let handle=create_workspace().unwrap();let directory=root.to_string_lossy().to_string();
        workspace_add_repo(handle,directory.clone()).unwrap();
        for path in ["a.org","b.org"] {std::fs::write(root.join(path),"* 同步冲突 :CONFLICT:\n** Point\n").unwrap();}
        let notices:serde_json::Value=serde_json::from_str(&workspace_notifications_json(handle).unwrap()).unwrap();
        let values=notices.as_array().unwrap();assert_eq!(values.len(),3);
        assert_eq!(values[0]["path"],"a.org");assert_eq!(values[1]["path"],"b.org");
        assert_eq!(values[2]["type"],"syncRequired");assert!(values[0].get("syncId").is_none());
        assert_eq!(values[0]["rootDirectory"],directory);
        std::fs::write(root.join("a.org"),"* Normal\n").unwrap();
        let current:serde_json::Value=serde_json::from_str(&workspace_notifications_json(handle).unwrap()).unwrap();
        assert_eq!(current.as_array().unwrap().len(),2);assert_eq!(current[0]["path"],"b.org");
        release_workspace(handle);std::fs::remove_dir_all(root).unwrap();
    }

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
        let result_dir = root.join(".sync/history/10/files/a.org");
        std::fs::create_dir_all(&result_dir).unwrap();
        std::fs::write(result_dir.join("a.resolved.org"), "* TODO Done\n").unwrap();
        let history: serde_json::Value =
            serde_json::from_str(&repo_history_json(handle, directory.clone()).unwrap()).unwrap();
        assert_eq!(history[0]["result"], "failed");
        assert_eq!(history[0]["executionResult"], "succeeded");
        assert_eq!(history[0]["transfer"], "unchanged");
        assert_eq!(history[0]["conflicts"].as_array().unwrap().len(), 2);
        assert!(history[0].get("resolvedConflicts").is_none());
        assert!(history[0]["errorCategory"].is_null());
        assert_eq!(history[1]["transfer"], "download");
        assert_eq!(history[1]["downloadedFiles"], 1);
        assert_eq!(history[1]["uploadedFiles"], 0);
        let detail: serde_json::Value = serde_json::from_str(
            &repo_history_detail_json(handle, directory.clone(), "conflict".into()).unwrap(),
        )
        .unwrap();
        assert!(detail["summary"].get("pendingConflicts").is_none());
        assert_eq!(detail["files"][0]["outcome"], "conflict");
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
        std::fs::write(root.join("work.org"), "#+TITLE: 工作计划\n#+TAGS: { 家居(j) unused(u) }\n* TODO Task :家居:\n").unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let metadata: serde_json::Value =
            serde_json::from_str(&repo_file_metadata_json(handle, directory.clone()).unwrap())
                .unwrap();
        assert_eq!(metadata[0]["title"], "工作计划");
        assert_eq!(metadata[0]["path"], "work.org");
        assert_eq!(metadata[0]["isIgnore"], false);
        assert_eq!(metadata[0]["tagOptions"], serde_json::json!(["家居", "unused"]));
        assert_eq!(metadata[0]["tagGroups"], serde_json::json!([["家居", "unused"]]));
        let tasks: serde_json::Value = serde_json::from_str(&workspace_query_json(handle, r#"{"expression":"t.家居"}"#.into()).unwrap()).unwrap();
        assert_eq!(tasks["tasks"][0]["tags"], serde_json::json!(["家居"]));
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
        assert_eq!(changed[0]["tagOptions"], serde_json::json!([]));
        assert_eq!(changed[0]["tagGroups"], serde_json::json!([]));
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
    fn workspace_query_reloads_task_ignore_rules_before_projection() {
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
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
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
        repo_load(handle,directory).unwrap();
        let records:serde_json::Value=serde_json::from_str(&query_tasks_json(handle,"".into()).unwrap()).unwrap();
        let result=workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Modification","data":{"path":records[0]["fullPath"],"modifications":[{"field":"ADDRESS_LINK","value":{"oldUri":"addr:old","newUri":"geo:39.9,116.4"}}]}}]}).to_string()).unwrap();
        assert_eq!(result, "{}");
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
        let core_tasks = session.lock().unwrap().query(&org_tasks_core::TaskQuery::default()).unwrap().tasks;
        assert_eq!(after["tasks"][0]["id"], core_tasks[0].id());
        assert!(serde_json::from_str::<serde_json::Value>(core_tasks[0].id())
            .unwrap()
            .is_array());
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
        assert!(tasks[0]["modifiedAt"].is_null());
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
    fn task_modified_time_projects_own_property_and_keeps_disk_only_time_null() {
        let root = std::env::temp_dir().join(format!("org-task-modified-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* Missing\n:PROPERTIES:\n:CREATED: [2030-01-01 Tue 12:00]\n:END:\n* Old\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-08 Sun 09:00]\n:END:\n* New\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-09 Mon 10:00]\n:END:\n";
        std::fs::write(root.join("notes.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let result: serde_json::Value = serde_json::from_str(
            &workspace_query_json(handle, r#"{"expression":".o.modified"}"#.into()).unwrap(),
        ).unwrap();
        let tasks = result["tasks"].as_array().unwrap();
        assert_eq!(tasks.iter().map(|task| task["heading"].as_str().unwrap()).collect::<Vec<_>>(), ["New", "Old", "Missing"]);
        assert!(tasks[0]["modifiedAt"].as_i64().unwrap() > tasks[1]["modifiedAt"].as_i64().unwrap());
        assert!(tasks[2]["modifiedAt"].is_null());
        assert!(tasks[2]["createdAt"].as_i64().is_some());
        assert_eq!(std::fs::read_to_string(root.join("notes.org")).unwrap(), source);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn scoped_refile_query_and_someday_edit_options_cross_bridge() {
        let root = std::env::temp_dir().join(format!("org-someday-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), "#+CATEGORY: InboxOnly\n* DONE Move me\nSCHEDULED: <2026-11-08 Sun> DEADLINE: <2026-11-09 Mon>\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n* Inbox :REFILE:\n").unwrap();
        std::fs::write(root.join("someday.org"), "#+CATEGORY: LaterOnly\n* First :REFILE:\n** Existing\n* Second :REFILE:\n").unwrap();
        std::fs::write(root.join("normal.org"), "#+CATEGORY: Work\n* Work :REFILE:\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let tasks: serde_json::Value = serde_json::from_str(&workspace_query_json(handle, r#"{"expression":"b.inbox.org"}"#.into()).unwrap()).unwrap();
        let task = tasks["tasks"].as_array().unwrap().iter().find(|task| task["heading"] == "Move me").unwrap();
        let query = serde_json::json!({ "excludedFiles": [ {"repoId": task["repoId"], "path": "inbox.org"}, {"repoId":task["repoId"],"path":"someday.org"} ] });
        let targets: serde_json::Value = serde_json::from_str(&workspace_refile_targets_json(handle, query.to_string()).unwrap()).unwrap();
        assert_eq!(targets.as_array().unwrap().len(), 1);
        assert_eq!(targets[0]["category"], "Work");
        let query = serde_json::json!({ "files": [{"repoId":task["repoId"],"path":"someday.org"}] });
        let targets: serde_json::Value = serde_json::from_str(&workspace_refile_targets_json(handle, query.to_string()).unwrap()).unwrap();
        let target = &targets[0];
        assert_eq!(target["headingPath"][0], "First");
        let request = serde_json::json!({ "operations": [
            {"type":"Modification", "data":{"path":task["fullPath"], "modifications":[
                {"field":"TODO", "value":"TODO"}, {"field":"SCHEDULE", "value":null},
                {"field":"DEADLINE", "value":null}, {"field":"CLOSED", "value":null}]}},
            {"type":"Movement", "data":{"path":task["fullPath"], "position":{"parent":target["fullPath"]}}}
        ], "fileVersions":[
            {"repoId":task["repoId"], "file":task["filePath"], "version":task["fileVersion"]},
            {"repoId":target["repoId"], "file":target["path"], "version":target["fileVersion"]}
        ] });
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        let bytes = std::fs::read_to_string(root.join("someday.org")).unwrap();
        assert!(bytes.contains("* First :REFILE:\n** TODO Move me\n:PROPERTIES:\n:CREATED:"));
        assert!(!bytes.contains("SCHEDULED:") && !bytes.contains("DEADLINE:"));
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
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
        let task = tasks
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["heading"] == "Move me")
            .unwrap();
        let targets: serde_json::Value =
            serde_json::from_str(&workspace_refile_targets_json(handle, "{}".into()).unwrap()).unwrap();
        let target = &targets[0];
        assert_eq!(target["category"], "Work");
        let request=serde_json::json!({"operations":[{"type":"Movement","data":{"path":task["fullPath"],"position":{"parent":target["fullPath"]}}}],"queueRepoIds":[task["repoId"]]});
        workspace_execute_task_operations(handle,request.to_string()).unwrap();
        assert!(workspace_execute_task_operations(handle,request.to_string()).is_err());
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
        repo_load(handle,directory.clone()).unwrap();
        let id=repo_id(handle,directory.clone()).unwrap();
        workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"}},"title":"Captured","state":"TODO","recordCreated":true}}],"queueRepoIds":[id]}).to_string()).unwrap();
        let source = std::fs::read_to_string(root.join("inbox.org")).unwrap();
        assert!(source.starts_with("* TODO Captured\n:PROPERTIES:\n:CREATED: ["));
        assert!(source.ends_with(original));
        repo_load(handle, directory.clone()).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_str(&repo_snapshot_json(handle, directory).unwrap()).unwrap();
        assert_eq!(snapshot["files"][0]["source"], source);
        let tasks: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
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
        let id=repo_id(handle,root_directory.clone()).unwrap();
        let records:serde_json::Value=serde_json::from_str(&query_tasks_json(handle,"".into()).unwrap()).unwrap();
        workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"},"after":records[0]["fullPath"]},"title":"created from bridge","state":"TODO"}}],"queueRepoIds":[id]}).to_string()).unwrap();
        let tasks: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "i.todo".into()).unwrap()).unwrap();
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
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
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
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    encode(&runtime()?.block_on(repository.pending_sync_conflicts())?)
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
            serde_json::from_str(&query_tasks_json(handle, "it.done".into()).unwrap())
                .unwrap();
        assert_eq!(done.as_array().unwrap().len(), 2);
        assert_eq!(done[0]["todoKind"], "done");
        assert_eq!(done[0]["isDone"], true);
        assert!(workspace_set_todo_defaults(handle, "invalid".into()).is_err());
        workspace_set_todo_defaults(handle, "#+TODO: OTHER | END".into()).unwrap();
        let done: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "it.done".into()).unwrap())
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
        let task = task_from_filter(workspace.query(&org_tasks_core::TaskQuery::default()).unwrap().tasks.remove(0), &workspace).unwrap();
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
        assert!(value["modifiedAt"].is_null());
        assert!(value["bodyHtml"].as_str().unwrap().contains("<ul>"));
        assert_eq!(value["bodyFirstLine"], "First");
        assert_eq!(value["tags"][0], "work");
    }
}

/// 放置目标和任务整理均由 Core 求值，bridge 只持有会话锁并调度运行时。
pub fn workspace_refile_targets_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let query: org_tasks_core::RefileTargetQuery = serde_json::from_str(&query_json)
        .map_err(|_| CoreError::InvalidInput("放置目标查询参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos { runtime.block_on(repo.load::<WebDavSyncPolicy>())?; }
    encode(&workspace.query_refile_targets(&query)?)
}

pub fn workspace_execute_task_operations(handle:u64, request:String)->Result<String,CoreError>{
    let group:org_tasks_core::TaskOperationGroup=serde_json::from_str(&request)
        .map_err(|_|CoreError::InvalidInput("任务操作组参数无效"))?;
    let session=workspace_for_handle(handle)?;
    let mut workspace=session.lock().map_err(|_|CoreError::Store("Harmony workspace 锁不可用".into()))?;
    runtime()?.block_on(workspace.execute_task_operations(&group))?;
    Ok("{}".into())
}

/// 公开对象方法在 ABI 内统一编组；操作及路径校验仍由 Core 完成。
pub fn repo_history_operation(handle: u64, root: String, request: String) -> Result<String, CoreError> {
    #[derive(serde::Deserialize)]
    #[serde(tag = "operation", rename_all = "camelCase")]
    enum Request {
        LastEffectSync,
        #[serde(rename_all = "camelCase")]
        File { sync_id: String, path: String, resolved: bool },
    }
    let request: Request = serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("历史文件参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session.lock().map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo = workspace.repo_mut_by_root_directory(&root).ok_or(CoreError::InvalidInput("仓库不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    match request {
        Request::LastEffectSync => {
            let current = runtime.block_on(repo.last_effect_sync())?;
            let summary = current.map(|r| {
                bridge_sync_summary(org_tasks_core::webdav::WebDavSyncRecordSummary::from_record(&r)?)
            }).transpose()?;
            encode(&summary)
        },
        Request::File { sync_id, path, resolved } => encode(&file_snapshot(&runtime.block_on(repo.history_file(&sync_id, &path, resolved))?)?),
    }
}

static NOTIFICATION_SUBSCRIPTIONS: OnceLock<Mutex<BTreeMap<u64, org_tasks_core::NotificationSubscription>>> = OnceLock::new();
static NEXT_NOTIFICATION_SUBSCRIPTION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
static DATA_CHANGE_SUBSCRIPTIONS: OnceLock<Mutex<BTreeMap<u64, org_tasks_core::DataChangeSubscription>>> = OnceLock::new();
static NEXT_DATA_CHANGE_SUBSCRIPTION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
struct NotificationMonitor(u64);
#[cfg(not(test))]
unsafe extern "C" {
    fn org_tasks_harmony_notification_update(handle: u64, json: *const std::ffi::c_char);
    fn org_tasks_harmony_notification_monitor_release(handle: u64);
    fn org_tasks_harmony_data_change_update(handle: u64, json: *const std::ffi::c_char);
    fn org_tasks_harmony_data_change_monitor_release(handle: u64);
}
impl Drop for NotificationMonitor {
    fn drop(&mut self) {
        #[cfg(test)]
        let _ = self.0;
        #[cfg(not(test))]
        unsafe { org_tasks_harmony_notification_monitor_release(self.0); }
    }
}
pub fn workspace_watch_notifications(handle:u64, monitor:u64)->Result<u64,CoreError> {
    let monitor=NotificationMonitor(monitor);
    let session=workspace_for_handle(handle)?;
    let workspace=session.lock().map_err(|_|CoreError::Store("workspace 锁不可用".into()))?;
    let subscription=workspace.watch_notifications(move |event| {
        let _keep_alive=&monitor;
        if let Ok(json)=serde_json::to_string(&event).and_then(|s|CString::new(s).map_err(serde::ser::Error::custom)) {
            #[cfg(not(test))]
            unsafe {org_tasks_harmony_notification_update(monitor.0,json.as_ptr());}
            #[cfg(test)]
            let _=json;
        }
    });
    let id=NEXT_NOTIFICATION_SUBSCRIPTION.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
    NOTIFICATION_SUBSCRIPTIONS.get_or_init(Default::default).lock().map_err(|_|CoreError::Store("通知订阅锁不可用".into()))?.insert(id,subscription);
    Ok(id)
}
pub fn workspace_unwatch_notifications(id:u64) {
    // 在锁外销毁回调资源，避免释放宿主句柄时重入注册表。
    let removed=NOTIFICATION_SUBSCRIPTIONS.get_or_init(Default::default).lock().ok().and_then(|mut map|map.remove(&id));
    drop(removed);
}

struct DataChangeMonitor(u64);
impl Drop for DataChangeMonitor {
    fn drop(&mut self) {
        #[cfg(test)]
        let _ = self.0;
        #[cfg(not(test))]
        unsafe { org_tasks_harmony_data_change_monitor_release(self.0); }
    }
}
pub fn workspace_watch_data_changes(handle:u64, monitor:u64)->Result<u64,CoreError> {
    let monitor=DataChangeMonitor(monitor);
    let session=workspace_for_handle(handle)?;
    let workspace=session.lock().map_err(|_|CoreError::Store("workspace 锁不可用".into()))?;
    let subscription=workspace.watch_data_changes(move |event| {
        let _keep_alive=&monitor;
        if let Ok(json)=serde_json::to_string(&event).and_then(|s|CString::new(s).map_err(serde::ser::Error::custom)) {
            #[cfg(not(test))]
            unsafe { org_tasks_harmony_data_change_update(monitor.0, json.as_ptr()); }
            #[cfg(test)]
            let _=json;
        }
    });
    let id=NEXT_DATA_CHANGE_SUBSCRIPTION.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
    DATA_CHANGE_SUBSCRIPTIONS.get_or_init(Default::default).lock().map_err(|_|CoreError::Store("数据监控订阅锁不可用".into()))?.insert(id,subscription);
    Ok(id)
}
pub fn workspace_unwatch_data_changes(id:u64) {
    let removed=DATA_CHANGE_SUBSCRIPTIONS.get_or_init(Default::default).lock().ok().and_then(|mut map|map.remove(&id));
    drop(removed);
}
pub fn workspace_reload(handle:u64)->Result<(),CoreError> {
    let session=workspace_for_handle(handle)?;
    let mut workspace=session.lock().map_err(|_|CoreError::Store("workspace 锁不可用".into()))?;
    runtime()?.block_on(workspace.reload())
}

#[cfg(test)]
mod reset_bridge_tests {
    use super::*;

    #[test]
    fn reset_keeps_id_and_exposes_file_conflict_metadata_before_clearing() {
        let root = std::env::temp_dir().join(format!("org-reset-bridge-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("A.org"), "#+TITLE: A\n* 同步冲突 :CONFLICT:\n** TODO A\n").unwrap();
        let path = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, path.clone()).unwrap();
        repo_load(handle, path.clone()).unwrap();
        let id = repo_id(handle, path.clone()).unwrap();
        let metadata: serde_json::Value = serde_json::from_str(&repo_file_metadata_json(handle, path.clone()).unwrap()).unwrap();
        assert_eq!(metadata[0]["hasConflict"], true);
        let snapshot: serde_json::Value = serde_json::from_str(&repo_snapshot_json(handle, path.clone()).unwrap()).unwrap();
        assert_eq!(snapshot["files"][0]["hasConflict"], true);
        std::fs::create_dir_all(root.join(".sync/history")).unwrap();
        std::fs::write(root.join(".sync/history/broken.json"), "bad").unwrap();
        repo_reset(handle, path.clone()).unwrap();
        assert_eq!(repo_id(handle, path.clone()).unwrap(), id);
        assert!(!root.join("A.org").exists());
        assert_eq!(repo_file_metadata_json(handle, path.clone()).unwrap(), "[]");
        assert_eq!(repo_history_json(handle, path).unwrap(), "[]");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

/// 活动对象行为仅在 ABI 中打包，所有语义与文件操作由 Core 执行。
pub fn workspace_preview_operation(handle:u64,request:String)->Result<String,CoreError> {
    #[derive(serde::Deserialize)]
    #[serde(tag="operation",rename_all="camelCase",deny_unknown_fields)]
    enum Request {
        Configure {root:String},
        Create {request:org_tasks_core::ConflictPreviewRequest},
        FileAt {path:org_tasks_core::TaskPath},
        #[serde(rename_all="camelCase")] File {preview_id:String},
        #[serde(rename_all="camelCase")] SourceFile {preview_id:String},
        #[serde(rename_all="camelCase")] Changes {preview_id:String},
        #[serde(rename_all="camelCase")] Finish {preview_id:String,options:org_tasks_core::ConflictPreviewFinishOptions},
        #[serde(rename_all="camelCase")] Discard {preview_id:String},
    }
    let request:Request=serde_json::from_str(&request).map_err(|_|CoreError::InvalidInput("预览请求参数无效"))?;
    let session=workspace_for_handle(handle)?;
    let mut workspace=session.lock().map_err(|_|CoreError::InvalidState("工作区锁不可用"))?;
    let runtime=runtime()?;
    match request {
        Request::Configure {root}=>{workspace.set_preview_root(root.into())?;encode(&serde_json::json!({}))}
        Request::Create {request}=>{
            let preview=runtime.block_on(workspace.create_conflict_preview(request))?;
            let value=serde_json::json!({"id":preview.id(),"sourcePath":preview.source_path(),"sourceVersion":preview.source_version(),"conflictId":preview.conflict_id(),"fullPath":preview.full_path()});
            workspace_sessions().lock().map_err(|_|CoreError::InvalidState("会话锁不可用"))?.sessions.get_mut(&handle).ok_or(CoreError::InvalidState("工作区已关闭"))?.previews.insert(preview.id().into(),preview);
            encode(&value)
        }
        Request::FileAt {path}=>encode(&file_snapshot(&runtime.block_on(workspace.file_at(&path))?)?),
        request=>{
            let id=match &request {Request::File{preview_id}|Request::SourceFile{preview_id}|Request::Changes{preview_id}|Request::Finish{preview_id,..}|Request::Discard{preview_id}=>preview_id,_=>unreachable!()};
            let preview=workspace_sessions().lock().map_err(|_|CoreError::InvalidState("会话锁不可用"))?.sessions.get(&handle).and_then(|s|s.previews.get(id)).cloned().ok_or(CoreError::Preview{code:"previewExpired",message:"预览对象已释放"})?;
            match request {
                Request::File{..}=>encode(&file_snapshot(&runtime.block_on(preview.file())?)?),
                Request::SourceFile{..}=>encode(&file_snapshot(&runtime.block_on(preview.source_file())?)?),
                Request::Changes{..}=>encode(&runtime.block_on(preview.changes())?),
                Request::Finish{options,..}=>encode(&runtime.block_on(preview.finish(options))?),
                Request::Discard{..}=>{runtime.block_on(preview.discard())?;encode(&serde_json::json!({}))},
                _=>unreachable!()
            }
        }
    }
}
pub fn release_preview(handle:u64,id:&str) {
    if let Ok(mut sessions)=workspace_sessions().lock() {if let Some(session)=sessions.sessions.get_mut(&handle) {session.previews.remove(id);}}
}

#[cfg(test)]
mod preview_tests {
    use super::*;
    fn request(handle:u64,value:serde_json::Value)->serde_json::Value {
        serde_json::from_str(&workspace_preview_operation(handle,value.to_string()).unwrap()).unwrap()
    }
    #[test]
    fn preview_objects_return_operations_and_only_data_interface_writes_repository() {
        let root=std::fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("harmony-preview-{}-{}",std::process::id(),org_tasks_core::LocalFileVersion::from_bytes(format!("{:?}",std::time::SystemTime::now()).as_bytes()).content_hash));
        std::fs::create_dir_all(root.join("repo")).unwrap();
        let base="* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nbase\n";
        let source=org_tasks_core::merge(base.as_bytes(),base.replace("base","local").as_bytes(),base.replace("base","remote").as_bytes()).unwrap();
        std::fs::write(root.join("repo/a.org"),&source).unwrap();
        let handle=create_workspace().unwrap();let directory=root.join("repo").to_str().unwrap().to_owned();workspace_add_repo(handle,directory.clone()).unwrap();
        let file:serde_json::Value=serde_json::from_str(&repo_file_json(handle,directory.clone(),"a.org".into()).unwrap()).unwrap();
        request(handle,serde_json::json!({"operation":"configure","root":root.join("cache")}));
        let preview=request(handle,serde_json::json!({"operation":"create","request":{"file":file["fullPath"],"conflictId":file["conflictIds"][0],"sourceVersion":file["fileVersion"]}}));
        assert_eq!(preview["fullPath"]["repoId"],"<preview>");assert_eq!(preview["fullPath"]["file"],preview["id"]);
        let copied=request(handle,serde_json::json!({"operation":"file","previewId":preview["id"]}));
        assert_eq!(copied["source"],file["source"]);assert_eq!(copied["nodes"][0]["repoId"],"<preview>");
        let staged:serde_json::Value=serde_json::from_str(&workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"ConfilictSelection","data":{"path":preview["fullPath"],"id":preview["conflictId"],"action":"useLocal","target":copied["conflicts"][0]["suggestedTarget"]}}],"fileVersions":[{"repoId":"<preview>","file":preview["id"],"version":copied["fileVersion"]}]}).to_string()).unwrap()).unwrap();
        assert_eq!(staged,serde_json::json!({}));assert_eq!(std::fs::read(root.join("repo/a.org")).unwrap(),source);
        let edited=request(handle,serde_json::json!({"operation":"file","previewId":preview["id"]}));
        assert_eq!(edited["nodes"][0]["repoId"],"<preview>");
        let group=request(handle,serde_json::json!({"operation":"finish","previewId":preview["id"],"options":{"previewVersion":edited["fileVersion"]}}));
        assert_eq!(std::fs::read(root.join("repo/a.org")).unwrap(),source);assert_eq!(group["operations"][0]["data"]["path"],file["fullPath"]);assert_eq!(group["fileVersions"][0]["version"],file["fileVersion"]);
        assert_eq!(request(handle,serde_json::json!({"operation":"finish","previewId":preview["id"],"options":{"previewVersion":edited["fileVersion"]}})),group);
        workspace_execute_task_operations(handle,group.to_string()).unwrap();
        assert_eq!(std::fs::read(root.join("repo/a.org")).unwrap(),edited["source"].as_str().unwrap().as_bytes());
        release_preview(handle,preview["id"].as_str().unwrap());
        assert!(matches!(workspace_preview_operation(handle,serde_json::json!({"operation":"file","previewId":preview["id"]}).to_string()),Err(CoreError::Preview{code:"previewExpired",..})));
        release_workspace(handle);std::fs::remove_dir_all(root).unwrap();
    }
}
