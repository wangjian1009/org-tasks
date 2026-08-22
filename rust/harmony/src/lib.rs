//! HarmonyOS 访问适配层。
//!
//! 此 crate 不依赖 N-API。C++ N-API bridge 把 ArkTS 输入转换为
//! HarmonyRequest，并将调用结果包装回 ArkTS Promise。

use std::collections::HashMap;
use std::ffi::{CStr, c_char};
use std::sync::{Mutex, OnceLock};

use org_tasks_core::{
    CoreChangeSet, CoreError, CoreService, CoreStore, CreateSyncJobRequest, CreateTaskRequest,
    JobKind, JobPriority, JobState, OutboxEntry, PlatformAction, SyncJob, TaskCreation, TaskRecord,
};

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

    pub fn handle(&mut self, request: HarmonyRequest) -> Result<HarmonyResponse, CoreError> {
        match request {
            HarmonyRequest::CreateTask(request) => self
                .core
                .create_task(request)
                .map(HarmonyResponse::TaskCreated),
            HarmonyRequest::CreateSyncJob(request) => self
                .core
                .create_sync_job(request)
                .map(HarmonyResponse::SyncJobCreated),
            HarmonyRequest::PlanExecution { job_id } => {
                let job = self
                    .core
                    .get_job(&job_id)?
                    .ok_or(CoreError::InvalidInput("同步作业不存在"))?;
                CoreService::<S>::plan_execution(&job).map(HarmonyResponse::ExecutionPlanned)
            }
        }
    }

    pub fn into_store(self) -> S {
        self.core.into_store()
    }
}

/// HarmonyOS 进程内的易失会话仓储。
///
/// 它使 N-API bridge 能在引入 SQLite 适配器前调用核心用例；生产持久化实现应以
/// CoreStore 的独立实现替换它，而不能进入 core crate。
#[derive(Default)]
struct SessionStore {
    tasks: HashMap<String, TaskRecord>,
    jobs: HashMap<String, SyncJob>,
    outbox: HashMap<String, OutboxEntry>,
}

impl CoreStore for SessionStore {
    fn find_task(&self, id: &str) -> Result<Option<TaskRecord>, CoreError> {
        Ok(self.tasks.get(id).cloned())
    }

    fn find_job(&self, id: &str) -> Result<Option<SyncJob>, CoreError> {
        Ok(self.jobs.get(id).cloned())
    }

    fn find_job_by_idempotency(&self, key: &str) -> Result<Option<SyncJob>, CoreError> {
        Ok(self
            .jobs
            .values()
            .find(|job| job.idempotency_key == key)
            .cloned())
    }

    fn find_active_sync_job(&self) -> Result<Option<SyncJob>, CoreError> {
        Ok(self
            .jobs
            .values()
            .find(|job| {
                job.kind == JobKind::Sync
                    && matches!(job.state, JobState::Queued | JobState::Running)
            })
            .cloned())
    }

    fn apply(&mut self, changes: CoreChangeSet) -> Result<(), CoreError> {
        for task in changes.tasks {
            self.tasks.insert(task.id.clone(), task);
        }
        for entry in changes.outbox_entries {
            self.outbox.insert(entry.id.clone(), entry);
        }
        for job in changes.jobs {
            self.jobs.insert(job.id.clone(), job);
        }
        Ok(())
    }
}

type Runtime = HarmonyCoreAdapter<SessionStore>;
static RUNTIME: OnceLock<Mutex<Runtime>> = OnceLock::new();

fn runtime() -> &'static Mutex<Runtime> {
    RUNTIME.get_or_init(|| Mutex::new(HarmonyCoreAdapter::new(SessionStore::default())))
}

/// 提交同步意图给 Rust 核心服务。
///
/// 返回值：0 表示成功，-1 表示请求无效，-2 表示核心服务失败，-3 表示运行时锁不可用。
/// 该函数不接收密码、WebDAV URL 或任何远端文件内容。
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
        let mut runtime = runtime()
            .lock()
            .map_err(|_| CoreError::Store("Harmony 运行时锁不可用".into()))?;
        let response = runtime.handle(HarmonyRequest::CreateSyncJob(CreateSyncJobRequest {
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
        }))?;
        match response {
            HarmonyResponse::SyncJobCreated(_) => Ok(()),
            _ => Err(CoreError::InvalidState("Harmony 同步请求返回了错误资源")),
        }
    })();
    match result {
        Ok(()) => 0,
        Err(CoreError::InvalidInput(_) | CoreError::InvalidState(_)) => -1,
        Err(CoreError::Store(message)) if message.contains("锁不可用") => -3,
        Err(CoreError::Store(_)) => -2,
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

    #[test]
    fn sync_request_is_mapped_to_core_job() {
        let mut adapter = HarmonyCoreAdapter::new(SessionStore::default());

        let response = adapter
            .handle(sync_request("request-1", "job-1"))
            .expect("同步请求应被核心服务接受");

        match response {
            HarmonyResponse::SyncJobCreated(job) => {
                assert_eq!(job.id, "job-1");
                assert_eq!(job.priority, JobPriority::Foreground);
            }
            _ => panic!("Harmony 请求映射到了错误响应"),
        }
    }

    #[test]
    fn concurrent_sync_request_is_coalesced_by_core() {
        let mut adapter = HarmonyCoreAdapter::new(SessionStore::default());
        let first = adapter
            .handle(sync_request("request-1", "job-1"))
            .expect("首个同步请求应成功");
        let second = adapter
            .handle(sync_request("request-2", "job-2"))
            .expect("后续同步请求应成功");

        match (first, second) {
            (HarmonyResponse::SyncJobCreated(first), HarmonyResponse::SyncJobCreated(second)) => {
                assert_eq!(first.id, second.id);
            }
            _ => panic!("Harmony 请求映射到了错误响应"),
        }
    }
}
