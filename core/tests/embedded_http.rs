use org_tasks_core::{webdav::WebDavSyncPolicy, *};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shared_workspace_http_queries_mutations_events_and_lifecycle() {
    let root = std::env::temp_dir().join(format!(
        "org-http-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("tasks.org"), "* TODO Original\n").unwrap();
    let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    let repo_id = repo.id.clone();
    let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let capture = events.clone();
    let subscription = workspace
        .subscribe_query(vec![QuerySubscriptionRequest::new(TaskQuery::default().into(), move |event| {
            capture.lock().unwrap().push(event)
        })])
        .await
        .unwrap().remove(0);
    let workspace = workspace.clone();
    let mut server = OrgWorkspace::start_http_server(workspace, "127.0.0.1:0".parse().unwrap())
        .await
        .unwrap();
    let address = server.address();
    let base = format!("http://{address}/api/v1");
    let client = reqwest::Client::new();
    async fn post(client: &reqwest::Client, url: &str, body: Value) -> (u16, Value) {
        let response = client
            .post(url)
            .header("content-type", "application/json")
            .body(body.to_string())
            .send()
            .await
            .unwrap();
        let status = response.status().as_u16();
        (
            status,
            serde_json::from_str(&response.text().await.unwrap()).unwrap(),
        )
    }
    let query = json!([{"type":"task","query":{}}]);
    let (status, initial) = post(&client, &format!("{base}/queries"), query.clone()).await;
    assert_eq!(status, 200);
    assert_eq!(initial[0]["result"]["tasks"][0]["title"], "Original");
    let (status, created) = post(&client, &format!("{base}/task-operation-groups"), json!({"operationId":"http/test-create", "operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":repo_id,"file":"tasks.org","titles":[]}},"title":"Created","state":"TODO"}}]})).await;
    assert_eq!(
        (status, created["status"].as_str()),
        (200, Some("committed")),
        "{created}"
    );
    let (_, data) = post(&client, &format!("{base}/queries"), query.clone()).await;
    let task = data[0]["result"]["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|task| task["title"] == "Created")
        .unwrap();
    let path = task["fullPath"].clone();
    let (status, error) = post(&client, &format!("{base}/task-operation-groups"), json!({"fileVersions":[{"repoId":repo_id,"file":"tasks.org","version":"stale"}],"operations":[{"type":"Deletion","data":{"path":path}}]})).await;
    assert_eq!(status, 409, "{error}");
    let (status, result) = post(&client, &format!("{base}/task-operation-groups"), json!({"operations":[{"type":"Modification","data":{"path":path,"modifications":[{"field":"NOTES","value":"Updated through API"}]}}]})).await;
    assert_eq!(status, 200, "{result}");
    assert!(result["operationId"].as_str().unwrap().starts_with("http/"));
    let (status, result) = post(
        &client,
        &format!("{base}/task-operation-groups"),
        json!({"operations":[{"type":"Deletion","data":{"path":path}}]}),
    )
    .await;
    assert_eq!(status, 200, "{result}");
    let (_, final_data) = post(&client, &format!("{base}/queries"), query).await;
    assert_eq!(
        final_data[0]["result"]["tasks"].as_array().unwrap().len(),
        1
    );
    assert!(format!("{:?}", events.lock().unwrap()).contains("http/test-create"));
    assert_eq!(
        client
            .post(format!("{base}/queries"))
            .header("content-type", "application/json")
            .body("{")
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        client
            .get(format!("{base}/health"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    drop(subscription);
    OrgWorkspace::stop_http_server(&mut server).await.unwrap();
    let rebound = tokio::net::TcpListener::bind(address).await.unwrap();
    drop(rebound);
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn host_handlers_register_after_start_without_core_knowing_host_semantics() {
    let workspace = OrgWorkspace::start(vec![]).await.unwrap();
    let mut server = OrgWorkspace::start_http_server(workspace, "127.0.0.1:0".parse().unwrap()).await.unwrap();
    let base = format!("http://{}", server.address());
    let client = reqwest::Client::new();
    assert_eq!(client.get(format!("{base}/host/example")).send().await.unwrap().status(), 404);
    let route = axum::routing::get(|| async { axum::Json(json!({"value":42})) })
        .put(|axum::Json(value): axum::Json<Value>| async move { axum::Json(value) });
    server.register_handler("/host/example", route).unwrap();
    let response = client.get(format!("{base}/host/example")).send().await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.text().await.unwrap(), r#"{"value":42}"#);
    let response = client.put(format!("{base}/host/example")).header("content-type", "application/json").body(r#"{"input":1}"#).send().await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.text().await.unwrap(), r#"{"input":1}"#);
    assert_eq!(client.post(format!("{base}/host/example")).send().await.unwrap().status(), 405);
    assert!(server.register_handler("/api/v1/queries", axum::routing::get(|| async { "override" })).is_err());
    assert!(server.register_handler("/host/example", axum::routing::get(|| async { "duplicate" })).is_err());
    assert!(server.register_handler("/:id", axum::routing::get(|| async { "dynamic" })).is_err());
    let response = client.post(format!("{base}/api/v1/queries")).header("content-type", "application/json").body("[]").send().await.unwrap();
    assert_eq!(response.status(), 200);
    OrgWorkspace::stop_http_server(&mut server).await.unwrap();
    assert!(std::net::TcpListener::bind(server.address()).is_ok());
    assert!(server.register_handler("/stopped", axum::routing::get(|| async { "stopped" })).is_err());
}
