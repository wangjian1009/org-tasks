use org_tasks_core::{OrgWorkspace, QuerySubscriptionRequest, QuerySubscriptionStatus, TaskQuery};
use std::sync::Arc;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stop_closes_subscriptions_and_http_servers_across_workspace_clones() {
    let workspace = OrgWorkspace::start(vec![]).await.unwrap();
    let subscription = workspace
        .subscribe_query(vec![QuerySubscriptionRequest::new(TaskQuery::default().into(), |_| {})])
        .await
        .unwrap().remove(0);
    let owner = workspace.clone();
    let shared = workspace.clone();
    let mut server =
        OrgWorkspace::start_http_server(shared.clone(), "127.0.0.1:0".parse().unwrap())
            .await
            .unwrap();
    let address = server.address();
    tokio::time::timeout(std::time::Duration::from_secs(3), owner.stop())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        owner.query_subscription_status(&subscription.subscription),
        QuerySubscriptionStatus::Closed
    );
    assert!(owner.query(&[]).await.is_err());
    assert!(
        owner
            .subscribe_query(vec![QuerySubscriptionRequest::new(TaskQuery::default().into(), |_| {})])
            .await
            .is_err()
    );
    assert!(
        OrgWorkspace::start_http_server(shared, "127.0.0.1:0".parse().unwrap())
            .await
            .is_err()
    );
    assert!(std::net::TcpStream::connect(address).is_err());
    let rebound = std::net::TcpListener::bind(address).unwrap();
    owner.stop().await.unwrap();
    OrgWorkspace::stop_http_server(&mut server).await.unwrap();
    drop(rebound);
}

#[tokio::test]
async fn mutations_and_reset_notify_only_the_workspace_that_started_them() {
    use org_tasks_core::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    let root = std::env::temp_dir().join(format!(
        "workspace-isolation-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("tasks.org"), "* TODO Original\n").unwrap();
    let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
    repo.load::<webdav::WebDavSyncPolicy>().await.unwrap();
    let first = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
    let second = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
    let first_count = Arc::new(AtomicUsize::new(0));
    let second_count = Arc::new(AtomicUsize::new(0));
    let count = first_count.clone();
    let _first = first.watch_data_changes(move |_| {
        count.fetch_add(1, Ordering::SeqCst);
    });
    let count = second_count.clone();
    let _second = second.watch_data_changes(move |_| {
        count.fetch_add(1, Ordering::SeqCst);
    });
    let count = first_count.clone();
    let _first_files = first.watch_external_file_changes(move |_| { count.fetch_add(1, Ordering::SeqCst); });
    let count = second_count.clone();
    let _second_files = second.watch_external_file_changes(move |_| { count.fetch_add(1, Ordering::SeqCst); });
    let file = repo.file("tasks.org").await.unwrap();
    let creation = TaskCreation::new(
        TaskPosition {
            parent: TaskPath::file(repo.id.clone(), "tasks.org".into()),
            after: None,
        },
        "Created".into(),
    );
    first
        .execute_task_operations(&TaskOperationGroup {
            operation_id: Some("isolation/create".into()),
            operations: vec![TaskOperation::Creation(creation)],
            file_versions: vec![TaskFileVersion {
                repo_id: repo.id.clone(),
                file: "tasks.org".into(),
                version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
            }],
        })
        .await
        .unwrap();
    second.query(&[]).await.unwrap();
    assert_eq!(first_count.load(Ordering::SeqCst), 1);
    assert_eq!(second_count.load(Ordering::SeqCst), 0);
    repo.reset(Some(first.notification_center())).await.unwrap();
    second.query(&[]).await.unwrap();
    assert_eq!(first_count.load(Ordering::SeqCst), 2);
    assert_eq!(second_count.load(Ordering::SeqCst), 0);
    first.stop().await.unwrap();
    second.stop().await.unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
