//! HarmonyOS 访问适配层。
//!
//! 此 crate 不依赖 N-API。C++ N-API bridge 把 ArkTS 输入转换为
//! HarmonyRequest，并将调用结果包装回 ArkTS Promise。

mod store;

use std::ffi::{CStr, c_char};
use std::future::Future;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::task::{Context, Poll, Waker};

use org_tasks_core::{
    CoreError, CoreService, CoreStore, CreateSyncJobRequest, CreateTaskRequest, JobPriority,
    PlatformAction, SyncJob, TaskCreation,
};

pub use store::FileCoreStore;

pub enum HarmonyRequest {
    CreateTask(CreateTaskRequest),
    CreateSyncJob(CreateSyncJobRequest),
    PlanExecution { job_id: String },
}

pub enum HarmonyResponse {
    TaskCreated(TaskCreation),
    SyncJobCreated(SyncJob),
    ExecutionPlanned(Vec<PlatformAction>),
}

pub struct HarmonyCoreAdapter<S> {
    core: CoreService<S>,
}

impl<S> HarmonyCoreAdapter<S>
where
    S: CoreStore,
{
    pub fn new(store: S) -> Self {
        Self {
            core: CoreService::new(store),
        }
    }

    pub async fn handle(&mut self, request: HarmonyRequest) -> Result<HarmonyResponse, CoreError> {
        match request {
            HarmonyRequest::CreateTask(request) => self
                .core
                .create_task(request)
                .await
                .map(HarmonyResponse::TaskCreated),
            HarmonyRequest::CreateSyncJob(request) => self
                .core
                .create_sync_job(request)
                .await
                .map(HarmonyResponse::SyncJobCreated),
            HarmonyRequest::PlanExecution { job_id } => {
                let job = self
                    .core
                    .get_job(&job_id)
                    .await?
                    .ok_or(CoreError::InvalidInput("同步作业不存在"))?;
                CoreService::<S>::plan_execution(&job).map(HarmonyResponse::ExecutionPlanned)
            }
        }
    }

    pub fn into_store(self) -> S {
        self.core.into_store()
    }
}

type Runtime = HarmonyCoreAdapter<FileCoreStore>;

#[derive(Default)]
struct RuntimeState {
    data_dir: Option<PathBuf>,
    runtime: Option<Runtime>,
}

static RUNTIME: OnceLock<Mutex<RuntimeState>> = OnceLock::new();

fn runtime_state() -> &'static Mutex<RuntimeState> {
    RUNTIME.get_or_init(|| Mutex::new(RuntimeState::default()))
}

/// 初始化 HarmonyOS 进程内服务，并组合应用私有目录的持久化仓储。
///
/// 返回值：0 表示成功，-1 表示参数或状态无效，-2 表示持久化失败，-3 表示运行时锁不可用。
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
        let store = FileCoreStore::open(&data_dir)?;
        state.runtime = Some(HarmonyCoreAdapter::new(store));
        state.data_dir = Some(data_dir);
        Ok(())
    })();
    ffi_result_code(result)
}

/// 提交同步意图给 Rust 核心服务。
///
/// C++ N-API bridge 保证该函数运行在后台 worker，因此同步 FFI 边界不会阻塞 ArkUI
/// 线程；Rust 服务内部的用例与仓储端口均为 async。该函数不接收密码、WebDAV URL
/// 或任何远端文件内容。
///
/// 返回值：0 表示成功，-1 表示请求无效，-2 表示持久化失败，-3 表示运行时锁不可用。
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_queue_sync(
    idempotency_key: *const c_char,
    job_id: *const c_char,
    reason: *const c_char,
    include_calendar: bool,
    foreground: bool,
    now: i64,
) -> i32 {
    let result = (|| {
        let request = CreateSyncJobRequest {
            idempotency_key: read_c_string(idempotency_key)?,
            job_id: read_c_string(job_id)?,
            reason: read_c_string(reason)?,
            priority: if foreground {
                JobPriority::Foreground
            } else {
                JobPriority::Background
            },
            include_calendar,
            now,
        };
        let mut state = runtime_state()
            .lock()
            .map_err(|_| CoreError::Store("Harmony 运行时锁不可用".into()))?;
        let runtime = state
            .runtime
            .as_mut()
            .ok_or(CoreError::InvalidState("Harmony 服务尚未初始化"))?;
        match run_ready(runtime.handle(HarmonyRequest::CreateSyncJob(request)))? {
            HarmonyResponse::SyncJobCreated(_) => Ok(()),
            _ => Err(CoreError::InvalidState("Harmony 同步请求返回了错误资源")),
        }
    })();
    ffi_result_code(result)
}

