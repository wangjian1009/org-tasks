use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

use org_tasks_core::webdav::{WebDavEndpoint, WebDavSyncPolicy};
use org_tasks_core::{
    CoreError, Filter, FilterTask, OrgRepo, OrgRepoSyncResult, OrgWorkspace, SyncCancellation,
    SyncProgressReporter, TimestampMs,
};
use serde::Serialize;

struct WorkspaceSession {
    workspace: Arc<Mutex<OrgWorkspace>>,
    references: usize,
}

struct WebDavSyncPolicySession {
    policy: Arc<WebDavSyncPolicy>,
    references: usize,
}

#[derive(Default)]
struct WorkspaceSessions {
    next_handle: u64,
    sessions: BTreeMap<u64, WorkspaceSession>,
}

#[derive(Default)]
struct WebDavSyncPolicySessions {
    next_handle: u64,
    sessions: BTreeMap<u64, WebDavSyncPolicySession>,
}

static WORKSPACE_SESSIONS: OnceLock<Mutex<WorkspaceSessions>> = OnceLock::new();
static WEBDAV_SYNC_POLICY_SESSIONS: OnceLock<Mutex<WebDavSyncPolicySessions>> = OnceLock::new();

fn workspace_sessions() -> &'static Mutex<WorkspaceSessions> {
    WORKSPACE_SESSIONS.get_or_init(|| Mutex::new(WorkspaceSessions::default()))
}

