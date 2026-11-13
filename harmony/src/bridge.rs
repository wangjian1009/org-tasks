use std::collections::BTreeMap;
use std::ffi::CString;
use std::sync::{Arc, Mutex, OnceLock};

use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavError, WebDavSyncEvent, WebDavSyncMonitor, WebDavSyncPolicy,
};
use org_tasks_core::{
    CoreError, FilterTask, OrgRepo, OrgRepoSyncResult, OrgWorkspace, SyncCancellation, SyncOptions,
    SyncProgressReporter, TimestampMs,
};
use serde::Serialize;

struct WorkspaceSession {
    workspace: Arc<Mutex<OrgWorkspace>>,
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
    pub logs: Vec<org_tasks_core::TaskLog>,
    pub progress: i32,
    pub has_list: bool,
    pub has_text: bool,
    pub is_repeating: bool,
    pub is_habit: bool,
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
        body_html: content.body_html,
        logbook_html: content.logbook_html,
        logs: content.logs,
        progress: -1,
        has_list: content.has_list,
        has_text: content.has_text,
        is_repeating: task.is_repeating(),
        is_habit: task.is_habit(),
    })
}

/// 创建持久的空 workspace session；加入仓库时初始化其稳定身份。
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
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let mut repository = OrgRepo::new(root_directory)?;
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
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
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repository.reset())?;
    let repo_id = repository.id.clone();
    // 重置后不保留这个仓库的旧操作回退原文。
    workspace.task_operation_history.entries.retain(|entry| {
        !entry
            .fallback_group
            .files
            .iter()
            .any(|file| file.repo_id == repo_id)
    });
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
        &runtime()?
            .block_on(repository.history_summaries())?
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
        files: detail.files.into_iter().map(|file| {
            let mut value = serde_json::to_value(&file).map_err(|_| CoreError::InvalidState("无法编码同步文件摘要"))?;
            if let Some(backup) = file.backup {
                value["backup"] = serde_json::to_value(file_metadata_snapshot(backup)).map_err(|_| CoreError::InvalidState("无法编码备份元信息"))?;
            }
            Ok(value)
        }).collect::<Result<Vec<_>, CoreError>>()?,
        errors: detail.errors,
    })
}

