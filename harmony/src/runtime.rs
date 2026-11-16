//! 与 Harmony Workspace 会话绑定的持续运行时；Core 仅使用其 Tokio 执行上下文。
use org_tasks_core::CoreError;

pub(crate) struct WorkspaceRuntime(Option<tokio::runtime::Runtime>);

impl WorkspaceRuntime {
    pub(crate) fn new() -> Result<Self, CoreError> {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("org-tasks-workspace")
            .enable_all()
            .build()
            .map(|runtime| Self(Some(runtime)))
            .map_err(|error| CoreError::Store(format!("无法创建 Workspace 运行时: {error}")))
    }
}

impl std::ops::Deref for WorkspaceRuntime {
    type Target = tokio::runtime::Runtime;
    fn deref(&self) -> &Self::Target {
        self.0.as_ref().expect("Workspace 运行时已释放")
    }
}

impl Drop for WorkspaceRuntime {
    fn drop(&mut self) {
        // 宿主先等待 Core stop；最后一个引用可在 Tokio 的收尾任务内释放。
        if let Some(runtime) = self.0.take() {
            runtime.shutdown_background();
        }
    }
}
