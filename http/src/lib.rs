//! RESTful HTTP 仓库同步记录适配层。

pub mod server;
mod store;

use org_tasks_core::{CoreError, OrgRepoId, OrgRepoSyncRecord, OrgRepoSyncRecordStore};

pub use store::CsvOrgRepoSyncRecordStore;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
}

pub enum HttpBody {
    SyncRecord(OrgRepoSyncRecord),
}

pub struct HttpRequest {
    pub method: HttpMethod,
    pub path: String,
    pub body: Option<HttpBody>,
}

pub enum HttpResponseBody {
    SyncRecord(OrgRepoSyncRecord),
    SyncRecords(Vec<OrgRepoSyncRecord>),
    Error(CoreError),
}

pub struct HttpResponse {
    pub status: u16,
    pub body: Option<HttpResponseBody>,
}

pub struct HttpApi<S> {
    store: S,
}

impl<S> HttpApi<S>
where
    S: OrgRepoSyncRecordStore,
{
    pub fn new(store: S) -> Self {
        Self { store }
    }

    pub async fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        let Some(repo_id) = sync_record_repo_path(&request.path) else {
            return error_response(CoreError::InvalidInput("不支持的 REST 资源"), 404);
        };
        match (request.method, request.body) {
            (HttpMethod::Post, Some(HttpBody::SyncRecord(record))) => {
                if record.repo_id != repo_id {
                    return error_response(
                        CoreError::InvalidInput("请求路径与同步记录仓库不一致"),
                        400,
                    );
                }
                match self.store.append(record.clone()).await {
                    Ok(()) => HttpResponse {
                        status: 201,
                        body: Some(HttpResponseBody::SyncRecord(record)),
                    },
                    Err(error) => map_error(error),
                }
            }
            (HttpMethod::Get, None) => match self.store.list(&repo_id, 100).await {
                Ok(records) => HttpResponse {
                    status: 200,
                    body: Some(HttpResponseBody::SyncRecords(records)),
                },
                Err(error) => map_error(error),
            },
            _ => error_response(CoreError::InvalidInput("请求体与 HTTP 方法不匹配"), 400),
        }
    }

    pub fn into_store(self) -> S {
        self.store
    }
}

fn sync_record_repo_path(path: &str) -> Option<OrgRepoId> {
    let prefix = "/v1/repos/";
    let suffix = "/sync-records";
    let repo_id = path.strip_prefix(prefix)?.strip_suffix(suffix)?;
    if repo_id.is_empty() || repo_id.contains('/') {
        return None;
    }
    Some(repo_id.into())
}

fn map_error(error: CoreError) -> HttpResponse {
    let status = if matches!(error, CoreError::Store(_)) {
        500
    } else {
        400
    };
    error_response(error, status)
}

fn error_response(error: CoreError, status: u16) -> HttpResponse {
    HttpResponse {
        status,
        body: Some(HttpResponseBody::Error(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use org_tasks_core::{OrgRepoSyncResult, TimestampMs};
    use std::collections::BTreeMap;
    use std::fs;
    use std::future::Future;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::task::{Context, Poll, Waker};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[derive(Default)]
    struct MemoryStore {
        records: BTreeMap<String, OrgRepoSyncRecord>,
    }

    impl OrgRepoSyncRecordStore for MemoryStore {
        fn append(
            &mut self,
            record: OrgRepoSyncRecord,
        ) -> impl Future<Output = Result<(), CoreError>> + Send {
            self.records.insert(record.id.clone(), record);
            async { Ok(()) }
        }

        fn list(
            &self,
            repo_id: &OrgRepoId,
            limit: usize,
        ) -> impl Future<Output = Result<Vec<OrgRepoSyncRecord>, CoreError>> + Send {
            let mut records = self
                .records
                .values()
                .filter(|record| &record.repo_id == repo_id)
                .cloned()
                .collect::<Vec<_>>();
            records.sort_by(|left, right| right.started_at.cmp(&left.started_at));
            records.truncate(limit);
            async move { Ok(records) }
        }
    }

    fn block_on<F: Future>(future: F) -> F::Output {
        let waker = Waker::noop();
        let mut context = Context::from_waker(waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("内存仓储不应产生挂起的 Future"),
        }
    }

    fn record(id: &str, started_at: TimestampMs) -> OrgRepoSyncRecord {
        let mut record = OrgRepoSyncRecord::new(id.into(), "repo-1".into(), started_at).unwrap();
        record
            .finish(OrgRepoSyncResult::Succeeded, started_at + 1)
            .unwrap();
        record
    }

    fn post(record: OrgRepoSyncRecord) -> HttpRequest {
        HttpRequest {
            method: HttpMethod::Post,
            path: "/v1/repos/repo-1/sync-records".into(),
            body: Some(HttpBody::SyncRecord(record)),
        }
    }

    #[test]
    fn appends_and_lists_repository_sync_records() {
        let mut api = HttpApi::new(MemoryStore::default());
        let created = block_on(api.handle(post(record("record-1", 1))));
        assert_eq!(created.status, 201);
        let listed = block_on(api.handle(HttpRequest {
            method: HttpMethod::Get,
            path: "/v1/repos/repo-1/sync-records".into(),
            body: None,
        }));
        match listed.body {
            Some(HttpResponseBody::SyncRecords(records)) => assert_eq!(records.len(), 1),
            _ => panic!("HTTP 路由返回了错误响应"),
        }
    }

    static TEST_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn test_data_dir() -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("系统时间应晚于 Unix epoch")
            .as_nanos();
        let sequence = TEST_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("org-tasks-http-{timestamp}-{sequence}"))
    }

    #[test]
    fn csv_store_restores_sync_records_after_reopen() {
        let data_dir = test_data_dir();
        let mut api = HttpApi::new(CsvOrgRepoSyncRecordStore::open(&data_dir).unwrap());
        let _ = block_on(api.handle(post(record("record-1", 1))));
        drop(api);
        assert!(
            data_dir
                .join("snapshots/00000000000000000001/sync_records.csv")
                .exists()
        );

        let store = CsvOrgRepoSyncRecordStore::open(&data_dir).unwrap();
        let records = block_on(store.list(&"repo-1".into(), 10)).unwrap();
        assert_eq!(records[0].id, "record-1");
        fs::remove_dir_all(data_dir).unwrap();
    }
}
