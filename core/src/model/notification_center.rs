//! Workspace 私有的通知请求通道；订阅表和 ID 只存在于 process 的局部状态。
use super::notification::{
    NotificationCallback, NotificationLoads, NotificationRequest, NotificationState,
    RepositoryNotifications,
};
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
        let requests = Requests(receiver, sender.downgrade(), sequence.clone());
        (Self { sender, sequence }, requests)
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
                repos,
            )));
    }

    pub(crate) fn watch_notifications(
        &self,
        repo_ids: Option<Vec<super::OrgRepoId>>,
        callback: NotificationCallback,
    ) -> Subscription {
        let token = Arc::new(());
        let (active, status) = watch::channel(true);
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Subscribe {
                repo_ids,
                token: Arc::downgrade(&token),
                callback,
                active,
            }));
        Subscription {
            center: self.clone(),
            token,
            active: status,
        }
    }

    pub(crate) fn update_files(
        &self,
        repo_id: &str,
        files: Vec<super::FileDataChange>,
        conflicts: bool,
    ) {
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Files {
                repo_id: repo_id.into(),
                revision: self.next_revision(),
                files,
                conflicts,
            }));
    }

    pub(crate) fn update_snapshot(&self, repo_id: String, data: RepositoryNotifications) {
        let _ = self
            .sender
            .send(Request::Notifications(NotificationRequest::Snapshot {
                repo_id,
                data,
            }));
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
                Request::Publish(event) => {
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

        let mut notices = NotificationState::default();
        let mut loads = NotificationLoads::new();
        let mut monitors = BTreeMap::new();
        let mut next_id = 0;
        loop {
            let next = tokio::select! {
                biased;
                _ = &mut stopping => break,
                next = requests.0.recv() => next,
                loaded = loads.join_next(), if !loads.is_empty() => {
                    if let Some(Ok((generation, repo_id, data))) = loaded { notices.loaded(generation, repo_id, data); }
                    continue;
                },
            };
            let Some(next) = next else {
                break;
            };
            if let Request::Notifications(request) = next {
                if let Some(sender) = requests.1.upgrade() {
                    notices.handle(
                        request,
                        &mut loads,
                        &Self {
                            sender,
                            sequence: requests.2.clone(),
                        },
                    );
                }
            } else {
                handle(next, &mut monitors, &mut next_id)?;
            }
        }
        // 关闭入口后排空已受理请求；当前回调由本任务执行，返回时已全部完成。
        requests.0.close();
        while let Some(request) = requests.0.recv().await {
            if let Request::Notifications(request) = request {
                if let Some(sender) = requests.1.upgrade() {
                    notices.handle(
                        request,
                        &mut loads,
                        &Self {
                            sender,
                            sequence: requests.2.clone(),
                        },
                    );
                }
            } else {
                handle(request, &mut monitors, &mut next_id)?;
            }
        }
        loads.abort_all();
        while loads.join_next().await.is_some() {}
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
            files: None,
            changes: vec![],
        }
    }

    fn observe(center: &NotificationCenter) -> (Subscription, mpsc::UnboundedReceiver<u64>) {
        let (sender, received) = mpsc::unbounded_channel();
        let subscription = center.subscribe(move |event| {
            let SyncCommitted::Repository { operation_id, .. } = event;
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
            let SyncCommitted::Repository { operation_id, .. } = event;
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
