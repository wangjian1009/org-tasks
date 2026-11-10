//! 每轮同步的存活租约与恢复入口；网络阶段只持有同步锁。
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::fs;

use super::transaction;
use crate::CoreError;

const MARKER: &str = "sync";
const DIRECTORY: &str = ".sync/sessions";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Phase {
    Downloading,
    Merging,
    Uploading,
    Committing,
    Committed,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct State {
    version: u32,
    id: String,
    repo_id: String,
    started_at: crate::TimestampMs,
    phase: Phase,
}

pub(crate) struct Session {
    root: PathBuf,
    state: State,
    // 文件描述符由真正执行同步的 Core 调用持有，不依赖页面或宿主 Promise。
    _lease: std::fs::File,
}

fn io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法访问同步会话: {error}"))
}

fn relative(id: &str, name: &str) -> String {
    format!("{DIRECTORY}/{id}/{name}")
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 160
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

async fn state(root: &Path) -> Result<Option<State>, CoreError> {
    let Some(marker) = transaction::read(root, MARKER).await? else {
        return Ok(None);
    };
    let id = std::str::from_utf8(&marker)
        .map_err(|_| CoreError::InvalidState("同步标记编码无效"))?
        .trim_end_matches('\n');
    if !valid_id(id) {
        return Err(CoreError::InvalidState("同步标记 ID 无效"));
    }
    let bytes = transaction::read(root, &relative(id, "state.json"))
        .await?
        .ok_or(CoreError::InvalidState("同步标记对应的恢复材料丢失"))?;
    let value: State =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidState("同步阶段记录无效"))?;
    if value.version != 1 || value.id != id {
        return Err(CoreError::InvalidState("同步标记与阶段记录不一致"));
    }
    Ok(Some(value))
}

fn lease(file: &std::fs::File) -> Result<bool, CoreError> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        unsafe extern "C" {
            fn flock(fd: std::ffi::c_int, operation: std::ffi::c_int) -> std::ffi::c_int;
        }
        loop {
            if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
                return Ok(true);
            }
            let error = std::io::Error::last_os_error();
            match error.kind() {
                std::io::ErrorKind::Interrupted => continue,
                std::io::ErrorKind::WouldBlock => return Ok(false),
                _ => return Err(io(error)),
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        Err(CoreError::InvalidState("当前平台不支持同步存活文件锁"))
    }
}

async fn open_lease(root: &Path, id: &str) -> Result<std::fs::File, CoreError> {
    let path = transaction::target(root, &relative(id, "lock")).await?;
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(io)
}

async fn write_state(root: &Path, value: &State) -> Result<(), CoreError> {
    let path = transaction::target(root, &relative(&value.id, "state.json")).await?;
    transaction::atomic_write(
        &path,
        &serde_json::to_vec(value).map_err(|_| CoreError::InvalidState("无法编码同步阶段"))?,
    )
    .await
}

async fn clear(root: &Path, value: &State) -> Result<(), CoreError> {
    let current = state(root)
        .await?
        .ok_or(CoreError::InvalidState("同步标记已被移除"))?;
    if current.id != value.id || current.repo_id != value.repo_id {
        return Err(CoreError::InvalidState("同步身份已变化，拒绝清理"));
    }
    fs::remove_file(root.join(MARKER)).await.map_err(io)?;
    transaction::sync_dir(root).await?;
    // 标记先移除并落盘；清理失败留下可回收目录，不留下悬空恢复指针。
    let _ = fs::remove_dir_all(root.join(DIRECTORY).join(&value.id)).await;
    Ok(())
}

/// 调用者必须持有仓库锁；只探测同步锁，绝不在仓库锁内等待。
pub(crate) async fn active(root: &Path) -> Result<bool, CoreError> {
    let Some(value) = state(root).await? else {
        return Ok(false);
    };
    Ok(!lease(&open_lease(root, &value.id).await?)?)
}

/// 有活动同步时不触碰其材料；失去租约后先恢复旧提交，再移除同步标记。
pub(crate) async fn recover(root: &Path) -> Result<(), CoreError> {
    crate::model::reset::recover(root).await?;
    let Some(value) = state(root).await? else {
        return transaction::recover(root).await;
    };
    let identity = transaction::read(root, ".sync/id")
        .await?
        .ok_or(CoreError::InvalidState("仓库身份丢失"))?;
    if std::str::from_utf8(&identity).map(str::trim).ok() != Some(value.repo_id.as_str()) {
        return Err(CoreError::InvalidState("同步恢复材料不属于当前仓库"));
    }
    let file = open_lease(root, &value.id).await?;
    if !lease(&file)? {
        return Ok(());
    }
    transaction::recover(root).await?;
    clear(root, &value).await
}

