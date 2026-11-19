//! 一次查询内的共享文件读取；缓存与同路径等待者只归 process 所有。
use crate::CoreError;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio::task::{AbortHandle, JoinSet};

type ReadResult = Result<Option<Arc<[u8]>>, CoreError>;
type FileKey = (PathBuf, String);
type Reply = oneshot::Sender<ReadResult>;

enum Command {
    Read { key: FileKey, reply: Reply },
    Finish(oneshot::Sender<()>),
}

struct Process(AbortHandle);
impl Drop for Process {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// 克隆只共享入口；最后一个句柄释放时取消仍在等待的读取并丢弃缓存。
#[derive(Clone)]
pub(crate) struct SharedFileManager {
    sender: mpsc::UnboundedSender<Command>,
    _process: Arc<Process>,
}

impl SharedFileManager {
    pub(crate) fn new() -> Self {
        let (sender, requests) = mpsc::unbounded_channel();
        let task = tokio::spawn(Self::process(requests));
        Self {
            sender,
            _process: Arc::new(Process(task.abort_handle())),
        }
    }

    pub(crate) async fn read(&self, root: &Path, path: &str) -> ReadResult {
        let path = normalize(path)?;
        let (reply, received) = oneshot::channel();
        self.sender
            .send(Command::Read {
                key: (root.to_path_buf(), path),
                reply,
            })
            .map_err(|_| stopped())?;
        received.await.map_err(|_| stopped())?
    }

    /// 调用方收齐本次查询结果后等待清理；错误或取消由句柄释放兜底。
    pub(crate) async fn finish(&self) -> Result<(), CoreError> {
        let (reply, received) = oneshot::channel();
        self.sender
            .send(Command::Finish(reply))
            .map_err(|_| stopped())?;
        received.await.map_err(|_| stopped())
    }

