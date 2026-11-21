use std::collections::BTreeMap;
use std::ffi::CString;
use std::sync::{Arc, Mutex, OnceLock};

use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavError, WebDavSyncEvent, WebDavSyncMonitor, WebDavSyncPolicy,
};
use org_tasks_core::{
    CoreError, FilterTask, OrgRepo, OrgRepoSyncResult, OrgWorkspace, TimestampMs,
};
use serde::{Deserialize, Serialize};

struct WorkspaceSession {
    workspace: OrgWorkspace,
    runtime: Arc<crate::runtime::WorkspaceRuntime>,
    references: usize,
    previews: BTreeMap<String, org_tasks_core::ConflictPreview>,
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
    #[serde(rename = "documentHtml")]
    pub document_html: String,
    #[serde(rename = "documentSections")]
    // 包含 Core 的 linkTargets，完整透传而不在 bridge 解析目标。
    pub document_sections: Vec<org_tasks_core::DocumentSection>,
    #[serde(rename = "fileTags")]
    pub file_tags: Vec<String>,
    #[serde(rename = "headerEntries")]
    pub header_entries: Vec<org_tasks_core::FileHeaderEntry>,
    #[serde(rename = "specialTags")]
    pub special_tags: Vec<String>,
    #[serde(rename = "projectName")]
    pub project_name: Option<String>,
    pub conflicts: Vec<org_tasks_core::FileConflict>,
    #[serde(rename = "conflictError")]
    pub conflict_error: Option<serde_json::Value>,
    pub nodes: Vec<HarmonyBridgeTask>,
    #[serde(rename = "editableNodePaths")]
    pub editable_node_paths: Vec<org_tasks_core::TaskPath>,
    #[serde(rename = "insertionPositions")]
    pub insertion_positions: Vec<org_tasks_core::TaskPosition>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarmonyBridgeTask {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order_key: Option<Vec<org_tasks_core::QueryOrderPart>>,
    pub project_name: Option<String>,
    pub id: String,
    pub full_path: org_tasks_core::TaskPath,
    pub task_id: Option<String>,
    pub file_version: String,
    pub repo_id: String,
    pub heading: String,
    pub category: Option<String>,
    // 包含 Core 生成的链接与分数计数；保留原始 heading 供复制、路由和查询。
    pub heading_parts: Vec<org_tasks_core::TitlePart>,
    pub state: Option<org_tasks_core::TaskState>,
    pub task_state_options: BTreeMap<String, Option<org_tasks_core::TaskState>>,
    pub is_done: bool,
    pub created_at: Option<TimestampMs>,
    pub closed_at: Option<TimestampMs>,
    pub deleted_at: Option<TimestampMs>,
    pub modified_at: Option<TimestampMs>,
    pub priority: Option<org_tasks_core::TaskPriority>,
    pub priority_options: Vec<org_tasks_core::TaskPriority>,
    pub default_priority: org_tasks_core::TaskPriority,
    pub task_priority_options: BTreeMap<String, Option<org_tasks_core::TaskPriority>>,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub own_tags: Vec<String>,
    pub inherited_tags: Vec<String>,
    pub support_tags: Option<org_tasks_core::SupportTags>,
    // 日期与时间由 Core 投影，嵌套对象原样传给 N-API，不在宿主解析 Org。
    // Core 生成有序区块与快照内身份；bridge 不拆分 HTML 或解释 Org。
    pub edit_content: org_tasks_core::TaskEditContent,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub body: String,
    pub body_first_line: Option<String>,
    #[serde(rename = "addressLinks")]
    pub address_links: Vec<org_tasks_core::AddressLink>,
    #[serde(rename = "appLinks")]
    pub app_links: Vec<org_tasks_core::AppLink>,
    pub body_html: String,
    pub logbook_html: String,
    pub logs: Vec<org_tasks_core::TaskLog>,
    pub progress: i32,
    pub has_list: bool,
    pub has_text: bool,
    pub is_repeating: bool,
    pub is_habit: bool,
    pub properties: BTreeMap<String, String>,
    pub reminder_at: Option<TimestampMs>,
    pub has_attach: bool,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSync {
    pub id: String,
    #[serde(rename = "triggerReason")]
    pub trigger_reason: Option<String>,
    pub result: Option<String>,
    pub started_at: Option<TimestampMs>,
    pub finished_at: Option<TimestampMs>,
    pub files: Option<usize>,
    #[serde(rename = "downloadedFiles")]
    pub downloaded_files: Option<usize>,
    #[serde(rename = "uploadedFiles")]
    pub uploaded_files: Option<usize>,
    pub conflicts: Vec<String>,
    #[serde(rename = "executionResult")]
    pub execution_result: Option<String>,
    pub transfer: Option<org_tasks_core::webdav::WebDavSyncTransfer>,
    #[serde(rename = "errorCategory")]
    pub error_category: Option<org_tasks_core::OrgRepoSyncErrorCategory>,
    #[serde(rename = "errorMessage")]
    pub error_message: Option<String>,
    #[serde(rename = "conflictCount")]
    pub conflict_count: Option<usize>,
    pub incomplete: bool,
    pub issues: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSyncDetail {
    pub summary: HarmonyBridgeSync,
    pub files: Vec<serde_json::Value>,
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

struct HarmonyWebDavSyncMonitor {
    handle: u64,
}

#[cfg(not(test))]
unsafe extern "C" {
    fn org_tasks_harmony_webdav_sync_monitor_event(
        handle: u64,
        event_json: *const std::ffi::c_char,
    );
    fn org_tasks_harmony_webdav_sync_monitor_release(handle: u64);
}

impl Drop for HarmonyWebDavSyncMonitor {
    fn drop(&mut self) {
        #[cfg(not(test))]
        if self.handle != 0 { unsafe { org_tasks_harmony_webdav_sync_monitor_release(self.handle); } }
    }
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

fn task_from_filter(task: FilterTask) -> Result<HarmonyBridgeTask, CoreError> {
    let repo_id = task.repo_id().to_owned();
    let path = task.path().to_owned();
    let file_version = task.file_version().to_owned();
    let task_id = task.task_id().map(str::to_owned);
    let is_done = task.is_done();
    let heading_parts = task.title_parts();
    let content = task.render_content();
    let edit_content = task.edit_content().clone();
    let mut tags = task.own_tags().to_vec();
    for inherited in task.inherited_tags() {
        if !tags.contains(inherited) {
            tags.push(inherited.clone());
        }
    }
    Ok(HarmonyBridgeTask {
        order_key: None,
        full_path: task.full_path().clone(),
        task_id,
        file_version,
        id: task.id().to_owned(),
        repo_id,
        heading: task.title().to_owned(),
        category: task.category().map(str::to_owned),
        project_name: task.project().map(str::to_owned),
        heading_parts,
        state: task.state().cloned(),
        task_state_options: state_options(|category| task.task_state_of(category)),
        is_done,
        created_at: task.created_at(),
        closed_at: task.closed_at(),
        deleted_at: task.deleted_at(),
        modified_at: task.modified_at(),
        priority: task.priority().cloned(),
        priority_options: task.priority_options(),
        default_priority: task.default_priority().clone(),
        task_priority_options: priority_options(|category| task.task_priority_of(category)),
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
        app_links: task.app_links().to_vec(),
        body_html: content.body_html,
        logbook_html: content.logbook_html,
        logs: content.logs,
        progress: -1,
        has_list: content.has_list,
        has_text: content.has_text,
        is_repeating: task.is_repeating(),
        is_habit: task.is_habit(),
        properties: task.properties().clone(),
        reminder_at: task.reminder_at(),
        has_attach: task.has_attach(),
    })
}

/// 创建持久的空 workspace session；加入仓库时初始化其稳定身份。
pub fn create_workspace() -> Result<u64, CoreError> {
    let runtime = Arc::new(crate::runtime::WorkspaceRuntime::new()?);
    let workspace = runtime.block_on(OrgWorkspace::start(Vec::new()))?;
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
            workspace,
            runtime,
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
    let released = if let Ok(mut sessions) = workspace_sessions().lock() {
        if let Some(session) = sessions.sessions.get_mut(&handle) {
            session.references = session.references.saturating_sub(1);
            if session.references == 0 {
                sessions.sessions.remove(&handle)
            } else { None }
        } else { None }
    } else { None };
    if let Some(session) = released {
        let server = {
            crate::http_ui::cancel(handle);
            let mut state = EMBEDDED_HTTP.get_or_init(Default::default).lock().unwrap_or_else(|error| error.into_inner());
            if state.as_ref().is_some_and(|(owner, _)| *owner == handle) { state.take() } else { None }
        };
        drop(server);
        let mut subscriptions = QUERY_SUBSCRIPTIONS.get_or_init(Default::default).lock().unwrap_or_else(|error| error.into_inner());
        let ids = subscriptions.iter().filter(|(_, (owner, _))| *owner == handle).map(|(id, _)| *id).collect::<Vec<_>>();
        let removed = ids.into_iter().filter_map(|id| subscriptions.remove(&id)).collect::<Vec<_>>();
        drop(subscriptions);
        drop(removed);
        // Finalizer 可能位于 UI 线程；收尾在宿主运行时等待，且不持有会话表锁。
        let runtime = session.runtime.clone();
        session.runtime.spawn_blocking(move || {
            let workspace = session.workspace;
            if let Err(error) = runtime.block_on(workspace.stop()) {
                eprintln!("停止 Workspace 失败: {error}");
            }
        });
    }
}

pub fn workspace_repo_roots(handle: u64) -> Result<Vec<String>, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    Ok(workspace
        .repos()
        .iter()
        .map(|repo| repo.root_directory.clone())
        .collect())
}

pub fn workspace_remove_repo(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    runtime(handle)?.block_on(workspace.remove_repo_by_root_directory(&root_directory))?;
    Ok(())
}

pub fn workspace_add_repo(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut repository = OrgRepo::new(root_directory)?;
    runtime(handle)?.block_on(repository.load::<WebDavSyncPolicy>())?;
    runtime(handle)?.block_on(workspace.add_repo(repository))
}

pub fn validate_configuration_json(request: String) -> Result<String, CoreError> {
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Request { todo_defaults: Option<String>, core_settings: Option<org_tasks_core::CoreSettings> }
    let request: Request = serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("配置校验参数无效"))?;
    let settings = request.core_settings.unwrap_or_default();
    settings.validate()?;
    if let Some(todo) = request.todo_defaults { org_tasks_core::TodoConfig::from_settings(&todo)?; }
    encode(&settings)
}

pub fn workspace_validate_repository(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let defaults = workspace.todo_defaults();
    let mut repo = OrgRepo::new(root_directory)?;
    repo.set_todo_defaults(defaults)?;
    runtime(handle)?.block_on(repo.load::<WebDavSyncPolicy>())?;
    Ok(())
}

pub fn repo_load(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    runtime(handle)?.block_on(workspace.load_repo::<WebDavSyncPolicy>(&root_directory))
}

pub fn repo_reset(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    runtime(handle)?.block_on(workspace.reset_repo(&root_directory))
}

/// 读取仓库已完成的同步记录。历史由 core 从 `.sync/history` 恢复，宿主只接收展示投影。
pub fn repo_history_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let records =
        runtime(handle)?.block_on(workspace.read_repo(&root_directory, |repo| async move {
            repo.sync_log_summaries().await
        }))?;
    encode(
        &records
            .into_iter()
            .map(bridge_log_summary)
            .collect::<Vec<_>>(),
    )
}

pub fn repo_history_detail_json(
    handle: u64,
    root_directory: String,
    sync_id: String,
) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let detail = runtime(handle)?.block_on(workspace.read_repo(&root_directory, move |repo| async move {
        let detail = repo.sync_log_detail(&sync_id).await?;
        let mut files = Vec::new();
        let mut errors = Vec::new();
        for entry in detail.files {
            errors.extend(entry.issues.iter().map(bridge_log_issue));
            let data = &entry.data;
            let outcome = data.file_outcome();
            if let Some(error) = &data.error {
                if error["category"] != "Conflict" && let Some(message) = error["message"].as_str() {
                    errors.push(org_tasks_core::webdav::WebDavSyncHistoryError {
                        path: data.relative_path.clone(), message: message.into(),
                    });
                }
            }
            let mut backup = None;
            if outcome == Some("deleted") && let Some(path) = &data.relative_path {
                match repo.history_file_metadata(&sync_id, path).await {
                    Ok(metadata) => backup = Some(file_metadata_snapshot(metadata)),
                    Err(error) => errors.push(org_tasks_core::webdav::WebDavSyncHistoryError {
                        path: Some(path.clone()), message: error.to_string(),
                    }),
                }
            }
            files.push(serde_json::json!({"path":data.relative_path,"outcome":outcome,"section":null,"backup":backup}));
        }
        errors.extend(detail.summary.issues.iter().map(bridge_log_issue));
        let mut seen = std::collections::BTreeSet::new();
        errors.retain(|error| seen.insert((error.path.clone(),error.message.clone())));
        Ok(HarmonyBridgeSyncDetail {summary: bridge_log_summary(detail.summary),files,errors})
    }))?;
    encode(&detail)
}

fn bridge_log_issue(issue: &org_tasks_core::SyncLogIssue) -> org_tasks_core::webdav::WebDavSyncHistoryError {
    org_tasks_core::webdav::WebDavSyncHistoryError {
        path: Some(issue.path.clone()),
        message: issue.field.as_ref().map(|field|format!("[{field}] {}",issue.message)).unwrap_or_else(||issue.message.clone()),
    }
}

fn bridge_log_summary(entry: org_tasks_core::SyncLogRecord) -> HarmonyBridgeSync {
    use org_tasks_core::webdav::WebDavSyncTransfer;
    let data = entry.data;
    let transfer = match (data.downloaded_count, data.uploaded_count) {
        (Some(0), Some(0)) => Some(WebDavSyncTransfer::Unchanged),
        (Some(0), Some(_)) => Some(WebDavSyncTransfer::Upload),
        (Some(_), Some(0)) => Some(WebDavSyncTransfer::Download),
        (Some(_), Some(_)) => Some(WebDavSyncTransfer::Bidirectional),
        _ => None,
    };
    let incomplete = !entry.issues.is_empty()
        || data.started_at.is_none()
        || data.result.is_none()
        || data.file_count.is_none()
        || transfer.is_none();
    let issues = entry
        .issues
        .into_iter()
        .map(|issue| {
            format!(
                "{}{}: {}",
                issue.path,
                issue
                    .field
                    .map(|field| format!(" [{field}]"))
                    .unwrap_or_default(),
                issue.message
            )
        })
        .collect();
    let error_category = data
        .error
        .as_ref()
        .and_then(|value| value.get("category"))
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok());
    let error_message = data
        .error
        .as_ref()
        .and_then(|value| value.get("message"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    HarmonyBridgeSync {
        id: entry.key,
        trigger_reason: data.trigger_reason,
        result: data.result.clone(),
        execution_result: data.execution_result.or(data.result),
        started_at: data.started_at,
        finished_at: data.finished_at,
        files: data.file_count,
        downloaded_files: data.downloaded_count,
        uploaded_files: data.uploaded_count,
        conflicts: data.conflicts.unwrap_or_default(),
        conflict_count: data.conflict_count,
        transfer,
        error_category,
        error_message,
        incomplete,
        issues,
    }
}
pub fn repo_full_path_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let repo = workspace
        .repo_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    encode(&repo.full_path())
}

pub fn repo_id(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let repository = workspace
        .repo_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    Ok(repository.id.clone())
}

#[cfg(test)]
fn query_task_results_json(handle: u64, queries: String) -> Result<String, CoreError> {
    let tasks: Vec<org_tasks_core::TaskQuery> =
        serde_json::from_str(&queries).map_err(|_| CoreError::InvalidInput("任务查询参数无效"))?;
    let request = tasks
        .into_iter()
        .map(org_tasks_core::CoreQuery::from)
        .collect::<Vec<_>>();
    let response = workspace_query_json(handle, serde_json::to_string(&request).unwrap())?;
    let results: Vec<serde_json::Value> = serde_json::from_str(&response).unwrap();
    encode(
        &results
            .into_iter()
            .map(|result| result["result"].clone())
            .collect::<Vec<_>>(),
    )
}

#[cfg(test)]
fn query_files_json(handle: u64, root: String) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let repo_id = session
        .repo_by_root_directory(&root)
        .ok_or(CoreError::InvalidInput("仓库不存在"))?
        .id
        .clone();
    let response = workspace_query_json(
        handle,
        r#"[{"type":"file","query":{"includeIgnored":true}}]"#.into(),
    )?;
    let results: serde_json::Value = serde_json::from_str(&response).unwrap();
    encode(
        &results[0]["result"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|file| file["repoId"] == repo_id)
            .collect::<Vec<_>>(),
    )
}

