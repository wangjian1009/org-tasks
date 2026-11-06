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
    pub repo_id: String,
    pub heading: String,
    pub heading_parts: Vec<org_tasks_core::TitlePart>,
    pub todo_state: String,
    pub todo_kind: Option<org_tasks_core::TodoStateKind>,
    pub is_done: bool,
    pub priority: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub body: String,
    pub body_html: String,
    pub logbook_html: String,
    pub progress: i32,
    pub has_list: bool,
    pub is_repeating: bool,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSync {
    pub id: String,
    pub result: String,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub files: usize,
    pub conflicts: Vec<String>,
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
        .map(task_from_filter)
        .collect())
}

fn task_from_filter(task: FilterTask) -> HarmonyBridgeTask {
    let is_done = task.is_done();
    let heading_parts = task.title_parts();
    let content = task.render_content();
    let mut tags = task.own_tags;
    for inherited in task.inherited_tags {
        if !tags.contains(&inherited) {
            tags.push(inherited);
        }
    }
    HarmonyBridgeTask {
        id: task.id,
        repo_id: task.repo_id,
        heading: task.title,
        heading_parts,
        todo_state: task.state.unwrap_or_default(),
        todo_kind: match task.state_type {
            org_tasks_core::FilterStateType::Todo => Some(org_tasks_core::TodoStateKind::Pending),
            org_tasks_core::FilterStateType::Done => Some(org_tasks_core::TodoStateKind::Done),
            _ => None,
        },
        is_done,
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
        body_html: content.body_html,
        logbook_html: content.logbook_html,
        progress: -1,
        has_list: content.has_list,
        is_repeating: task.is_repeating,
    }
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
        "tasks": result.tasks.into_iter().map(task_from_filter).collect::<Vec<_>>(),
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
    encode(&HarmonyBridgeSync {
        id: record.id,
        result: sync_result_label(record.result)?,
        started_at: record.started_at,
        finished_at: record.finished_at,
        files: record.files.len(),
        conflicts: record
            .files
            .iter()
            .filter(|f| {
                matches!(
                    f.state,
                    org_tasks_core::OrgRepoSyncFileState::Conflict
                        | org_tasks_core::OrgRepoSyncFileState::RemoteDeleted
                )
            })
            .map(|f| f.relative_path.clone())
            .collect(),
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
                b"* TODO Task :work:\nSCHEDULED: <2026-11-06 Fri +1d>\n- [ ] First\n".to_vec(),
            )
            .unwrap(),
        );
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let task = task_from_filter(workspace.search(&Filter::parse("")).remove(0));
        let value = serde_json::to_value(task).unwrap();
        assert_eq!(value["hasList"], true);
        assert_eq!(value["isRepeating"], true);
        assert_eq!(value["scheduled"], "2026-11-06");
        assert!(value["bodyHtml"].as_str().unwrap().contains("<ul>"));
        assert_eq!(value["tags"][0], "work");
    }
}