    async fn process(mut requests: mpsc::UnboundedReceiver<Command>) {
        let mut cache = BTreeMap::<FileKey, ReadResult>::new();
        let mut pending = BTreeMap::<FileKey, Vec<Reply>>::new();
        let mut reads = JoinSet::<(FileKey, ReadResult)>::new();
        loop {
            tokio::select! {
                command = requests.recv() => match command {
                    Some(Command::Read { key, reply }) => {
                        if let Some(result) = cache.get(&key) {
                            let _ = reply.send(result.clone());
                        } else if let Some(waiters) = pending.get_mut(&key) {
                            waiters.push(reply);
                        } else {
                            pending.insert(key.clone(), vec![reply]);
                            reads.spawn(async move {
                                #[cfg(test)]
                                crate::model::test_support::record_file_access(&key.0.join(&key.1), 0);
                                let result = crate::webdav::transaction::read(&key.0, &key.1)
                                    .await.map(|bytes| bytes.map(Arc::from));
                                (key, result)
                            });
                        }
                    }
                    Some(Command::Finish(reply)) => {
                        requests.close();
                        reads.abort_all();
                        while reads.join_next().await.is_some() {}
                        cache.clear();
                        pending.clear();
                        let _ = reply.send(());
                        break;
                    }
                    None => break,
                },
                completed = reads.join_next(), if !reads.is_empty() => match completed {
                    Some(Ok((key, result))) => {
                        if let Some(waiters) = pending.remove(&key) {
                            for reply in waiters { let _ = reply.send(result.clone()); }
                        }
                        cache.insert(key, result);
                    }
                    // task 异常时终止本管理器，等待者从关闭的 reply 得到错误，不会挂起。
                    Some(Err(_)) => break,
                    None => {},
                },
            }
        }
    }
}

fn stopped() -> CoreError {
    CoreError::InvalidState("共享文件读取已结束")
}

fn normalize(path: &str) -> Result<String, CoreError> {
    if path.is_empty() || path.contains('\\') || path.contains('\0') {
        return Err(CoreError::InvalidInput("共享文件路径必须是仓库内相对路径"));
    }
    let mut normalized = PathBuf::new();
    for component in Path::new(path).components() {
        match component {
            Component::Normal(name) if name != ".sync" => normalized.push(name),
            Component::CurDir => {}
            Component::ParentDir if normalized.pop() => {}
            _ => {
                return Err(CoreError::InvalidInput(
                    "共享文件路径不能越界或访问控制目录",
                ));
            }
        }
    }
    let normalized = normalized
        .to_str()
        .ok_or(CoreError::InvalidInput("文件路径必须是 UTF-8"))?;
    if normalized.is_empty() {
        return Err(CoreError::InvalidInput("共享文件路径不能为空"));
    }
    Ok(normalized.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::test_support::file_accesses;

    async fn root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "shared-reads-{}",
            crate::model::service::generate_repo_id().unwrap()
        ));
        tokio::fs::create_dir_all(root.join("nested"))
            .await
            .unwrap();
        root
    }

    #[tokio::test]
    async fn concurrent_aliases_share_one_read_and_only_the_next_manager_sees_changes() {
        let root = root().await;
        tokio::fs::write(root.join("setup.conf"), b"original")
            .await
            .unwrap();
        let reads = SharedFileManager::new();
        let mut jobs = JoinSet::new();
        for i in 0..64 {
            let reads = reads.clone();
            let root = root.clone();
            jobs.spawn(async move {
                reads
                    .read(
                        &root,
                        if i % 2 == 0 {
                            "./setup.conf"
                        } else {
                            "nested/../setup.conf"
                        },
                    )
                    .await
                    .unwrap()
                    .unwrap()
            });
        }
        let first = jobs.join_next().await.unwrap().unwrap();
        while let Some(next) = jobs.join_next().await {
            assert!(Arc::ptr_eq(&first, &next.unwrap()));
        }
        assert_eq!(file_accesses(&root.join("setup.conf")), [1, 0]);
        tokio::fs::write(root.join("setup.conf"), b"changed")
            .await
            .unwrap();
        assert_eq!(
            reads
                .read(&root, "setup.conf")
                .await
                .unwrap()
                .unwrap()
                .as_ref(),
            b"original"
        );
        reads.finish().await.unwrap();
        assert!(reads.read(&root, "setup.conf").await.is_err());
        let next = SharedFileManager::new();
        assert_eq!(
            next.read(&root, "setup.conf")
                .await
                .unwrap()
                .unwrap()
                .as_ref(),
            b"changed"
        );
        assert_eq!(file_accesses(&root.join("setup.conf")), [2, 0]);
        next.finish().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn missing_and_failed_reads_are_shared_until_the_query_ends() {
        let root = root().await;
        let reads = SharedFileManager::new();
        let mut jobs = JoinSet::new();
        for _ in 0..32 {
            let reads = reads.clone();
            let root = root.clone();
            jobs.spawn(async move { reads.read(&root, "missing.conf").await.unwrap() });
        }
        while let Some(result) = jobs.join_next().await {
            assert!(result.unwrap().is_none());
        }
        assert_eq!(file_accesses(&root.join("missing.conf")), [1, 0]);
        tokio::fs::write(root.join("missing.conf"), b"created")
            .await
            .unwrap();
        assert!(reads.read(&root, "missing.conf").await.unwrap().is_none());
        assert!(reads.read(&root, "nested").await.is_err());
        tokio::fs::remove_dir(root.join("nested")).await.unwrap();
        tokio::fs::write(root.join("nested"), b"now a file")
            .await
            .unwrap();
        assert!(reads.read(&root, "nested").await.is_err());
        assert_eq!(file_accesses(&root.join("nested")), [1, 0]);
        reads.finish().await.unwrap();
        let next = SharedFileManager::new();
        assert_eq!(
            next.read(&root, "missing.conf")
                .await
                .unwrap()
                .unwrap()
                .as_ref(),
            b"created"
        );
        assert_eq!(
            next.read(&root, "nested").await.unwrap().unwrap().as_ref(),
            b"now a file"
        );
        next.finish().await.unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn dropping_the_last_handle_releases_cached_bytes() {
        let root = root().await;
        tokio::fs::write(root.join("setup.conf"), b"data")
            .await
            .unwrap();
        let reads = SharedFileManager::new();
        let bytes = reads.read(&root, "setup.conf").await.unwrap().unwrap();
        let weak = Arc::downgrade(&bytes);
        drop(bytes);
        assert!(weak.upgrade().is_some());
        drop(reads);
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while weak.upgrade().is_some() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn repository_keys_are_separate_and_unsafe_paths_are_rejected() {
        let a = root().await;
        let b = root().await;
        tokio::fs::write(a.join("setup.conf"), b"a").await.unwrap();
        tokio::fs::write(b.join("setup.conf"), b"b").await.unwrap();
        let reads = SharedFileManager::new();
        assert_eq!(
            reads
                .read(&a, "setup.conf")
                .await
                .unwrap()
                .unwrap()
                .as_ref(),
            b"a"
        );
        assert_eq!(
            reads
                .read(&b, "setup.conf")
                .await
                .unwrap()
                .unwrap()
                .as_ref(),
            b"b"
        );
        for path in [
            "../escape",
            "nested/../../escape",
            "/etc/passwd",
            ".sync/id",
            "nested/../.sync/id",
            "",
            ".",
        ] {
            assert!(reads.read(&a, path).await.is_err(), "{path}");
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(b.join("setup.conf"), a.join("link.conf")).unwrap();
            assert!(reads.read(&a, "link.conf").await.is_err());
        }
        reads.finish().await.unwrap();
        tokio::fs::remove_dir_all(a).await.unwrap();
        tokio::fs::remove_dir_all(b).await.unwrap();
    }
}
