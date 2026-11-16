//! 单次查询使用的多线程异步执行器。
//!
//! 查询调用方保留结果编组和合并的执行上下文；文件读取、解析和任务投影等独立任务
//! 通过本执行器调度，结果通过通道及时回送，避免把 CPU 和异步 I/O 绑定在宿主临时 runtime 上。

use std::future::Future;
use std::sync::Arc;

use tokio::runtime::{Builder, Runtime};
use tokio::task::JoinHandle;

use crate::CoreError;

pub(crate) struct Executor {
    runtime: Option<Arc<Runtime>>,
}

impl Executor {
    pub(crate) fn new() -> Result<Self, CoreError> {
        let runtime = Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| CoreError::Store(format!("创建 Core 查询执行器失败: {error}")))?;
        Ok(Self {
            runtime: Some(Arc::new(runtime)),
        })
    }

    pub(crate) fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        self.runtime
            .as_ref()
            .expect("Core Executor 已关闭")
            .spawn(future)
    }
}

impl Clone for Executor {
    fn clone(&self) -> Self {
        Self {
            runtime: self.runtime.clone(),
        }
    }
}

impl Drop for Executor {
    fn drop(&mut self) {
        let Some(runtime) = self.runtime.take() else {
            return;
        };
        if Arc::strong_count(&runtime) > 1 || tokio::runtime::Handle::try_current().is_err() {
            drop(runtime);
            return;
        }
        // Tokio 不允许在异步上下文中同步销毁 Runtime；把最后一个引用交给独立线程，
        // 避免 Workspace 在 async 测试或宿主 Future 结束时触发 shutdown panic。
        let runtime = Arc::into_raw(runtime) as usize;
        if std::thread::Builder::new()
            .name("org-tasks-core-executor-drop".into())
            .spawn(move || {
                // SAFETY: runtime 由 Arc::into_raw 转移到该线程，且只在此处恢复一次。
                unsafe { drop(Arc::from_raw(runtime as *const Runtime)) };
            })
            .is_err()
        {
            // 线程创建失败时保留裸引用，避免在异步调用方同步销毁 Runtime。
        }
    }
}

impl std::fmt::Debug for Executor {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Executor").finish_non_exhaustive()
    }
}

impl PartialEq for Executor {
    fn eq(&self, other: &Self) -> bool {
        match (&self.runtime, &other.runtime) {
            (Some(left), Some(right)) => Arc::ptr_eq(left, right),
            (None, None) => true,
            _ => false,
        }
    }
}

impl Eq for Executor {}