/// 写入当前活跃同步作业的执行结果。
///
/// 返回值与 `org_tasks_harmony_queue_sync` 一致。没有活跃作业时返回成功，便于平台
/// 在失败清理路径中幂等调用。
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_finish_active_sync(succeeded: bool, now: i64) -> i32 {
    let result = (|| {
        let mut state = runtime_state()
            .lock()
            .map_err(|_| CoreError::Store("Harmony 运行时锁不可用".into()))?;
        let runtime = state
            .runtime
            .as_mut()
            .ok_or(CoreError::InvalidState("Harmony 服务尚未初始化"))?;
        run_ready(runtime.core.finish_active_sync(succeeded, now)).map(|_| ())
    })();
    ffi_result_code(result)
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

    fn sync_request(idempotency_key: &str, job_id: &str) -> HarmonyRequest {
        HarmonyRequest::CreateSyncJob(CreateSyncJobRequest {
            idempotency_key: idempotency_key.into(),
            job_id: job_id.into(),
            reason: "manual".into(),
            priority: JobPriority::Foreground,
            include_calendar: true,
            now: 1,
        })
    }

    fn test_data_dir() -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("系统时间应晚于 Unix epoch")
            .as_nanos();
        let sequence = TEST_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("org-tasks-harmony-{timestamp}-{sequence}"))
    }

    #[test]
    fn sync_request_is_mapped_to_core_job() {
        let data_dir = test_data_dir();
        let store = FileCoreStore::open(&data_dir).expect("应创建测试仓储");
        let mut adapter = HarmonyCoreAdapter::new(store);

        let response = run_ready(adapter.handle(sync_request("request-1", "job-1")))
            .expect("同步请求应被核心服务接受");

        match response {
            HarmonyResponse::SyncJobCreated(job) => {
                assert_eq!(job.id, "job-1");
                assert_eq!(job.priority, JobPriority::Foreground);
            }
            _ => panic!("Harmony 请求映射到了错误响应"),
        }
        fs::remove_dir_all(data_dir).expect("应移除测试仓储");
    }

    #[test]
    fn persisted_sync_job_is_restored_after_reopen() {
        let data_dir = test_data_dir();
        let store = FileCoreStore::open(&data_dir).expect("应创建测试仓储");
        let mut first_adapter = HarmonyCoreAdapter::new(store);
        let first = run_ready(first_adapter.handle(sync_request("request-1", "job-1")))
            .expect("首个同步请求应成功");
        drop(first_adapter);

        let store = FileCoreStore::open(&data_dir).expect("应恢复测试仓储");
        let mut second_adapter = HarmonyCoreAdapter::new(store);
        let second = run_ready(second_adapter.handle(sync_request("request-2", "job-2")))
            .expect("重启后的同步请求应成功");

        match (first, second) {
            (HarmonyResponse::SyncJobCreated(first), HarmonyResponse::SyncJobCreated(second)) => {
                assert_eq!(first.id, second.id);
            }
            _ => panic!("Harmony 请求映射到了错误响应"),
        }
        fs::remove_dir_all(data_dir).expect("应移除测试仓储");
    }
}
