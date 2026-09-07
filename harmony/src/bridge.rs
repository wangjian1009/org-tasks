use org_tasks_core::webdav::{WebDavEndpoint, WebDavSyncPolicy};
use org_tasks_core::{
    CoreError, OrgRepo, OrgRepoSyncResult, SyncCancellation, SyncProgressReporter, TimestampMs,
};
use serde::{Deserialize, Serialize};

/// Harmony 宿主到 core 的结构化请求。
#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum HarmonyBridgeRequest {
    LoadRepository {
        root_directory: String,
    },
    SyncWebDav {
        root_directory: String,
        webdav_url: String,
        username: String,
        password: String,
        started_at: TimestampMs,
    },
}

#[derive(Debug, Serialize)]
pub struct HarmonyBridgeResponse {
    pub repository: HarmonyBridgeRepository,
    pub sync: Option<HarmonyBridgeSync>,
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
pub struct HarmonyBridgeSync {
    pub id: String,
    pub result: String,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub files: usize,
}

/// 调用 core 的仓库加载与 WebDAV 同步能力，返回供 ArkTS 渲染的快照。
pub async fn execute(request: HarmonyBridgeRequest) -> Result<HarmonyBridgeResponse, CoreError> {
    match request {
        HarmonyBridgeRequest::LoadRepository { root_directory } => {
            let mut repository = OrgRepo::new(root_directory)?;
            repository.load::<WebDavSyncPolicy>().await?;
            Ok(HarmonyBridgeResponse {
                repository: repository_snapshot(&repository)?,
                sync: None,
            })
        }
        HarmonyBridgeRequest::SyncWebDav {
            root_directory,
            webdav_url,
            username,
            password,
            started_at,
        } => {
            let mut repository = OrgRepo::new(root_directory)?;
            let history = repository.load::<WebDavSyncPolicy>().await?;
            let policy =
                WebDavSyncPolicy::new(WebDavEndpoint::new(webdav_url)?, username, password)?;
            let record = repository
                .sync(
                    &policy,
                    &history,
                    started_at,
                    &SyncCancellation::default(),
                    &SyncProgressReporter::default(),
                )
                .await?;
            Ok(HarmonyBridgeResponse {
                repository: repository_snapshot(&repository)?,
                sync: Some(HarmonyBridgeSync {
                    id: record.id,
                    result: sync_result_label(record.result)?,
                    started_at: record.started_at,
                    finished_at: record.finished_at,
                    files: record.files.len(),
                }),
            })
        }
    }
}

/// C ABI 使用的同步包装。Tokio runtime 在 Harmony 宿主层创建。
pub fn execute_json(request: &str) -> Result<String, CoreError> {
    let request: HarmonyBridgeRequest = serde_json::from_str(request)
        .map_err(|_| CoreError::InvalidInput("Harmony bridge 请求 JSON 无效"))?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| CoreError::Store(format!("无法创建 Harmony runtime: {error}")))?;
    let response = runtime.block_on(execute(request))?;
    serde_json::to_string(&response)
        .map_err(|error| CoreError::Store(format!("无法编码 Harmony bridge 响应: {error}")))
}

fn repository_snapshot(repository: &OrgRepo) -> Result<HarmonyBridgeRepository, CoreError> {
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
    Ok(HarmonyBridgeRepository {
        id: repository.id.clone(),
        files,
    })
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
    fn load_request_returns_core_file_snapshot() {
        let root =
            std::env::temp_dir().join(format!("org-tasks-harmony-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("inbox.org"), "* TODO bridge\n").unwrap();

        let request = serde_json::json!({
            "action": "load_repository",
            "root_directory": root.to_string_lossy(),
        });
        let response = execute_json(&request.to_string()).unwrap();
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["repository"]["files"][0]["path"], "inbox.org");
        assert_eq!(
            response["repository"]["files"][0]["source"],
            "* TODO bridge\n"
        );

        std::fs::remove_dir_all(root).unwrap();
    }
}
