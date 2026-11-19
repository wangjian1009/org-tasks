//! Workspace 私有的通知请求通道；订阅表和 ID 只存在于 process 的局部状态。
use super::notification::{NotificationMonitor, NotificationRequest, NotificationState};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use tokio::sync::{mpsc, oneshot, watch};

use super::sync_events::SyncCommitted;
use crate::CoreError;

type Callback = Box<dyn Fn(&SyncCommitted) + Send + Sync>;

#[derive(Clone)]
pub struct NotificationCenter {
    sender: mpsc::UnboundedSender<Request>,
    sequence: Arc<AtomicU64>,
    files: crate::file_state::FileStateManager,
}

pub(crate) struct Subscription {
    center: NotificationCenter,
    token: Arc<()>,
    active: watch::Receiver<bool>,
}

pub(crate) struct Requests(
    mpsc::UnboundedReceiver<Request>,
    mpsc::WeakUnboundedSender<Request>,
    Arc<AtomicU64>,
    crate::file_state::FileStateManager,
    mpsc::UnboundedReceiver<crate::file_state::Command>,
);

enum Request {
    Notifications(NotificationRequest),
    Subscribe {
        token: Weak<()>,
        callback: Callback,
        active: watch::Sender<bool>,
    },
    Unsubscribe(Weak<()>),
    Publish(SyncCommitted),
    Flush(oneshot::Sender<()>),
}

impl std::fmt::Debug for NotificationCenter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NotificationCenter").finish_non_exhaustive()
    }
}
impl PartialEq for NotificationCenter {
    fn eq(&self, other: &Self) -> bool {
        self.sender.same_channel(&other.sender)
    }
}
impl Eq for NotificationCenter {}

impl NotificationCenter {
    pub(crate) fn new() -> (Self, Requests) {
        let (sender, receiver) = mpsc::unbounded_channel();
        let sequence = Arc::new(AtomicU64::new(0));
        let (files, file_requests) = crate::file_state::FileStateManager::new();
        let requests = Requests(receiver, sender.downgrade(), sequence.clone(), files.clone(), file_requests);
        (Self { sender, sequence, files }, requests)
    }

    pub(crate) fn subscribe<F>(&self, callback: F) -> Subscription
    where
        F: Fn(&SyncCommitted) + Send + Sync + 'static,
    {
        let token = Arc::new(());
        let (active, status) = watch::channel(true);
        let _ = self.sender.send(Request::Subscribe {
            token: Arc::downgrade(&token),
            callback: Box::new(callback),
            active,
        });
        Subscription {
            center: self.clone(),
            token,
            active: status,
        }
    }

