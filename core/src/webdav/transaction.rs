//! 仓库级可恢复本地提交：准备材料不生效，提交失败还原，崩溃恢复先于仓库加载。
use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use tokio::fs;

/// 同进程内的同仓库同步、恢复与编辑串行；文件版本校验继续保护外部编辑。
pub(crate) struct Guard {
    // 先释放 OS 文件锁，再唤醒同进程等待者。
    #[cfg(unix)]
    _file: std::fs::File,
    _local: tokio::sync::OwnedMutexGuard<()>,
}

pub(crate) async fn lock(root: &Path) -> Result<Guard, CoreError> {
    lock_before(root, tokio::time::Instant::now() + std::time::Duration::from_secs(10)).await
}

pub(crate) async fn lock_before(root: &Path, deadline: tokio::time::Instant) -> Result<Guard, CoreError> {
    use std::sync::{Arc, Mutex, OnceLock, Weak};
    static LOCKS: OnceLock<
        Mutex<std::collections::BTreeMap<PathBuf, Weak<tokio::sync::Mutex<()>>>>,
    > = OnceLock::new();
    let path = fs::canonicalize(root).await.map_err(io)?;
    #[cfg(test)]
    crate::model::test_support::record_access(&path, 0);
    let mutex = {
        let mut locks = LOCKS
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        locks.retain(|_, value| value.strong_count() > 0);
        if let Some(mutex) = locks.get(&path).and_then(Weak::upgrade) {
            mutex
        } else {
            let mutex = Arc::new(tokio::sync::Mutex::new(()));
            locks.insert(path, Arc::downgrade(&mutex));
            mutex
        }
    };
    let local = tokio::time::timeout_at(deadline, mutex.lock_owned())
        .await
        .map_err(|_| busy())?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        unsafe extern "C" {
            fn flock(fd: std::ffi::c_int, operation: std::ffi::c_int) -> std::ffi::c_int;
        }
        ensure_directory(root, ".sync").await?;
        let path = target(root, ".sync/.transaction.lock").await?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
            .map_err(io)?;
        // 非阻塞探测配合异步退避；等待期间不恢复另一进程仍在执行的事务。
        let mut delay = std::time::Duration::from_millis(25);
        loop {
            if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            match error.kind() {
                std::io::ErrorKind::Interrupted => continue,
                std::io::ErrorKind::WouldBlock => {}
                _ => return Err(io(error)),
            }
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() { return Err(busy()); }
            tokio::time::sleep(delay.min(remaining)).await;
            delay = (delay * 2).min(std::time::Duration::from_millis(200));
        }
        return Ok(Guard {
            _local: local,
            _file: file,
        });
    }
    #[cfg(not(unix))]
    Ok(Guard { _local: local })
}

fn busy() -> CoreError {
    CoreError::InvalidState("等待仓库空闲超时，请稍后重试")
}

