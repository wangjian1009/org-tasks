use std::future::Future;

use super::{OrgFile, OrgRepo, OrgRepoId, OrgRepoSyncRecord};
use crate::{CoreError, TimestampMs};

/// 目录扫描适配器返回的一个 org 源文件。
pub struct OrgRepoSourceFile {
    pub path: String,
    pub source_bytes: Vec<u8>,
}

impl OrgRepoSourceFile {
    pub fn new(path: String, source_bytes: Vec<u8>) -> Result<Self, CoreError> {
        if path.trim().is_empty()
            || path.starts_with('/')
            || path.contains('\\')
            || path
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err(CoreError::InvalidInput("文件路径必须是安全的相对路径"));
        }
        Ok(Self { path, source_bytes })
    }
}

/// 扫描仓库根目录的 I/O 端口；core 不直接访问文件系统。
pub trait OrgRepoLoader: Send + Sync {
    fn scan(&self, root_directory: &str) -> Result<Vec<OrgRepoSourceFile>, CoreError>;
}

/// 将一个 org 源文件解析为保留原始字节的内容模型。
pub trait OrgRepoParser: Send + Sync {
    fn parse_file(
        &self,
        repo_id: &OrgRepoId,
        source: OrgRepoSourceFile,
    ) -> Result<OrgFile, CoreError>;
}

/// 仓库同步策略。WebDAV 是该端口的一个宿主实现。
pub trait SyncPolicy: Send + Sync {
    fn synchronize(
        &self,
        repo: &mut OrgRepo,
        started_at: TimestampMs,
    ) -> impl Future<Output = Result<OrgRepoSyncRecord, CoreError>> + Send;
}

pub trait OrgRepoSyncRecordStore: Send {
    fn append(
        &mut self,
        repo_id: &OrgRepoId,
        record: OrgRepoSyncRecord,
    ) -> impl Future<Output = Result<(), CoreError>> + Send;

    fn list(
        &self,
        repo_id: &OrgRepoId,
        limit: usize,
    ) -> impl Future<Output = Result<Vec<OrgRepoSyncRecord>, CoreError>> + Send;
}

impl OrgRepo {
    /// 扫描根目录并以 parser 生成本仓库的完整文件快照。
    pub fn load<L, P>(&mut self, loader: &L, parser: &P) -> Result<&[OrgFile], CoreError>
    where
        L: OrgRepoLoader,
        P: OrgRepoParser,
    {
        let sources = loader.scan(&self.root_directory)?;
        let mut files = Vec::with_capacity(sources.len());
        for source in sources {
            if !self.contains_path(&source.path) {
                return Err(CoreError::InvalidInput("扫描结果包含非法文件路径"));
            }
            let path = source.path.clone();
            let file = parser.parse_file(&self.id, source)?;
            if file.repo_id != self.id || file.path != path {
                return Err(CoreError::InvalidState(
                    "解析结果必须属于当前仓库且保持文件路径",
                ));
            }
            if files
                .iter()
                .any(|existing: &OrgFile| existing.path == file.path)
            {
                return Err(CoreError::InvalidState("扫描结果包含重复文件路径"));
            }
            files.push(file);
        }
        self.files = files;
        Ok(&self.files)
    }

    /// 执行同步策略，并将已完成的记录追加到仓库历史。
    pub async fn sync<P>(
        &mut self,
        policy: &P,
        started_at: TimestampMs,
    ) -> Result<OrgRepoSyncRecord, CoreError>
    where
        P: SyncPolicy,
    {
        let record = policy.synchronize(self, started_at).await?;
        if record.finished_at.is_none() || record.result.is_none() {
            return Err(CoreError::InvalidState(
                "同步策略必须返回当前仓库已完成的同步记录",
            ));
        }
        if self
            .sync_records
            .iter()
            .any(|existing| existing.id == record.id)
        {
            return Err(CoreError::InvalidState("同步记录 ID 已存在"));
        }
        self.sync_records.push(record.clone());
        Ok(record)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OrgRepoSyncResult;
    use std::task::{Context, Poll, Waker};

    struct TestLoader;

    impl OrgRepoLoader for TestLoader {
        fn scan(&self, root_directory: &str) -> Result<Vec<OrgRepoSourceFile>, CoreError> {
            assert_eq!(root_directory, "/data/org");
            Ok(vec![OrgRepoSourceFile::new(
                "inbox.org".into(),
                b"plain text\n".to_vec(),
            )?])
        }
    }

    struct TestParser;

    impl OrgRepoParser for TestParser {
        fn parse_file(
            &self,
            repo_id: &OrgRepoId,
            source: OrgRepoSourceFile,
        ) -> Result<OrgFile, CoreError> {
            OrgFile::new(
                repo_id.clone(),
                source.path,
                source.source_bytes,
                Vec::new(),
            )
        }
    }

    struct CompletedSync;

    impl SyncPolicy for CompletedSync {
        fn synchronize(
            &self,
            _repo: &mut OrgRepo,
            started_at: TimestampMs,
        ) -> impl Future<Output = Result<OrgRepoSyncRecord, CoreError>> + Send {
            let mut record =
                OrgRepoSyncRecord::new("sync-1".into(), started_at).expect("记录应有效");
            record
                .finish(OrgRepoSyncResult::Succeeded, started_at + 1)
                .expect("记录应完成");
            async move { Ok(record) }
        }
    }

    fn block_on<F: Future>(future: F) -> F::Output {
        let waker = Waker::noop();
        let mut context = Context::from_waker(waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("测试 Future 不应挂起"),
        }
    }

    #[test]
    fn repo_loads_relative_files_through_loader_and_parser() {
        let mut repo = OrgRepo::new("repo-1".into(), "/data/org".into()).unwrap();
        let files = repo.load(&TestLoader, &TestParser).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "inbox.org");
    }

    #[test]
    fn repo_sync_appends_completed_record() {
        let mut repo = OrgRepo::new("repo-1".into(), "/data/org".into()).unwrap();
        let record = block_on(repo.sync(&CompletedSync, 10)).unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(repo.sync_records().len(), 1);
    }
}
