use org_tasks_core::{CoreNotification, OrgWorkspace};
pub trait NotificationsForTest {
    async fn notification_snapshot(&self) -> Vec<CoreNotification>;
}
impl NotificationsForTest for OrgWorkspace {
    async fn notification_snapshot(&self) -> Vec<CoreNotification> {
        self.query(&[org_tasks_core::CoreQuery::File { query: org_tasks_core::FileQuery::default() }]).await.unwrap();
        let (send, mut received) = tokio::sync::mpsc::unbounded_channel();
        let _subscription = self.watch_notifications(None, monitor(move |notifications| {
            let _ = send.send(notifications);
        }));
        tokio::time::timeout(std::time::Duration::from_secs(5), received.recv())
            .await
            .unwrap()
            .unwrap()
    }
}

pub fn monitor<F>(callback: F) -> impl org_tasks_core::NotificationMonitor
where F: Fn(Vec<CoreNotification>) + Send + Sync + 'static {
    let state = std::sync::Arc::new(std::sync::Mutex::new(org_tasks_core::NotificationSnapshot { revision: 0, notifications: Vec::new() }));
    let initial = state.clone(); let callback = std::sync::Arc::new(callback); let first = callback.clone();
    (move |snapshot: org_tasks_core::NotificationSnapshot| {
        *initial.lock().unwrap() = snapshot.clone(); first(snapshot.notifications);
    }, move |delta: org_tasks_core::NotificationDelta| {
        let mut snapshot = state.lock().unwrap(); delta.apply(&mut snapshot).unwrap(); callback(snapshot.notifications.clone());
    })
}