impl Session {
    /// 调用者持有仓库锁；租约、阶段先落盘，再发布当前同步 ID。
    pub(crate) async fn begin(
        root: &Path,
        repo_id: &str,
        started_at: crate::TimestampMs,
    ) -> Result<Self, CoreError> {
        if active(root).await? {
            return Err(CoreError::InvalidState("此仓库已有同步正在进行"));
        }
        recover(root).await?;
        let id = crate::model::service::generate_repo_id()?;
        transaction::ensure_directory(root, &format!("{DIRECTORY}/{id}")).await?;
        let path = transaction::target(root, &relative(&id, "lock")).await?;
        let file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(path)
            .map_err(io)?;
        if !lease(&file)? {
            return Err(CoreError::InvalidState("无法取得新同步租约"));
        }
        file.sync_all().map_err(io)?;
        let value = State {
            version: 1,
            id,
            repo_id: repo_id.into(),
            started_at,
            phase: Phase::Downloading,
        };
        write_state(root, &value).await?;
        transaction::atomic_write(
            &transaction::target(root, MARKER).await?,
            format!("{}\n", value.id).as_bytes(),
        )
        .await?;
        Ok(Self {
            root: root.into(),
            state: value,
            _lease: file,
        })
    }

    pub(crate) async fn finish(&self) -> Result<(), CoreError> {
        let _guard = transaction::lock(&self.root).await?;
        self.check().await?;
        transaction::recover(&self.root).await?;
        let value = State {
            version: 1,
            id: self.state.id.clone(),
            repo_id: self.state.repo_id.clone(),
            started_at: self.state.started_at,
            phase: Phase::Committed,
        };
        write_state(&self.root, &value).await?;
        clear(&self.root, &value).await
    }

    async fn check(&self) -> Result<(), CoreError> {
        check(&self.root, &self.state.repo_id, self.state.started_at)
            .await
            .map(|_| ())
    }
}

async fn check(
    root: &Path,
    repo_id: &str,
    started_at: crate::TimestampMs,
) -> Result<State, CoreError> {
    if transaction::read(root, "reset").await?.is_some() {
        return Err(CoreError::InvalidState("仓库正在重置，本轮同步停止提交"));
    }
    let value = state(root)
        .await?
        .ok_or(CoreError::InvalidState("本轮同步标记已丢失"))?;
    if value.repo_id != repo_id || value.started_at != started_at {
        return Err(CoreError::InvalidState("当前同步身份已改变"));
    }
    let current = crate::model::service::read_repo_id(&root.join(".sync/id"))
        .await
        .map_err(io)?;
    if current != repo_id {
        return Err(CoreError::InvalidState("仓库身份已改变"));
    }
    Ok(value)
}

pub(crate) async fn enter(
    root: &Path,
    repo_id: &str,
    started_at: crate::TimestampMs,
    phase: Phase,
) -> Result<transaction::Guard, CoreError> {
    let guard = transaction::lock(root).await?;
    let mut value = check(root, repo_id, started_at).await?;
    value.phase = phase;
    write_state(root, &value).await?;
    Ok(guard)
}