#[cfg(test)]
fn subscribed_notifications_json(handle: u64) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let roots = workspace.repos().into_iter().map(|repo| (repo.id, repo.root_directory)).collect();
    let notifications = runtime(handle)?.block_on(async {
        let (send, mut received) = tokio::sync::mpsc::unbounded_channel();
        let _subscription = workspace.watch_notifications(None, (
            move |snapshot: org_tasks_core::NotificationSnapshot| { let _ = send.send(snapshot.notifications); },
            |_delta: org_tasks_core::NotificationDelta| {},
        ));
        tokio::time::timeout(std::time::Duration::from_secs(5), received.recv()).await
            .map_err(|_| CoreError::InvalidState("通知初始化超时"))?
            .ok_or(CoreError::InvalidState("通知初始化失败"))
    })?;
    encode(&notification_values(notifications, &roots))
}

#[cfg(test)]
fn query_tasks_json(handle: u64, expression: String) -> Result<String, CoreError> {
    let response = query_task_results_json(
        handle,
        serde_json::json!([{ "expression": expression }]).to_string(),
    )?;
    let result: serde_json::Value = serde_json::from_str(&response).unwrap();
    encode(&result[0]["tasks"])
}

// 宿主查询别名只在请求上下文内解析，Core 始终接收真实仓库 ID。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueryRepositoryBinding {
    id: String,
    root_directory: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BoundQueryRequest {
    queries: Vec<org_tasks_core::CoreQuery>,
    #[serde(default)]
    repository_bindings: Vec<QueryRepositoryBinding>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum WorkspaceQueryRequest {
    Queries(Vec<org_tasks_core::CoreQuery>),
    Bound(BoundQueryRequest),
}

fn resolve_query_repositories(
    workspace: &OrgWorkspace,
    queries: &mut [org_tasks_core::CoreQuery],
    bindings: &[QueryRepositoryBinding],
) -> Result<(), CoreError> {
    let mut identities = BTreeMap::new();
    for binding in bindings {
        if binding.id.is_empty() || identities.contains_key(&binding.id) {
            return Err(CoreError::InvalidInput("查询仓库别名为空或重复"));
        }
        let repo = workspace.repo_by_root_directory(&binding.root_directory)
            .ok_or(CoreError::InvalidInput("查询仓库目录不属于 workspace"))?;
        if workspace.repo(&binding.id).is_some_and(|existing| existing.id != repo.id) {
            return Err(CoreError::InvalidInput("查询仓库别名与 Core 身份冲突"));
        }
        identities.insert(binding.id.clone(), repo.id.clone());
    }
    let resolve = |id: &mut String| {
        if let Some(value) = identities.get(id) { *id = value.clone(); }
    };
    for query in queries {
        match query {
            org_tasks_core::CoreQuery::Task { query, repo_ids } => {
                for id in repo_ids { resolve(id); }
                for file in query.include_files.iter_mut().chain(&mut query.exclude_files).chain(&mut query.full_files) {
                    resolve(&mut file.repo_id);
                }
            }
            org_tasks_core::CoreQuery::File { query } => {
                for file in query.include_files.iter_mut().chain(&mut query.exclude_files) { resolve(&mut file.repo_id); }
            }

        }
    }
    Ok(())
}

pub fn workspace_query_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let request: WorkspaceQueryRequest = serde_json::from_str(&query_json)
        .map_err(|_| CoreError::InvalidInput("查询参数无效"))?;
    let (mut queries, bindings) = match request {
        WorkspaceQueryRequest::Queries(queries) => (queries, Vec::new()),
        WorkspaceQueryRequest::Bound(request) => (request.queries, request.repository_bindings),
    };
    let session = workspace_for_handle(handle)?;
    if queries.is_empty() {
        return encode(&Vec::<serde_json::Value>::new());
    }
    let workspace = session;
    resolve_query_repositories(&workspace, &mut queries, &bindings)?;
    let roots = workspace
        .repos()
        .iter()
        .map(|repo| (repo.id.clone(), repo.root_directory.clone()))
        .collect::<BTreeMap<_, _>>();
    let results = runtime(handle)?.block_on(workspace.query(&queries))?;
    let values = results.into_iter().map(|result| query_result_value(result, &roots, None)).collect::<Result<Vec<_>, _>>()?;
    encode(&values)
}

fn query_result_value(result: org_tasks_core::CoreQueryResult, _roots: &BTreeMap<String, String>, ordering: Option<&org_tasks_core::QueryOrdering>) -> Result<serde_json::Value, CoreError> {
    Ok(match result {
        org_tasks_core::CoreQueryResult::Task(result) => serde_json::json!({
            "type": "task", "result": {
                "tasks": result.tasks.into_iter().map(|task| {
                    let key = ordering.map(|ordering| ordering.task_key(&task));
                    let mut view = task_from_filter(task)?; view.order_key = key; Ok(view)
                }).collect::<Result<Vec<_>, CoreError>>()?,
                "categories": result.categories,
                "fullFiles": result.full_files.iter().map(file_snapshot).collect::<Result<Vec<_>, _>>()?,
            }
        }),
        org_tasks_core::CoreQueryResult::File(files) => {
            serde_json::json!({ "type": "file", "result": files.into_iter().map(|file| {
                let key = ordering.map(|ordering| ordering.file_key(&file));
                let mut view = file_metadata_snapshot(file); view.order_key = key; view
            }).collect::<Vec<_>>() })
        }

    })
}

/// monitor 的所有权在进入函数时转交给 Rust，失败路径同样释放。
pub fn workspace_sync_operation(
    handle: u64, request: Result<String, CoreError>, monitor_handle: u64,
) -> Result<String, CoreError> {
    let monitor = HarmonyWebDavSyncMonitor { handle: monitor_handle };
    #[derive(Deserialize)]
    #[serde(tag = "operation", rename_all = "camelCase")]
    enum Request {
        #[serde(rename_all = "camelCase")]
        Set { repo_id: String, webdav_url: String, username: String, password: String,
            excluded_directories: Vec<String> },
        #[serde(rename_all = "camelCase")]
        Remove { repo_id: String },
        Check,
        #[serde(rename_all = "camelCase")]
        Sync { repo_ids: Vec<String>, trigger_reason: org_tasks_core::SyncTriggerReason },
    }
    let request: Request = serde_json::from_str(&request?)
        .map_err(|_| CoreError::InvalidInput("Workspace 同步参数无效"))?;
    let workspace = workspace_for_handle(handle)?;
    let runtime = runtime(handle)?;
    match request {
        Request::Set { repo_id, webdav_url, username, password, excluded_directories } => {
            let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(webdav_url)?, username, password)?;
            let policy = if monitor_handle == 0 { policy } else { policy.with_monitor(monitor) };
            runtime.block_on(workspace.set_sync_policy(&repo_id, policy, excluded_directories))?;
            Ok("null".into())
        }
        Request::Remove { repo_id } => {
            runtime.block_on(workspace.remove_sync_policy(&repo_id))?;
            Ok("null".into())
        }
        Request::Check => {
            let results = runtime.block_on(workspace.check_remote_changes())?;
            encode(&results.into_iter().map(|item| match item.result {
                Ok(state) => serde_json::json!({"repoId":item.repo_id,"state":state,"error":null}),
                Err(error) => serde_json::json!({"repoId":item.repo_id,"state":null,"error":crate::core_error_value(&error)}),
            }).collect::<Vec<_>>())
        }
        Request::Sync { repo_ids, trigger_reason } => {
            let results = runtime.block_on(workspace.sync_repos(&repo_ids, trigger_reason, None, None))?;
            encode(&results.into_iter().map(|item| {
                let result = item.result.and_then(|record| {
                    let record = serde_json::from_value(serde_json::to_value(record)
                        .map_err(|_| CoreError::InvalidState("无法编码同步记录"))?)
                        .map_err(|_| CoreError::InvalidState("无法读取 WebDAV 同步结果"))?;
                    bridge_sync_summary(org_tasks_core::webdav::WebDavSyncRecordSummary::from_record(&record)?)
                });
                match result {
                    Ok(record) => serde_json::json!({"repoId":item.repo_id,"record":record,"error":null}),
                    Err(error) => serde_json::json!({"repoId":item.repo_id,"record":null,"error":crate::core_error_value(&error)}),
                }
            }).collect::<Vec<_>>())
        }
    }
}

fn bridge_sync_summary(
    summary: org_tasks_core::webdav::WebDavSyncRecordSummary,
) -> Result<HarmonyBridgeSync, CoreError> {
    Ok(HarmonyBridgeSync {
        id: summary.id,
        trigger_reason: summary.trigger_reason.map(|reason|serde_json::to_value(reason).expect("原因可序列化").as_str().unwrap().to_owned()),
        result: Some(sync_result_label(Some(summary.result))?),
        execution_result: Some(sync_result_label(Some(summary.execution_result))?),
        started_at: Some(summary.started_at),
        finished_at: summary.finished_at,
        files: Some(summary.files),
        downloaded_files: Some(summary.downloaded_files),
        uploaded_files: Some(summary.uploaded_files),
        conflict_count: Some(summary.conflicts.len()),
        conflicts: summary.conflicts,
        transfer: Some(summary.transfer),
        incomplete: false,
        issues: Vec::new(),
        error_category: summary.error_category,
        error_message: summary.error_message,
    })
}

pub fn repo_snapshot_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    repo_load_files_json(handle, root_directory, "[]".into())
}

pub fn repo_load_files_json(
    handle: u64,
    root_directory: String,
    ignore_files_json: String,
) -> Result<String, CoreError> {
    let ignore_files: Vec<String> = serde_json::from_str(&ignore_files_json)
        .map_err(|_| CoreError::InvalidInput("排除文件必须是仓库相对路径列表"))?;
    let workspace = workspace_for_handle(handle)?;
    let snapshot = runtime(handle)?.block_on(workspace.read_repo(&root_directory, move |repo| async move {
        let files = repo.load_files(&ignore_files).await?.iter().map(file_snapshot).collect::<Result<Vec<_>, _>>()?;
        Ok(HarmonyBridgeRepository { id: repo.id, files })
    }))?;
    encode(&snapshot)
}

fn file_snapshot(file: &org_tasks_core::OrgFile) -> Result<HarmonyBridgeFile, CoreError> {
    let (conflicts, conflict_error) = match file.conflicts() {
        Ok(conflicts) => (conflicts, None),
        Err(error) => {
            let code = match &error {
                CoreError::InvalidInput(_) => "invalidInput",
                CoreError::InvalidState(_) => "invalidState",
                CoreError::Store(_) => "store",
                CoreError::Preview { code, .. } => code,
            };
            (
                Vec::new(),
                Some(serde_json::json!({"code":code,"message":error.to_string()})),
            )
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
        file_version: org_tasks_core::LocalFileVersion::from_bytes(file.source_bytes())
            .content_hash,
        todo: file.todo.clone(),
        has_conflict: file.has_conflict(),
        conflict_ids: file.conflict_ids(),
        category: file.category(),
        title: file.title(),
        title_parts: file.title_parts(),
        rendered_html: file.render_html(),
        document_html: file.render_document_html(),
        document_sections: file.document_sections(),
        file_tags: file.file_tags(),
        header_entries: file.header_entries(),
        special_tags: file.special_tags(),
        project_name: file.project(),
        conflicts,
        conflict_error,
        nodes: file
            .nodes()
            .into_iter()
            .map(task_from_filter)
            .collect::<Result<Vec<_>, _>>()?,
        editable_node_paths: file.editable_node_paths(),
        insertion_positions: file.insertion_positions(),
    })
}

fn workspace_for_handle(handle: u64) -> Result<OrgWorkspace, CoreError> {
    let sessions = workspace_sessions()
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace session 锁不可用".into()))?;
    sessions
        .sessions
        .get(&handle)
        .map(|session| session.workspace.clone())
        .ok_or(CoreError::InvalidInput("workspace handle 无效"))
}

fn runtime(handle: u64) -> Result<Arc<crate::runtime::WorkspaceRuntime>, CoreError> {
    let sessions = workspace_sessions().lock()
        .map_err(|_| CoreError::Store("Harmony workspace session 锁不可用".into()))?;
    sessions.sessions.get(&handle).map(|session| session.runtime.clone())
        .ok_or(CoreError::InvalidInput("workspace handle 无效"))
}

pub fn test_webdav_connection(
    url: String,
    username: String,
    password: String,
) -> Result<(), CoreError> {
    let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(url)?, username, password)?;
    crate::runtime::WorkspaceRuntime::new()?
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

fn state_options(
    mut lookup: impl FnMut(org_tasks_core::TaskStateCategory) -> Option<org_tasks_core::TaskState>,
) -> BTreeMap<String, Option<org_tasks_core::TaskState>> {
    use org_tasks_core::TaskStateCategory::*;
    [Todo, Doing, Wait, Done, Cancel]
        .into_iter()
        .map(|category| (format!("{category:?}"), lookup(category)))
        .collect()
}

fn priority_options(
    mut lookup: impl FnMut(org_tasks_core::PeriodCategory) -> Option<org_tasks_core::TaskPriority>,
) -> BTreeMap<String, Option<org_tasks_core::TaskPriority>> {
    use org_tasks_core::PeriodCategory::*;
    [Hight, Middle, Low].into_iter()
        .map(|category| (format!("{category:?}"), lookup(category))).collect()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HarmonyBridgeFileMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    order_key: Option<Vec<org_tasks_core::QueryOrderPart>>,
    // fileVersion、headerEntries 及现有元信息由 Core 同次生成，宿主原样序列化。
    #[serde(flatten)]
    metadata: org_tasks_core::OrgFileMetadata,
    task_priority_options: BTreeMap<String, Option<org_tasks_core::TaskPriority>>,
    task_state_options: BTreeMap<String, Option<org_tasks_core::TaskState>>,
}

