use org_tasks_core::{CoreNotification, OrgWorkspace};
pub trait NotificationsForTest {
    async fn notification_snapshot(&self) -> Vec<CoreNotification>;
}
impl NotificationsForTest for OrgWorkspace {
    async fn notification_snapshot(&self) -> Vec<CoreNotification> {
        let (send, mut received) = tokio::sync::mpsc::unbounded_channel();
        let _subscription = self.watch_notifications(None, move |notifications| {
            let _ = send.send(notifications);
        });
        tokio::time::timeout(std::time::Duration::from_secs(5), received.recv())
            .await
            .unwrap()
            .unwrap()
    }
}