// 私有提交槽把策略准备的本地事务交回 OrgRepo，保持 SyncContext 的公开字段与构造接口不变。
type SlotKey = (PathBuf, crate::TimestampMs);
type SlotValue = std::sync::Mutex<Option<Plan>>;
fn slots()
-> &'static std::sync::Mutex<std::collections::BTreeMap<SlotKey, std::sync::Weak<SlotValue>>> {
    static SLOTS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::BTreeMap<SlotKey, std::sync::Weak<SlotValue>>>,
    > = std::sync::OnceLock::new();
    SLOTS.get_or_init(Default::default)
}
pub(crate) struct CommitSlot {
    key: SlotKey,
    value: std::sync::Arc<SlotValue>,
}
impl CommitSlot {
    pub fn new(root: &Path, time: crate::TimestampMs) -> Self {
        let key = (root.to_path_buf(), time);
        let value = std::sync::Arc::new(std::sync::Mutex::new(None));
        slots()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(key.clone(), std::sync::Arc::downgrade(&value));
        Self { key, value }
    }
    pub fn take(&self) -> Option<Plan> {
        self.value.lock().unwrap_or_else(|e| e.into_inner()).take()
    }
}
impl Drop for CommitSlot {
    fn drop(&mut self) {
        let mut slots = slots().lock().unwrap_or_else(|e| e.into_inner());
        if slots
            .get(&self.key)
            .is_some_and(|slot| slot.ptr_eq(&std::sync::Arc::downgrade(&self.value)))
        {
            slots.remove(&self.key);
        }
    }
}
pub(crate) fn stage(root: &Path, time: crate::TimestampMs, plan: Plan) -> Result<(), CoreError> {
    let slot = slots()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&(root.to_path_buf(), time))
        .and_then(std::sync::Weak::upgrade);
    if let Some(slot) = slot {
        let mut pending = slot.lock().unwrap_or_else(|e| e.into_inner());
        if pending.is_some() {
            return Err(CoreError::InvalidState("同一同步已准备本地提交"));
        }
        *pending = Some(plan);
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Change {
    pub path: String,
    pub before: Option<Vec<u8>>,
    pub after: Option<Vec<u8>>,
}
#[derive(Default)]
pub(crate) struct Plan {
    pub changes: Vec<Change>,
    pub guards: Vec<(String, Option<Vec<u8>>)>,
}
#[derive(Serialize, Deserialize)]
struct Journal {
    version: u32,
    changes: Vec<Change>,
    created_dirs: Vec<String>,
}

fn io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法提交或恢复仓库事务: {error}"))
}
fn validate(path: &str) -> Result<(), CoreError> {
    crate::model::validate_relative_path(path)?;
    if path.starts_with(".sync/transactions/") || path == ".sync/id" {
        return Err(CoreError::InvalidInput("事务目标不能覆盖自身或仓库身份"));
    }
    Ok(())
}
/// 不跟随任意路径组件的符号链接，检查阶段不创建目录。
pub(crate) async fn target(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
    crate::model::validate_relative_path(path)?;
    let mut result = root.to_path_buf();
    let parts = path.split('/').collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        result.push(part);
        match fs::symlink_metadata(&result).await {
            Ok(info)
                if info.file_type().is_symlink()
                    || (index + 1 < parts.len() && !info.is_dir())
                    || (index + 1 == parts.len() && !info.is_file()) =>
            {
                return Err(CoreError::Store("事务目标含符号链接或文件类型不符".into()));
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(io(e)),
        }
    }
    Ok(result)
}
pub(crate) async fn read(root: &Path, path: &str) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::read(target(root, path).await?).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(io(e)),
    }
}
pub(crate) async fn sync_dir(path: &Path) -> Result<(), CoreError> {
    // 同文件系统 rename 后刷新父目录，确保恢复日志与正式目标的提交顺序。
    std::fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(io)
}
pub(crate) async fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), CoreError> {
    let temporary = path.with_file_name(format!(
        ".{}.tmp",
        crate::model::service::generate_repo_id()?
    ));
    crate::model::write_intent::write_new(&temporary, bytes).await?;
    if let Err(e) = fs::rename(&temporary, path).await {
        let _ = fs::remove_file(&temporary).await;
        return Err(io(e));
    }
    sync_dir(path.parent().unwrap()).await
}
async fn put(root: &Path, path: &str, bytes: Option<&[u8]>) -> Result<(), CoreError> {
    let destination = target(root, path).await?;
    if let Some(bytes) = bytes {
        atomic_write(&destination, bytes).await
    } else {
        match fs::remove_file(&destination).await {
            Ok(()) => sync_dir(destination.parent().unwrap()).await,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io(e)),
        }
    }
}
impl Plan {
    pub async fn set(
        &mut self,
        root: &Path,
        path: String,
        after: Option<Vec<u8>>,
    ) -> Result<(), CoreError> {
        validate(&path)?;
        if self.changes.iter().any(|c| c.path == path) {
            return Err(CoreError::InvalidState("仓库事务包含重复目标"));
        }
        let before = read(root, &path).await?;
        self.changes.push(Change {
            path,
            before,
            after,
        });
        Ok(())
    }
    pub async fn verify(&self, root: &Path) -> Result<(), CoreError> {
        for (path, before) in &self.guards {
            if read(root, path).await? != *before {
                return Err(CoreError::InvalidState(
                    "同步期间本地文件已改变，未提交本轮结果",
                ));
            }
        }
        for change in &self.changes {
            if read(root, &change.path).await? != change.before {
                return Err(CoreError::InvalidState(
                    "同步期间仓库或基线已改变，未提交本轮结果",
                ));
            }
        }
        Ok(())
    }
    pub async fn commit(self, root: &Path) -> Result<(), CoreError> {
        self.verify(root).await?;
        let directory = root.join(".sync/transactions");
        ensure_directory(root, ".sync/transactions").await?;
        let work = directory.join(crate::model::service::generate_repo_id()?);
        fs::create_dir(&work).await.map_err(io)?;
        let mut created_dirs = BTreeSet::new();
        for change in &self.changes {
            let mut path = PathBuf::new();
            for part in Path::new(&change.path).parent().unwrap().components() {
                path.push(part);
                let absolute = root.join(&path);
                match fs::symlink_metadata(absolute).await {
                    Ok(info) if info.file_type().is_symlink() || !info.is_dir() => {
                        return Err(CoreError::Store("事务父目录类型无效".into()));
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                        created_dirs.insert(path.to_string_lossy().into_owned());
                    }
                    Err(e) => return Err(io(e)),
                }
            }
        }
        let journal = Journal {
            version: 1,
            changes: self.changes,
            created_dirs: created_dirs.into_iter().collect(),
        };
        let source = serde_json::to_vec(&journal)
            .map_err(|_| CoreError::InvalidState("无法编码仓库事务"))?;
        crate::model::write_intent::write_new(&work.join("journal.json"), &source).await?;
        sync_dir(&work).await?;
        sync_dir(&directory).await?;
        let apply = async {
            for path in &journal.created_dirs {
                ensure_directory(root, path).await?;
            }
            for change in &journal.changes {
                if read(root, &change.path).await? != change.before {
                    return Err(CoreError::InvalidState(
                        "本地文件在提交期间改变，停止本轮提交",
                    ));
                }
                put(root, &change.path, change.after.as_deref()).await?;
            }
            for change in &journal.changes {
                if read(root, &change.path).await? != change.after {
                    return Err(CoreError::InvalidState(
                        "本地文件在提交期间再次改变，停止本轮提交",
                    ));
                }
            }
            crate::model::write_intent::write_new(&work.join("committed"), b"1\n").await?;
            sync_dir(&work).await
        }
        .await;
        if let Err(error) = apply {
            rollback(root, &journal).await?;
            let _ = fs::remove_dir_all(&work).await;
            return Err(error);
        }
        // 完成标记之后清理失败不把成功事务改报失败；后续加载继续清理。
        let _ = fs::remove_dir_all(&work).await;
        Ok(())
    }
}
pub(crate) async fn ensure_directory(root: &Path, path: &str) -> Result<(), CoreError> {
    crate::model::validate_relative_path(path)?;
    let mut directory = root.to_path_buf();
    for part in path.split('/') {
        directory.push(part);
        match fs::symlink_metadata(&directory).await {
            Ok(info) if info.file_type().is_symlink() || !info.is_dir() => {
                return Err(CoreError::Store("事务路径不是安全目录".into()));
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&directory).await.map_err(io)?;
                sync_dir(directory.parent().unwrap()).await?;
            }
            Err(e) => return Err(io(e)),
        }
    }
    Ok(())
}
async fn rollback(root: &Path, journal: &Journal) -> Result<(), CoreError> {
    // 先预检全部目标，遇到外部新编辑不覆盖任何外部数据，保留事务供恢复。
    for change in &journal.changes {
        let current = read(root, &change.path).await?;
        if current != change.before && current != change.after {
            return Err(CoreError::Store(
                "事务恢复被外部编辑阻止，已保留恢复材料".into(),
            ));
        }
    }
    for change in journal.changes.iter().rev() {
        if read(root, &change.path).await? != change.before {
            put(root, &change.path, change.before.as_deref()).await?;
        }
    }
    for path in journal.created_dirs.iter().rev() {
        let _ = fs::remove_dir(root.join(path)).await;
    }
    Ok(())
}
pub(crate) async fn recover(root: &Path) -> Result<(), CoreError> {
    let directory = root.join(".sync/transactions");
    match fs::symlink_metadata(&directory).await {
        Ok(info) if info.file_type().is_symlink() || !info.is_dir() => {
            return Err(CoreError::Store("仓库事务目录无效".into()));
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(io(e)),
        _ => {}
    }
    let mut entries = fs::read_dir(&directory).await.map_err(io)?;
    let mut works = Vec::new();
    while let Some(entry) = entries.next_entry().await.map_err(io)? {
        if !entry.file_type().await.map_err(io)?.is_dir() {
            return Err(CoreError::Store("仓库事务恢复材料类型无效".into()));
        }
        works.push(entry.path());
    }
    works.sort();
    for work in works {
        let relative = work
            .strip_prefix(root)
            .map_err(|_| CoreError::InvalidState("事务目录越界"))?
            .to_string_lossy();
        let source = read(root, &format!("{relative}/journal.json")).await?;
        if let Some(source) = source {
            let journal: Journal = serde_json::from_slice(&source)
                .map_err(|_| CoreError::Store("仓库事务日志无效".into()))?;
            if journal.version != 1 {
                return Err(CoreError::InvalidState("不支持的仓库事务版本"));
            }
            let mut paths = BTreeSet::new();
            for change in &journal.changes {
                validate(&change.path)?;
                if !paths.insert(&change.path) {
                    return Err(CoreError::Store("事务恢复目标重复".into()));
                }
            }
            for path in &journal.created_dirs {
                crate::model::validate_relative_path(path)?;
            }
            match read(root, &format!("{relative}/committed")).await? {
                Some(bytes) if bytes == b"1\n" => {}
                Some(_) => return Err(CoreError::Store("仓库事务完成标记无效".into())),
                None => rollback(root, &journal).await?,
            }
        }
        fs::remove_dir_all(work).await.map_err(io)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn root() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "org-transaction-{}",
            crate::model::service::generate_repo_id().unwrap()
        ));
        fs::create_dir_all(path.join(".sync")).await.unwrap();
        path
    }
    #[tokio::test]
    async fn recovery_rolls_back_partial_writes_and_removes_unpublished_metadata() {
        let root = root().await;
        fs::write(root.join("a.org"), b"new").await.unwrap();
        ensure_directory(&root, ".sync/remote_base").await.unwrap();
        fs::write(root.join(".sync/remote_base/current.json"), b"new index")
            .await
            .unwrap();
        let journal = Journal {
            version: 1,
            changes: vec![
                Change {
                    path: "a.org".into(),
                    before: Some(b"old".to_vec()),
                    after: Some(b"new".to_vec()),
                },
                Change {
                    path: ".sync/remote_base/current.json".into(),
                    before: None,
                    after: Some(b"new index".to_vec()),
                },
            ],
            created_dirs: vec![".sync/remote_base".into()],
        };
        ensure_directory(&root, ".sync/transactions/one")
            .await
            .unwrap();
        fs::write(
            root.join(".sync/transactions/one/journal.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .await
        .unwrap();
        recover(&root).await.unwrap();
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"old");
        assert!(!root.join(".sync/remote_base").exists());
        fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn invalidation_and_symlinks_never_overwrite_working_files() {
        let root = root().await;
        fs::write(root.join("a.org"), b"old").await.unwrap();
        let mut plan = Plan::default();
        plan.set(&root, "a.org".into(), Some(b"new".to_vec()))
            .await
            .unwrap();
        fs::write(root.join("a.org"), b"external").await.unwrap();
        assert!(plan.commit(&root).await.is_err());
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"external");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("a.org"), root.join("link.org")).unwrap();
            assert!(read(&root, "link.org").await.is_err());
        }
        fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn committed_recovery_keeps_new_files_and_only_cleans_the_journal() {
        let root = root().await;
        fs::write(root.join("a.org"), b"new").await.unwrap();
        let journal = Journal {
            version: 1,
            changes: vec![Change {
                path: "a.org".into(),
                before: Some(b"old".to_vec()),
                after: Some(b"new".to_vec()),
            }],
            created_dirs: vec![],
        };
        ensure_directory(&root, ".sync/transactions/one")
            .await
            .unwrap();
        fs::write(
            root.join(".sync/transactions/one/journal.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .await
        .unwrap();
        fs::write(root.join(".sync/transactions/one/committed"), b"1\n")
            .await
            .unwrap();
        recover(&root).await.unwrap();
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"new");
        assert!(!root.join(".sync/transactions/one").exists());
        fs::remove_dir_all(root).await.unwrap();
    }
    #[tokio::test]
    async fn recovery_never_overwrites_external_changes_and_retains_recovery_material() {
        let root = root().await;
        fs::write(root.join("a.org"), b"external").await.unwrap();
        let journal = Journal {
            version: 1,
            changes: vec![Change {
                path: "a.org".into(),
                before: Some(b"old".to_vec()),
                after: Some(b"new".to_vec()),
            }],
            created_dirs: vec![],
        };
        ensure_directory(&root, ".sync/transactions/one")
            .await
            .unwrap();
        fs::write(
            root.join(".sync/transactions/one/journal.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .await
        .unwrap();
        assert!(recover(&root).await.is_err());
        assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"external");
        assert!(root.join(".sync/transactions/one/journal.json").is_file());
        fs::remove_dir_all(root).await.unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn active_transaction_locks_are_shared_across_processes_and_released_on_drop() {
        let root = root().await;
        let guard = lock(&root).await.unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "webdav::transaction::tests::another_process_cannot_recover_an_active_transaction",
            ])
            .env("ORG_TASKS_LOCKED_ROOT", &root)
            .status()
            .unwrap();
        assert!(status.success());
        drop(guard);
        drop(lock(&root).await.unwrap());
        fs::remove_dir_all(root).await.unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn another_process_cannot_recover_an_active_transaction() {
        let Some(root) = std::env::var_os("ORG_TASKS_LOCKED_ROOT") else {
            return;
        };
        assert!(matches!(
            lock_before(Path::new(&root), tokio::time::Instant::now() + std::time::Duration::from_millis(100)).await,
            Err(CoreError::InvalidState(_))
        ));
    }

    #[tokio::test]
    async fn queued_writer_waits_until_owner_releases_and_timeout_releases_local_queue() {
        let root = root().await;
        let guard = lock(&root).await.unwrap();
        let waiting_root = root.clone();
        let waiting = tokio::spawn(async move { lock(&waiting_root).await });
        tokio::task::yield_now().await;
        assert!(!waiting.is_finished());
        assert!(lock_before(&root, tokio::time::Instant::now() + std::time::Duration::from_millis(20)).await.is_err());
        drop(guard);
        drop(waiting.await.unwrap().unwrap());
        drop(lock(&root).await.unwrap());
        fs::remove_dir_all(root).await.unwrap();
    }
}