    pub(crate) fn next_revision(&self) -> u64 {
        self.sequence.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub(crate) fn configure(&self, repos: Vec<super::OrgRepo>) {
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Configure(
                repos.clone(),
            )));
        self.files.configure(repos, self);
    }

    pub(crate) fn watch_notifications(
        &self,
        repo_ids: Option<Vec<super::OrgRepoId>>,
        monitor: Box<dyn NotificationMonitor>,
    ) -> Subscription {
        let token = Arc::new(());
        let (active, status) = watch::channel(true);
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Subscribe {
                repo_ids,
                token: Arc::downgrade(&token),
                monitor,
                active,
            }));
        Subscription {
            center: self.clone(),
            token,
            active: status,
        }
    }

    pub(crate) fn files(&self) -> &crate::file_state::FileStateManager { &self.files }

    pub(crate) fn file_states(&self, event: crate::file_state::FileStateEvent) {
        let _ = self.sender.send(Request::Notifications(NotificationRequest::FileStates(event)));
    }

    fn unsubscribe(&self, token: Weak<()>) {
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Unsubscribe(
                token.clone(),
            )));
        let _ = self.sender.send(Request::Unsubscribe(token));
    }

    pub(crate) fn publish(&self, event: SyncCommitted) {
        let _ = self.sender.send(Request::Publish(event));
    }

    /// 确认此前入队的订阅、事件和取消已处理；不重新查询仓库。
    pub(crate) async fn flush(&self) -> Result<(), CoreError> {
        self.files.flush().await?;
        let (done, received) = oneshot::channel();
        self.sender
            .send(Request::Flush(done))
            .map_err(|_| CoreError::InvalidState("通知处理任务已停止"))?;
        received
            .await
            .map_err(|_| CoreError::InvalidState("通知处理任务已停止"))
    }

    pub(crate) async fn process(
        mut requests: Requests,
        mut stopping: oneshot::Receiver<()>,
    ) -> Result<(), CoreError> {
        struct Monitor {
            token: Weak<()>,
            callback: Callback,
            active: watch::Sender<bool>,
        }
        impl Drop for Monitor {
            fn drop(&mut self) {
                self.active.send_replace(false);
            }
        }
        fn handle(
            request: Request,
            monitors: &mut BTreeMap<u64, Monitor>,
            next_id: &mut u64,
            notices: &NotificationState,
        ) -> Result<(), CoreError> {
            match request {
                Request::Notifications(_) => unreachable!("通知状态由外层任务处理"),
                Request::Subscribe {
                    token,
                    callback,
                    active,
                } => {
                    *next_id = next_id
                        .checked_add(1)
                        .ok_or(CoreError::InvalidState("通知订阅 ID 已耗尽"))?;
                    monitors.insert(
                        *next_id,
                        Monitor {
                            token,
                            callback,
                            active,
                        },
                    );
                }
                Request::Unsubscribe(token) => {
                    let id = monitors
                        .iter()
                        .find_map(|(id, monitor)| monitor.token.ptr_eq(&token).then_some(*id));
                    if let Some(id) = id {
                        monitors.remove(&id);
                    }
                }
                Request::Publish(mut event) => {
                    if let SyncCommitted::Repository { repo_id, notifications, .. } = &mut event {
                        *notifications = notices.notifications_for_repo(repo_id);
                    }
                    for monitor in monitors.values() {
                        (monitor.callback)(&event);
                    }
                }
                Request::Flush(done) => {
                    let _ = done.send(());
                }
            }
            Ok(())
        }

        let Some(sender) = requests.1.upgrade() else { return Ok(()); };
        let center = Self { sender, sequence: requests.2.clone(), files: requests.3.clone() };
        let (_, empty_requests) = mpsc::unbounded_channel();
        let file_requests = std::mem::replace(&mut requests.4, empty_requests);
        let file_center = center.clone();
        let files_task = tokio::spawn(crate::file_state::FileStateManager::process(file_requests, file_center));
        let mut notices = NotificationState::default();
        let mut monitors = BTreeMap::new();
        let mut next_id = 0;
        loop {
            let next = tokio::select! {
                biased;
                _ = &mut stopping => break,
                next = requests.0.recv() => next,
            };
            let Some(next) = next else { break; };
            if let Request::Notifications(request) = next {
                notices.handle(request, &center);
            } else {
                handle(next, &mut monitors, &mut next_id, &notices)?;
            }
        }
        center.files.stop().await;
        files_task.await.map_err(|_| CoreError::InvalidState("文件状态服务退出失败"))?;
        requests.0.close();
        while let Some(request) = requests.0.recv().await {
            if let Request::Notifications(request) = request { notices.handle(request, &center); }
            else { handle(request, &mut monitors, &mut next_id, &notices)?; }
        }
        Ok(())
    }
}

impl Subscription {
    pub(crate) fn is_active(&self) -> bool {
        self.active.has_changed().is_ok() && *self.active.borrow()
    }
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.center.unsubscribe(Arc::downgrade(&self.token));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(index: u64) -> SyncCommitted {
        SyncCommitted::Repository {
            repo_id: "repo".into(),
            operation_id: Some(index.to_string()),
            files: Some(Vec::new()),
            changes: vec![],
            notifications: Vec::new(),
        }
    }