fn file_metadata_snapshot(metadata: org_tasks_core::OrgFileMetadata) -> HarmonyBridgeFileMetadata {
    let task_state_options = state_options(|category| metadata.task_state_of(category));
    let task_priority_options = priority_options(|category| metadata.task_priority_of(category));
    HarmonyBridgeFileMetadata {
        order_key: None,
        task_priority_options,
        metadata,
        task_state_options,
    }
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
    fn priority_objects_and_targets_are_core_snapshots_for_tasks_and_metadata() {
        let handle = create_workspace().unwrap();
        let root = std::env::temp_dir().join(format!("org-priority-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), "#+PRIORITIES: B D C\n* TODO [#C] Task\n* TODO Plain\n").unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let response = workspace_query_json(handle, r#"[{"type":"file","query":{}},{"type":"task","query":{}}]"#.into()).unwrap();
        let values: serde_json::Value = serde_json::from_str(&response).unwrap();
        let file = &values[0]["result"][0];
        let tasks = &values[1]["result"]["tasks"];
        assert_eq!(file["priorityOptions"], tasks[0]["priorityOptions"]);
        assert_eq!(file["taskPriorityOptions"], tasks[0]["taskPriorityOptions"]);
        assert_eq!(tasks[0]["priority"], serde_json::json!({"name":"C","category":"Middle"}));
        assert_eq!(tasks[0]["taskPriorityOptions"]["Hight"]["name"], "B");
        assert_eq!(tasks[0]["taskPriorityOptions"]["Low"]["name"], "D");
        assert!(tasks[1]["priority"].is_null());
        assert_eq!(file["defaultPriority"], serde_json::json!({"name":"C","category":"Middle"}));
        assert_eq!(tasks[1]["defaultPriority"], file["defaultPriority"]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn file_new_crosses_the_existing_operation_bridge_with_template_and_initial_tasks() {
        let root = std::env::temp_dir().join(format!("org-file-new-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let repo_id = workspace_for_handle(handle).unwrap().repos()[0].id.clone();
        let group = serde_json::json!({"operations":[{"type":"FileNew","data":{
            "path":{"repoId":repo_id,"file":"project.org","titles":[]},
            "templateContent":"#+TITLE: {{name}}\n#+FILETAGS: :project:\n#+SETUPFILE:\n",
            "arguments":{"name":"新项目"},"initTasks":[{"title":"初始任务","state":"TODO"}]
        }}]});
        workspace_execute_task_operations(handle, group.to_string()).unwrap();
        let value: serde_json::Value = serde_json::from_str(&workspace_query_json(handle,
            r#"[{"type":"file","query":{}},{"type":"task","query":{}}]"#.into()).unwrap()).unwrap();
        assert_eq!(value[0]["result"][0]["projectName"],"新项目");
        assert_eq!(value[1]["result"]["tasks"][0]["heading"],"初始任务");
        assert!(workspace_execute_task_operations(handle, group.to_string()).is_err());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn trash_and_restore_reuse_the_existing_structured_operation_bridge() {
        let root = std::env::temp_dir().join(format!("org-trash-bridge-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("tasks.org"), "* TODO Bridge leaf\n:PROPERTIES:\n:CREATED: [2020-01-01 Wed]\n:END:\nNotes\n").unwrap();
        std::fs::write(root.join("trash.org"), "#+TITLE: 废纸篓\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let query = |file: &str| -> serde_json::Value {
            let repo_id = workspace_for_handle(handle).unwrap().repos()[0].id.clone();
            serde_json::from_str(&workspace_query_json(handle, serde_json::json!([{"type":"task","query":{"includeFiles":[{"repoId":repo_id,"path":file}]}}]).to_string()).unwrap()).unwrap()
        };
        let before = query("tasks.org");
        let repo_id = before[0]["result"]["tasks"][0]["repoId"].clone();
        workspace_execute_task_operations(handle, serde_json::json!({"operations":[{"type":"Trash","data":{"path":before[0]["result"]["tasks"][0]["fullPath"],"target":{"repoId":repo_id,"path":"trash.org"}}}]}).to_string()).unwrap();
        assert!(query("tasks.org")[0]["result"]["tasks"].as_array().unwrap().is_empty());
        let trash = query("trash.org");
        assert!(trash[0]["result"]["tasks"][0]["properties"]["SOURCE_TIME"].is_string());
        workspace_execute_task_operations(handle, serde_json::json!({"operations":[{"type":"Restore","data":{"path":trash[0]["result"]["tasks"][0]["fullPath"]}}]}).to_string()).unwrap();
        let restored = query("tasks.org");
        assert_eq!(restored[0]["result"]["tasks"][0]["heading"], "Bridge leaf");
        assert_eq!(restored[0]["result"]["tasks"][0]["createdAt"], before[0]["result"]["tasks"][0]["createdAt"]);
        assert!(query("trash.org")[0]["result"]["tasks"].as_array().unwrap().is_empty());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unified_query_json_dispatches_all_kinds_and_rejects_the_old_task_array_protocol() {
        let handle = create_workspace().unwrap();
        let root = std::env::temp_dir().join(format!("org-unified-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), "#+TITLE: File\n* TODO Task\n").unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let response=workspace_query_json(handle,r#"[{"type":"file","query":{}},{"type":"task","query":{}}]"#.into()).unwrap();
        let values: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(values[0]["type"], "file");
        assert_eq!(values[0]["result"][0]["title"], "File");
        assert_eq!(values[1]["type"], "task");
        assert_eq!(values[1]["result"]["tasks"][0]["heading"], "Task");
        assert!(workspace_query_json(handle, r#"[{"type":"notification","query":{}}]"#.into()).is_err());
        assert!(workspace_query_json(handle, "[{}]".into()).is_err());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn project_names_cross_metadata_and_task_projections_without_host_parsing() {
        let root = std::env::temp_dir().join(format!("org-project-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("project.org"), "#+TITLE: Fallback\n#+FILETAGS: :project:\n#+PROJECT_NAME: Shared Project\n* TODO First\n* TODO Second\n").unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().into_owned();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let metadata: serde_json::Value =
            serde_json::from_str(&query_files_json(handle, directory).unwrap()).unwrap();
        let results: serde_json::Value =
            serde_json::from_str(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap();
        let source_file = org_tasks_core::OrgFile::new("repo".into(), "project.org".into(),
            std::fs::read(root.join("project.org")).unwrap()).unwrap();
        let snapshot = serde_json::to_value(file_snapshot(&source_file).unwrap()).unwrap();
        assert_eq!(snapshot["projectName"], "Shared Project");
        assert_eq!(snapshot["fileTags"], serde_json::json!(["project"]));
        assert_eq!(snapshot["headerEntries"][0]["name"], "TITLE");
        assert_eq!(snapshot["headerEntries"][0]["value"], "Fallback");
        assert_eq!(snapshot["headerEntries"][1]["name"], "FILETAGS");
        assert_eq!(snapshot["headerEntries"][1]["value"], ":project:");
        assert_eq!(snapshot["headerEntries"][1]["tags"], serde_json::json!(["project"]));
        assert_eq!(snapshot["specialTags"], serde_json::json!(["project", "REFILE", "ARCHIVE", "CONFLICT", "ATTACH"]));
        assert_eq!(snapshot["documentSections"].as_array().unwrap().len(), 3);
        assert!(snapshot["documentSections"][0]["path"].is_null());
        assert!(snapshot["documentSections"][1]["linkTargets"].as_array().unwrap().iter()
            .all(|target| target["target"].is_string() && target["priority"] == 2));
        assert_eq!(snapshot["documentSections"][1]["path"], snapshot["nodes"][0]["fullPath"]);
        assert!(snapshot["documentHtml"].as_str().unwrap().contains("document-project-name"));
        assert!(snapshot["documentHtml"].as_str().unwrap().contains("data-org-task=\"true\""));
        assert_eq!(metadata[0]["projectName"], "Shared Project");
        assert_eq!(
            results[0]["tasks"][0]["projectName"],
            metadata[0]["projectName"]
        );
        assert_eq!(
            results[0]["tasks"][1]["projectName"],
            metadata[0]["projectName"]
        );
        std::fs::write(root.join("project.org"), ":PROPERTIES:\n:PROJECT_NAME: Drawer\n:PROJECT_NAME+: Project\n:END:\n#+FILETAGS: :project:\n* TODO First\n").unwrap();
        let drawer_metadata: serde_json::Value = serde_json::from_str(
            &query_files_json(handle, root.to_string_lossy().into_owned()).unwrap(),
        )
        .unwrap();
        let drawer_tasks: serde_json::Value =
            serde_json::from_str(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap();
        assert_eq!(drawer_metadata[0]["projectName"], "Drawer Project");
        assert_eq!(
            drawer_tasks[0]["tasks"][0]["projectName"],
            drawer_metadata[0]["projectName"]
        );
        std::fs::write(root.join("project.org"), "#+TITLE: Plain\n* TODO First\n").unwrap();
        let updated: serde_json::Value =
            serde_json::from_str(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap();
        assert!(updated[0]["tasks"][0]["projectName"].is_null());
        assert_eq!(results[0]["tasks"][0]["projectName"], "Shared Project");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn structured_planning_edits_round_trip_time_and_reject_invalid_groups() {
        let root = std::env::temp_dir().join(format!("org-planning-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* TODO Task\r\nSCHEDULED: <2026-11-09 Mon 09:30-10:30 +1w -2d> DEADLINE: <2026-12-01 Tue 18:00 .+1m/2m --3d>\r\nNotes  \r\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let snapshot: serde_json::Value = serde_json::from_str(&repo_file_json(handle, directory.clone(), "tasks.org".into()).unwrap()).unwrap();
        let task = &snapshot["nodes"][0];
        assert_eq!(task["scheduled"], "2026-11-09");
        assert_eq!(task["editContent"]["scheduledPlanning"], serde_json::json!({"date":"2026-11-09","time":{"start":"09:30","end":"10:30"}}));
        assert_eq!(task["editContent"]["deadlinePlanning"]["time"]["start"], "18:00");
        let mut request = serde_json::json!({
            "operations": [{"type":"Modification","data":{"path":task["fullPath"],"modifications":[
                {"field":"SCHEDULE","value":{"date":"2026-11-10","time":{"start":"11:00","end":"12:00"}}},
                {"field":"DEADLINE","value":{"date":"2026-12-02","time":{"start":"24:00","end":null}}}
            ]}}],
            "fileVersions":[{"repoId":task["repoId"],"file":"tasks.org","version":task["fileVersion"]}]
        });
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        assert_eq!(std::fs::read(root.join("tasks.org")).unwrap(), source.as_bytes());
        request["operations"][0]["data"]["modifications"][1]["value"]["time"] = serde_json::Value::Null;
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        let updated: serde_json::Value = serde_json::from_str(&repo_file_json(handle, directory, "tasks.org".into()).unwrap()).unwrap();
        assert_eq!(updated["nodes"][0]["editContent"]["scheduledPlanning"]["time"]["end"], "12:00");
        assert!(updated["nodes"][0]["editContent"]["deadlinePlanning"]["time"].is_null());
        assert_eq!(updated["nodes"][0]["editContent"]["deadlineRepeat"]["rule"], serde_json::json!({"mode":"afterCompletion","interval":1,"unit":"month"}));
        assert_eq!(std::fs::read(root.join("tasks.org")).unwrap(), source.replace("2026-11-09 Mon 09:30-10:30", "2026-11-10 Tue 11:00-12:00").replace("2026-12-01 Tue 18:00", "2026-12-02 Wed").as_bytes());
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn task_completion_uses_first_file_defined_done_keyword() {
        let root = std::env::temp_dir().join(format!("org-complete-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "#+TODO: OPEN | FINISHED(f!) CANCELLED(c)\n* OPEN Task\n原始正文\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let file: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "tasks.org".into()).unwrap(),
        )
        .unwrap();
        let task = &file["nodes"][0];
        assert_eq!(task["taskStateOptions"]["Done"]["name"], "FINISHED");
        let request = serde_json::json!({
            "operations": [{"type":"Modification", "data": {"path":task["fullPath"], "modifications":[{"field":"TODO", "value":task["taskStateOptions"]["Done"]["name"]}]}}],
            "fileVersions": [{"repoId":task["repoId"], "file":"tasks.org", "version":task["fileVersion"]}]
        });
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        let updated: serde_json::Value =
            serde_json::from_str(&repo_file_json(handle, directory, "tasks.org".into()).unwrap())
                .unwrap();
        assert_eq!(updated["nodes"][0]["state"]["name"], "FINISHED");
        assert_eq!(updated["nodes"][0]["state"]["category"], "Done");
        assert!(
            std::fs::read_to_string(root.join("tasks.org"))
                .unwrap()
                .ends_with("原始正文\n")
        );
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reopening_and_completion_keep_logging_after_each_bridge_query() {
        let root = std::env::temp_dir().join(format!("org-reopen-logs-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let history = "- State \"DONE\"       from \"TODO\"       [2026-11-01 Sun 09:00]\n  历史说明保留  \n:END:\n正文  \n";
        let source = format!(
            "#+SETUPFILE: .setup.org\n#+TODO: TODO(t!) INPROGRESS(p) WAIT(w) | DONE(d!)\n* DONE Task\nCLOSED: [2026-11-01 Sun 09:00]\n:LOGBOOK:\n{history}"
        );
        std::fs::write(root.join("tasks.org"), source).unwrap();
        std::fs::write(
            root.join(".setup.org"),
            "#+STARTUP: logdone logdrawer logrepeat\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let mut previous_version = serde_json::Value::Null;
        for (index, (category, expected)) in [
            ("Todo", "TODO"),
            ("Done", "DONE"),
            ("Todo", "TODO"),
            ("Done", "DONE"),
        ]
        .into_iter()
        .enumerate()
        {
            let result: serde_json::Value = serde_json::from_str(
                &query_task_results_json(handle, "[{}]".into()).unwrap(),
            )
            .unwrap();
            let task = &result[0]["tasks"][0];
            assert_ne!(task["fileVersion"], previous_version);
            previous_version = task["fileVersion"].clone();
            assert_eq!(task["taskStateOptions"][category]["name"], expected);
            let request = serde_json::json!({
                "operations": [{"type":"Modification", "data": {"path":task["fullPath"], "modifications":[{"field":"TODO", "value":task["taskStateOptions"][category]["name"]}]}}],
                "fileVersions": [{"repoId":task["repoId"], "file":task["filePath"], "version":task["fileVersion"]}]
            });
            workspace_execute_task_operations(handle, request.to_string()).unwrap();
            let saved = std::fs::read_to_string(root.join("tasks.org")).unwrap();
            assert!(saved.contains(&format!("* {expected} Task\n")), "{saved}");
            assert_eq!(saved.matches("- State ").count(), index + 2, "{saved}");
            assert!(
                saved.contains(&format!(":LOGBOOK:\n- State \"{expected}\"")),
                "{saved}"
            );
            assert!(saved.ends_with(history), "{saved}");
        }
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn workspace_query_only_accepts_batches_and_preserves_result_positions() {
        let handle = create_workspace().unwrap();
        let root = std::env::temp_dir().join(format!("org-batch-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("tasks.org"), "* TODO Pending\n* DONE Finished\n").unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let request = serde_json::json!([
            {"expression": "it.done"}, {"expression": "t.no_such_tag"},
            {"expression": "it.todo"}, {"expression": "it.done"}
        ]);
        let results: serde_json::Value =
            serde_json::from_str(&query_task_results_json(handle, request.to_string()).unwrap())
                .unwrap();
        assert_eq!(results.as_array().unwrap().len(), 4);
        assert_eq!(results[0]["tasks"][0]["heading"], "Finished");
        assert!(results[1]["tasks"].as_array().unwrap().is_empty());
        assert_eq!(results[2]["tasks"][0]["heading"], "Pending");
        assert_eq!(results[0], results[3]);
        assert!(query_task_results_json(handle, "{}".into()).is_err());
        for value in [true, false] {
            let removed = serde_json::json!([
                { "type": "task", "query": { "includeDone": value } }
            ]);
            assert!(workspace_query_json(handle, removed.to_string()).is_err());
        }
        assert!(
            query_task_results_json(
                handle,
                r#"[{}, {"excludeFiles": [{"repoId":"", "path":"tasks.org"}]}]"#.into()
            )
            .is_err()
        );
        std::fs::write(root.join("broken.org"), [0xff]).unwrap();
        assert!(query_task_results_json(handle, request.to_string()).is_err());
        // 空批次不碰业务锁，即使磁盘已损坏也返回空数组。
        assert_eq!(query_task_results_json(handle, "[]".into()).unwrap(), "[]");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn merge_planning_returns_one_ordinary_operation_group_with_a_version_guard() {
        let root = std::env::temp_dir().join(format!("org-merge-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* TODO Main\nmain\n* Source\nextra\n";
        std::fs::write(root.join("inbox.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let file: serde_json::Value =
            serde_json::from_str(&repo_file_json(handle, directory, "inbox.org".into()).unwrap())
                .unwrap();
        let request = serde_json::json!({"paths":[file["nodes"][1]["fullPath"],file["nodes"][0]["fullPath"]],"fileVersion":file["fileVersion"]});
        let plan: serde_json::Value = serde_json::from_str(
            &workspace_task_merge_operations(handle, request.to_string()).unwrap(),
        )
        .unwrap();
        assert_eq!(plan["operationGroup"]["operations"][0]["type"], "Deletion");
        assert_eq!(
            plan["operationGroup"]["operations"][1]["type"],
            "Modification"
        );
        assert_eq!(plan["mainPath"]["titles"][0], "合并: Source");
        assert_eq!(
            std::fs::read_to_string(root.join("inbox.org")).unwrap(),
            source
        );
        workspace_execute_task_operations(handle, plan["operationGroup"].to_string()).unwrap();
        assert!(
            workspace_execute_task_operations(handle, plan["operationGroup"].to_string()).is_err()
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn task_supported_tags_preserve_groups_empty_and_missing_configuration() {
        for (source, expected) in [
            (
                "#+TAGS: { iOS(i) Android(a) } 工作\n* TODO Task\n",
                serde_json::json!({"tags":["iOS","Android","工作"],"groups":[["iOS","Android"]]}),
            ),
            (
                "#+TAGS:\n* TODO Task\n",
                serde_json::json!({"tags":[],"groups":[]}),
            ),
            ("* TODO Task\n", serde_json::Value::Null),
        ] {
            let mut repo = OrgRepo::new("/unused/supported-tags".into()).unwrap();
            repo.id = "repo".into();
            {
                let value = org_tasks_core::OrgFile::new(
                    repo.id.clone(),
                    "tasks.org".into(),
                    source.as_bytes().to_vec(),
                )
                .unwrap();
                test_support::push_file(&mut repo, value);
            };
            let runtime = crate::runtime::WorkspaceRuntime::new().unwrap();
        let workspace = runtime.block_on(OrgWorkspace::start(vec![repo])).unwrap();
            let task = runtime
                .block_on(workspace.query(&[(org_tasks_core::TaskQuery::default()).into()]))
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .remove(0);
            let projection = serde_json::to_value(task_from_filter(task).unwrap()).unwrap();
            assert_eq!(projection["supportTags"], expected);
        }
    }

    #[test]
    fn workspace_notifications_push_one_event_per_conflict_file_and_reuse_cache() {
        let root =
            std::env::temp_dir().join(format!("org-notification-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        for path in ["a.org", "b.org"] {
            std::fs::write(root.join(path), "* 同步冲突 :CONFLICT:\n** Point\n").unwrap();
        }
        // 注册只发送缓存；普通文件查询才发现冲突。
        assert_eq!(serde_json::from_str::<serde_json::Value>(&subscribed_notifications_json(handle).unwrap()).unwrap(), serde_json::json!([]));
        query_files_json(handle, directory.clone()).unwrap();
        let notices: serde_json::Value =
            serde_json::from_str(&subscribed_notifications_json(handle).unwrap()).unwrap();
        let values = notices.as_array().unwrap();
        assert_eq!(values.len(), 2);
        assert_eq!(values[0]["path"], "a.org");
        assert_eq!(values[1]["path"], "b.org");
        assert!(values[0].get("syncId").is_none());
        assert_eq!(values[0]["rootDirectory"], directory);
        std::fs::write(root.join("a.org"), "* Normal\n").unwrap();
        let current: serde_json::Value =
            serde_json::from_str(&subscribed_notifications_json(handle).unwrap()).unwrap();
        assert_eq!(current.as_array().unwrap().len(), 2);
        assert_eq!(current, notices);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sync_history_preserves_legacy_reasons_and_nullable_fields_with_diagnostics() {
        let root = std::env::temp_dir().join(format!("org-history-tolerant-{}", std::process::id()));
        std::fs::create_dir_all(root.join(".sync/history")).unwrap();
        let directory = root.to_string_lossy().to_string();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let original = serde_json::to_vec(&serde_json::json!({
            "id":"legacy", "kind":"webdav", "started_at":10, "finished_at":"bad",
            "result":"Succeeded", "trigger_reason":"appStartup", "event":42,
            "files":[{"relative_path":"good.org","action":"Downloaded","state":"Synchronized"},
                     {"relative_path":"bad.org","action":false}]
        })).unwrap();
        std::fs::write(root.join(".sync/history/10.json"), &original).unwrap();
        std::fs::write(root.join(".sync/history/20.json"), b"{").unwrap();
        let history: serde_json::Value = serde_json::from_str(&repo_history_json(handle,directory.clone()).unwrap()).unwrap();
        assert_eq!(history[0]["triggerReason"], "appStartup");
        assert_eq!(history[0]["result"], "succeeded");
        assert_eq!(history[0]["started_at"], 10);
        for field in ["finished_at","files","downloadedFiles","uploadedFiles","conflictCount","transfer"] {
            assert!(history[0][field].is_null(), "{field}");
        }
        assert_eq!(history[0]["incomplete"], true);
        assert!(history[1]["result"].is_null());
        assert_eq!(history[1]["id"], "history-20");
        let detail: serde_json::Value = serde_json::from_str(&repo_history_detail_json(handle,directory,"legacy".into()).unwrap()).unwrap();
        assert_eq!(detail["files"][0]["outcome"], "downloaded");
        assert!(detail["files"][1]["outcome"].is_null());
        assert!(detail["errors"].as_array().unwrap().iter().any(|error|error["message"].as_str().unwrap().contains("[finished_at]")));
        assert_eq!(std::fs::read(root.join(".sync/history/10.json")).unwrap(), original);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
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
        conflict.trigger_reason = Some(org_tasks_core::SyncTriggerReason::LocalChanged);
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
        std::fs::create_dir_all(root.join(".sync/history")).unwrap();
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
        assert_eq!(history[0]["triggerReason"], "localChanged");
        assert_eq!(history[0]["executionResult"], "succeeded");
        assert_eq!(history[0]["transfer"], "unchanged");
        assert_eq!(history[0]["conflicts"].as_array().unwrap().len(), 2);
        assert!(history[0].get("resolvedConflicts").is_none());
        assert!(history[0]["errorCategory"].is_null());
        assert_eq!(history[1]["transfer"], "download");
        assert_eq!(history[1]["triggerReason"], serde_json::Value::Null);
        assert_eq!(history[1]["downloadedFiles"], 1);
        assert_eq!(history[1]["uploadedFiles"], 0);
        let detail: serde_json::Value = serde_json::from_str(
            &repo_history_detail_json(handle, directory.clone(), "conflict".into()).unwrap(),
        )
        .unwrap();
        assert!(detail["summary"].get("pendingConflicts").is_none());
        assert_eq!(detail["summary"]["triggerReason"], "localChanged");
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
        std::fs::write(
            root.join("work.org"),
            "#+TITLE: 工作计划\n#+TAGS: { 家居(j) unused(u) }\n* TODO Task :家居:\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.to_string_lossy().to_string();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let metadata: serde_json::Value =
            serde_json::from_str(&query_files_json(handle, directory.clone()).unwrap()).unwrap();
        assert_eq!(metadata[0]["title"], "工作计划");
        assert_eq!(metadata[0]["path"], "work.org");
        assert_eq!(metadata[0]["isIgnore"], false);
        assert_eq!(metadata[0]["taskStateCounts"], serde_json::json!([
            { "state": "TODO", "category": "Todo", "count": 1 }
        ]));
        assert!(metadata[0].get("taskCount").is_none());
        assert_eq!(
            metadata[0]["tagOptions"],
            serde_json::json!(["家居", "unused"])
        );
        assert_eq!(
            metadata[0]["tagGroups"],
            serde_json::json!([["家居", "unused"]])
        );
        assert_eq!(metadata[0]["tagRows"], serde_json::json!([["家居", "unused"]]));
        let tasks: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, r#"[{"expression":"t.家居"}]"#.into()).unwrap(),
        )
        .unwrap()
        .remove(0);
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
            serde_json::from_str(&query_files_json(handle, directory).unwrap()).unwrap();
        assert_eq!(changed[0]["title"], "");
        assert_eq!(changed[0]["tagOptions"], serde_json::json!([]));
        assert_eq!(changed[0]["tagGroups"], serde_json::json!([]));
        std::fs::write(root.join(".orgzlyignore"), "work.org\n").unwrap();
        let ignored: serde_json::Value =
            serde_json::from_str(&query_files_json(handle, root.to_string_lossy().into()).unwrap())
                .unwrap();
        assert_eq!(ignored[0]["isIgnore"], true);
        assert_eq!(ignored[0]["taskStateCounts"], serde_json::json!([]));
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
            let metadata: serde_json::Value = serde_json::from_str(
                &query_files_json(handle, directory.clone()).unwrap(),
            ).unwrap();
            assert_eq!(metadata.as_array().unwrap().iter().find(|file| file["path"] == path).unwrap()["category"], expected);
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
            "expression": ".it.done s.none d.none",
        })
        .to_string();
        let queried: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, format!("[{query}]")).unwrap(),
        )
        .unwrap()
        .remove(0);
        assert_eq!(queried["tasks"].as_array().unwrap().len(), 1);
        assert_eq!(queried["tasks"][0]["heading"], "Visible");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn location_update_returns_a_fresh_task_for_the_editor() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-location-editor-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("work.org"), "* TODO Visit\n[[addr:old][Place]]\n").unwrap();
        let directory = root.to_string_lossy().to_string();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory).unwrap();
        let records: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
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
            serde_json::from_str::<Vec<serde_json::Value>>(
                &query_task_results_json(handle, serde_json::json!([{"includeFiles":[{"repoId":repo_id(handle, root_directory.clone()).unwrap(),"path":"inbox.org"}]}]).to_string())
                    .unwrap(),
            )
            .unwrap()
            .remove(0)
        };
        let before = query();
        std::fs::write(&file, "* DONE Charlie [1/1]\n新正文\n* TODO Delta\n").unwrap();
        let after = query();
        assert_eq!(after["tasks"].as_array().unwrap().len(), 2);
        assert_eq!(before["tasks"][2]["id"], after["tasks"][0]["id"]);
        assert_eq!(before["tasks"][3]["id"], after["tasks"][1]["id"]);
        assert_ne!(before["tasks"][0]["id"], after["tasks"][0]["id"]);
        assert_eq!(after["tasks"][0]["heading"], "Charlie [1/1]");
        assert_eq!(after["tasks"][0]["state"]["category"], "Done");
        assert_eq!(after["tasks"][0]["body"], "新正文\n");
        assert_eq!(before["tasks"][2]["state"]["category"], "Todo");
        let session = workspace_for_handle(handle).unwrap();
        let core_tasks = runtime(handle)
            .unwrap()
            .block_on(
                session.query(&[(org_tasks_core::TaskQuery::default()).into()]),
            )
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap()
            .tasks;
        assert_eq!(after["tasks"][0]["id"], core_tasks[0].id());
        assert!(
            serde_json::from_str::<serde_json::Value>(core_tasks[0].id())
                .unwrap()
                .is_array()
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn created_date_expression_and_cancelled_projection_cross_existing_query_bridge() {
        let root = std::env::temp_dir().join(format!("org-created-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("tasks.org"), "#+TODO: TODO | STOP DONE\n#+TASK_STATE_CATEGORY: Cancel STOP\n* STOP Cancelled\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 10:00]\n:END:\n* DONE Finished\nCLOSED: [2026-11-09 Mon 15:45]\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 11:00]\n:END:\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let all: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, r#"[{"expression":".o.created"}]"#.into()).unwrap(),
        )
        .unwrap()
        .remove(0);
        let tasks = all["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["heading"], "Finished");
        assert_eq!(tasks[1]["heading"], "Cancelled");
        assert_ne!(tasks[0]["state"]["category"], "Cancel");
        assert_eq!(tasks[1]["state"]["category"], "Cancel");
        assert_eq!(tasks[1]["state"]["category"], "Cancel");
        assert_eq!(tasks[0]["state"]["category"], "Done");
        assert_eq!(tasks[1]["taskStateOptions"]["Done"]["name"], "DONE");
        assert!(tasks[0]["createdAt"].as_i64().is_some());
        assert!(tasks[0]["closedAt"].as_i64().unwrap() > tasks[0]["createdAt"].as_i64().unwrap());
        assert!(tasks[1]["closedAt"].is_null());
        assert!(tasks[0]["modifiedAt"].is_null());
        let query = serde_json::json!({ "expression": "cr.ge.-2d cr.le.today .o.created" });
        let result: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, serde_json::json!([query]).to_string()).unwrap(),
        )
        .unwrap()
        .remove(0);
        // 固定样例只在其创建日期落入最近三个自然日时匹配。
        let projection = workspace_for_handle(handle).unwrap();
        let expected = runtime(handle)
            .unwrap()
            .block_on(
                projection.query(&[(org_tasks_core::TaskQuery {
                        expression: "cr.ge.-2d cr.le.today .o.created".into(),
                        ..Default::default()
                    })
                    .into()]),
            )
            .unwrap()
            .remove(0)
            .into_task()
            .unwrap()
            .tasks
            .len();
        assert_eq!(result["tasks"].as_array().unwrap().len(), expected);
        let excluded = serde_json::json!({ "excludeFiles": [{ "repoId":tasks[0]["repoId"], "path":"tasks.org" }] });
        let result: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, serde_json::json!([excluded]).to_string()).unwrap(),
        )
        .unwrap()
        .remove(0);
        assert!(result["tasks"].as_array().unwrap().is_empty());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn generic_properties_round_trip_without_a_folding_specific_interface() {
        let root = std::env::temp_dir().join(format!("org-properties-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* Heading\r\n:PROPERTIES:\r\n:KEEP: untouched\r\n:VISIBILITY: all\r\n:END:\r\n正文  \r\n** TODO Child\r\n子正文\r\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        for value in [serde_json::json!("folded"), serde_json::json!("all"), serde_json::Value::Null] {
            let before: serde_json::Value = serde_json::from_str(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap();
            let task = &before[0]["tasks"][0];
            let request = serde_json::json!({"operations":[{"type":"Modification","data":{
                "path":task["fullPath"], "modifications":[{"field":"PROPERTY","value":{"name":"VISIBILITY","value":value}}]
            }}],"fileVersions":[{"repoId":task["repoId"],"file":task["filePath"],"version":task["fileVersion"]}]});
            workspace_execute_task_operations(handle, request.to_string()).unwrap();
            let after: serde_json::Value = serde_json::from_str(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap();
            assert_eq!(after[0]["tasks"][0]["properties"]["VISIBILITY"], value);
            assert_eq!(after[0]["tasks"][0]["properties"]["KEEP"], "untouched");
            assert!(after[0]["tasks"][1]["properties"]["VISIBILITY"].is_null());
            assert!(after[0]["tasks"][0].get("isSubtreeFolded").is_none());
            assert!(after[0]["tasks"][0]["editContent"].get("visibility").is_none());
        }
        let actual = std::fs::read_to_string(root.join("tasks.org")).unwrap();
        // 工作区会维护修改时间；其余原属性、正文与子树仍完整保留。
        assert!(actual.contains(":KEEP: untouched\r\n"));
        assert!(actual.ends_with("正文  \r\n** TODO Child\r\n子正文\r\n"));
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn attachment_tag_is_hidden_but_preserved_as_a_readonly_task_flag() {
        let file = org_tasks_core::OrgFile::new("repo".into(), "tasks.org".into(),
            b"* TODO Attached :ATTACH:work:\n** TODO Child :home:\n".to_vec()).unwrap();
        let snapshot = serde_json::to_value(file_snapshot(&file).unwrap()).unwrap();
        assert_eq!(snapshot["nodes"][0]["hasAttach"], true);
        assert_eq!(snapshot["nodes"][1]["hasAttach"], false);
        assert_eq!(snapshot["nodes"][0]["tags"], serde_json::json!(["work"]));
        assert_eq!(snapshot["nodes"][1]["tags"], serde_json::json!(["home", "work"]));
        assert!(snapshot["nodes"][0]["ownTags"].as_array().unwrap().contains(&serde_json::json!("ATTACH")));
        assert!(snapshot["specialTags"].as_array().unwrap().contains(&serde_json::json!("ATTACH")));
    }

    #[test]
    fn content_blocks_are_ordered_and_local_edits_reject_stale_versions() {
        let root = std::env::temp_dir().join(format!("org-content-blocks-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* TODO Task\r\nBefore\r\n\r\n| A | B |\r\n| 1 | 2 |\r\n\r\n- [ ] Item\r\n:LOGBOOK:\r\nkeep\r\n:END:\r\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let result = serde_json::from_str::<Vec<serde_json::Value>>(&query_task_results_json(handle, "[{}]".into()).unwrap()).unwrap().remove(0);
        let task = &result["tasks"][0];
        let blocks = task["editContent"]["blocks"].as_array().unwrap();
        assert_eq!(blocks.iter().map(|b| b["kind"].as_str().unwrap()).collect::<Vec<_>>(), ["text", "table", "checklist"]);
        assert_eq!(blocks[2]["items"][0]["text"], "Item");
        assert_eq!(blocks[0]["paragraph"], true);
        assert_eq!(blocks[1]["paragraph"], false);
        assert_eq!(blocks[1]["blankLinesBefore"], 1);
        let snapshot: serde_json::Value = serde_json::from_str(&repo_file_json(handle,
            root.to_string_lossy().into_owned(), "tasks.org".into()).unwrap()).unwrap();
        assert_eq!(snapshot["documentSections"][1]["blocks"], task["editContent"]["blocks"]);
        let request = serde_json::json!({
            "operations":[{"type":"Modification","data":{"path":task["fullPath"],"modifications":[
                {"field":"CONTENT_BLOCK","value":{"type":"replace","id":blocks[1]["id"],"source":"| A | B |\n| 3 | 4 |"}}
            ]}}],
            "fileVersions":[{"repoId":task["repoId"],"file":task["filePath"],"version":task["fileVersion"]}]
        });
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        let expected = source.replace("| 1 | 2 |", "| 3 | 4 |");
        assert_eq!(std::fs::read_to_string(root.join("tasks.org")).unwrap(), expected);
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        assert_eq!(std::fs::read_to_string(root.join("tasks.org")).unwrap(), expected);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn checklist_move_preserves_bytes_and_rejects_old_snapshot_across_bridge() {
        let root =
            std::env::temp_dir().join(format!("org-checklist-move-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* TODO Task [[https://example.com/title][链接]]\r\nNotes https://example.com/  \r\n- [X] Parent\r\n  - [-] Nested\r\n- [ ] Sibling\r\n\r\n** Child\r\nUnchanged\r\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let query = || -> serde_json::Value {
            serde_json::from_str::<Vec<serde_json::Value>>(
                &query_task_results_json(handle, "[{}]".into()).unwrap(),
            )
            .unwrap()
            .remove(0)
        };
        let before = query();
        let task = &before["tasks"][0];
        assert_eq!(task["headingParts"][1]["link"]["source"], "[[https://example.com/title][链接]]");
        assert_eq!(task["headingParts"][1]["link"]["url"], "https://example.com/title");
        assert!(task["editContent"]["notesHtml"].as_str().unwrap().contains("href=\"https://example.com/\""));
        assert!(!task["editContent"]["notesHtml"].as_str().unwrap().contains("Parent"));
        let items = &task["editContent"]["checklist"];
        assert_eq!(items[0]["siblingGroup"], items[2]["siblingGroup"]);
        assert_ne!(items[0]["siblingGroup"], items[1]["siblingGroup"]);
        let request = serde_json::json!({
            "operations":[{"type":"Modification","data":{"path":task["fullPath"],"modifications":[
                {"field":"CHECKLIST","value":{"type":"move","id":items[0]["id"],"beforeId":null}}
            ]}}],
            "fileVersions":[{"repoId":task["repoId"],"file":task["filePath"],"version":task["fileVersion"]}]
        });
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        let expected = source.replace(
            "- [X] Parent\r\n  - [-] Nested\r\n- [ ] Sibling\r\n",
            "- [ ] Sibling\r\n- [X] Parent\r\n  - [-] Nested\r\n",
        );
        assert_eq!(
            std::fs::read_to_string(root.join("tasks.org")).unwrap(),
            expected
        );
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        assert_eq!(
            std::fs::read_to_string(root.join("tasks.org")).unwrap(),
            expected
        );
        let after = query();
        let updated = &after["tasks"][0];
        assert_ne!(updated["fileVersion"], task["fileVersion"]);
        assert_eq!(updated["editContent"]["checklist"][0]["text"], "Sibling");
        assert_eq!(updated["editContent"]["checklist"][1]["checked"], true);
        assert_eq!(updated["editContent"]["checklist"][2]["partial"], true);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn task_modified_time_projects_own_property_and_keeps_disk_only_time_null() {
        let root =
            std::env::temp_dir().join(format!("org-task-modified-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* Missing\n:PROPERTIES:\n:CREATED: [2030-01-01 Tue 12:00]\n:END:\n* Old\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-08 Sun 09:00]\n:END:\n* New\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-09 Mon 10:00]\n:END:\n";
        std::fs::write(root.join("notes.org"), source).unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let result: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, r#"[{"expression":".o.modified"}]"#.into()).unwrap(),
        )
        .unwrap()
        .remove(0);
        let tasks = result["tasks"].as_array().unwrap();
        assert_eq!(
            tasks
                .iter()
                .map(|task| task["heading"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["New", "Old", "Missing"]
        );
        assert!(
            tasks[0]["modifiedAt"].as_i64().unwrap() > tasks[1]["modifiedAt"].as_i64().unwrap()
        );
        assert!(tasks[2]["modifiedAt"].is_null());
        assert!(tasks[2]["createdAt"].as_i64().is_some());
        assert_eq!(
            std::fs::read_to_string(root.join("notes.org")).unwrap(),
            source
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn scoped_refile_query_and_someday_edit_options_cross_bridge() {
        let root = std::env::temp_dir().join(format!("org-someday-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), "#+CATEGORY: InboxOnly\n* DONE Move me\nSCHEDULED: <2026-11-08 Sun> DEADLINE: <2026-11-09 Mon>\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 09:00]\n:END:\n* Inbox :REFILE:\n").unwrap();
        std::fs::write(
            root.join("someday.org"),
            "#+CATEGORY: LaterOnly\n* First :REFILE:\n** Existing\n* Second :REFILE:\n",
        )
        .unwrap();
        std::fs::write(
            root.join("normal.org"),
            "#+CATEGORY: Work\n#+FILETAGS: :project:\n#+PROJECT_NAME: 官网改版\n* Work :REFILE:\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let tasks: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, serde_json::json!([{"includeFiles":[{"repoId":repo_id(handle, root.to_string_lossy().into_owned()).unwrap(),"path":"inbox.org"}]}]).to_string()).unwrap(),
        )
        .unwrap()
        .remove(0);
        let task = tasks["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["heading"] == "Move me")
            .unwrap();
        let query = serde_json::json!({ "excludedFiles": [ {"repoId": task["repoId"], "path": "inbox.org"}, {"repoId":task["repoId"],"path":"someday.org"} ] });
        let targets: serde_json::Value = serde_json::from_str(
            &workspace_refile_targets_json(handle, query.to_string()).unwrap(),
        )
        .unwrap();
        assert_eq!(targets.as_array().unwrap().len(), 1);
        assert_eq!(targets[0]["category"], "Work");
        assert_eq!(targets[0]["projectName"], "官网改版");
        let mut project_query = query.clone();
        project_query["includeProjectRoots"] = serde_json::json!(true);
        let project_targets: serde_json::Value = serde_json::from_str(
            &workspace_refile_targets_json(handle, project_query.to_string()).unwrap(),
        ).unwrap();
        assert_eq!(project_targets.as_array().unwrap().len(), 2);
        assert_eq!(project_targets[0]["fullPath"]["titles"], serde_json::json!([]));
        assert_eq!(project_targets[0]["fullPath"]["file"], "normal.org");
        assert_eq!(project_targets[0]["fileVersion"], targets[0]["fileVersion"]);
        let query =
            serde_json::json!({ "files": [{"repoId":task["repoId"],"path":"someday.org"}] });
        let targets: serde_json::Value = serde_json::from_str(
            &workspace_refile_targets_json(handle, query.to_string()).unwrap(),
        )
        .unwrap();
        let target = &targets[0];
        assert_eq!(target["headingPath"][0], "First");
        let request = serde_json::json!({ "operations": [
            {"type":"Modification", "data":{"path":task["fullPath"], "modifications":[
                {"field":"TODO", "value":"TODO"}, {"field":"SCHEDULE", "value":null},
                {"field":"DEADLINE", "value":null}]}},
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
        let root =
            std::env::temp_dir().join(format!("org-inbox-edit-bridge-{}", std::process::id()));
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
            serde_json::from_str(&workspace_refile_targets_json(handle, "{}".into()).unwrap())
                .unwrap();
        let target = &targets[0];
        assert_eq!(target["category"], "Work");
        let request = serde_json::json!({"operations":[{"type":"Movement","data":{"path":task["fullPath"],"position":{"parent":target["fullPath"]}}}]});
        workspace_execute_task_operations(handle, request.to_string()).unwrap();
        assert!(workspace_execute_task_operations(handle, request.to_string()).is_err());
        assert_eq!(std::fs::read_to_string(root.join("inbox.org")).unwrap(), "");
        let source = std::fs::read_to_string(root.join("targets.org")).unwrap();
        assert!(source.contains("* Parent :REFILE:\n** TODO Move me\n:PROPERTIES:\n"));
        assert!(source.ends_with(":END:\n** Existing\n"));
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn capture_creation_automatically_records_created_and_survives_reload() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-capture-created-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let original = "* TODO Existing\n:PROPERTIES:\n:CREATED: [2020-01-02 Thu 03:04]\n:END:\n";
        std::fs::write(root.join("inbox.org"), original).unwrap();
        let directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory.clone()).unwrap();
        let id = repo_id(handle, directory.clone()).unwrap();
        workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"}},"title":"Captured","state":"TODO"}}]}).to_string()).unwrap();
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
        let id = repo_id(handle, root_directory.clone()).unwrap();
        let records: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "".into()).unwrap()).unwrap();
        workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"},"after":records[0]["fullPath"]},"title":"created from bridge","state":"TODO"}}]}).to_string()).unwrap();
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
        let source = response["files"][0]["source"].as_str().unwrap();
        assert!(
            source.starts_with(
                "* TODO bridge\n* TODO created from bridge\n:PROPERTIES:\n:CREATED: ["
            )
        );
        assert!(source.ends_with("]\n:END:\n"));
        assert_eq!(
            source,
            std::fs::read_to_string(root.join("inbox.org")).unwrap()
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
    encode(&runtime(handle)?.block_on(workspace.read_repo(&root_directory, |repo| async move {
        repo.pending_sync_conflicts().await
    }))?)
}

pub fn workspace_get_settings_json(handle: u64) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    encode(&workspace.get_settings())
}

pub fn workspace_set_settings(handle: u64, json: String) -> Result<(), CoreError> {
    let settings: org_tasks_core::CoreSettings = serde_json::from_str(&json)
        .map_err(|_| CoreError::InvalidInput("CoreSettings 参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    runtime(handle)?.block_on(workspace.set_settings(settings))
}

pub fn workspace_set_todo_defaults(handle: u64, settings: String) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    runtime(handle)?.block_on(workspace.set_todo_defaults_text(&settings))
}

pub fn repo_file_json(
    handle: u64,
    root_directory: String,
    path: String,
) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let file = runtime(handle)?.block_on(workspace.read_repo(&root_directory, move |repo| async move {
        repo.file(&path).await
    }))?;
    encode(&file_snapshot(&file)?)
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
            serde_json::from_str(&query_tasks_json(handle, "it.done".into()).unwrap()).unwrap();
        assert_eq!(done.as_array().unwrap().len(), 2);
        assert_eq!(done[0]["state"]["category"], "Done");
        assert_eq!(done[0]["isDone"], true);
        assert!(workspace_set_todo_defaults(handle, "invalid".into()).is_err());
        workspace_set_todo_defaults(handle, "#+TODO: OTHER | END".into()).unwrap();
        let done: serde_json::Value =
            serde_json::from_str(&query_tasks_json(handle, "it.done".into()).unwrap()).unwrap();
        assert_eq!(done.as_array().unwrap().len(), 1);
        assert_eq!(done[0]["isDone"], true);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn task_list_display_hints_are_serialized_without_parsing_in_host() {
        let mut repo = OrgRepo::new("/tmp/harmony-display-hints".into()).unwrap();
        repo.id = "display".into();
        {
            let value = org_tasks_core::OrgFile::new(
                repo.id.clone(),
                "tasks.org".into(),
                b"#+CATEGORY: Work\n* TODO Task [1/2] :work:\nSCHEDULED: <2026-11-06 Fri +1d>\n:PROPERTIES:\n:STYLE: habit\n:END:\n- [ ] First\n:LOGBOOK:\n- Note taken on [2026-11-13 Fri 09:00] \\\\\n  *Note*\n:END:\n"
                    .to_vec(),
            )
            .unwrap();
            test_support::push_file(&mut repo, value);
        };
        let runtime = crate::runtime::WorkspaceRuntime::new().unwrap();
        let workspace = runtime.block_on(OrgWorkspace::start(vec![repo])).unwrap();
        let task = task_from_filter(
            runtime
                .block_on(workspace.query(&[(org_tasks_core::TaskQuery::default()).into()]))
                .unwrap()
                .remove(0)
                .into_task()
                .unwrap()
                .tasks
                .remove(0),
        )
        .unwrap();
        let value = serde_json::to_value(task).unwrap();
        assert_eq!(value["heading"], "Task [1/2]");
        assert_eq!(value["headingParts"][1]["count"]["completed"], 1);
        assert_eq!(value["headingParts"][1]["count"]["total"], 2);
        assert_eq!(value["state"]["category"], "Todo");
        assert_eq!(value["editContent"]["noteRequiredStates"], serde_json::json!([]));
        assert_eq!(value["hasList"], true);
        assert_eq!(value["hasText"], false);
        assert_eq!(value["logs"][0]["type"], "taskNote");
        assert_eq!(value["logs"][0]["timestamp"], "2026-11-13 09:00");
        assert!(value["logs"][0]["noteHtml"].as_str().unwrap().contains("<b>Note</b>"));
        assert!(value["logbookHtml"].as_str().unwrap().contains("Note"));
        assert!(!value["bodyHtml"].as_str().unwrap().contains("Note"));
        assert_eq!(value["isRepeating"], true);
        assert_eq!(value["isHabit"], true);
        assert_eq!(value["category"], "Work");
        assert_eq!(value["scheduled"], "2026-11-06");
        assert_eq!(
            value["editContent"]["scheduledRepeat"]["rule"],
            serde_json::json!({"mode":"cumulative","interval":1,"unit":"day"})
        );
        assert_eq!(
            value["editContent"]["scheduledRepeat"]["date"],
            "2026-11-06"
        );
        assert!(value["editContent"]["deadlineRepeat"].is_null());
        assert!(value["modifiedAt"].is_null());
        assert!(value["bodyHtml"].as_str().unwrap().contains("<ul>"));
        assert_eq!(value["bodyFirstLine"], "First");
        assert_eq!(value["tags"][0], "work");
    }
}

/// 放置目标和任务整理均由 Core 求值，bridge 只取得命令句柄并在宿主运行时等待结果。
pub fn workspace_refile_targets_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let query: org_tasks_core::RefileTargetQuery = serde_json::from_str(&query_json)
        .map_err(|_| CoreError::InvalidInput("放置目标查询参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let runtime = runtime(handle)?;
    // 包括 titleParts 的完整 Core 投影，保持标题原文与展示分段各自的边界。
    encode(&runtime.block_on(workspace.query_refile_targets(&query))?)
}

pub fn workspace_execute_task_operations(
    handle: u64,
    request: String,
) -> Result<String, CoreError> {
    // bridge 透传结构化操作组，由 Core 校验清单位置并统一调度和提交。
    let group: org_tasks_core::TaskOperationGroup = serde_json::from_str(&request)
        .map_err(|_| CoreError::InvalidInput("任务操作组参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    runtime(handle)?.block_on(workspace.execute_task_operations(&group))?;
    Ok("{}".into())
}

pub fn workspace_task_merge_operations(handle: u64, request: String) -> Result<String, CoreError> {
    let request: org_tasks_core::TaskMergeRequest =
        serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("记录合并参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    encode(&runtime(handle)?.block_on(workspace.task_merge_operations(&request))?)
}

/// 公开对象方法在 ABI 内统一编组；操作及路径校验仍由 Core 完成。
pub fn repo_history_operation(
    handle: u64,
    root: String,
    request: String,
) -> Result<String, CoreError> {
    #[derive(serde::Deserialize)]
    #[serde(tag = "operation", rename_all = "camelCase")]
    enum Request {
        LastEffectSync,
        #[serde(rename_all = "camelCase")]
        File {
            sync_id: String,
            path: String,
            resolved: bool,
        },
    }
    let request: Request =
        serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("历史文件参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    runtime(handle)?.block_on(workspace.read_repo(&root, move |repo| async move {
        match request {
            Request::LastEffectSync => {
                let current = repo.last_effect_sync().await?;
                let summary = current
                    .map(|r| {
                        bridge_sync_summary(
                            org_tasks_core::webdav::WebDavSyncRecordSummary::from_record(&r)?,
                        )
                    })
                    .transpose()?;
                encode(&summary)
            }
            Request::File {
                sync_id,
                path,
                resolved,
            } => encode(&file_snapshot(
                &repo.history_file(&sync_id, &path, resolved).await?,
            )?),
        }
    }))
}

static NOTIFICATION_SUBSCRIPTIONS: OnceLock<
    Mutex<BTreeMap<u64, org_tasks_core::NotificationSubscription>>,
> = OnceLock::new();
static NEXT_NOTIFICATION_SUBSCRIPTION: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(1);
static DATA_CHANGE_SUBSCRIPTIONS: OnceLock<
    Mutex<BTreeMap<u64, org_tasks_core::DataChangeSubscription>>,
> = OnceLock::new();
static NEXT_DATA_CHANGE_SUBSCRIPTION: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(1);
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
        unsafe {
            org_tasks_harmony_notification_monitor_release(self.0);
        }
    }
}
fn notification_values(notifications: Vec<org_tasks_core::CoreNotification>, roots: &BTreeMap<String, String>) -> Vec<serde_json::Value> {
    notifications.into_iter().map(|notification| {
        let mut value = serde_json::to_value(&notification).expect("通知可序列化");
        let repo_id = match &notification {
            org_tasks_core::CoreNotification::SyncConflict(conflict) => Some(&conflict.repo_id),
            org_tasks_core::CoreNotification::SyncBaselineUnavailable { repo_id, .. } => Some(repo_id),
            _ => None,
        };
        if let Some(repo_id) = repo_id { value["rootDirectory"] = roots.get(repo_id).cloned().unwrap_or_default().into(); }
        value
    }).collect()
}

pub fn workspace_watch_notifications(handle: u64, monitor: u64, scope_json: &str) -> Result<u64, CoreError> {
    let monitor = NotificationMonitor(monitor);
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let scope = serde_json::from_str::<Option<Vec<String>>>(scope_json).map_err(|_| CoreError::InvalidInput("通知订阅范围无效"))?;
    let roots = workspace.repos().into_iter().map(|repo| (repo.id, repo.root_directory)).collect::<BTreeMap<_, _>>();
    struct BridgeMonitor { handle: NotificationMonitor, roots: BTreeMap<String, String> }
    impl BridgeMonitor {
        fn send(&self, mut event: serde_json::Value) {
            fn attach(value: &mut serde_json::Value, roots: &BTreeMap<String, String>) {
                match value {
                    serde_json::Value::Array(values) => for value in values { attach(value, roots); },
                    serde_json::Value::Object(object) => {
                        if let Some(id) = object.get("repoId").and_then(|id| id.as_str()) {
                            let root = roots.get(id).cloned().unwrap_or_default();
                            object.insert("rootDirectory".into(), root.into());
                        }
                        for value in object.values_mut() { attach(value, roots); }
                    }
                    _ => {},
                }
            }
            attach(&mut event, &self.roots);
            if let Ok(json) = serde_json::to_string(&event).and_then(|s| CString::new(s).map_err(serde::ser::Error::custom)) {
                #[cfg(not(test))]
                unsafe { org_tasks_harmony_notification_update(self.handle.0, json.as_ptr()); }
                #[cfg(test)]
                let _ = (&self.handle, json);
            }
        }
    }
    impl org_tasks_core::NotificationMonitor for BridgeMonitor {
        fn snapshot(&self, snapshot: org_tasks_core::NotificationSnapshot) {
            let mut event = serde_json::to_value(snapshot).expect("通知快照可序列化");
            event["type"] = "snapshot".into();
            self.send(event);
        }
        fn changed(&self, delta: org_tasks_core::NotificationDelta) {
            let mut event = serde_json::to_value(delta).expect("通知增量可序列化");
            event["type"] = "changed".into();
            self.send(event);
        }
    }
    let subscription = workspace.watch_notifications(scope, BridgeMonitor { handle: monitor, roots })?;
    let id = NEXT_NOTIFICATION_SUBSCRIPTION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    NOTIFICATION_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| CoreError::Store("通知订阅锁不可用".into()))?
        .insert(id, subscription);
    Ok(id)
}
pub fn workspace_unwatch_notifications(id: u64) {
    // 在锁外销毁回调资源，避免释放宿主句柄时重入注册表。
    let removed = NOTIFICATION_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&id));
    drop(removed);
}

static EXTERNAL_FILE_SUBSCRIPTIONS: OnceLock<Mutex<BTreeMap<u64, org_tasks_core::ExternalFileSubscription>>> = OnceLock::new();
static NEXT_EXTERNAL_FILE_SUBSCRIPTION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

struct DataChangeMonitor(u64);
impl Drop for DataChangeMonitor {
    fn drop(&mut self) {
        #[cfg(test)]
        let _ = self.0;
        #[cfg(not(test))]
        unsafe {
            org_tasks_harmony_data_change_monitor_release(self.0);
        }
    }
}
pub fn workspace_watch_data_changes(handle: u64, monitor: u64) -> Result<u64, CoreError> {
    let monitor = DataChangeMonitor(monitor);
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let roots = workspace.repos().into_iter().map(|repo| (repo.id, repo.root_directory)).collect::<BTreeMap<_, _>>();
    let subscription = workspace.watch_data_changes(move |event| {
        let _keep_alive = &monitor;
        if let Ok(json) = notification_event_value(&event, &roots).and_then(|value| encode(&value))
            .and_then(|s| CString::new(s).map_err(|_| CoreError::InvalidState("无法编码通知事件")))
        {
            #[cfg(not(test))]
            unsafe {
                org_tasks_harmony_data_change_update(monitor.0, json.as_ptr());
            }
            #[cfg(test)]
            let _ = json;
        }
    });
    let id = NEXT_DATA_CHANGE_SUBSCRIPTION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    DATA_CHANGE_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| CoreError::Store("数据监控订阅锁不可用".into()))?
        .insert(id, subscription);
    Ok(id)
}
pub fn workspace_unwatch_data_changes(id: u64) {
    let removed = DATA_CHANGE_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&id));
    drop(removed);
}

pub fn workspace_watch_external_file_changes(handle: u64, monitor: u64) -> Result<u64, CoreError> {
    let monitor = DataChangeMonitor(monitor);
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let subscription = workspace.watch_external_file_changes(move |event| {
        let _keep_alive = &monitor;
        if let Ok(json) = serde_json::to_string(&event)
            .and_then(|s| CString::new(s).map_err(serde::ser::Error::custom))
        {
            #[cfg(not(test))]
            unsafe {
                org_tasks_harmony_data_change_update(monitor.0, json.as_ptr());
            }
            #[cfg(test)]
            let _ = json;
        }
    });
    let id = NEXT_EXTERNAL_FILE_SUBSCRIPTION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    EXTERNAL_FILE_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| CoreError::Store("文件监控订阅锁不可用".into()))?
        .insert(id, subscription);
    Ok(id)
}
pub fn workspace_unwatch_external_file_changes(id: u64) {
    let removed = EXTERNAL_FILE_SUBSCRIPTIONS
        .get_or_init(Default::default)
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&id));
    drop(removed);
}

#[cfg(test)]
mod reset_bridge_tests {
    use super::*;

    #[test]
    fn reset_keeps_id_and_exposes_file_conflict_metadata_before_clearing() {
        let root = std::env::temp_dir().join(format!(
            "org-reset-bridge-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(
            root.join("A.org"),
            "#+TITLE: A\n* 同步冲突 :CONFLICT:\n** TODO A\n",
        )
        .unwrap();
        let path = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, path.clone()).unwrap();
        repo_load(handle, path.clone()).unwrap();
        let id = repo_id(handle, path.clone()).unwrap();
        let metadata: serde_json::Value =
            serde_json::from_str(&query_files_json(handle, path.clone()).unwrap()).unwrap();
        assert_eq!(metadata[0]["hasConflict"], true);
        let snapshot: serde_json::Value =
            serde_json::from_str(&repo_snapshot_json(handle, path.clone()).unwrap()).unwrap();
        assert_eq!(snapshot["files"][0]["hasConflict"], true);
        std::fs::create_dir_all(root.join(".sync/history")).unwrap();
        std::fs::write(root.join(".sync/history/broken.json"), "bad").unwrap();
        repo_reset(handle, path.clone()).unwrap();
        assert_eq!(repo_id(handle, path.clone()).unwrap(), id);
        assert!(!root.join("A.org").exists());
        assert_eq!(query_files_json(handle, path.clone()).unwrap(), "[]");
        assert_eq!(repo_history_json(handle, path).unwrap(), "[]");
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

/// 活动对象行为仅在 ABI 中打包，所有语义与文件操作由 Core 执行。
pub fn workspace_preview_operation(handle: u64, request: String) -> Result<String, CoreError> {
    #[derive(serde::Deserialize)]
    #[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
    enum Request {
        Configure {
            root: String,
        },
        Create {
            request: org_tasks_core::ConflictPreviewRequest,
        },
        FileAt {
            path: org_tasks_core::TaskPath,
        },
        #[serde(rename_all = "camelCase")]
        File {
            preview_id: String,
        },
        #[serde(rename_all = "camelCase")]
        SourceFile {
            preview_id: String,
        },
        #[serde(rename_all = "camelCase")]
        Conflicts {
            preview_id: String,
        },
        #[serde(rename_all = "camelCase")]
        Changes {
            preview_id: String,
        },
        #[serde(rename_all = "camelCase")]
        Project {
            preview_id: String,
            request: org_tasks_core::ConflictPreviewProjectionRequest,
        },
        #[serde(rename_all = "camelCase")]
        Finish {
            preview_id: String,
            options: org_tasks_core::ConflictPreviewFinishOptions,
        },
        #[serde(rename_all = "camelCase")]
        Discard {
            preview_id: String,
        },
    }
    let request: Request =
        serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("预览请求参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session;
    let runtime = runtime(handle)?;
    match request {
        Request::Configure { root } => {
            runtime.block_on(workspace.set_preview_root(root.into()))?;
            encode(&serde_json::json!({}))
        }
        Request::Create { request } => {
            let preview = runtime.block_on(workspace.create_conflict_preview(request))?;
            let value = serde_json::json!({"id":preview.id(),"sourcePath":preview.source_path(),"sourceVersion":preview.source_version(),"conflictId":preview.conflict_id(),"fullPath":preview.full_path()});
            workspace_sessions()
                .lock()
                .map_err(|_| CoreError::InvalidState("会话锁不可用"))?
                .sessions
                .get_mut(&handle)
                .ok_or(CoreError::InvalidState("工作区已关闭"))?
                .previews
                .insert(preview.id().into(), preview);
            encode(&value)
        }
        Request::FileAt { path } => encode(&file_snapshot(
            &runtime.block_on(workspace.file_at(&path))?,
        )?),
        request => {
            let id = match &request {
                Request::File { preview_id }
                | Request::SourceFile { preview_id }
                | Request::Conflicts { preview_id }
                | Request::Changes { preview_id }
                | Request::Project { preview_id, .. }
                | Request::Finish { preview_id, .. }
                | Request::Discard { preview_id } => preview_id,
                _ => unreachable!(),
            };
            let preview = workspace_sessions()
                .lock()
                .map_err(|_| CoreError::InvalidState("会话锁不可用"))?
                .sessions
                .get(&handle)
                .and_then(|s| s.previews.get(id))
                .cloned()
                .ok_or(CoreError::Preview {
                    code: "previewExpired",
                    message: "预览对象已释放",
                })?;
            match request {
                Request::File { .. } => encode(&file_snapshot(&runtime.block_on(preview.file())?)?),
                Request::SourceFile { .. } => {
                    encode(&file_snapshot(&runtime.block_on(preview.source_file())?)?)
                }
                // 保留 Core 返回的候选渲染与主树展示坐标，宿主不推断匹配规则。
                Request::Conflicts { .. } => encode(&runtime.block_on(preview.conflicts())?),
                Request::Changes { .. } => encode(&runtime.block_on(preview.changes())?),
                Request::Project { request, .. } => {
                    encode(&runtime.block_on(preview.project(request))?)
                }
                Request::Finish { options, .. } => {
                    encode(&runtime.block_on(preview.finish(options))?)
                }
                Request::Discard { .. } => {
                    runtime.block_on(preview.discard())?;
                    encode(&serde_json::json!({}))
                }
                _ => unreachable!(),
            }
        }
    }
}
pub fn release_preview(handle: u64, id: &str) {
    if let Ok(mut sessions) = workspace_sessions().lock() {
        if let Some(session) = sessions.sessions.get_mut(&handle) {
            session.previews.remove(id);
        }
    }
}

#[cfg(test)]
mod preview_tests {
    use super::*;
    fn request(handle: u64, value: serde_json::Value) -> serde_json::Value {
        serde_json::from_str(&workspace_preview_operation(handle, value.to_string()).unwrap())
            .unwrap()
    }
    #[test]
    fn preview_objects_return_operations_and_only_data_interface_writes_repository() {
        let root = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "harmony-preview-{}-{}",
                std::process::id(),
                org_tasks_core::LocalFileVersion::from_bytes(
                    format!("{:?}", std::time::SystemTime::now()).as_bytes()
                )
                .content_hash
            ));
        std::fs::create_dir_all(root.join("repo")).unwrap();
        let base = "* TODO Work\n:PROPERTIES:\n:ID: work\n:END:\nbase\n";
        let source = org_tasks_core::merge(
            base.as_bytes(),
            base.replace("base", "local").as_bytes(),
            base.replace("base", "remote").as_bytes(),
        )
        .unwrap();
        std::fs::write(root.join("repo/a.org"), &source).unwrap();
        let handle = create_workspace().unwrap();
        let directory = root.join("repo").to_str().unwrap().to_owned();
        workspace_add_repo(handle, directory.clone()).unwrap();
        let file: serde_json::Value = serde_json::from_str(
            &repo_file_json(handle, directory.clone(), "a.org".into()).unwrap(),
        )
        .unwrap();
        request(
            handle,
            serde_json::json!({"operation":"configure","root":root.join("cache")}),
        );
        let preview = request(
            handle,
            serde_json::json!({"operation":"create","request":{"file":file["fullPath"],"conflictId":file["conflictIds"][0],"sourceVersion":file["fileVersion"]}}),
        );
        assert_eq!(preview["fullPath"]["repoId"], "<preview>");
        assert_eq!(preview["fullPath"]["file"], preview["id"]);
        let copied = request(
            handle,
            serde_json::json!({"operation":"file","previewId":preview["id"]}),
        );
        assert_eq!(copied["source"], base.replace("base", "remote"));
        assert_eq!(copied["nodes"][0]["repoId"], "<preview>");
        assert_eq!(copied["hasConflict"], false);
        assert_eq!(copied["conflicts"], serde_json::json!([]));
        let conflicts = request(
            handle,
            serde_json::json!({"operation":"conflicts","previewId":preview["id"]}),
        );
        let projection = request(
            handle,
            serde_json::json!({"operation":"project","previewId":preview["id"],"request":{"conflictId":preview["conflictId"],"previewVersion":copied["fileVersion"]}}),
        );
        assert_eq!(projection["status"], "ready");
        assert_eq!(projection["beforeText"], "remote\n");
        assert_eq!(projection["afterText"], "local\n");
        assert_eq!(projection["workingVersion"], copied["fileVersion"]);
        assert_eq!(
            request(
                handle,
                serde_json::json!({"operation":"file","previewId":preview["id"]})
            )["fileVersion"],
            copied["fileVersion"]
        );
        assert_eq!(
            request(
                handle,
                serde_json::json!({"operation":"conflicts","previewId":preview["id"]})
            ),
            conflicts
        );
        let staged:serde_json::Value=serde_json::from_str(&workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"ConfilictSelection","data":{"path":preview["fullPath"],"id":preview["conflictId"],"action":"useLocal","target":conflicts[0]["suggestedTarget"]}}],"fileVersions":[{"repoId":"<preview>","file":preview["id"],"version":copied["fileVersion"]}]}).to_string()).unwrap()).unwrap();
        assert_eq!(staged, serde_json::json!({}));
        assert_eq!(std::fs::read(root.join("repo/a.org")).unwrap(), source);
        let edited = request(
            handle,
            serde_json::json!({"operation":"file","previewId":preview["id"]}),
        );
        assert_eq!(edited["nodes"][0]["repoId"], "<preview>");
        let group = request(
            handle,
            serde_json::json!({"operation":"finish","previewId":preview["id"],"options":{"previewVersion":edited["fileVersion"]}}),
        );
        assert_eq!(std::fs::read(root.join("repo/a.org")).unwrap(), source);
        assert_eq!(group["operations"][0]["data"]["path"], file["fullPath"]);
        assert_eq!(group["fileVersions"][0]["version"], file["fileVersion"]);
        assert_eq!(
            request(
                handle,
                serde_json::json!({"operation":"finish","previewId":preview["id"],"options":{"previewVersion":edited["fileVersion"]}})
            ),
            group
        );
        workspace_execute_task_operations(handle, group.to_string()).unwrap();
        assert_eq!(
            std::fs::read(root.join("repo/a.org")).unwrap(),
            edited["source"].as_str().unwrap().as_bytes()
        );
        release_preview(handle, preview["id"].as_str().unwrap());
        assert!(matches!(
            workspace_preview_operation(
                handle,
                serde_json::json!({"operation":"file","previewId":preview["id"]}).to_string()
            ),
            Err(CoreError::Preview {
                code: "previewExpired",
                ..
            })
        ));
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod sync_concurrency_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::time::Duration;

    #[test]
    fn queries_wait_for_sync_without_restoring_old_file_snapshots() {
        let root = std::env::temp_dir().join(format!(
            "org-harmony-concurrent-{}",
            org_tasks_core::model::LocalFileVersion::from_bytes(
                format!("{:?}", std::time::SystemTime::now()).as_bytes()
            )
            .content_hash
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("a.org"), b"* TODO Original\n").unwrap();
        let directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory.clone()).unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/org/", listener.local_addr().unwrap());
        let (entered, entering) = std::sync::mpsc::channel();
        let (resume, resuming) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            for index in 0..2 {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buffer = [0; 8192];
                let end = loop {
                    let n = socket.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    request.extend_from_slice(&buffer[..n]);
                    if let Some(offset) = request.windows(4).position(|s| s == b"\r\n\r\n") {
                        break offset + 4;
                    }
                };
                let header = String::from_utf8_lossy(&request[..end]).to_ascii_lowercase();
                let length: usize = header
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("content-length:")
                            .and_then(|value| value.trim().parse().ok())
                    })
                    .unwrap_or(0);
                while request.len() < end + length {
                    let n = socket.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    request.extend_from_slice(&buffer[..n]);
                }
                if index == 0 {
                    assert!(header.starts_with("propfind "));
                    entered.send(()).unwrap();
                    resuming.recv_timeout(Duration::from_secs(5)).unwrap();
                    let body = "<d:multistatus xmlns:d=\"DAV:\"></d:multistatus>";
                    write!(socket, "HTTP/1.1 207 Multi-Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
                } else {
                    assert!(header.starts_with("put "));
                    socket.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nETag: \"uploaded\"\r\nConnection: close\r\n\r\n").unwrap();
                }
            }
        });
        let id = repo_id(handle, directory.clone()).unwrap();
        workspace_sync_operation(handle, Ok(serde_json::json!({
            "operation":"set", "repoId":id, "webdavUrl":endpoint,
            "username":"user", "password":"secret", "excludedDirectories":["archive"]
        }).to_string()), 0).unwrap();
        let syncing = std::thread::spawn(move || workspace_sync_operation(handle, Ok(serde_json::json!({
            "operation":"sync", "repoIds":[id], "triggerReason":"manual"
        }).to_string()), 0));
        entering.recv_timeout(Duration::from_secs(5)).unwrap();
        std::fs::write(root.join("a.org"), b"* TODO Edited during network\n").unwrap();
        let (read, reading) = std::sync::mpsc::channel();
        let read_directory = directory.clone();
        let reader = std::thread::spawn(move || {
            read.send(repo_snapshot_json(handle, read_directory))
                .unwrap();
        });
        assert!(matches!(reading.recv_timeout(Duration::from_millis(100)), Err(std::sync::mpsc::RecvTimeoutError::Timeout)));
        // 配置快照不等待网络，业务查询按同步屏障等待。
        assert_eq!(workspace_repo_roots(handle).unwrap(), vec![directory.clone()]);
        // 远端检查使用配置快照；即使同步屏障已建立，也应直接返回首次同步判定。
        let (checked, checking) = std::sync::mpsc::channel();
        let checker = std::thread::spawn(move || {
            checked.send(workspace_sync_operation(handle, Ok("{\"operation\":\"check\"}".into()), 0)).unwrap();
        });
        let checks: serde_json::Value = serde_json::from_str(&checking.recv_timeout(Duration::from_secs(2)).unwrap().unwrap()).unwrap();
        assert_eq!(checks[0]["state"], "unknown");
        checker.join().unwrap();
        resume.send(()).unwrap();
        let snapshot = reading.recv_timeout(Duration::from_secs(5)).unwrap().unwrap();
        assert!(snapshot.contains("Edited during network"));
        reader.join().unwrap();
        let result = syncing.join().unwrap().unwrap();
        assert!(result.contains("succeeded"), "{result}");
        server.join().unwrap();
        assert!(
            repo_snapshot_json(handle, directory)
                .unwrap()
                .contains("Edited during network")
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
#[allow(dead_code)]
mod test_support {
    use org_tasks_core as core_types;
    include!("../../core/tests/support/disk.rs");
}

#[cfg(test)]
mod load_files_tests {
    use super::*;
    #[test]
    fn relative_ignored_files_cross_bridge_without_repository_snapshot_storage() {
        let root = std::env::temp_dir().join(format!(
            "org-bridge-load-files-{}",
            org_tasks_core::LocalFileVersion::from_bytes(
                format!("{:?}", std::time::SystemTime::now()).as_bytes()
            )
            .content_hash
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("good.org"), b"* TODO Good\n").unwrap();
        std::fs::write(root.join("ignored.org"), [0xff]).unwrap();
        let directory = root.to_string_lossy().into_owned();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, directory.clone()).unwrap();
        repo_load(handle, directory.clone()).unwrap();
        let first: serde_json::Value = serde_json::from_str(
            &repo_load_files_json(handle, directory.clone(), "[\"ignored.org\"]".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(first["files"].as_array().unwrap().len(), 1);
        assert_eq!(first["files"][0]["source"], "* TODO Good\n");
        std::fs::write(root.join("good.org"), b"* TODO New\n").unwrap();
        let second =
            repo_load_files_json(handle, directory.clone(), "[\"ignored.org\"]".into()).unwrap();
        assert!(second.contains("TODO New"));
        assert_eq!(first["files"][0]["source"], "* TODO Good\n");
        assert!(repo_load_files_json(handle, directory, "[\"../outside.org\"]".into()).is_err());
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod settings_object_tests {
    use super::*;

    #[test]
    fn settings_and_state_objects_cross_bridge_without_legacy_state_fields() {
        let root = std::env::temp_dir().join(format!("org-settings-object-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("tasks.org"),
            "#+TODO: OPEN ACTIVE STOP FINISH | END\n* ACTIVE Work\n* STOP Cancelled\n",
        )
        .unwrap();
        let handle = create_workspace().unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(
                &workspace_get_settings_json(handle).unwrap()
            )
            .unwrap(),
            serde_json::json!({"additionStates":[]})
        );
        let settings = serde_json::json!({"additionStates":[{"name":"ACTIVE","category":"Doing"},{"name":"STOP","category":"Cancel"},{"name":"FINISH","category":"Done"}]});
        workspace_set_settings(handle, settings.to_string()).unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let response: serde_json::Value = serde_json::from_str(
            &workspace_query_json(
                handle,
                r#"[{"type":"task","query":{}},{"type":"file","query":{}}]"#.into(),
            )
            .unwrap(),
        )
        .unwrap();
        let task = &response[0]["result"]["tasks"][0];
        let metadata = &response[1]["result"][0];
        assert_eq!(
            task["state"],
            serde_json::json!({"name":"ACTIVE","category":"Doing"})
        );
        assert_eq!(
            task["taskStateOptions"]["Done"],
            serde_json::json!({"name":"FINISH","category":"Done"})
        );
        assert_eq!(task["taskStateOptions"], metadata["taskStateOptions"]);
        assert_eq!(task["taskStateOptions"]["Cancel"]["category"], "Cancel");
        assert!(task["taskStateOptions"].get("Cancle").is_none());
        assert!(task["taskStateOptions"]["Wait"].is_null());
        for field in [
            "todoState",
            "todoKind",
            "stateCategory",
            "completionState",
            "doneKeywords",
            "isCancelled",
        ] {
            assert!(task.get(field).is_none());
        }
        assert!(
            workspace_set_settings(
                handle,
                r#"{"additionStates":[{"name":"DONE","category":"Todo"}]}"#.into()
            )
            .is_err()
        );
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(
                &workspace_get_settings_json(handle).unwrap()
            )
            .unwrap(),
            settings
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}


static QUERY_SUBSCRIPTIONS: OnceLock<Mutex<BTreeMap<u64, (u64, org_tasks_core::QuerySubscription)>>> = OnceLock::new();
static NEXT_QUERY_SUBSCRIPTION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn notification_event_value(event: &org_tasks_core::DataChangeEvent, roots: &BTreeMap<String, String>) -> Result<serde_json::Value, CoreError> {
    let mut value = serde_json::to_value(event).map_err(|_| CoreError::InvalidState("无法编码通知事件"))?;
    let org_tasks_core::DataChangeEvent::NotificationEvent { notifications, .. } = event;
    value["notifications"] = serde_json::Value::Array(notification_values(notifications.clone(), roots));
    Ok(value)
}

fn query_event_value(event: &org_tasks_core::DataChangeEvent, ordering: &org_tasks_core::QueryOrdering, roots: &BTreeMap<String, String>) -> Result<serde_json::Value, CoreError> {
    let mut value = notification_event_value(event, roots)?;
    let org_tasks_core::DataChangeEvent::NotificationEvent { changes, files, .. } = event;
    for (index, change) in changes.iter().enumerate() {
        for (name, snapshot) in [("before", &change.before), ("after", &change.after)] {
            if let Some(snapshot) = snapshot {
                let mut view = task_from_filter(snapshot.task.clone())?;
                view.order_key = Some(ordering.task_key(&snapshot.task));
                value["changes"][index][name]["view"] = serde_json::to_value(view)
                    .map_err(|_| CoreError::InvalidState("无法编码任务投影"))?;
            }
        }
    }
    for (index, file) in files.iter().flatten().enumerate() {
        let mut after = file_metadata_snapshot(file.after.clone()); after.order_key = Some(ordering.file_key(&file.after));
        value["files"][index]["afterView"] = serde_json::to_value(after)
            .map_err(|_| CoreError::InvalidState("无法编码文件投影"))?;
        if let Some(before) = &file.before {
            let mut view = file_metadata_snapshot(before.clone()); view.order_key = Some(ordering.file_key(before));
            value["files"][index]["beforeView"] = serde_json::to_value(view)
                .map_err(|_| CoreError::InvalidState("无法编码文件投影"))?;
        }
    }
    Ok(value)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QuerySubscriptionRequest {
    query: org_tasks_core::CoreQuery,
    #[serde(default)] operation_id: Option<String>,
    #[serde(default)] repository_bindings: Vec<QueryRepositoryBinding>,
}

pub fn workspace_subscribe_query_json(handle: u64, source: String, monitors: Vec<u64>) -> Result<(Vec<u64>, String), CoreError> {
    // 接管全部回调资源；任何校验或查询失败都会自动释放。
    let monitors = monitors.into_iter().map(|monitor| Arc::new(DataChangeMonitor(monitor))).collect::<Vec<_>>();
    let mut requests: Vec<QuerySubscriptionRequest> = serde_json::from_str(&source)
        .map_err(|_| CoreError::InvalidInput("批量订阅参数无效"))?;
    if requests.len() != monitors.len() {
        return Err(CoreError::InvalidInput("订阅参数与回调数量不一致"));
    }
    let workspace = workspace_for_handle(handle)?;
    let mut subscriptions = Vec::with_capacity(requests.len());
    let mut orderings = Vec::with_capacity(requests.len());
    for (request, monitor) in requests.iter_mut().zip(monitors) {
        resolve_query_repositories(&workspace, std::slice::from_mut(&mut request.query), &request.repository_bindings)?;
        let ordering = workspace.query_ordering(&request.query)?;
        let event_ordering = ordering.clone();
        let roots = workspace.repos().into_iter().map(|repo| (repo.id, repo.root_directory)).collect::<BTreeMap<_, _>>();
        subscriptions.push(org_tasks_core::QuerySubscriptionRequest::new(
            request.query.clone(),
            move |event| {
                let _keep_alive = &monitor;
                if let Ok(json) = query_event_value(&event, &event_ordering, &roots)
                    .and_then(|value| encode(&value))
                    .and_then(|value| {
                        CString::new(value).map_err(|_| CoreError::InvalidState("无法编码数据事件"))
                    })
                {
                    #[cfg(not(test))]
                    unsafe {
                        org_tasks_harmony_data_change_update(monitor.0, json.as_ptr());
                    }
                    #[cfg(test)]
                    let _ = json;
                }
            },
        ));
        orderings.push(ordering);
    }
    let started = runtime(handle)?.block_on(workspace.subscribe_query(subscriptions))?;
    let ids = started.iter().map(|_| NEXT_QUERY_SUBSCRIPTION.fetch_add(1, std::sync::atomic::Ordering::Relaxed)).collect::<Vec<_>>();
    let values = started.iter().enumerate().map(|(index, start)| {
        query_result_value(start.data.clone(), &BTreeMap::new(), Some(&orderings[index])).map(|data| serde_json::json!({
            "subscriptionId": ids[index], "data": data, "operationId": requests[index].operation_id
        }))
    }).collect::<Result<Vec<_>, _>>()?;
    let response = encode(&values)?;
    let mut subscriptions = QUERY_SUBSCRIPTIONS.get_or_init(Default::default).lock().map_err(|_| CoreError::Store("查询订阅锁不可用".into()))?;
    for (id, start) in ids.iter().copied().zip(started) {
        subscriptions.insert(id, (handle, start.subscription));
    }
    Ok((ids, response))
}

pub fn workspace_query_subscription_status(handle: u64, id: u64) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let subscriptions = QUERY_SUBSCRIPTIONS.get_or_init(Default::default).lock().map_err(|_| CoreError::Store("查询订阅锁不可用".into()))?;
    let (owner, subscription) = subscriptions.get(&id).ok_or(CoreError::InvalidInput("查询订阅不存在"))?;
    if *owner != handle { return Err(CoreError::InvalidInput("查询订阅不属于 workspace")); }
    let status = match workspace.query_subscription_status(subscription) {
        org_tasks_core::QuerySubscriptionStatus::Current => "current",
        org_tasks_core::QuerySubscriptionStatus::AwaitingEvents => "awaitingEvents",
        org_tasks_core::QuerySubscriptionStatus::Invalidated => "invalidated",
        org_tasks_core::QuerySubscriptionStatus::Closed => "closed",
    };
    encode(&status)
}

pub fn workspace_unsubscribe_query(handle: u64, id: u64) {
    let mut subscriptions = QUERY_SUBSCRIPTIONS.get_or_init(Default::default).lock().unwrap_or_else(|error| error.into_inner());
    let removed = if subscriptions.get(&id).is_some_and(|(owner, _)| *owner == handle) { subscriptions.remove(&id) } else { None };
    drop(subscriptions);
    drop(removed);
}

#[cfg(test)]
mod page_data_bridge_tests {
    use super::*;
    #[test]
    fn batch_returns_independent_ids_and_rejects_the_single_subscription_protocol() {
        let handle = create_workspace().unwrap();
        let (ids, source) = workspace_subscribe_query_json(handle,
            r#"[{"query":{"type":"task","query":{}},"operationId":"first"},{"query":{"type":"file","query":{}},"operationId":"second"}]"#.into(), vec![0, 0]).unwrap();
        let values: serde_json::Value = serde_json::from_str(&source).unwrap();
        assert_eq!(ids.len(), 2);
        assert_ne!(ids[0], ids[1]);
        assert_eq!(values[0]["operationId"], "first");
        assert_eq!(values[1]["operationId"], "second");
        assert_eq!(values[0]["data"]["type"], "task");
        assert_eq!(values[1]["data"]["type"], "file");
        workspace_unsubscribe_query(handle, ids[0]);
        assert!(workspace_query_subscription_status(handle, ids[0]).is_err());
        assert_eq!(workspace_query_subscription_status(handle, ids[1]).unwrap(), "\"current\"");
        assert!(workspace_subscribe_query_json(handle, r#"{"query":{"type":"task","query":{}}}"#.into(), vec![0]).is_err());
        assert_eq!(workspace_subscribe_query_json(handle, "[]".into(), vec![]).unwrap().1, "[]");
        release_workspace(handle);
    }

    #[test]
    fn query_subscription_projects_initial_data_events_and_enforces_owner_lifetime() {
        let root = std::env::temp_dir().join(format!("harmony-query-subscription-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), "* TODO Task\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let (_, response) = workspace_subscribe_query_json(handle, r#"[{"query":{"type":"task","query":{}},"operationId":"dataset/page/1/refresh"}]"#.into(), vec![0]).unwrap();
        let response: serde_json::Value = serde_json::from_str::<serde_json::Value>(&response).unwrap()[0].clone();
        let id = response["subscriptionId"].as_u64().unwrap();
        assert_eq!(response["operationId"], "dataset/page/1/refresh");
        assert_eq!(response["data"]["result"]["tasks"][0]["heading"], "Task");
        assert_eq!(response["data"]["result"]["tasks"][0]["taskStateOptions"]["Done"]["name"], "DONE");
        assert_eq!(workspace_query_subscription_status(handle, id).unwrap(), "\"current\"");
        let other = create_workspace().unwrap();
        assert!(workspace_query_subscription_status(other, id).is_err());
        workspace_unsubscribe_query(other, id);
        assert!(workspace_query_subscription_status(handle, id).is_ok());
        let workspace = workspace_for_handle(handle).unwrap();
            let repo = &workspace.repos()[0];
        let file = runtime(handle).unwrap().block_on(repo.file("a.org")).unwrap();
        let task = runtime(handle).unwrap().block_on(repo.nodes()).unwrap().remove(0);
        let event = org_tasks_core::DataChangeEvent::NotificationEvent {
            repo_id: repo.id.clone(), operation_id: Some("dataset/page/2/update".into()),
            files: Some(vec![org_tasks_core::FileDataChange { before: None, after: task.file_metadata().clone(), before_version: None, after_version: task.file_version().into() }]),
            changes: vec![org_tasks_core::TaskDataChange { kind: org_tasks_core::TaskDataChangeKind::Created, before: None,
                after: Some(org_tasks_core::TaskDataSnapshot { position: org_tasks_core::TaskPosition { parent: file.full_path(), after: None }, task }) }],
            notifications: vec![org_tasks_core::CoreNotification::SyncConflict(org_tasks_core::SyncConflictNotification { repo_id: repo.id.clone(), path: "a.org".into() })],
            removed_files: Vec::new(), categories: None,
        };
        let ordering = workspace.query_ordering(&org_tasks_core::TaskQuery::default().into()).unwrap();
        let value = query_event_value(&event, &ordering, &BTreeMap::from([(repo.id.clone(), repo.root_directory.clone())])).unwrap();
        assert_eq!(value["type"], "notificationEvent");
        assert_eq!(value["notifications"][0]["rootDirectory"], repo.root_directory);
        assert_eq!(value["changes"][0]["after"]["view"]["heading"], "Task");
        assert_eq!(value["changes"][0]["after"]["view"]["isDone"], false);
        assert!(value["files"][0]["afterView"]["taskPriorityOptions"].is_object());
            workspace_unsubscribe_query(handle, id);
        assert!(workspace_query_subscription_status(handle, id).is_err());
        let (ids, _) = workspace_subscribe_query_json(handle, r#"[{"query":{"type":"file","query":{}}}]"#.into(), vec![0]).unwrap();
        let id = ids[0];
        release_workspace(handle);
        assert!(!QUERY_SUBSCRIPTIONS.get().unwrap().lock().unwrap().contains_key(&id));
        release_workspace(other);
        std::fs::remove_dir_all(root).unwrap();
    }
}


static EMBEDDED_HTTP: OnceLock<Mutex<Option<(u64, org_tasks_core::http_server::EmbeddedHttpServer)>>> = OnceLock::new();
pub fn workspace_start_http_server(handle: u64, port: u16, monitor: u64) -> Result<String, CoreError> {
    let ui = crate::http_ui::UiBridge::new(handle, monitor);
    let shared = workspace_for_handle(handle)?;
    let mut state = EMBEDDED_HTTP.get_or_init(Default::default).lock().map_err(|_| CoreError::Store("HTTP 服务状态锁不可用".into()))?;
    if let Some((owner, server)) = state.as_ref() {
        if *owner == handle { return encode(&serde_json::json!({"address": server.address().to_string()})); }
        return Err(CoreError::InvalidState("已有另一个 Workspace 提供 HTTP 服务"));
    }
    let address = std::net::SocketAddr::from(([127,0,0,1], port));
    let mut server = runtime(handle)?.block_on(OrgWorkspace::start_http_server(shared, address))?;
    ui.register(&mut server)?;
    let response = encode(&serde_json::json!({"address": server.address().to_string()}))?;
    *state = Some((handle, server));
    Ok(response)
}
pub fn workspace_stop_http_server(handle: u64) -> Result<(), CoreError> {
    let removed = {
        let mut state = EMBEDDED_HTTP.get_or_init(Default::default).lock().map_err(|_| CoreError::Store("HTTP 服务状态锁不可用".into()))?;
        if state.as_ref().is_some_and(|(owner, _)| *owner == handle) { state.take() } else { None }
    };
    crate::http_ui::cancel(handle);
    if let Some((_, mut server)) = removed { runtime(handle)?.block_on(OrgWorkspace::stop_http_server(&mut server))?; }
    Ok(())
}
pub fn workspace_http_server_status(handle: u64) -> Result<String, CoreError> {
    let state = EMBEDDED_HTTP.get_or_init(Default::default).lock().map_err(|_| CoreError::Store("HTTP 服务状态锁不可用".into()))?;
    encode(&state.as_ref().filter(|(owner, _)| *owner == handle).map(|(_, server)| serde_json::json!({"address":server.address().to_string()})))
}

#[cfg(test)]
mod embedded_http_tests {
    use super::*;
    #[test]
    fn workspace_runtime_continues_between_requests_and_is_isolated_by_session() {
        let handle = create_workspace().unwrap();
        let other = create_workspace().unwrap();
        let executor = runtime(handle).unwrap();
        assert!(Arc::ptr_eq(&executor, &runtime(handle).unwrap()));
        assert!(!Arc::ptr_eq(&executor, &runtime(other).unwrap()));
        let (send, receive) = std::sync::mpsc::channel();
        executor.spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            send.send(()).unwrap();
        });
        receive.recv_timeout(std::time::Duration::from_secs(3)).unwrap();
        let workspace = workspace_for_handle(handle).unwrap();
        release_workspace(handle);
        assert!(runtime(handle).is_err());
        executor.block_on(async {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                while workspace.query(&[]).await.is_ok() { tokio::task::yield_now().await; }
            }).await.unwrap();
        });
        assert_eq!(workspace_query_json(other, "[]".into()).unwrap(), "[]");
        release_workspace(other);
    }
    #[test]
    fn listener_survives_start_request_and_stop_releases_port() {
        let handle = create_workspace().unwrap();
        let info: serde_json::Value = serde_json::from_str(&workspace_start_http_server(handle, 0, 0).unwrap()).unwrap();
        let address = info["address"].as_str().unwrap();
        // 启动请求返回后，监听仍由所属 Workspace 的运行时驱动。
        use std::io::{Read, Write};
        let mut stream = std::net::TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
        stream.write_all(b"POST /api/v1/queries HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]").unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.ends_with("[]"), "{response}");
        workspace_stop_http_server(handle).unwrap();
        assert_eq!(workspace_http_server_status(handle).unwrap(), "null");
        let rebound = std::net::TcpListener::bind(address).unwrap();
        drop(rebound);
        release_workspace(handle);
    }
}

#[cfg(test)]
mod configuration_validation_tests {
    use super::*;

    #[test]
    fn configuration_validation_uses_core_defaults_and_normalizes_without_workspace() {
        let defaults: serde_json::Value = serde_json::from_str(&validate_configuration_json("{}".into()).unwrap()).unwrap();
        assert_eq!(defaults, serde_json::json!({"additionStates": []}));
        let legacy = r#"{"coreSettings":{"additionStates":[{"name":"STOP","category":"Cancle"}]}}"#;
        let normalized: serde_json::Value = serde_json::from_str(&validate_configuration_json(legacy.into()).unwrap()).unwrap();
        assert_eq!(normalized["additionStates"][0]["category"], "Cancel");
        assert!(validate_configuration_json(r#"{"coreSettings":{"additionStates":[{"name":"TODO","category":"Done"}]}}"#.into()).is_err());
        assert!(validate_configuration_json(r#"{"todoDefaults":"invalid"}"#.into()).is_err());
    }
}

#[cfg(test)]
mod query_repository_binding_tests {
    use super::*;

    #[test]
    fn query_and_subscription_resolve_host_ids_in_the_same_worker_request() {
        let handle = create_workspace().unwrap();
        let root = std::env::temp_dir().join(format!("org-query-bindings-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let first = root.join("first");
        let second = root.join("second");
        for directory in [&first, &second] {
            std::fs::create_dir_all(directory).unwrap();
            std::fs::write(directory.join("same.org"), "* TODO Visible\n").unwrap();
            workspace_add_repo(handle, directory.to_string_lossy().into()).unwrap();
        }
        let core_id = repo_id(handle, second.to_string_lossy().into()).unwrap();
        let reference = serde_json::json!({"repoId":"host-second","path":"same.org"});
        let bindings = serde_json::json!([{"id":"host-second","rootDirectory":second}]);
        let task = serde_json::json!({"type":"task","repoIds":["host-second"],"query":{"includeFiles":[reference],"fullFiles":[reference],"expression":"it.todo"}});
        let file = serde_json::json!({"type":"file","query":{"includeFiles":[reference]}});
        let response = workspace_query_json(handle, serde_json::json!({"queries":[task,file],"repositoryBindings":bindings}).to_string()).unwrap();
        let values: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(values[0]["result"]["tasks"].as_array().unwrap().len(), 1);
        assert_eq!(values[0]["result"]["tasks"][0]["repoId"], core_id);
        assert_eq!(values[0]["result"]["fullFiles"][0]["repoId"], core_id);
        assert_eq!(values[0]["result"]["fullFiles"][0]["source"], "* TODO Visible\n");
        assert_eq!(values[0]["result"]["fullFiles"][0]["nodes"].as_array().unwrap().len(), 1);
        assert_eq!(values[1]["result"][0]["repoId"], core_id);
        let (ids, response) = workspace_subscribe_query_json(handle,
            serde_json::json!([{"query":task,"repositoryBindings":bindings,"operationId":"dataset/test/1/query"}]).to_string(), vec![0]).unwrap();
        let id = ids[0];
        let started: serde_json::Value = serde_json::from_str::<serde_json::Value>(&response).unwrap()[0].clone();
        assert_eq!(started["data"]["result"]["tasks"][0]["repoId"], core_id);
        assert_eq!(started["operationId"], "dataset/test/1/query");
        let response = workspace_query_json(handle, serde_json::json!({
            "queries":[{"type":"task","query":{"includeFiles":[reference],"excludeFiles":[reference]}}],
            "repositoryBindings":bindings}).to_string()).unwrap();
        let values: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert!(values[0]["result"]["tasks"].as_array().unwrap().is_empty());
        for invalid in [
            serde_json::json!([{"id":"","rootDirectory":second}]),
            serde_json::json!([{"id":"host-second","rootDirectory":root.join("missing")}]),
            serde_json::json!([{"id":"host-second","rootDirectory":second},{"id":"host-second","rootDirectory":first}]),
            serde_json::json!([{"id":core_id,"rootDirectory":first}]),
        ] {
            assert!(workspace_query_json(handle, serde_json::json!({"queries":[task],"repositoryBindings":invalid}).to_string()).is_err());
            assert!(workspace_subscribe_query_json(handle, serde_json::json!([{"query":task,"repositoryBindings":invalid}]).to_string(), vec![0]).is_err());
        }
        workspace_unsubscribe_query(handle, id);
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod file_header_edit_bridge_tests {
    use super::*;
    #[test]
    fn header_modification_uses_metadata_ids_and_existing_operation_bridge() {
        let root = std::env::temp_dir().join(format!(
            "org-header-bridge-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("p.org"),"#+TITLE: 原名\r\n#+FILETAGS: :project:todo:\r\n#+CATEGORY: 工作\r\n* TODO Task\r\n正文\r\n").unwrap();
        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into_owned()).unwrap();
        let read = || -> serde_json::Value {
            serde_json::from_str(
                &workspace_query_json(handle, r#"[{"type":"file","query":{}}]"#.into()).unwrap(),
            )
            .unwrap()
        };
        let before = read();
        let file = &before[0]["result"][0];
        let entry = &file["headerEntries"][0];
        assert_eq!(entry["edit"]["kind"], "text");
        assert!(entry["id"].is_string());
        let group = serde_json::json!({"operationId":"header-bridge","fileVersions":[{"repoId":file["repoId"],"file":"p.org","version":file["fileVersion"]}],
            "operations":[{"type":"FileHaderModification","data":{"file":{"repoId":file["repoId"],"path":"p.org"},"changes":[{"entryId":entry["id"],"value":{"type":"text","value":"新名"}}]}}]});
        workspace_execute_task_operations(handle, group.to_string()).unwrap();
        let next = read();
        assert_eq!(next[0]["result"][0]["title"], "新名");
        assert_ne!(next[0]["result"][0]["fileVersion"], file["fileVersion"]);
        assert_eq!(
            next[0]["result"][0]["headerEntries"][1]["edit"]["protectedTags"],
            serde_json::json!(["project", "todo"])
        );
        assert!(workspace_execute_task_operations(handle, group.to_string()).is_err());
        assert!(
            std::fs::read_to_string(root.join("p.org"))
                .unwrap()
                .ends_with("* TODO Task\r\n正文\r\n")
        );
        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}