fn webdav_sync_policy_sessions() -> &'static Mutex<WebDavSyncPolicySessions> {
    WEBDAV_SYNC_POLICY_SESSIONS.get_or_init(|| Mutex::new(WebDavSyncPolicySessions::default()))
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeRepository {
    pub id: String,
    pub files: Vec<HarmonyBridgeFile>,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeFile {
    pub path: String,
    pub source: String,
    pub byte_length: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarmonyBridgeTask {
    pub id: String,
    pub heading: String,
    pub todo_state: String,
    pub priority: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub file_path: String,
    pub file_name: String,
    pub level: u32,
    pub body: String,
    pub progress: i32,
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeSync {
    pub id: String,
    pub result: String,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub files: usize,
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
    let mut tags = task.own_tags;
    for inherited in task.inherited_tags {
        if !tags.contains(&inherited) {
            tags.push(inherited);
        }
    }
    HarmonyBridgeTask {
        id: format!("{}:{}:{}", task.repo_id, task.path, task.byte_offset),
        heading: task.title,
        todo_state: task.state.unwrap_or_default(),
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
        level: 0,
        body: task.body,
        progress: -1,
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

pub fn workspace_repo_ids(handle: u64) -> Result<Vec<String>, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    Ok(workspace
        .repos()
        .iter()
        .map(|repo| repo.id.clone())
        .collect())
}

pub fn workspace_load(handle: u64) -> Result<(), CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let runtime = runtime()?;
    runtime.block_on(workspace.load::<WebDavSyncPolicy>())
}

pub fn workspace_add_repo(handle: u64, root_directory: String) -> Result<(), CoreError> {
    let repository = OrgRepo::new(root_directory)?;
    let workspace = workspace_for_handle(handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    workspace.add_repo(repository)
}

pub fn workspace_search_json(handle: u64, expression: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    encode(&task_snapshot(&workspace, &Filter::parse(&expression))?)
}

pub fn create_webdav_sync_policy(
    webdav_url: String,
    username: String,
    password: String,
) -> Result<u64, CoreError> {
    let policy = WebDavSyncPolicy::new(WebDavEndpoint::new(webdav_url)?, username, password)?;
    let mut sessions = webdav_sync_policy_sessions()
        .lock()
        .map_err(|_| CoreError::Store("WebDAV SyncPolicy session 锁不可用".into()))?;
    sessions.next_handle = sessions
        .next_handle
        .checked_add(1)
        .ok_or(CoreError::InvalidState("WebDAV SyncPolicy handle 已耗尽"))?;
    let handle = sessions.next_handle;
    sessions.sessions.insert(
        handle,
        WebDavSyncPolicySession {
            policy: Arc::new(policy),
            references: 1,
        },
    );
    Ok(handle)
}

pub fn retain_webdav_sync_policy(handle: u64) -> Result<(), CoreError> {
    let mut sessions = webdav_sync_policy_sessions()
        .lock()
        .map_err(|_| CoreError::Store("WebDAV SyncPolicy session 锁不可用".into()))?;
    let session = sessions
        .sessions
        .get_mut(&handle)
        .ok_or(CoreError::InvalidInput("WebDAV SyncPolicy handle 无效"))?;
    session.references = session
        .references
        .checked_add(1)
        .ok_or(CoreError::InvalidState("WebDAV SyncPolicy 引用已耗尽"))?;
    Ok(())
}

pub fn release_webdav_sync_policy(handle: u64) {
    if let Ok(mut sessions) = webdav_sync_policy_sessions().lock() {
        if let Some(session) = sessions.sessions.get_mut(&handle) {
            session.references = session.references.saturating_sub(1);
            if session.references == 0 {
                sessions.sessions.remove(&handle);
            }
        }
    }
}

pub fn repo_sync_json(
    workspace_handle: u64,
    repo_id: String,
    policy_handle: u64,
    started_at: TimestampMs,
) -> Result<String, CoreError> {
    let policy = webdav_sync_policy_for_handle(policy_handle)?;
    let workspace = workspace_for_handle(workspace_handle)?;
    let mut workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo_mut(&repo_id)
        .ok_or(CoreError::InvalidInput("仓库 ID 不属于 workspace"))?;
    let runtime = runtime()?;
    let history = runtime.block_on(repository.load::<WebDavSyncPolicy>())?;
    let record = runtime.block_on(repository.sync(
        policy.as_ref(),
        &history,
        started_at,
        &SyncCancellation::default(),
        &SyncProgressReporter::default(),
    ))?;
    encode(&HarmonyBridgeSync {
        id: record.id,
        result: sync_result_label(record.result)?,
        started_at: record.started_at,
        finished_at: record.finished_at,
        files: record.files.len(),
    })
}

fn webdav_sync_policy_for_handle(handle: u64) -> Result<Arc<WebDavSyncPolicy>, CoreError> {
    let sessions = webdav_sync_policy_sessions()
        .lock()
        .map_err(|_| CoreError::Store("WebDAV SyncPolicy session 锁不可用".into()))?;
    sessions
        .sessions
        .get(&handle)
        .map(|session| Arc::clone(&session.policy))
        .ok_or(CoreError::InvalidInput("WebDAV SyncPolicy handle 无效"))
}

pub fn repo_snapshot_json(handle: u64, repo_id: String) -> Result<String, CoreError> {
    let workspace = workspace_for_handle(handle)?;
    let workspace = workspace
        .lock()
        .map_err(|_| CoreError::Store("Harmony workspace 锁不可用".into()))?;
    let repository = workspace
        .repo(&repo_id)
        .ok_or(CoreError::InvalidInput("仓库 ID 不属于 workspace"))?;
    let mut files = Vec::with_capacity(repository.files().len());
    for file in repository.files() {
        files.push(HarmonyBridgeFile {
            path: file.path.clone(),
            source: std::str::from_utf8(file.source_bytes())
                .map_err(|_| CoreError::InvalidState("已加载 Org 文件不是 UTF-8"))?
                .into(),
            byte_length: file.source_bytes().len(),
        });
    }
    encode(&HarmonyBridgeRepository {
        id: repository.id.clone(),
        files,
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
    fn repository_object_returns_core_file_snapshot() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), "* TODO bridge\n").unwrap();

        let handle = create_workspace().unwrap();
        workspace_add_repo(handle, root.to_string_lossy().into()).unwrap();
        workspace_load(handle).unwrap();
        let repository_id = workspace_repo_ids(handle).unwrap().pop().unwrap();
        let response = repo_snapshot_json(handle, repository_id).unwrap();
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["files"][0]["path"], "inbox.org");
        assert_eq!(response["files"][0]["source"], "* TODO bridge\n");

        release_workspace(handle);
        std::fs::remove_dir_all(root).unwrap();
    }
}
