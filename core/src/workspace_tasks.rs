//! Workspace 内部后台任务的停止信号与完成等待；运行时由宿主持有。
use std::future::Future;
use std::sync::{Arc, Mutex};
use tokio::sync::watch;

use crate::CoreError;

#[derive(Clone, Debug)]
pub(crate) struct WorkspaceTasks(Arc<Inner>);

#[derive(Debug)]
struct Inner {
    stopping: watch::Sender<bool>,
    state: Mutex<State>,
    idle: tokio::sync::Notify,
}

#[derive(Debug, Default)]
struct State {
    stopped: bool,
    tasks: Vec<Arc<Task>>,
    active: usize,
    finalizers: Vec<(Option<tokio::sync::oneshot::Sender<()>>, Arc<Task>)>,
}

pub(crate) struct Activity(WorkspaceTasks);
impl Drop for Activity {
    fn drop(&mut self) {
        let mut state = self.0.0.state.lock().unwrap();
        state.active -= 1;
        if state.active == 0 {
            self.0.0.idle.notify_waiters();
        }
    }
}

#[derive(Debug)]
pub(crate) struct Task(tokio::sync::Mutex<TaskState>);

#[derive(Debug)]
struct TaskState {
    handle: Option<tokio::task::JoinHandle<Result<(), CoreError>>>,
    result: Option<Result<(), CoreError>>,
}

impl PartialEq for WorkspaceTasks {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
impl Eq for WorkspaceTasks {}

impl WorkspaceTasks {
    pub(crate) fn new() -> Self {
        let (stopping, _) = watch::channel(false);
        Self(Arc::new(Inner {
            stopping,
            state: Mutex::new(State::default()),
            idle: Default::default(),
        }))
    }

    pub(crate) fn enter(&self) -> Result<Activity, CoreError> {
        let mut state = self.0.state.lock().unwrap();
        if state.stopped {
            return Err(CoreError::InvalidState("Workspace 已停止"));
        }
        state.active += 1;
        Ok(Activity(self.clone()))
    }

    pub(crate) fn ensure_running(&self) -> Result<(), CoreError> {
        if self.0.state.lock().unwrap().stopped {
            Err(CoreError::InvalidState("Workspace 已停止"))
        } else {
            Ok(())
        }
    }

    pub(crate) fn spawn<F, Fut>(&self, start: F) -> Result<Arc<Task>, CoreError>
    where
        F: FnOnce(watch::Receiver<bool>) -> Fut,
        Fut: Future<Output = Result<(), CoreError>> + Send + 'static,
    {
        let mut state = self.0.state.lock().unwrap();
        if state.stopped {
            return Err(CoreError::InvalidState("Workspace 已停止"));
        }
        let handle = tokio::spawn(start(self.0.stopping.subscribe()));
        let task = Arc::new(Task(tokio::sync::Mutex::new(TaskState {
            handle: Some(handle),
            result: None,
        })));
        state.tasks.push(task.clone());
        Ok(task)
    }

    /// 收尾任务先保持运行，待普通任务与在途操作退出后再发送 oneshot。
    pub(crate) fn spawn_finalizer<Fut>(
        &self,
        stop: tokio::sync::oneshot::Sender<()>,
        process: Fut,
    ) -> Result<(), CoreError>
    where
        Fut: Future<Output = Result<(), CoreError>> + Send + 'static,
    {
        let mut state = self.0.state.lock().unwrap();
        if state.stopped {
            return Err(CoreError::InvalidState("Workspace 已停止"));
        }
        let task = Arc::new(Task(tokio::sync::Mutex::new(TaskState {
            handle: Some(tokio::spawn(process)),
            result: None,
        })));
        state.finalizers.push((Some(stop), task));
        Ok(())
    }

    pub(crate) async fn stop(&self) -> Result<(), CoreError> {
        let tasks = {
            let mut state = self.0.state.lock().unwrap();
            state.stopped = true;
            self.0.stopping.send_replace(true);
            state.tasks.clone()
        };
        let mut result = Ok(());
        for task in tasks {
            if let Err(error) = task.wait().await {
                result = result.and(Err(error));
            }
        }
        loop {
            let idle = self.0.idle.notified();
            tokio::pin!(idle);
            idle.as_mut().enable();
            if self.0.state.lock().unwrap().active == 0 {
                break;
            }
            idle.await;
        }
        let finalizers = {
            let mut state = self.0.state.lock().unwrap();
            state
                .finalizers
                .iter_mut()
                .map(|(stop, task)| {
                    if let Some(stop) = stop.take() {
                        let _ = stop.send(());
                    }
                    task.clone()
                })
                .collect::<Vec<_>>()
        };
        for task in finalizers {
            if let Err(error) = task.wait().await {
                result = result.and(Err(error));
            }
        }
        result
    }
}

impl Task {
    pub(crate) async fn wait(&self) -> Result<(), CoreError> {
        let mut state = self.0.lock().await;
        if let Some(handle) = state.handle.as_mut() {
            // 在完成前保留 JoinHandle，取消 stop 后仍可再次等待。
            let result = handle.await.unwrap_or_else(|error| {
                Err(CoreError::Store(format!(
                    "Workspace 内部任务退出失败: {error}"
                )))
            });
            state.handle = None;
            state.result = Some(result);
        }
        state.result.clone().unwrap_or(Ok(()))
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.stopping.send_replace(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancelled_stop_can_resume_and_waits_for_cooperative_cleanup() {
        let tasks = WorkspaceTasks::new();
        let (stopping_seen, stopping) = tokio::sync::oneshot::channel();
        let (finish, finished) = tokio::sync::oneshot::channel();
        tasks
            .spawn(move |mut stop| async move {
                while !*stop.borrow_and_update() {
                    stop.changed().await.unwrap();
                }
                stopping_seen.send(()).unwrap();
                finished.await.unwrap();
                Ok(())
            })
            .unwrap();
        let copy = tasks.clone();
        let waiting = tokio::spawn(async move { copy.stop().await });
        stopping.await.unwrap();
        assert!(!waiting.is_finished());
        assert!(tasks.spawn(|_| async { Ok(()) }).is_err());
        assert!(tasks.enter().is_err());
        waiting.abort();
        assert!(waiting.await.unwrap_err().is_cancelled());
        let copy = tasks.clone();
        let resumed = tokio::spawn(async move { copy.stop().await });
        tokio::task::yield_now().await;
        assert!(!resumed.is_finished());
        finish.send(()).unwrap();
        resumed.await.unwrap().unwrap();
        tasks.stop().await.unwrap();
    }

    #[tokio::test]
    async fn task_failure_does_not_skip_other_tasks_or_active_operations() {
        let tasks = WorkspaceTasks::new();
        tasks
            .spawn(|_| async { Err(CoreError::InvalidState("测试任务失败")) })
            .unwrap();
        let activity = tasks.enter().unwrap();
        let copy = tasks.clone();
        let stop = tokio::spawn(async move { copy.stop().await });
        tokio::task::yield_now().await;
        assert!(!stop.is_finished());
        drop(activity);
        assert_eq!(
            stop.await.unwrap(),
            Err(CoreError::InvalidState("测试任务失败"))
        );
        assert_eq!(
            tasks.stop().await,
            Err(CoreError::InvalidState("测试任务失败"))
        );
    }
}