    fn observe(center: &NotificationCenter) -> (Subscription, mpsc::UnboundedReceiver<u64>) {
        let (sender, received) = mpsc::unbounded_channel();
        let subscription = center.subscribe(move |event| {
            let SyncCommitted::Repository { operation_id, .. } = event else { return; };
            sender
                .send(operation_id.as_ref().unwrap().parse().unwrap())
                .unwrap();
        });
        (subscription, received)
    }

    fn start() -> (
        NotificationCenter,
        oneshot::Sender<()>,
        tokio::task::JoinHandle<Result<(), CoreError>>,
    ) {
        let (center, requests) = NotificationCenter::new();
        let (stop, stopping) = oneshot::channel();
        (
            center,
            stop,
            tokio::spawn(NotificationCenter::process(requests, stopping)),
        )
    }

    #[tokio::test]
    async fn subscription_event_and_cancellation_follow_channel_order() {
        let (center, stop, process) = start();
        let (subscription, mut received) = observe(&center);
        center.publish(event(1));
        drop(subscription);
        center.publish(event(2));
        center.flush().await.unwrap();
        assert_eq!(received.recv().await, Some(1));
        assert!(received.try_recv().is_err());
        stop.send(()).unwrap();
        process.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn slow_process_keeps_every_queued_event_in_order() {
        let (center, stop, process) = start();
        let (_subscription, mut received) = observe(&center);
        for index in 0..10_000 {
            center.publish(event(index));
        }
        center.flush().await.unwrap();
        for expected in 0..10_000 {
            assert_eq!(received.recv().await, Some(expected));
        }
        stop.send(()).unwrap();
        process.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn processes_with_the_same_repository_identity_receive_only_their_own_events() {
        let (first, stop_first, process_first) = start();
        let (second, stop_second, process_second) = start();
        let (subscription_first, mut received_first) = observe(&first);
        let (_subscription_second, mut received_second) = observe(&second);
        first.publish(event(1));
        second.publish(event(2));
        first.flush().await.unwrap();
        second.flush().await.unwrap();
        assert_eq!(received_first.try_recv().unwrap(), 1);
        assert!(received_first.try_recv().is_err());
        assert_eq!(received_second.try_recv().unwrap(), 2);
        assert!(received_second.try_recv().is_err());
        stop_first.send(()).unwrap();
        process_first.await.unwrap().unwrap();
        assert!(!subscription_first.is_active());
        assert!(first.flush().await.is_err());
        second.publish(event(3));
        second.flush().await.unwrap();
        assert_eq!(received_second.recv().await, Some(3));
        stop_second.send(()).unwrap();
        process_second.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn oneshot_stop_waits_for_callback_and_drains_previously_queued_events() {
        let (center, stop, process) = start();
        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(std::sync::Barrier::new(2));
        let signal = entered.clone();
        let releasing = release.clone();
        let (sender, mut received) = mpsc::unbounded_channel();
        let subscription = center.subscribe(move |event| {
            let SyncCommitted::Repository { operation_id, .. } = event else { return; };
            let index: u64 = operation_id.as_ref().unwrap().parse().unwrap();
            if index == 1 {
                signal.notify_one();
                releasing.wait();
            }
            sender.send(index).unwrap();
        });
        center.publish(event(1));
        entered.notified().await;
        center.publish(event(2));
        stop.send(()).unwrap();
        assert!(!process.is_finished());
        release.wait();
        process.await.unwrap().unwrap();
        assert_eq!(received.recv().await, Some(1));
        assert_eq!(received.recv().await, Some(2));
        assert!(!subscription.is_active());
        assert!(center.flush().await.is_err());
    }

    #[tokio::test]
    async fn dropping_all_channel_handles_exits_process_without_workspace_stop() {
        let (center, _stop, process) = start();
        drop(center);
        tokio::time::timeout(std::time::Duration::from_secs(2), process)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}