/// 暂存仅写入本轮目录；网络响应与合并结果不会直接覆盖正式文件。
pub(crate) async fn stage(
    root: &Path,
    repo_id: &str,
    started_at: crate::TimestampMs,
    area: &str,
    path: &str,
    bytes: &[u8],
) -> Result<(), CoreError> {
    crate::model::validate_relative_path(path)?;
    let value = check(root, repo_id, started_at).await?;
    let relative = format!("{DIRECTORY}/{}/{area}/{path}", value.id);
    if let Some(parent) = Path::new(&relative).parent().and_then(Path::to_str) {
        transaction::ensure_directory(root, parent).await?;
    }
    transaction::atomic_write(&transaction::target(root, &relative).await?, bytes).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OrgRepo, webdav::WebDavSyncPolicy};

    async fn repository() -> (OrgRepo, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "org-sync-session-{}",
            crate::model::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        (repo, root)
    }

    #[tokio::test]
    async fn active_session_allows_reads_and_blocks_second_sync_without_recovering_its_files() {
        let (repo, root) = repository().await;
        fs::write(root.join("a.org"), b"* TODO Original\n")
            .await
            .unwrap();
        let guard = transaction::lock(&root).await.unwrap();
        let session = Session::begin(&root, &repo.id, 1).await.unwrap();
        assert!(active(&root).await.unwrap());
        assert!(Session::begin(&root, &repo.id, 2).await.is_err());
        drop(guard);
        stage(&root, &repo.id, 1, "remote", "a.org", b"downloaded")
            .await
            .unwrap();
        let mut reader = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            reader.load::<WebDavSyncPolicy>(),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            reader.file("a.org").await.unwrap().source_bytes(),
            b"* TODO Original\n"
        );
        assert!(root.join("sync").exists());
        assert!(
            root.join(relative(&session.state.id, "remote/a.org"))
                .exists()
        );
        session.finish().await.unwrap();
        assert!(!root.join("sync").exists());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn abandoned_download_is_recovered_without_changing_formal_content() {
        let (repo, root) = repository().await;
        fs::write(root.join("a.org"), b"* Existing\n")
            .await
            .unwrap();
        let guard = transaction::lock(&root).await.unwrap();
        let session = Session::begin(&root, &repo.id, 1).await.unwrap();
        let directory = root.join(DIRECTORY).join(&session.state.id);
        drop(guard);
        stage(&root, &repo.id, 1, "remote", "a.org", b"replacement")
            .await
            .unwrap();
        drop(session);
        let guard = transaction::lock(&root).await.unwrap();
        recover(&root).await.unwrap();
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"* Existing\n");
        assert!(!root.join("sync").exists());
        assert!(!directory.exists());
        drop(guard);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn abandoned_commit_restores_bytes_before_clearing_sync_marker() {
        let (repo, root) = repository().await;
        let guard = transaction::lock(&root).await.unwrap();
        let session = Session::begin(&root, &repo.id, 1).await.unwrap();
        transaction::ensure_directory(&root, ".sync/transactions/interrupted")
            .await
            .unwrap();
        let journal = serde_json::json!({"version":1,"changes":[{
            "path":"a.org","before":b"old".to_vec(),"after":b"new".to_vec()
        }],"created_dirs":[]});
        fs::write(
            root.join(".sync/transactions/interrupted/journal.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .await
        .unwrap();
        fs::write(root.join("a.org"), b"new").await.unwrap();
        drop(session);
        recover(&root).await.unwrap();
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"old");
        assert!(!root.join("sync").exists());
        drop(guard);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn reset_publishes_intent_then_waits_without_holding_repository_lock() {
        let (mut repo, root) = repository().await;
        fs::write(root.join("a.org"), b"* Existing\n")
            .await
            .unwrap();
        let identity = fs::read(root.join(".sync/id")).await.unwrap();
        let guard = transaction::lock(&root).await.unwrap();
        let session = Session::begin(&root, &repo.id, 1).await.unwrap();
        drop(guard);
        let reset_root = root.clone();
        let reset = tokio::spawn(async move { repo.reset().await });
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !reset_root.join("reset").exists() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let guard =
            tokio::time::timeout(std::time::Duration::from_secs(1), transaction::lock(&root))
                .await
                .unwrap()
                .unwrap();
        assert!(root.join("a.org").exists());
        drop(guard);
        assert!(session.check().await.is_err());
        drop(session);
        tokio::time::timeout(std::time::Duration::from_secs(2), reset)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(!root.join("reset").exists());
        assert!(!root.join("sync").exists());
        assert!(!root.join("a.org").exists());
        assert_eq!(fs::read(root.join(".sync/id")).await.unwrap(), identity);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn invalid_marker_is_preserved_and_never_used_as_directory_path() {
        let (_, root) = repository().await;
        fs::write(root.join("sync"), b"../outside\n").await.unwrap();
        let guard = transaction::lock(&root).await.unwrap();
        assert!(recover(&root).await.is_err());
        assert_eq!(fs::read(root.join("sync")).await.unwrap(), b"../outside\n");
        drop(guard);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn another_process_cannot_recover_a_live_sync_session() {
        let Some(path) = std::env::var_os("ORG_TASKS_ACTIVE_SYNC_ROOT") else {
            return;
        };
        let root = Path::new(&path);
        let guard = transaction::lock(root).await.unwrap();
        assert!(active(root).await.unwrap());
        recover(root).await.unwrap();
        assert!(root.join("sync").exists());
        drop(guard);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sync_session_is_live_across_processes_then_recoverable_after_owner_exits() {
        let (repo, root) = repository().await;
        let guard = transaction::lock(&root).await.unwrap();
        let session = Session::begin(&root, &repo.id, 1).await.unwrap();
        drop(guard);
        let child_root = root.clone();
        let output = tokio::task::spawn_blocking(move || {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "webdav::session::tests::another_process_cannot_recover_a_live_sync_session",
                ])
                .env("ORG_TASKS_ACTIVE_SYNC_ROOT", &child_root)
                .output()
        })
        .await
        .unwrap()
        .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        assert!(root.join("sync").exists());
        drop(session);
        let guard = transaction::lock(&root).await.unwrap();
        recover(&root).await.unwrap();
        assert!(!root.join("sync").exists());
        drop(guard);
        fs::remove_dir_all(root).await.unwrap();
    }
}