pub fn repo_full_path_json(handle: u64, root_directory: String) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo = workspace
        .repo_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
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
        .lock()
        .unwrap()
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
fn query_notifications_json(handle: u64) -> Result<String, CoreError> {
    let response = workspace_query_json(handle, r#"[{"type":"notification","query":{}}]"#.into())?;
    let results: serde_json::Value = serde_json::from_str(&response).unwrap();
    encode(&results[0]["result"])
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

pub fn workspace_query_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let queries: Vec<org_tasks_core::CoreQuery> =
        serde_json::from_str(&query_json).map_err(|_| CoreError::InvalidInput("查询参数无效"))?;
    let session = workspace_for_handle(handle)?;
    if queries.is_empty() {
        return encode(&Vec::<serde_json::Value>::new());
    }
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let roots = workspace
        .repos()
        .iter()
        .map(|repo| (repo.id.clone(), repo.root_directory.clone()))
        .collect::<BTreeMap<_, _>>();
    let results = runtime()?.block_on(workspace.query(&queries))?;
    drop(workspace);
    let values = results.into_iter().map(|result| -> Result<serde_json::Value, CoreError> {
        Ok(match result {
            org_tasks_core::CoreQueryResult::Task(result) => serde_json::json!({
                "type": "task", "result": {
                    "tasks": result.tasks.into_iter().map(task_from_filter).collect::<Result<Vec<_>, _>>()?,
                    "categories": result.categories,
                }
            }),
            org_tasks_core::CoreQueryResult::File(files) => serde_json::json!({ "type": "file", "result": files.into_iter().map(file_metadata_snapshot).collect::<Vec<_>>() }),
            org_tasks_core::CoreQueryResult::Notification(notifications) => {
                let values = notifications.into_iter().map(|notification| {
                    let mut value = serde_json::to_value(&notification).map_err(|_| CoreError::InvalidState("无法编码通知"))?;
                    if let org_tasks_core::CoreNotification::SyncConflict(ref conflict) = notification {
                        value["rootDirectory"] = roots.get(&conflict.repo_id)
                            .ok_or(CoreError::InvalidState("通知所属仓库不存在"))?.clone().into();
                    }
                    Ok(value)
                }).collect::<Result<Vec<_>, CoreError>>()?;
                serde_json::json!({ "type": "notification", "result": values })
            }
        })
    }).collect::<Result<Vec<_>, _>>()?;
    encode(&values)
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
    let mut repository = {
        let workspace = workspace
            .lock()
            .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
        workspace
            .repo_by_root_directory(&root_directory)
            .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?
            .clone()
    };
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
    // 只交回稳定身份，避免同步开始前取得的对象覆盖网络期间其他请求更新的快照。
    if record.result == Some(OrgRepoSyncResult::Succeeded) {
        let mut workspace = workspace
            .lock()
            .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
        if let Some(current) = workspace.repo_mut_by_root_directory(&root_directory) {
            if current.id.is_empty() || current.id == repository.id {
                current.id = repository.id;
            }
        }
    }
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
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    let files = runtime()?
        .block_on(repository.load_files(&ignore_files))?
        .iter()
        .map(file_snapshot)
        .collect::<Result<Vec<_>, _>>()?;
    encode(&HarmonyBridgeRepository {
        id: repository.id.clone(),
        files,
    })
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
    // category 与 taskStateCounts 随 Core 元信息原样序列化，不在宿主解析或统计。
    #[serde(flatten)]
    metadata: org_tasks_core::OrgFileMetadata,
    task_priority_options: BTreeMap<String, Option<org_tasks_core::TaskPriority>>,
    task_state_options: BTreeMap<String, Option<org_tasks_core::TaskState>>,
}

fn file_metadata_snapshot(metadata: org_tasks_core::OrgFileMetadata) -> HarmonyBridgeFileMetadata {
    let task_state_options = state_options(|category| metadata.task_state_of(category));
    let task_priority_options = priority_options(|category| metadata.task_priority_of(category));
    HarmonyBridgeFileMetadata {
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
    fn unified_query_json_dispatches_all_kinds_and_rejects_the_old_task_array_protocol() {
        let handle = create_workspace().unwrap();
        let root = std::env::temp_dir().join(format!("org-unified-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.org"), "#+TITLE: File\n* TODO Task\n").unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        let response=workspace_query_json(handle,r#"[{"type":"file","query":{}},{"type":"task","query":{}},{"type":"notification","query":{}}]"#.into()).unwrap();
        let values: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(values[0]["type"], "file");
        assert_eq!(values[0]["result"][0]["title"], "File");
        assert_eq!(values[1]["type"], "task");
        assert_eq!(values[1]["result"]["tasks"][0]["heading"], "Task");
        assert_eq!(values[2]["type"], "notification");
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
                &query_task_results_json(handle, "[{\"includeDone\":true}]".into()).unwrap(),
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
        assert!(
            query_task_results_json(
                handle,
                r#"[{}, {"excludedFiles": [{"repoId":"", "path":"tasks.org"}]}]"#.into()
            )
            .is_err()
        );
        std::fs::write(root.join("broken.org"), [0xff]).unwrap();
        assert!(query_task_results_json(handle, request.to_string()).is_err());
        // 空批次不碰业务锁，即使磁盘已损坏也返回空数组。
        let session = workspace_for_handle(handle).unwrap();
        let _guard = session.lock().unwrap();
        assert_eq!(query_task_results_json(handle, "[]".into()).unwrap(), "[]");
        drop(_guard);
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
            let workspace = OrgWorkspace::new(vec![repo]).unwrap();
            let task = runtime()
                .unwrap()
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
    fn workspace_notifications_reload_files_and_project_one_event_per_conflict_file() {
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
        let notices: serde_json::Value =
            serde_json::from_str(&query_notifications_json(handle).unwrap()).unwrap();
        let values = notices.as_array().unwrap();
        assert_eq!(values.len(), 3);
        assert_eq!(values[0]["path"], "a.org");
        assert_eq!(values[1]["path"], "b.org");
        assert_eq!(values[2]["type"], "syncRequired");
        assert!(values[0].get("syncId").is_none());
        assert_eq!(values[0]["rootDirectory"], directory);
        std::fs::write(root.join("a.org"), "* Normal\n").unwrap();
        let current: serde_json::Value =
            serde_json::from_str(&query_notifications_json(handle).unwrap()).unwrap();
        assert_eq!(current.as_array().unwrap().len(), 2);
        assert_eq!(current[0]["path"], "b.org");
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
            "expression": "s.none d.none",
            "includeDone": false,
            "includeComposeTasks": true
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
                &query_task_results_json(handle, r#"[{"expression":"b.\"inbox.org\""}]"#.into())
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
        let core_tasks = runtime()
            .unwrap()
            .block_on(
                session
                    .lock()
                    .unwrap()
                    .query(&[(org_tasks_core::TaskQuery::default()).into()]),
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
        let query = serde_json::json!({ "expression": "cr.ge.-2d cr.le.today .o.created", "includeDone": true });
        let result: serde_json::Value = serde_json::from_str::<Vec<serde_json::Value>>(
            &query_task_results_json(handle, serde_json::json!([query]).to_string()).unwrap(),
        )
        .unwrap()
        .remove(0);
        // 固定样例只在其创建日期落入最近三个自然日时匹配。
        let projection = workspace_for_handle(handle).unwrap();
        let expected = runtime()
            .unwrap()
            .block_on(
                projection
                    .lock()
                    .unwrap()
                    .query(&[(org_tasks_core::TaskQuery {
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
        let excluded = serde_json::json!({ "excludedFiles": [{ "repoId":tasks[0]["repoId"], "path":"tasks.org" }] });
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
    fn checklist_move_preserves_bytes_and_rejects_old_snapshot_across_bridge() {
        let root =
            std::env::temp_dir().join(format!("org-checklist-move-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let source = "* TODO Task\r\nNotes  \r\n- [X] Parent\r\n  - [-] Nested\r\n- [ ] Sibling\r\n\r\n** Child\r\nUnchanged\r\n";
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
            &query_task_results_json(handle, r#"[{"expression":"b.inbox.org"}]"#.into()).unwrap(),
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
        let request = serde_json::json!({"operations":[{"type":"Movement","data":{"path":task["fullPath"],"position":{"parent":target["fullPath"]}}}],"queueRepoIds":[task["repoId"]]});
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
        workspace_execute_task_operations(handle,serde_json::json!({"operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"}},"title":"Captured","state":"TODO"}}],"queueRepoIds":[id]}).to_string()).unwrap();
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
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut_by_root_directory(&root_directory)
        .ok_or(CoreError::InvalidInput("仓库目录不属于 workspace"))?;
    runtime()?.block_on(repository.load::<WebDavSyncPolicy>())?;
    encode(&runtime()?.block_on(repository.pending_sync_conflicts())?)
}

pub fn workspace_get_settings_json(handle: u64) -> Result<String, CoreError> {
    let session = workspace_for_handle(handle)?;
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    encode(&workspace.get_settings())
}

pub fn workspace_set_settings(handle: u64, json: String) -> Result<(), CoreError> {
    let settings: org_tasks_core::CoreSettings = serde_json::from_str(&json)
        .map_err(|_| CoreError::InvalidInput("CoreSettings 参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    workspace.set_settings(settings)
}

pub fn workspace_set_todo_defaults(handle: u64, settings: String) -> Result<(), CoreError> {
    let defaults = org_tasks_core::TodoConfig::from_settings(&settings)?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let core_settings = workspace.get_settings();
    workspace.set_todo_defaults(defaults)?;
    workspace.set_settings(core_settings)
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
    encode(&file_snapshot(&runtime()?.block_on(repo.file(&path))?)?)
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
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let task = task_from_filter(
            runtime()
                .unwrap()
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

/// 放置目标和任务整理均由 Core 求值，bridge 只持有会话锁并调度运行时。
pub fn workspace_refile_targets_json(handle: u64, query_json: String) -> Result<String, CoreError> {
    let query: org_tasks_core::RefileTargetQuery = serde_json::from_str(&query_json)
        .map_err(|_| CoreError::InvalidInput("放置目标查询参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    for repo in &mut workspace.repos {
        runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    }
    encode(&runtime.block_on(workspace.query_refile_targets(&query))?)
}

pub fn workspace_execute_task_operations(
    handle: u64,
    request: String,
) -> Result<String, CoreError> {
    let group: org_tasks_core::TaskOperationGroup = serde_json::from_str(&request)
        .map_err(|_| CoreError::InvalidInput("任务操作组参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    runtime()?.block_on(workspace.execute_task_operations(&group))?;
    Ok("{}".into())
}

pub fn workspace_task_merge_operations(handle: u64, request: String) -> Result<String, CoreError> {
    let request: org_tasks_core::TaskMergeRequest =
        serde_json::from_str(&request).map_err(|_| CoreError::InvalidInput("记录合并参数无效"))?;
    let session = workspace_for_handle(handle)?;
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    encode(&runtime()?.block_on(workspace.task_merge_operations(&request))?)
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
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repo = workspace
        .repo_mut_by_root_directory(&root)
        .ok_or(CoreError::InvalidInput("仓库不属于 workspace"))?;
    let runtime = runtime()?;
    runtime.block_on(repo.load::<WebDavSyncPolicy>())?;
    match request {
        Request::LastEffectSync => {
            let current = runtime.block_on(repo.last_effect_sync())?;
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
            &runtime.block_on(repo.history_file(&sync_id, &path, resolved))?,
        )?),
    }
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
pub fn workspace_watch_notifications(handle: u64, monitor: u64) -> Result<u64, CoreError> {
    let monitor = NotificationMonitor(monitor);
    let session = workspace_for_handle(handle)?;
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("workspace 锁不可用".into()))?;
    let subscription = workspace.watch_notifications(move |event| {
        let _keep_alive = &monitor;
        if let Ok(json) = serde_json::to_string(&event)
            .and_then(|s| CString::new(s).map_err(serde::ser::Error::custom))
        {
            #[cfg(not(test))]
            unsafe {
                org_tasks_harmony_notification_update(monitor.0, json.as_ptr());
            }
            #[cfg(test)]
            let _ = json;
        }
    });
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
    let workspace = session
        .lock()
        .map_err(|_| CoreError::Store("workspace 锁不可用".into()))?;
    let subscription = workspace.watch_data_changes(move |event| {
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
pub fn workspace_reload(handle: u64) -> Result<(), CoreError> {
    let session = workspace_for_handle(handle)?;
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::Store("workspace 锁不可用".into()))?;
    runtime()?.block_on(workspace.reload())
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
    let mut workspace = session
        .lock()
        .map_err(|_| CoreError::InvalidState("工作区锁不可用"))?;
    let runtime = runtime()?;
    match request {
        Request::Configure { root } => {
            workspace.set_preview_root(root.into())?;
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
    fn network_sync_does_not_block_other_workspace_requests_or_restore_old_file_snapshots() {
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
        let sync_directory = directory.clone();
        let syncing = std::thread::spawn(move || {
            repo_sync_json(
                handle,
                sync_directory,
                endpoint,
                "user".into(),
                "secret".into(),
                String::new(),
                0,
                1,
            )
        });
        entering.recv_timeout(Duration::from_secs(5)).unwrap();
        std::fs::write(root.join("a.org"), b"* TODO Edited during network\n").unwrap();
        let (read, reading) = std::sync::mpsc::channel();
        let read_directory = directory.clone();
        let reader = std::thread::spawn(move || {
            read.send(repo_snapshot_json(handle, read_directory))
                .unwrap();
        });
        let snapshot = reading.recv_timeout(Duration::from_secs(2));
        resume.send(()).unwrap();
        let snapshot = snapshot
            .expect("网络同步不能占住整个 workspace mutex")
            .unwrap();
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
