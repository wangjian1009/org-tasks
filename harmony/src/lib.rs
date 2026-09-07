//! HarmonyOS 宿主的仓库同步记录适配层。
//!
//! C++ N-API bridge 在工作线程调用本 crate。目录扫描、WebDAV 与日历同步仍由
//! ArkTS 宿主执行；Rust 只接收已完成的仓库同步结果并持久化其领域记录。

mod bridge;
mod store;

use std::ffi::{CStr, CString, c_char};
use std::future::Future;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::task::{Context, Poll, Waker};

use org_tasks_core::{
    CoreError, OrgRepoId, OrgRepoSyncRecord, OrgRepoSyncRecordId, OrgRepoSyncRecordStore,
    OrgRepoSyncResult, TimestampMs,
};

pub use store::FileOrgRepoSyncRecordStore;

pub enum HarmonyRequest {
    AppendSyncRecord {
        repo_id: OrgRepoId,
        record_id: OrgRepoSyncRecordId,
        started_at: TimestampMs,
        finished_at: TimestampMs,
        result: OrgRepoSyncResult,
    },
}

pub enum HarmonyResponse {
    SyncRecordStored(OrgRepoSyncRecord),
}

pub struct HarmonySyncRecordAdapter<S> {
    store: S,
}

impl<S> HarmonySyncRecordAdapter<S>
where
    S: OrgRepoSyncRecordStore,
{
    pub fn new(store: S) -> Self {
        Self { store }
    }

    pub async fn handle(&mut self, request: HarmonyRequest) -> Result<HarmonyResponse, CoreError> {
        match request {
            HarmonyRequest::AppendSyncRecord {
                repo_id,
                record_id,
                started_at,
                finished_at,
                result,
            } => {
                let mut record = OrgRepoSyncRecord::new(record_id, started_at)?;
                record.finish(result, finished_at)?;
                self.store.append(&repo_id, record.clone()).await?;
                Ok(HarmonyResponse::SyncRecordStored(record))
            }
        }
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    pub fn into_store(self) -> S {
        self.store
    }
}

type Runtime = HarmonySyncRecordAdapter<FileOrgRepoSyncRecordStore>;

#[derive(Default)]
struct RuntimeState {
    data_dir: Option<PathBuf>,
    runtime: Option<Runtime>,
}

static RUNTIME: OnceLock<Mutex<RuntimeState>> = OnceLock::new();

fn runtime_state() -> &'static Mutex<RuntimeState> {
    RUNTIME.get_or_init(|| Mutex::new(RuntimeState::default()))
}

/// 初始化 HarmonyOS 进程内同步记录服务。
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_initialize(data_dir: *const c_char) -> i32 {
    let result = (|| {
        let data_dir = PathBuf::from(read_c_string(data_dir)?);
        let mut state = runtime_state()
            .lock()
            .map_err(|_| CoreError::Store("Harmony 运行时锁不可用".into()))?;
        if let Some(active_data_dir) = &state.data_dir {
            if active_data_dir == &data_dir {
                return Ok(());
            }
            return Err(CoreError::InvalidState(
                "Harmony 服务已使用其他数据目录初始化",
            ));
        }
        state.runtime = Some(HarmonySyncRecordAdapter::new(
            FileOrgRepoSyncRecordStore::open(&data_dir)?,
        ));
        state.data_dir = Some(data_dir);
        Ok(())
    })();
    ffi_result_code(result)
}

/// 保存一次已完成的仓库同步记录。
///
/// C++ N-API bridge 保证在 worker 线程调用此函数。它不接收目录、WebDAV URL、
/// 密码或 org 文件内容。
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_record_sync(
    repo_id: *const c_char,
    record_id: *const c_char,
    started_at: i64,
    finished_at: i64,
    succeeded: bool,
) -> i32 {
    let result = (|| {
        let request = HarmonyRequest::AppendSyncRecord {
            repo_id: read_c_string(repo_id)?,
            record_id: read_c_string(record_id)?,
            started_at,
            finished_at,
            result: if succeeded {
                OrgRepoSyncResult::Succeeded
            } else {
                OrgRepoSyncResult::Failed
            },
        };
        let mut state = runtime_state()
            .lock()
            .map_err(|_| CoreError::Store("Harmony 运行时锁不可用".into()))?;
        let runtime = state
            .runtime
            .as_mut()
            .ok_or(CoreError::InvalidState("Harmony 服务尚未初始化"))?;
        match run_ready(runtime.handle(request))? {
            HarmonyResponse::SyncRecordStored(_) => Ok(()),
        }
    })();
    ffi_result_code(result)
}

/// 将 JSON 请求直接交给 Harmony bridge。
///
/// 此层不解析领域字段、不构造同步策略，也不保存业务状态；返回字符串须由
/// ~org_tasks_harmony_free_string~ 释放。
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_execute(request: *const c_char) -> *mut c_char {
    let result = (|| {
        let response = bridge::execute_json(&read_c_string(request)?)?;
        CString::new(response)
            .map(CString::into_raw)
            .map_err(|_| CoreError::InvalidState("Harmony bridge 响应包含空字符"))
    })();
    result.unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_free_string(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

fn ffi_result_code(result: Result<(), CoreError>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(CoreError::InvalidInput(_) | CoreError::InvalidState(_)) => -1,
        Err(CoreError::Store(message)) if message.contains("锁不可用") => -3,
        Err(CoreError::Store(_)) => -2,
    }
}

fn run_ready<F: Future>(future: F) -> F::Output {
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    let mut future = Box::pin(future);
    match future.as_mut().poll(&mut context) {
        Poll::Ready(value) => value,
        Poll::Pending => panic!("Harmony 仓储 Future 不应在 N-API worker 外等待"),
    }
}

fn read_c_string(value: *const c_char) -> Result<String, CoreError> {
    if value.is_null() {
        return Err(CoreError::InvalidInput("Harmony 字符串参数不能为空"));
    }
    let value = unsafe { CStr::from_ptr(value) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::InvalidInput("Harmony 字符串必须是 UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn test_data_dir() -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("系统时间应晚于 Unix epoch")
            .as_nanos();
        let sequence = TEST_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("org-tasks-harmony-{timestamp}-{sequence}"))
    }

    fn request(record_id: &str) -> HarmonyRequest {
        HarmonyRequest::AppendSyncRecord {
            repo_id: "repo-1".into(),
            record_id: record_id.into(),
            started_at: 1,
            finished_at: 2,
            result: OrgRepoSyncResult::Succeeded,
        }
    }

    #[test]
    fn completed_sync_record_is_persisted_and_restored() {
        let data_dir = test_data_dir();
        let mut adapter = HarmonySyncRecordAdapter::new(
            FileOrgRepoSyncRecordStore::open(&data_dir).expect("应创建测试仓储"),
        );
        let response = run_ready(adapter.handle(request("record-1"))).expect("应保存同步记录");
        match response {
            HarmonyResponse::SyncRecordStored(record) => assert_eq!(record.id, "record-1"),
        }
        drop(adapter);

        let store = FileOrgRepoSyncRecordStore::open(&data_dir).expect("应恢复测试仓储");
        let records = run_ready(store.list(&"repo-1".into(), 10)).expect("应查询同步记录");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].result, Some(OrgRepoSyncResult::Succeeded));
        fs::remove_dir_all(data_dir).expect("应移除测试仓储");
    }
}
