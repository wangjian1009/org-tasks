use super::*;
use crate::TaskScanRules;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

struct Remote {
    data: Vec<u8>,
    etag: String,
}
struct Dav {
    files: BTreeMap<String, Remote>,
    reject: BTreeSet<String>,
    reject_get: BTreeSet<String>,
    requests: Vec<String>,
    hierarchical: bool,
    invalid_listing: bool,
    omit_put_etag: bool,
    get_etag: BTreeMap<String, String>,
    transform_put: BTreeMap<String, Vec<u8>>,
    pause: Option<(String, Arc<tokio::sync::Notify>, Arc<tokio::sync::Notify>)>,
}

async fn server(
    files: &[(&str, &[u8])],
) -> (
    WebDavSyncPolicy,
    Arc<Mutex<Dav>>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let state = Arc::new(Mutex::new(Dav {
        files: files
            .iter()
            .map(|(path, data)| {
                (
                    path.to_string(),
                    Remote {
                        data: data.to_vec(),
                        etag: "\"v1\"".into(),
                    },
                )
            })
            .collect(),
        reject: BTreeSet::new(),
        reject_get: BTreeSet::new(),
        requests: Vec::new(),
        hierarchical: false,
        invalid_listing: false,
        omit_put_etag: false,
        get_etag: BTreeMap::new(),
        transform_put: BTreeMap::new(),
        pause: None,
    }));
    let shared = state.clone();
    let endpoint =
        WebDavEndpoint::new(format!("http://{}/org/", listener.local_addr().unwrap())).unwrap();
    let worker = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            let end = loop {
                let n = stream.read(&mut buffer).await.unwrap();
                if n == 0 {
                    return;
                }
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(offset) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                    break offset + 4;
                }
            };
            let headers = String::from_utf8_lossy(&bytes[..end]).to_string();
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            while bytes.len() < end + length {
                let n = stream.read(&mut buffer).await.unwrap();
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..n]);
            }
            let mut request = headers.split_whitespace();
            let method = request.next().unwrap();
            let path = request
                .next()
                .unwrap()
                .trim_start_matches("/org/")
                .to_string();
            let pause = {
                let mut dav = shared.lock().unwrap();
                if dav.pause.as_ref().is_some_and(|(expected, _, _)| expected == method) {
                    dav.pause.take()
                } else { None }
            };
            if let Some((_, entered, resume)) = pause {
                entered.notify_one();
                resume.notified().await;
            }
            let (status, body, etag) = {
                let mut dav = shared.lock().unwrap();
                dav.requests.push(headers.clone());
                match method {
                    "PROPFIND" => {
                        let mut directories = BTreeSet::new();
                        let mut entries = String::new();
                        for (filename, file) in &dav.files {
                            if dav.hierarchical {
                                let Some(rest) = filename.strip_prefix(&path) else {
                                    continue;
                                };
                                if let Some((child, _)) = rest.split_once('/') {
                                    directories.insert(format!("{path}{child}/"));
                                    continue;
                                }
                            }
                            entries.push_str(&format!("<d:response><d:href>/org/{filename}</d:href><d:propstat><d:prop><d:getetag>{}</d:getetag><d:getcontentlength>{}</d:getcontentlength></d:prop></d:propstat></d:response>",file.etag,file.data.len()));
                        }
                        for directory in directories {
                            entries.push_str(&format!("<d:response><d:href>/org/{directory}</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>"));
                        }
                        if dav.invalid_listing {
                            entries.push_str("<d:response>");
                        }
                        (
                            207,
                            format!("<d:multistatus xmlns:d=\"DAV:\">{entries}</d:multistatus>")
                                .into_bytes(),
                            None,
                        )
                    }
                    "GET" if dav.reject_get.contains(&path) => (412, Vec::new(), None),
                    "GET" => match dav.files.get(&path) {
                        Some(file)
                            if headers.contains(&format!("if-match: {}", file.etag))
                                || !headers.contains("if-match:") =>
                        {
                            (200, file.data.clone(), Some(dav.get_etag.get(&path).unwrap_or(&file.etag).clone()))
                        }
                        Some(_) => (412, Vec::new(), None),
                        None => (404, Vec::new(), None),
                    },
                    "DELETE" => {
                        let valid = dav
                            .files
                            .get(&path)
                            .is_some_and(|f| headers.contains(&format!("if-match: {}", f.etag)));
                        if !valid || dav.reject.contains(&path) {
                            (412, Vec::new(), None)
                        } else {
                            dav.files.remove(&path);
                            (204, Vec::new(), None)
                        }
                    }
                    "PUT" => {
                        let valid = if let Some(file) = dav.files.get(&path) {
                            headers.contains(&format!("if-match: {}", file.etag))
                        } else {
                            headers.contains("if-none-match: *")
                        };
                        if dav.reject.contains(&path) || !valid {
                            (412, Vec::new(), None)
                        } else {
                            let next_etag = format!("\"v{}\"", dav.requests.len());
                            let data = dav.transform_put.get(&path).cloned().unwrap_or_else(|| bytes[end..end + length].to_vec());
                            dav.files.insert(
                                path.clone(),
                                Remote {
                                    data,
                                    etag: next_etag.clone(),
                                },
                            );
                            (204, Vec::new(), if dav.omit_put_etag { None } else { Some(next_etag) })
                        }
                    }
                    _ => (500, Vec::new(), None),
                }
            };
            let etag = etag.map(|e| format!("ETag: {e}\r\n")).unwrap_or_default();
            stream.write_all(format!("HTTP/1.1 {status} Result\r\nContent-Length: {}\r\n{etag}Connection: close\r\n\r\n", body.len()).as_bytes()).await.unwrap();
            stream.write_all(&body).await.unwrap();
        }
    });
    (
        WebDavSyncPolicy::new(endpoint, "user".into(), "secret".into()).unwrap(),
        state,
        worker,
    )
}

async fn repo() -> (OrgRepo, std::path::PathBuf) {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "org-tasks-merge-sync-{}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    (repo, root)
}

async fn sync(
    repo: &mut OrgRepo,
    policy: &WebDavSyncPolicy,
    time: i64,
) -> OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail> {
    repo.sync(
        policy,
        time,
        &SyncCancellation::default(),
        &SyncProgressReporter::default(),
    )
    .await
    .unwrap()
}

async fn baseline_index(root: &std::path::Path) -> serde_json::Value {
    serde_json::from_slice(&tokio::fs::read(root.join(".sync/remote_base/current.json")).await.unwrap()).unwrap()
}

async fn baseline_source(root: &std::path::Path, path: &str, local: bool) -> Option<Vec<u8>> {
    let index = baseline_index(root).await;
    let id = index[if local { "local" } else { "generation" }].as_str().unwrap();
    let directory = root.join(format!(".sync/remote_base/generations/{id}"));
    let manifest: serde_json::Value = serde_json::from_slice(&tokio::fs::read(directory.join("manifest.json")).await.unwrap()).unwrap();
    if manifest["entries"][path]["hash"].is_null() { return None; }
    Some(tokio::fs::read(directory.join("files").join(path)).await.unwrap())
}

async fn offline(repo: &mut OrgRepo, path: &str) {
    crate::model::test_support::append_fixture(repo, path, "Offline")
        .await
        .unwrap();
}

#[tokio::test]
async fn trigger_reason_is_persisted_for_success_failure_and_cancellation() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* TODO Task\n")]).await;
    for (time, trigger_reason, expected) in [
        (
            1,
            crate::SyncTriggerReason::AppStartup,
            OrgRepoSyncResult::Succeeded,
        ),
        (
            2,
            crate::SyncTriggerReason::AppBackground,
            OrgRepoSyncResult::Failed,
        ),
        (
            3,
            crate::SyncTriggerReason::Manual,
            OrgRepoSyncResult::Cancelled,
        ),
    ] {
        state.lock().unwrap().invalid_listing = expected == OrgRepoSyncResult::Failed;
        let cancellation = SyncCancellation::default();
        if expected == OrgRepoSyncResult::Cancelled {
            cancellation.cancel();
        }
        let record = repo
            .sync_with_options(
                &policy,
                time,
                &cancellation,
                &SyncProgressReporter::default(),
                crate::SyncOptions {
                    trigger_reason,
                    ..crate::SyncOptions::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(record.result, Some(expected));
        assert_eq!(record.trigger_reason, Some(trigger_reason));
        let stored: serde_json::Value = serde_json::from_slice(
            &tokio::fs::read(root.join(format!(".sync/history/{time}.json")))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            stored["trigger_reason"],
            serde_json::to_value(trigger_reason).unwrap()
        );
        let summary = repo
            .history_summaries()
            .await
            .unwrap()
            .into_iter()
            .find(|item| item.id == record.id)
            .unwrap();
        assert_eq!(summary.trigger_reason, Some(trigger_reason));
        assert_eq!(
            repo.history_detail(&record.id)
                .await
                .unwrap()
                .summary
                .trigger_reason,
            Some(trigger_reason)
        );
    }
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn checklist_sort_sync_with_updated_progress_keeps_one_task_tree_and_is_idempotent() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Project [/]\r\n- [ ] First\r\n- [X] Second\r\n** TODO Child [%]\r\nNotes\r\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    assert_eq!(sync(&mut repo, &policy, 1).await.result, Some(OrgRepoSyncResult::Succeeded));
    let file = repo.file("a.org").await.unwrap();
    let path = file.node_paths()[0].clone();
    let item = file.task_edit_content(&path).unwrap().checklist[0].id.clone();
    let repo_id = repo.id.clone();
    let mut workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
    workspace.execute_task_operations(&crate::TaskOperationGroup {
        operations: vec![crate::TaskOperation::Modification(crate::TaskModificationOperation {
            path,
            modifications: vec![
                crate::TaskModification::Checklist(crate::TaskChecklistChange::Move { id: item, before_id: None }),
                crate::TaskModification::Title(Some("Project [1/2]".into())),
            ],
        })],
        queue_repo_ids: vec![repo_id.clone()],
        file_versions: vec![crate::TaskFileVersion {
            repo_id, file: "a.org".into(), version: LocalFileVersion::from_bytes(base).content_hash,
        }],
    }).await.unwrap();
    assert_eq!(workspace.query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap(), vec![crate::CoreNotification::SyncRequired]);
    repo = workspace.repos.remove(0);
    let remote = String::from_utf8(base.to_vec()).unwrap().replace("Project [/]", "Project [1/2]").replace("Child [%]", "Child [50%]").replace("Notes", "Remote notes");
    state.lock().unwrap().files.insert("a.org".into(), Remote { data: remote.into_bytes(), etag: "\"remote\"".into() });
    let expected = String::from_utf8(base.to_vec()).unwrap()
        .replace("Project [/]", "Project [1/2]").replace("Child [%]", "Child [50%]")
        .replace("- [ ] First\r\n- [X] Second\r\n", "- [X] Second\r\n- [ ] First\r\n")
        .replace("Notes", "Remote notes");
    for time in [2, 3] {
        let result = sync(&mut repo, &policy, time).await;
        assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), expected.as_bytes());
        assert_eq!(state.lock().unwrap().files["a.org"].data, expected.as_bytes());
        assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
        assert!(repo.pending_writes().await.unwrap().is_empty());
        assert!(!crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
        let tasks = crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[(crate::TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].full_path().titles, ["Project"]);
        assert_eq!(tasks[1].full_path().titles, ["Project", "Child"]);
    }
    assert!(crate::OrgWorkspace::new(vec![repo]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn bilateral_new_file_changes_merge_fields_logs_and_then_isolate_same_todo_conflict() {
    use crate::model::conflict;

    let base = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/bilateral-sync.org"));
    let (mut first, first_root) = repo().await;
    let (mut second, second_root) = repo().await;
    let (policy, state, worker) = server(&[("bilateral.org", base)]).await;
    assert_eq!(sync(&mut first, &policy, 1).await.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(sync(&mut second, &policy, 2).await.result, Some(OrgRepoSyncResult::Succeeded));

    let base_text = String::from_utf8(base.to_vec()).unwrap();
    let first_text = base_text
        .replace("* TODO 项目 :base:", "* TODO 项目 :base:甲端:")
        .replace("SCHEDULED: <2026-01-01 Thu>", "SCHEDULED: <2026-02-01 Sun>")
        .replace("基线正文", "甲端正文")
        .replace(
            "- Note taken on [2026-01-01 Thu]\n",
            "- Note taken on [2026-01-01 Thu]\n- Note taken on [2026-01-03 Sat]\n",
        );
    let second_text = base_text
        .replace("* TODO 项目 :base:", "* TODO 项目 :base:乙端:")
        .replace("DEADLINE: <2026-01-02 Fri>", "DEADLINE: <2026-03-02 Mon>")
        .replace("CLOSED: [2026-01-05 Mon]", "CLOSED: [2026-04-05 Sun]")
        .replace("子任务基线", "乙端子任务正文")
        .replace(
            "- Note taken on [2026-01-01 Thu]\n",
            "- Note taken on [2026-01-01 Thu]\n- Note taken on [2026-01-02 Fri]\n",
        );
    tokio::fs::write(first_root.join("bilateral.org"), first_text).await.unwrap();
    tokio::fs::write(second_root.join("bilateral.org"), second_text).await.unwrap();

    assert_eq!(sync(&mut first, &policy, 3).await.result, Some(OrgRepoSyncResult::Succeeded));
    let merged_record = sync(&mut second, &policy, 4).await;
    assert_eq!(merged_record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(merged_record.files.iter().find(|file| file.relative_path == "bilateral.org").unwrap().outcome, OrgRepoSyncFileOutcome::Merged);
    let merged = tokio::fs::read(second_root.join("bilateral.org")).await.unwrap();
    assert_eq!(state.lock().unwrap().files["bilateral.org"].data, merged);
    let merged_text = String::from_utf8(merged.clone()).unwrap();
    assert!(merged_text.contains("SCHEDULED: <2026-02-01 Sun>"));
    assert!(merged_text.contains("DEADLINE: <2026-03-02 Mon>"));
    assert!(merged_text.contains("CLOSED: [2026-04-05 Sun]"));
    assert!(merged_text.contains(":base:") && merged_text.contains("甲端") && merged_text.contains("乙端"));
    assert!(merged_text.contains("甲端正文"));
    assert!(merged_text.contains("乙端子任务正文"));
    assert!(merged_text.find("2026-01-01").unwrap() < merged_text.find("2026-01-02").unwrap());
    assert!(merged_text.find("2026-01-02").unwrap() < merged_text.find("2026-01-03").unwrap());
    assert!(conflict::points(&second.file("bilateral.org").await.unwrap()).unwrap().is_empty());

    let first_conflict = merged_text.replace("* TODO 项目", "* DONE 项目");
    let second_conflict = merged_text.replace("* TODO 项目", "* WAIT 项目");
    tokio::fs::write(first_root.join("bilateral.org"), first_conflict).await.unwrap();
    tokio::fs::write(second_root.join("bilateral.org"), second_conflict).await.unwrap();
    assert_eq!(sync(&mut first, &policy, 5).await.result, Some(OrgRepoSyncResult::Succeeded));
    let conflict_record = sync(&mut second, &policy, 6).await;
    assert_eq!(conflict_record.result, Some(OrgRepoSyncResult::Succeeded));
    let current = second.file("bilateral.org").await.unwrap();
    let points = conflict::points(&current).unwrap();
    assert_eq!(points.len(), 1);
    assert_eq!(state.lock().unwrap().files["bilateral.org"].data, tokio::fs::read(second_root.join("bilateral.org")).await.unwrap());
    assert!(String::from_utf8_lossy(&conflict::main_source(&current)).contains("* DONE 项目"));
    assert!(points[0].source.contains("* WAIT 项目"));

    worker.abort();
    tokio::fs::remove_dir_all(first_root).await.unwrap();
    tokio::fs::remove_dir_all(second_root).await.unwrap();
}

#[tokio::test]
async fn checklist_sort_only_sync_uploads_without_conflict() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Project [/]\r\n- [ ] First\r\n- [X] Second\r\n** TODO Child [%]\r\nNotes\r\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    sync(&mut repo, &policy, 1).await;
    let file = repo.file("a.org").await.unwrap();
    let path = file.node_paths()[0].clone();
    let item = file.task_edit_content(&path).unwrap().checklist[0].id.clone();
    let repo_id = repo.id.clone();
    let mut workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
    workspace.execute_task_operations(&crate::TaskOperationGroup {
        operations: vec![crate::TaskOperation::Modification(crate::TaskModificationOperation {
            path,
            modifications: vec![crate::TaskModification::Checklist(crate::TaskChecklistChange::Move { id: item, before_id: None })],
        })],
        queue_repo_ids: vec![repo_id.clone()],
        file_versions: vec![crate::TaskFileVersion { repo_id, file: "a.org".into(), version: LocalFileVersion::from_bytes(base).content_hash }],
    }).await.unwrap();
    repo = workspace.repos.remove(0);
    let result = sync(&mut repo, &policy, 2).await;
    assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(result.files.iter().all(|file| file.state != OrgRepoSyncFileState::Conflict));
    assert!(!String::from_utf8_lossy(&tokio::fs::read(root.join("a.org")).await.unwrap()).contains("CONFLICT"));
    assert_eq!(state.lock().unwrap().files["a.org"].data, tokio::fs::read(root.join("a.org")).await.unwrap());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn old_conflict_material_does_not_block_edits_and_success_advances_all_snapshots() {
    use crate::{TaskChecklistChange, TaskCreation, TaskFileVersion, TaskModification,
        TaskModificationOperation, TaskOperation, TaskOperationGroup, TaskPosition};
    for (move_checklist, insert_node) in [(true, false), (false, true), (true, true)] {
        let main = "* TODO 任务编辑 - 检查清单 [4/5]\n- [X] 展示清单\n- [X] 编辑条目\n- [X] 标记完成\n- [X] 删除条目\n- [ ] 调整顺序\n* TODO Other\nbase\n";
        let seed = crate::merge(main.as_bytes(), main.replace("base", "local").as_bytes(), main.replace("base", "remote").as_bytes()).unwrap();
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("a.org", &seed)]).await;
        sync(&mut repo, &policy, 1).await;
        let file = repo.file("a.org").await.unwrap();
        let old_points = crate::model::conflict::points(&file).unwrap().into_iter()
            .map(|point| (point.id, point.source)).collect::<Vec<_>>();
        assert_eq!(old_points.len(), 1);
        let path = file.node_paths()[0].clone();
        let mut operations = Vec::new();
        if move_checklist {
            let id = file.task_edit_content(&path).unwrap().checklist[0].id.clone();
            operations.push(TaskOperation::Modification(TaskModificationOperation {
                path: path.clone(), modifications: vec![TaskModification::Checklist(TaskChecklistChange::Move { id, before_id: None })],
            }));
        }
        if insert_node {
            let mut creation = TaskCreation::new(TaskPosition { parent: file.full_path(), after: Some(path) }, "新增任务".into());
            creation.state = Some("TODO".into());
            creation.body = "新增备注\n".into();
            operations.push(TaskOperation::Creation(creation));
        }
        let mut workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        workspace.execute_task_operations(&TaskOperationGroup {
            operations, queue_repo_ids: vec![file.repo_id.clone()],
            file_versions: vec![TaskFileVersion { repo_id: file.repo_id.clone(), file: "a.org".into(), version: LocalFileVersion::from_bytes(&seed).content_hash }],
        }).await.unwrap();
        let expected = tokio::fs::read(root.join("a.org")).await.unwrap();
        if move_checklist { assert!(String::from_utf8_lossy(&expected).contains("- [ ] 调整顺序\n- [X] 展示清单\n")); }
        if insert_node { assert!(String::from_utf8_lossy(&expected).contains("* TODO 新增任务\n")); }
        repo = workspace.repos.remove(0);
        for time in [2, 3] {
            let record = sync(&mut repo, &policy, time).await;
            assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
            assert_eq!(record.files[0].action, if time == 2 { OrgRepoSyncFileAction::Uploaded } else { OrgRepoSyncFileAction::Unchanged });
            assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), expected);
            assert_eq!(state.lock().unwrap().files["a.org"].data, expected);
            assert_eq!(record.files[0].detail.synced_source.as_deref().unwrap().as_bytes(), expected);
            let index: serde_json::Value = serde_json::from_slice(&tokio::fs::read(root.join(".sync/remote_base/current.json")).await.unwrap()).unwrap();
            let entry = &index["entries"]["a.org"];
            let revision = entry["revision"].as_str().unwrap();
            assert_eq!(entry["hash"], LocalFileVersion::from_bytes(&expected).content_hash);
            assert_eq!(tokio::fs::read(root.join(format!(".sync/remote_base/generations/{revision}/files/a.org"))).await.unwrap(), expected);
            let current = repo.file("a.org").await.unwrap();
            let points = crate::model::conflict::points(&current).unwrap().into_iter()
                .map(|point| (point.id, point.source)).collect::<Vec<_>>();
            assert_eq!(points, old_points, "旧候选保持原样，不能新增伪冲突");
            assert!(!crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
            assert!(repo.pending_writes().await.unwrap().is_empty());
        }
        let put_count = state.lock().unwrap().requests.iter().filter(|request| request.starts_with("PUT ")).count();
        assert_eq!(put_count, 1, "无修改的再次同步不重复上传");
        let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
        let tasks = workspace.query(&[(crate::TaskQuery::default()).into()]).await.unwrap().remove(0).into_task().unwrap().tasks;
        assert_eq!(tasks.len(), if insert_node { 3 } else { 2 });
        assert!(!workspace.query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}

#[tokio::test]
async fn existing_conflicts_merge_concurrent_local_and_remote_changes_and_converge() {
    use crate::model::conflict;
    for scenario in ["independent", "new-main-conflict", "both-resolved"] {
        let main = "* TODO A\n原始 A\n* TODO B\n原始 B\n* TODO 旧任务\n原始正文\n";
        let seed = crate::merge(
            main.as_bytes(),
            main.replace("原始正文", "旧候选").as_bytes(),
            main.replace("原始正文", "远端原文").as_bytes(),
        )
        .unwrap();
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("a.org", &seed)]).await;
        sync(&mut repo, &policy, 1).await;
        let initial = repo.file("a.org").await.unwrap();
        let old_points = conflict::points(&initial).unwrap();
        let seed_text = String::from_utf8(seed).unwrap();
        let mut local = seed_text.replace("原始 A", "本地修改 A");
        let mut remote = seed_text.replace("原始 B", "远端修改 B");
        if scenario == "new-main-conflict" {
            remote = remote.replace("原始 A", "远端修改 A");
        } else if scenario == "both-resolved" {
            let without_points = String::from_utf8(conflict::main_source(&initial)).unwrap();
            local = without_points.replace("原始 A", "本地修改 A");
            remote = without_points.replace("原始 B", "远端修改 B");
        }
        tokio::fs::write(root.join("a.org"), &local).await.unwrap();
        state.lock().unwrap().files.insert(
            "a.org".into(),
            Remote {
                data: remote.as_bytes().to_vec(),
                etag: "\"v2\"".into(),
            },
        );
        let merged_record = sync(&mut repo, &policy, 2).await;
        assert_eq!(merged_record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(
            merged_record.files[0].action,
            OrgRepoSyncFileAction::Uploaded
        );
        let merged = repo.file("a.org").await.unwrap();
        let points = conflict::points(&merged).unwrap();
        assert_eq!(
            points.len(),
            match scenario {
                "independent" => 1,
                "new-main-conflict" => 2,
                "both-resolved" => 0,
                _ => unreachable!(),
            }
        );
        if scenario != "both-resolved" {
            assert_eq!(points[0].id, old_points[0].id);
            assert_eq!(points[0].source, old_points[0].source);
        }
        let expected_main = main
            .replace("原始正文", "远端原文")
            .replace(
                "原始 A",
                if scenario == "new-main-conflict" {
                    "远端修改 A"
                } else {
                    "本地修改 A"
                },
            )
            .replace("原始 B", "远端修改 B");
        assert_eq!(conflict::main_source(&merged), expected_main.as_bytes());
        let expected = merged.source_bytes().to_vec();
        let repeated = sync(&mut repo, &policy, 3).await;
        assert_eq!(repeated.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(repeated.files[0].action, OrgRepoSyncFileAction::Unchanged);
        assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), expected);
        assert_eq!(state.lock().unwrap().files["a.org"].data, expected);
        for record in [&merged_record, &repeated] {
            assert_eq!(
                record.files[0]
                    .detail
                    .synced_source
                    .as_deref()
                    .unwrap()
                    .as_bytes(),
                expected
            );
            let snapshot = root.join(format!(
                ".sync/history/{}/conflicts/a.org/a.org",
                record.started_at
            ));
            if scenario == "both-resolved" {
                assert!(!snapshot.exists());
            } else {
                assert_eq!(tokio::fs::read(snapshot).await.unwrap(), expected);
            }
        }
        let index: serde_json::Value = serde_json::from_slice(
            &tokio::fs::read(root.join(".sync/remote_base/current.json"))
                .await
                .unwrap(),
        )
        .unwrap();
        let revision = index["entries"]["a.org"]["revision"].as_str().unwrap();
        assert_eq!(
            tokio::fs::read(root.join(format!(".sync/remote_base/generations/{revision}/files/a.org")))
                .await
                .unwrap(),
            expected
        );
        assert!(!crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
        assert!(repo.pending_writes().await.unwrap().is_empty());
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}

#[tokio::test]
async fn remote_deletion_directly_removes_modified_local_file_and_consumes_intents() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("inbox.org", b"* TODO Original\n")]).await;
    sync(&mut repo, &policy, 1).await;
    offline(&mut repo, "inbox.org").await;
    let deleted_content = tokio::fs::read(root.join("inbox.org")).await.unwrap();
    state.lock().unwrap().files.clear();
    let result = sync(&mut repo, &policy, 2).await;
    assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(result.files[0].action, OrgRepoSyncFileAction::Deleted);
    assert_eq!(
        result.files[0].outcome,
        crate::OrgRepoSyncFileOutcome::Deleted
    );
    assert_eq!(
        tokio::fs::read(root.join(".sync/history/2/deleted/inbox.org/inbox.org"))
            .await
            .unwrap(),
        deleted_content
    );
    assert_eq!(
        repo.history_file(&result.id, "inbox.org", false)
            .await
            .unwrap()
            .source_bytes(),
        deleted_content
    );
    assert!(
        repo.history_detail(&result.id).await.unwrap().files[0]
            .backup
            .is_some()
    );
    assert!(!root.join("inbox.org").exists());
    assert!(repo.pending_writes().await.unwrap().is_empty());
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn history_persists_file_results_and_keeps_deleted_bytes_out_of_remote_baseline() {
    use crate::OrgRepoSyncFileOutcome as Outcome;
    let (mut repo, root) = repo().await;
    let base = b"* TODO A\n:PROPERTIES:\n:ID: a\n:END:\nbase\n";
    let (policy, state, worker) = server(&[
        ("same.org", base),
        ("update.org", base),
        ("merge.org", base),
        ("conflict.org", base),
        ("delete.org", base),
        ("upload.org", base),
    ])
    .await;
    let first = sync(&mut repo, &policy, 1).await;
    assert!(first.files.iter().all(|f| f.outcome == Outcome::Created));
    let remote = String::from_utf8(base.to_vec())
        .unwrap()
        .replace("base", "remote");
    tokio::fs::write(
        root.join("merge.org"),
        String::from_utf8(base.to_vec())
            .unwrap()
            .replace("TODO", "DONE"),
    )
    .await
    .unwrap();
    tokio::fs::write(
        root.join("conflict.org"),
        String::from_utf8(base.to_vec())
            .unwrap()
            .replace("base", "local"),
    )
    .await
    .unwrap();
    tokio::fs::write(
        root.join("upload.org"),
        String::from_utf8(base.to_vec())
            .unwrap()
            .replace("base", "local"),
    )
    .await
    .unwrap();
    tokio::fs::write(root.join("new-local.org"), b"* New local\n")
        .await
        .unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.remove("delete.org");
        for path in ["update.org", "merge.org", "conflict.org"] {
            dav.files.insert(
                path.into(),
                Remote {
                    data: remote.as_bytes().to_vec(),
                    etag: "\"changed\"".into(),
                },
            );
        }
        dav.files.insert(
            "new-remote.org".into(),
            Remote {
                data: b"* New remote\n".to_vec(),
                etag: "\"new\"".into(),
            },
        );
    }
    let result = sync(&mut repo, &policy, 2).await;
    assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
    let expected = [
        ("same.org", Outcome::Unchanged),
        ("update.org", Outcome::Updated),
        ("merge.org", Outcome::Merged),
        ("conflict.org", Outcome::Conflict),
        ("delete.org", Outcome::Deleted),
        ("upload.org", Outcome::Uploaded),
        ("new-local.org", Outcome::Created),
        ("new-remote.org", Outcome::Created),
    ];
    let persisted: OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail> =
        serde_json::from_slice(
            &tokio::fs::read(root.join(".sync/history/2.json"))
                .await
                .unwrap(),
        )
        .unwrap();
    for (path, outcome) in expected {
        assert_eq!(
            persisted
                .files
                .iter()
                .find(|f| f.relative_path == path)
                .unwrap()
                .outcome,
            outcome,
            "{path}"
        );
    }
    let deletion = persisted
        .files
        .iter()
        .find(|f| f.relative_path == "delete.org")
        .unwrap();
    assert!(deletion.detail.synced_source.is_none());
    assert!(deletion.local_version.is_none());
    assert!(deletion.detail.deleted_archive.is_some());
    assert_eq!(
        repo.history_file(&result.id, "delete.org", false)
            .await
            .unwrap()
            .source_bytes(),
        base
    );
    let detail = repo.history_detail(&result.id).await.unwrap();
    assert_eq!(detail.files.len(), 8);
    assert_eq!(
        detail
            .files
            .iter()
            .find(|f| f.path == "merge.org")
            .unwrap()
            .outcome,
        WebDavSyncFileOutcome::Merged
    );
    let again = sync(&mut repo, &policy, 3).await;
    assert_eq!(
        again
            .files
            .iter()
            .find(|f| f.relative_path == "delete.org")
            .unwrap()
            .outcome,
        Outcome::Unchanged
    );
    assert!(!root.join(".sync/history/3/deleted").exists());
    tokio::fs::write(
        root.join(".sync/history/2/deleted/delete.org/delete.org"),
        b"damaged",
    )
    .await
    .unwrap();
    assert!(
        repo.history_file(&result.id, "delete.org", false)
            .await
            .is_err()
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn remote_deletion_backs_up_empty_baseline_when_local_is_already_missing() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("empty.org", b"")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::remove_file(root.join("empty.org")).await.unwrap();
    state.lock().unwrap().files.clear();
    let result = sync(&mut repo, &policy, 2).await;
    assert_eq!(result.files[0].outcome, crate::OrgRepoSyncFileOutcome::Deleted);
    assert_eq!(tokio::fs::read(root.join(".sync/history/2/deleted/empty.org/empty.org")).await.unwrap(), b"");
    assert!(repo.history_file(&result.id, "empty.org", false).await.unwrap().source_bytes().is_empty());
    assert!(!root.join("empty.org").exists());
    assert!(result.files[0].detail.synced_source.is_none());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
#[tokio::test]
async fn task_ignore_does_not_change_upload_download_or_write_acknowledgement() {
    let (mut repo, root) = repo().await;
    tokio::fs::write(root.join(".orgzlyignore"), "local.org\nremote.org\n")
        .await
        .unwrap();
    offline(&mut repo, "local.org").await;
    let local = tokio::fs::read(root.join("local.org")).await.unwrap();
    let remote = b"* TODO Remote ignored task\r\n";
    let (policy, state, worker) = server(&[("remote.org", remote)]).await;
    let record = sync(&mut repo, &policy, 1).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(record.files.len(), 2);
    assert_eq!(state.lock().unwrap().files["local.org"].data, local);
    assert_eq!(
        tokio::fs::read(root.join("remote.org")).await.unwrap(),
        remote
    );
    assert_eq!(repo.load_files(&[]).await.unwrap().len(), 2);
    assert!(repo.pending_writes().await.unwrap().is_empty());
    assert!(crate::filter::tasks_from_repo(&repo).await.unwrap().is_empty());
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert_eq!(repo.load_files(&[]).await.unwrap().len(), 2);
    assert!(crate::filter::tasks_from_repo(&repo).await.unwrap().is_empty());
    tokio::fs::remove_file(root.join(".orgzlyignore"))
        .await
        .unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert_eq!(crate::filter::tasks_from_repo(&repo).await.unwrap().len(), 2);
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn sync_downloads_root_ignore_rules_and_applies_updates_and_removal() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[
        (".orgzlyignore", b"\xef\xbb\xbfann.org\r\n"),
        ("nested/.orgzlyignore", b"visible.org\n"),
        ("ann.org", b"* TODO Announcement\n"),
        ("visible.org", b"* TODO Visible\n"),
    ])
    .await;
    let record = sync(&mut repo, &policy, 1).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(repo.load_files(&[]).await.unwrap().len(), 2);
    assert!(!root.join("nested/.orgzlyignore").exists());
    assert_eq!(
        tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
        b"\xef\xbb\xbfann.org\r\n"
    );
    let query = crate::TaskQuery {
        expression: "s.none d.none".into(),
        include_done: false,
        ..Default::default()
    };
    let result = crate::OrgWorkspace::new(vec![repo.clone()])
        .unwrap()
        .query(&[(&query).into()]).await
        .unwrap().remove(0).into_task().unwrap();
    assert_eq!(result.tasks.len(), 1);
    assert_eq!(result.tasks[0].path(), "visible.org");
    assert!(
        crate::model::test_support::query_files(&repo).await.unwrap()
            .iter()
            .find(|file| file.path == "ann.org")
            .unwrap()
            .is_ignore
    );
    let rules = record
        .files
        .iter()
        .find(|file| file.relative_path == ".orgzlyignore")
        .unwrap();
    assert!(rules.detail.task_versions.is_none());
    assert_eq!(
        rules.detail.synced_source.as_deref(),
        Some("\u{feff}ann.org\r\n")
    );
    {
        let mut dav = state.lock().unwrap();
        let rules = dav.files.get_mut(".orgzlyignore").unwrap();
        rules.data = b"visible.org\n".to_vec();
        rules.etag = "\"v2\"".into();
    }
    assert_eq!(
        sync(&mut repo, &policy, 2).await.result,
        Some(OrgRepoSyncResult::Succeeded)
    );
    assert!(TaskScanRules::load(&root).await.unwrap().excludes("visible.org"));
    assert!(!TaskScanRules::load(&root).await.unwrap().excludes("ann.org"));
    state.lock().unwrap().files.remove(".orgzlyignore");
    assert_eq!(
        sync(&mut repo, &policy, 3).await.result,
        Some(OrgRepoSyncResult::Succeeded)
    );
    assert!(!root.join(".orgzlyignore").exists());
    assert!(!TaskScanRules::load(&root).await.unwrap().excludes("visible.org"));
    assert!(
        state
            .lock()
            .unwrap()
            .requests
            .iter()
            .all(|request| !request.starts_with("PUT /org/.orgzlyignore"))
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn sync_ignore_rules_preserves_local_edits_and_rejects_invalid_remote_content() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[(".orgzlyignore", b"ann.org\n")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(root.join(".orgzlyignore"), "local.org\n")
        .await
        .unwrap();
    assert!(
        repo.sync(
            &policy,
            2,
            &SyncCancellation::default(),
            &SyncProgressReporter::default()
        )
        .await
        .unwrap()
        .result
            == Some(OrgRepoSyncResult::Failed)
    );
    assert_eq!(
        tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
        b"local.org\n"
    );
    assert!(TaskScanRules::load(&root).await.unwrap().excludes("local.org"));
    tokio::fs::write(root.join(".orgzlyignore"), "ann.org\n")
        .await
        .unwrap();
    for (index, invalid) in [vec![0xff], b"[z-a]\n".to_vec()].into_iter().enumerate() {
        state
            .lock()
            .unwrap()
            .files
            .get_mut(".orgzlyignore")
            .unwrap()
            .data = invalid;
        assert!(
            repo.sync(
                &policy,
                3 + index as i64,
                &SyncCancellation::default(),
                &SyncProgressReporter::default()
            )
            .await
            .unwrap()
            .result
                == Some(OrgRepoSyncResult::Failed)
        );
        assert_eq!(
            tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
            b"ann.org\n"
        );
        assert!(TaskScanRules::load(&root).await.unwrap().excludes("ann.org"));
    }
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn sync_directory_filters_skip_transfers_and_can_be_overridden_per_call() {
    let (mut repo, root) = repo().await;
    let original = b"* TODO Local archive\r\n";
    tokio::fs::create_dir_all(root.join("archive"))
        .await
        .unwrap();
    tokio::fs::write(root.join("archive/local.org"), original)
        .await
        .unwrap();
    let (policy, state, worker) = server(&[
        ("archive/remote.org", b"* TODO Remote archive\n"),
        ("nested/archive/remote.org", b"* TODO Nested archive\n"),
        ("private/remote.org", b"* TODO Private\n"),
        ("archives/keep.org", b"* TODO Keep similar name\n"),
        ("keep.org", b"* TODO Keep\n"),
    ])
    .await;
    let first = sync(&mut repo, &policy, 1).await;
    assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(first.files.len(), 3);
    assert!(!root.join("archive/remote.org").exists());
    assert!(!root.join("nested/archive/remote.org").exists());
    assert!(root.join("private/remote.org").is_file());
    assert!(root.join("archives/keep.org").is_file());
    assert_eq!(
        tokio::fs::read(root.join("archive/local.org"))
            .await
            .unwrap(),
        original
    );
    assert!(
        !state
            .lock()
            .unwrap()
            .files
            .contains_key("archive/local.org")
    );
    assert!(
        state
            .lock()
            .unwrap()
            .requests
            .iter()
            .filter(|r| !r.starts_with("PROPFIND"))
            .all(|r| !r
                .split_whitespace()
                .nth(1)
                .unwrap()
                .split('/')
                .any(|part| part == "archive"))
    );

    // 自定义参数替换默认规则，仅对本次调用生效。
    let second = repo
        .sync_with_options(
            &policy,
            2,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
            crate::SyncOptions {
                excluded_directories: vec!["private".into()],
                ..crate::SyncOptions::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(second.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(second.files.len(), 5);
    assert!(
        second
            .files
            .iter()
            .all(|file| !file.relative_path.starts_with("private/"))
    );
    assert!(root.join("archive/remote.org").is_file());
    assert!(root.join("nested/archive/remote.org").is_file());
    assert_eq!(
        state.lock().unwrap().files["archive/local.org"].data,
        original
    );

    // 已有基线和待上传意图的目录被排除后也不能发生传输或误报远端删除。
    offline(&mut repo, "archive/local.org").await;
    state.lock().unwrap().files.remove("archive/local.org");
    let third = sync(&mut repo, &policy, 3).await;
    assert_eq!(third.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(third.files.len(), 3);
    assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
    assert!(
        !state
            .lock()
            .unwrap()
            .files
            .contains_key("archive/local.org")
    );

    let fourth = repo
        .sync_with_options(
            &policy,
            4,
            &SyncCancellation::default(),
            &SyncProgressReporter::default(),
            crate::SyncOptions {
                excluded_directories: Vec::new(),
                ..crate::SyncOptions::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(fourth.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(fourth.files.len(), 6);
    assert_eq!(
        fourth
            .files
            .iter()
            .find(|file| file.relative_path == "archive/local.org")
            .unwrap()
            .state,
        OrgRepoSyncFileState::Synchronized
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn first_sync_merges_existing_files_and_commits_one_sided_files_without_manual_file_conflicts()
 {
    let (mut repo, root) = repo().await;
    tokio::fs::write(root.join("local.org"), b"* TODO Local\n")
        .await
        .unwrap();
    tokio::fs::write(root.join("same.org"), b"* TODO Same\r\n")
        .await
        .unwrap();
    let (policy, state, worker) = server(&[
        ("remote.org", b"* TODO Remote\r\n"),
        ("same.org", b"* TODO Same\r\n"),
    ])
    .await;
    let first = sync(&mut repo, &policy, 1).await;
    assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(
        first
            .files
            .iter()
            .all(|f| f.state == OrgRepoSyncFileState::Synchronized)
    );
    assert!(root.join("remote.org").is_file());
    assert!(root.join(".sync/remote_base/current.json").is_file());
    assert_eq!(
        state.lock().unwrap().files["local.org"].data,
        b"* TODO Local\n"
    );
    let count = state.lock().unwrap().requests.len();
    sync(&mut repo, &policy, 2).await;
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .all(|r| !r.starts_with("GET") && !r.starts_with("PUT"))
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn first_sync_uploads_local_only_and_downloads_remote_only_files() {
    let (mut repo, root) = repo().await;
    offline(&mut repo, "local.org").await;
    let original = tokio::fs::read(root.join("local.org")).await.unwrap();
    let (policy, _, worker) = server(&[("remote.org", b"* TODO Remote\n")]).await;
    let first = sync(&mut repo, &policy, 1).await;
    assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(
        tokio::fs::read(root.join("local.org")).await.unwrap(),
        original
    );
    assert_eq!(
        tokio::fs::read(root.join("remote.org")).await.unwrap(),
        b"* TODO Remote\n"
    );
    assert!(repo.pending_writes().await.unwrap().is_empty());
    assert!(repo.file("remote.org").await.unwrap().modified_at.is_some());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
#[tokio::test]
async fn downloaded_file_todo_declarations_override_external_defaults_and_survive_reload() {
    let (mut repo, root) = repo().await;
    repo.set_todo_defaults(crate::TodoConfig::from_settings("#+TODO: GLOBAL | CLOSED").unwrap())
        .unwrap();
    let bytes = b"#+TODO: OPEN(o) | FINISHED(f!)\r\n* OPEN Pending\r\n* FINISHED Complete\r\n";
    let (policy, _, worker) = server(&[("inbox.org", bytes)]).await;
    let first = sync(&mut repo, &policy, 1).await;
    assert_eq!(first.result, Some(OrgRepoSyncResult::Succeeded));
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    let file = &repo.load_files(&[]).await.unwrap()[0];
    assert_eq!(file.source_bytes(), bytes);
    assert_eq!(file.todo.source, crate::TodoSource::InBuffer);
    assert_eq!(file.todo.initial_state.as_deref(), Some("OPEN"));
    assert_eq!(file.todo.done_keywords, ["FINISHED"]);
    let workspace = crate::OrgWorkspace::new(vec![repo]).unwrap();
    assert_eq!(
        workspace
            .query(&[(crate::TaskQuery {
                expression: "it.done".into(),
                ..Default::default()
            }).into()]).await
            .unwrap().remove(0).into_task().unwrap()
            .tasks
            .len(),
        1
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}
#[tokio::test]
async fn file_local_operations_replay_over_remote_and_only_modified_remote_files_download() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Work\r\n:PROPERTIES:\r\n:ID: stable\r\n:END:\r\nbase body\r\n";
    let (policy, state, worker) = server(&[("a.org", base), ("b.org", b"* Cached\n")]).await;
    sync(&mut repo, &policy, 1).await;
    let local = String::from_utf8(base.to_vec())
        .unwrap()
        .replace("TODO", "DONE");
    let remote = String::from_utf8(base.to_vec())
        .unwrap()
        .replace("base body", "remote body");
    tokio::fs::write(root.join("a.org"), &local).await.unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.insert(
            "a.org".into(),
            Remote {
                data: remote.into_bytes(),
                etag: "\"changed\"".into(),
            },
        );
    }
    let count = state.lock().unwrap().requests.len();
    let second = sync(&mut repo, &policy, 2).await;
    assert_eq!(second.result, Some(OrgRepoSyncResult::Succeeded));
    let expected = local.replace("base body", "remote body").into_bytes();
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), expected);
    assert_eq!(state.lock().unwrap().files["a.org"].data, expected);
    let dav = state.lock().unwrap();
    let requests = &dav.requests[count..];
    assert_eq!(requests.iter().filter(|r| r.starts_with("GET")).count(), 1);
    assert!(
        requests
            .iter()
            .any(|r| r.starts_with("PUT") && r.contains("if-match: \"changed\""))
    );
    drop(dav);
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn task_conflict_uploads_both_versions_remains_readable_and_does_not_block_new_sync() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Work\n:PROPERTIES:\n:ID: stable\n:END:\nbase\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(
        root.join("a.org"),
        String::from_utf8(base.to_vec())
            .unwrap()
            .replace("base", "local"),
    )
    .await
    .unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.insert(
            "a.org".into(),
            Remote {
                data: String::from_utf8(base.to_vec())
                    .unwrap()
                    .replace("base", "remote")
                    .into_bytes(),
                etag: "\"remote\"".into(),
            },
        );
    }
    let conflict = sync(&mut repo, &policy, 2).await;
    assert_eq!(conflict.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(conflict.files[0].state, OrgRepoSyncFileState::Conflict);
    let merged = tokio::fs::read(root.join("a.org")).await.unwrap();
    let text = String::from_utf8(merged.clone()).unwrap();
    assert!(text.contains("local"));
    assert!(text.contains("remote"));
    assert!(text.contains("* 同步冲突 :CONFLICT:"));
    assert_eq!(state.lock().unwrap().files["a.org"].data, merged);
    let archived = root.join(".sync/history/2/conflicts/a.org/a.org");
    assert_eq!(tokio::fs::read(&archived).await.unwrap(), merged);
    let detail = repo.history_detail(&conflict.id).await.unwrap();
    assert_eq!(detail.summary.conflicts.len(), 1);
    assert!(detail.files[0].backup.is_none());
    assert_eq!(
        repo.history_file(&conflict.id, "a.org", false)
            .await
            .unwrap()
            .source_bytes(),
        merged
    );
    let count = state.lock().unwrap().requests.len();
    let next = sync(&mut repo, &policy, 3).await;
    assert_eq!(next.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), merged);
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .all(|r| !r.starts_with("PUT"))
    );
    assert_eq!(crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().into_iter().filter(|notice| matches!(notice, crate::CoreNotification::SyncConflict(_))).collect::<Vec<_>>().len(), 1);
    // 外部编辑移除完整冲突容器，下一次同步照常上传本地修改。
    let clean = crate::model::conflict::main_source(&repo.file("a.org").await.unwrap());
    tokio::fs::write(root.join("a.org"), clean)
        .await
        .unwrap();
    repo.load::<WebDavSyncPolicy>().await.unwrap();
    assert!(crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().into_iter().filter(|notice| matches!(notice, crate::CoreNotification::SyncConflict(_))).collect::<Vec<_>>().is_empty());
    sync(&mut repo, &policy, 4).await;
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    assert_eq!(tokio::fs::read(archived).await.unwrap(), merged);
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn ordinary_upload_needs_no_archive_and_remote_modification_overrides_local_deletion() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* TODO Remote\n")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(root.join("a.org"), b"* TODO Local\n")
        .await
        .unwrap();
    tokio::fs::write(root.join(".sync/history/2"), b"not a directory")
        .await
        .unwrap();
    let count = state.lock().unwrap().requests.len();
    let upload = sync(&mut repo, &policy, 2).await;
    assert_eq!(upload.files[0].state, OrgRepoSyncFileState::Synchronized);
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .any(|r| r.starts_with("PUT"))
    );
    tokio::fs::remove_file(root.join(".sync/history/2"))
        .await
        .unwrap();
    tokio::fs::remove_file(root.join("a.org")).await.unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.insert(
            "a.org".into(),
            Remote {
                data: b"* TODO Changed remote\n".to_vec(),
                etag: "\"changed\"".into(),
            },
        );
    }
    let downloaded = sync(&mut repo, &policy, 3).await;
    assert_eq!(
        downloaded.files[0].action,
        OrgRepoSyncFileAction::Downloaded
    );
    assert_eq!(
        tokio::fs::read(root.join("a.org")).await.unwrap(),
        b"* TODO Changed remote\n"
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn failed_merge_preserves_working_files_and_publishes_confirmed_remote_snapshot() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[
        (".orgzlyignore", b"old.org\n"),
        ("a.org", b"* TODO Old A\n"),
        ("b.org", b"* TODO Old B\n"),
        ("z.org", b"* TODO Old Z\n"),
    ])
    .await;
    let first = sync(&mut repo, &policy, 1).await;
    offline(&mut repo, "b.org").await;
    let before_b = tokio::fs::read(root.join("b.org")).await.unwrap();
    let before_base = tokio::fs::read(root.join(".sync/remote_base/current.json"))
        .await
        .unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.get_mut("a.org").unwrap().data = b"* TODO New A\n".to_vec();
        dav.files.get_mut("a.org").unwrap().etag = "\"a-new\"".into();
        dav.files.remove("b.org");
        dav.files.get_mut(".orgzlyignore").unwrap().data = b"new.org\n".to_vec();
        dav.files.get_mut(".orgzlyignore").unwrap().etag = "\"rules-new\"".into();
        dav.files.get_mut("z.org").unwrap().data = vec![0xff];
        dav.files.get_mut("z.org").unwrap().etag = "\"z-bad\"".into();
    }
    let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let captured = events.clone();
    let workspace = crate::OrgWorkspace::new(vec![repo.clone()]).unwrap();
    let subscription = workspace.watch_notifications(move |event| {
        if matches!(event, crate::NotificationUpdate::RepositoryChanged { .. }) {
            captured.lock().unwrap().push(event);
        }
    });
    let failed = sync(&mut repo, &policy, 2).await;
    assert_eq!(
        events.lock().unwrap().len(),
        1,
        "失败日志提交也应广播通知更新"
    );
    drop(subscription);
    assert_eq!(failed.result, Some(OrgRepoSyncResult::Failed));
    assert!(!root.join(".sync/history/2/deleted").exists());
    assert_eq!(
        tokio::fs::read(root.join("a.org")).await.unwrap(),
        b"* TODO Old A\n"
    );
    assert_eq!(tokio::fs::read(root.join("b.org")).await.unwrap(), before_b);
    assert_eq!(
        tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
        b"old.org\n"
    );
    assert!(TaskScanRules::load(&root).await.unwrap().excludes("old.org"));
    assert!(!TaskScanRules::load(&root).await.unwrap().excludes("new.org"));
    assert_eq!(repo.last_effect_sync().await.unwrap().unwrap().id, first.id);
    assert!(repo.history_file(&failed.id, "a.org", false).await.is_err());
    let before: serde_json::Value = serde_json::from_slice(&before_base).unwrap();
    assert_eq!(baseline_index(&root).await["local"], before["local"]);
    assert_eq!(baseline_source(&root, "a.org", false).await.unwrap(), b"* TODO New A\n");
    assert_eq!(baseline_source(&root, "b.org", false).await, None);
    assert_eq!(baseline_source(&root, "z.org", false).await.unwrap(), vec![0xff]);
    assert_eq!(baseline_source(&root, "a.org", true).await.unwrap(), b"* TODO Old A\n");
    assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
    {
        let mut dav = state.lock().unwrap();
        dav.files.get_mut("z.org").unwrap().data = b"* TODO Fixed\n".to_vec();
        dav.files.get_mut("z.org").unwrap().etag = "\"z-good\"".into();
    }
    let success = sync(&mut repo, &policy, 3).await;
    assert_eq!(success.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(
        tokio::fs::read(root.join("a.org")).await.unwrap(),
        b"* TODO New A\n"
    );
    assert!(!root.join("b.org").exists());
    assert_eq!(
        tokio::fs::read(root.join(".orgzlyignore")).await.unwrap(),
        b"new.org\n"
    );
    assert!(repo.pending_writes().await.unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn successful_finish_observes_committed_files_baseline_conflicts_and_history() {
    struct ObserveFinish {
        root: std::path::PathBuf,
        snapshots: Arc<Mutex<Vec<Vec<Vec<u8>>>>>,
    }
    impl WebDavSyncMonitor for ObserveFinish {
        fn on_event(&self, event: WebDavSyncEvent) {
            if !matches!(
                event,
                WebDavSyncEvent::Finished {
                    result: OrgRepoSyncResult::Succeeded,
                    ..
                }
            ) {
                return;
            }
            let read = |path| std::fs::read(self.root.join(path)).unwrap_or_default();
            let index: serde_json::Value =
                serde_json::from_slice(&read(".sync/remote_base/current.json".into()))
                    .unwrap_or_default();
            let revision = index["entries"]["a.org"]["revision"]
                .as_str()
                .unwrap_or("missing");
            let history: serde_json::Value =
                serde_json::from_slice(&read(".sync/history/2.json".into())).unwrap_or_default();
            self.snapshots.lock().unwrap().push(vec![
                read("a.org".into()),
                read(format!(".sync/remote_base/generations/{revision}/files/a.org")),
                read(".sync/history/2/conflicts/a.org/a.org".into()),
                history["files"][0]["detail"]["synced_source"]
                    .as_str()
                    .unwrap_or_default()
                    .as_bytes()
                    .to_vec(),
            ]);
        }
    }
    let (mut repo, root) = repo().await;
    let base = b"* TODO Work\n:PROPERTIES:\n:ID: stable\n:END:\nbase\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(
        root.join("a.org"),
        String::from_utf8_lossy(base).replace("base", "local"),
    )
    .await
    .unwrap();
    state.lock().unwrap().files.insert(
        "a.org".into(),
        Remote {
            data: String::from_utf8_lossy(base)
                .replace("base", "remote")
                .into_bytes(),
            etag: "\"changed\"".into(),
        },
    );
    let snapshots = Arc::new(Mutex::new(Vec::new()));
    let policy = policy.with_monitor(ObserveFinish {
        root: root.clone(),
        snapshots: snapshots.clone(),
    });
    let record = sync(&mut repo, &policy, 2).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(record.files[0].state, OrgRepoSyncFileState::Conflict);
    let remote = state.lock().unwrap().files["a.org"].data.clone();
    assert_eq!(
        *snapshots.lock().unwrap(),
        vec![vec![remote.clone(); 4]],
        "成功事件必须晚于所有正式文件的提交"
    );
    let current = repo.file("a.org").await.unwrap();
    assert!(
        String::from_utf8_lossy(&crate::model::conflict::main_source(&current)).contains("remote")
    );
    let points = crate::model::conflict::points(&current).unwrap();
    assert_eq!(points.len(), 1);
    assert!(points[0].source.contains("local"));
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn history_persist_failure_preserves_working_files_and_confirmed_remote_base() {
    struct RejectHistory {
        target: std::path::PathBuf,
        finished: Arc<Mutex<Vec<OrgRepoSyncResult>>>,
    }
    impl WebDavSyncMonitor for RejectHistory {
        fn on_event(&self, event: WebDavSyncEvent) {
            if matches!(event, WebDavSyncEvent::FileProcessed { .. }) {
                std::fs::write(&self.target, b"occupied").unwrap();
            }
            if let WebDavSyncEvent::Finished { result, .. } = event {
                self.finished.lock().unwrap().push(result);
            }
        }
    }
    let (mut repo, root) = repo().await;
    let (policy, _, worker) = server(&[("a.org", b"* TODO Download\n")]).await;
    let finished = Arc::new(Mutex::new(Vec::new()));
    let policy = policy.with_monitor(RejectHistory {
        target: root.join(".sync/history/1.json"),
        finished: finished.clone(),
    });
    let progress = SyncProgressReporter::default();
    let result = repo
        .sync(&policy, 1, &SyncCancellation::default(), &progress)
        .await;
    assert!(result.is_err());
    assert!(
        finished.lock().unwrap().is_empty(),
        "提交失败不能发布完成事件"
    );
    assert_ne!(progress.snapshot().stage, "Finished");
    assert!(!root.join("a.org").exists());
    assert!(baseline_source(&root, "a.org", false).await.is_some());
    assert!(baseline_source(&root, "a.org", true).await.is_none());
    assert!(!root.join(".sync/history/1").exists());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn cancelled_after_publication_keeps_remote_snapshot_and_old_local_ancestor() {
    struct CancelAfterDownload {
        token: SyncCancellation,
    }
    impl WebDavSyncMonitor for CancelAfterDownload {
        fn on_event(&self, event: WebDavSyncEvent) {
            if matches!(event, WebDavSyncEvent::FileProcessed { .. }) {
                self.token.cancel();
            }
        }
    }
    let (mut repo, root) = repo().await;
    let (policy, _, worker) = server(&[("a.org", b"* TODO A\n"), ("b.org", b"* TODO B\n")]).await;
    let token = SyncCancellation::default();
    let policy = policy.with_monitor(CancelAfterDownload {
        token: token.clone(),
    });
    let record = repo
        .sync(&policy, 1, &token, &SyncProgressReporter::default())
        .await
        .unwrap();
    assert_eq!(record.result, Some(OrgRepoSyncResult::Cancelled));
    assert!(!root.join("a.org").exists());
    assert!(!root.join("b.org").exists());
    assert!(baseline_source(&root, "a.org", false).await.is_some());
    assert!(baseline_source(&root, "a.org", true).await.is_none());
assert!(baseline_source(&root, "b.org", false).await.is_some());
    assert!(baseline_source(&root, "b.org", true).await.is_none());
    assert!(repo.last_effect_sync().await.unwrap().is_none());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn executing_a_stale_snapshot_never_overwrites_an_external_local_edit() {
    struct EditAfterNetwork {
        path: std::path::PathBuf,
    }
    impl WebDavSyncMonitor for EditAfterNetwork {
        fn on_event(&self, event: WebDavSyncEvent) {
            if matches!(event, WebDavSyncEvent::FileProcessed { .. }) {
                std::fs::write(&self.path, b"* External edit\n").unwrap();
            }
        }
    }
    let (mut repo, root) = repo().await;
    let (policy, _, worker) = server(&[("a.org", b"* Download\n")]).await;
    let policy = policy.with_monitor(EditAfterNetwork {
        path: root.join("a.org"),
    });
    assert!(
        repo.sync(
            &policy,
            1,
            &SyncCancellation::default(),
            &SyncProgressReporter::default()
        )
        .await
        .is_err()
    );
    assert_eq!(
        tokio::fs::read(root.join("a.org")).await.unwrap(),
        b"* External edit\n"
    );
    assert!(baseline_source(&root, "a.org", false).await.is_some());
    assert!(baseline_source(&root, "a.org", true).await.is_none());
    assert!(!root.join(".sync/history/1.json").exists());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn failed_remote_write_never_consumes_outbox_or_changes_remote_base() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[]).await;
    offline(&mut repo, "a.org").await;
    sync(&mut repo, &policy, 1).await;
    let baseline = tokio::fs::read(root.join(".sync/remote_base/current.json"))
        .await
        .unwrap();
    offline(&mut repo, "a.org").await;
    let local = tokio::fs::read(root.join("a.org")).await.unwrap();
    let intents = repo.pending_writes().await.unwrap();
    state.lock().unwrap().reject.insert("a.org".into());
    let failed = sync(&mut repo, &policy, 2).await;
    assert_eq!(failed.result, Some(OrgRepoSyncResult::Failed));
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), local);
    assert_eq!(repo.pending_writes().await.unwrap(), intents);
    assert_eq!(
        tokio::fs::read(root.join(".sync/remote_base/current.json"))
            .await
            .unwrap(),
        baseline
    );
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    state.lock().unwrap().reject.clear();
    let retry = sync(&mut repo, &policy, 3).await;
    assert_eq!(retry.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(repo.pending_writes().await.unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn changed_remote_during_backup_is_retryable_without_an_unresolvable_conflict() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* TODO Base\n")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(root.join("a.org"), b"* TODO Local\n")
        .await
        .unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.insert(
            "a.org".into(),
            Remote {
                data: b"* TODO Remote\n".to_vec(),
                etag: "\"new\"".into(),
            },
        );
        dav.reject_get.insert("a.org".into());
    }
    let failed = sync(&mut repo, &policy, 2).await;
    assert_eq!(failed.result, Some(OrgRepoSyncResult::Failed));
    assert!(!history_is_conflict(&failed.files[0]));
    assert!(failed.files[0].error.as_ref().unwrap().retryable);
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    assert!(!root.join(".sync/history/2/conflicts").exists());
    assert_eq!(
        tokio::fs::read(root.join("a.org")).await.unwrap(),
        b"* TODO Local\n"
    );
    state.lock().unwrap().reject_get.clear();
    let retried = sync(&mut repo, &policy, 3).await;
    assert_eq!(retried.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(
        String::from_utf8_lossy(&tokio::fs::read(root.join("a.org")).await.unwrap())
            .contains("Local")
    );
    assert!(
        String::from_utf8_lossy(&tokio::fs::read(root.join("a.org")).await.unwrap())
            .contains("Remote")
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn remote_base_is_bound_to_remote_origin_and_detects_missing_cached_content() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* Base\n")]).await;
    sync(&mut repo, &policy, 1).await;
    let (other, _, second_worker) = server(&[("a.org", b"* Other\n")]).await;
    let before = tokio::fs::read(root.join("a.org")).await.unwrap();
    assert!(
        repo.sync(
            &other,
            2,
            &SyncCancellation::default(),
            &SyncProgressReporter::default()
        )
        .await
        .is_err()
    );
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), before);
    let index: serde_json::Value = serde_json::from_slice(
        &tokio::fs::read(root.join(".sync/remote_base/current.json"))
            .await
            .unwrap(),
    )
    .unwrap();
    let revision = index["entries"]["a.org"]["revision"].as_str().unwrap();
    tokio::fs::remove_file(root.join(format!(".sync/remote_base/generations/{revision}/files/a.org")))
        .await
        .unwrap();
    let count = state.lock().unwrap().requests.len();
    assert!(
        repo.sync(
            &policy,
            3,
            &SyncCancellation::default(),
            &SyncProgressReporter::default()
        )
        .await
        .is_err()
    );
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .all(|r| !r.starts_with("PUT") && !r.starts_with("DELETE"))
    );
    worker.abort();
    second_worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn complete_recursive_listing_preserves_nested_files_and_skips_filtered_directories() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[
        ("root.org", b"* Root\n"),
        ("nested/a.org", b"* Nested\n"),
        ("nested/deep/b.org", b"* Deep\n"),
        ("archive/c.org", b"* Filtered\n"),
        (".sync/private.org", b"* Control\n"),
    ])
    .await;
    state.lock().unwrap().hierarchical = true;
    let record = sync(&mut repo, &policy, 1).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(root.join("nested/a.org").is_file());
    assert!(root.join("nested/deep/b.org").is_file());
    assert!(!root.join("archive/c.org").exists());
    let dav = state.lock().unwrap();
    assert!(
        dav.requests
            .iter()
            .any(|r| r.starts_with("PROPFIND /org/nested/ "))
    );
    assert!(
        dav.requests
            .iter()
            .any(|r| r.starts_with("PROPFIND /org/nested/deep/ "))
    );
    assert!(
        dav.requests
            .iter()
            .all(|r| !r.contains("/org/archive/") && !r.contains("/org/.sync/"))
    );
    drop(dav);
    tokio::fs::write(root.join("nested/a.org"), b"* Local edit\n")
        .await
        .unwrap();
    // 列举不完整不能把原远端误判为删除；整仓库没有后续提交。
    let baseline = tokio::fs::read(root.join(".sync/remote_base/current.json"))
        .await
        .unwrap();
    state.lock().unwrap().invalid_listing = true;
    assert_eq!(
        sync(&mut repo, &policy, 2).await.result,
        Some(OrgRepoSyncResult::Failed)
    );
    assert_eq!(
        tokio::fs::read(root.join("nested/a.org")).await.unwrap(),
        b"* Local edit\n"
    );
    assert_eq!(
        tokio::fs::read(root.join(".sync/remote_base/current.json"))
            .await
            .unwrap(),
        baseline
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn successful_remote_write_before_a_later_failure_is_reconciled_on_retry() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[]).await;
    offline(&mut repo, "a.org").await;
    offline(&mut repo, "z.org").await;
    let intents = repo.pending_writes().await.unwrap();
    state.lock().unwrap().reject.insert("z.org".into());
    let failed = sync(&mut repo, &policy, 1).await;
    assert_eq!(failed.result, Some(OrgRepoSyncResult::Failed));
    assert!(state.lock().unwrap().files.contains_key("a.org"));
    assert_eq!(baseline_source(&root, "a.org", false).await.unwrap(), tokio::fs::read(root.join("a.org")).await.unwrap());
    assert!(baseline_source(&root, "a.org", true).await.is_none());
    assert!(baseline_source(&root, "z.org", false).await.is_none());
    assert_eq!(repo.pending_writes().await.unwrap(), intents);
    state.lock().unwrap().reject.clear();
    let count = state.lock().unwrap().requests.len();
    let retry = sync(&mut repo, &policy, 2).await;
    assert_eq!(retry.result, Some(OrgRepoSyncResult::Succeeded));
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .all(|r| !r.starts_with("PUT /org/a.org "))
    );
    assert!(repo.pending_writes().await.unwrap().is_empty());
    assert_eq!(
        state.lock().unwrap().files["a.org"].data,
        tokio::fs::read(root.join("a.org")).await.unwrap()
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn only_local_file_deletion_is_conditional_and_both_missing_updates_the_tombstone() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* Base\n")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::remove_file(root.join("a.org")).await.unwrap();
    let record = sync(&mut repo, &policy, 2).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(
        record.files[0].outcome,
        crate::OrgRepoSyncFileOutcome::Deleted
    );
    assert!(!state.lock().unwrap().files.contains_key("a.org"));
    assert!(
        state
            .lock()
            .unwrap()
            .requests
            .iter()
            .any(|r| r.starts_with("DELETE") && r.contains("if-match: \"v1\""))
    );
    let index: serde_json::Value = serde_json::from_slice(
        &tokio::fs::read(root.join(".sync/remote_base/current.json"))
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(index["entries"]["a.org"]["hash"].is_null());
    assert_eq!(
        sync(&mut repo, &policy, 3).await.result,
        Some(OrgRepoSyncResult::Succeeded)
    );
    // 基线中的路径即使两端都缺失也继续被正确确认，不重新创建空文件。
    assert!(!root.join("a.org").exists());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn missing_or_weak_etags_block_mutation_before_any_remote_upload() {
    let (mut repo, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* Base\n")]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(root.join("a.org"), b"* Local\n")
        .await
        .unwrap();
    state.lock().unwrap().files.get_mut("a.org").unwrap().etag = "W/\"same\"".into();
    let baseline = tokio::fs::read(root.join(".sync/remote_base/current.json"))
        .await
        .unwrap();
    let count = state.lock().unwrap().requests.len();
    let failed = sync(&mut repo, &policy, 2).await;
    assert_eq!(failed.result, Some(OrgRepoSyncResult::Failed));
    assert!(
        state.lock().unwrap().requests[count..]
            .iter()
            .all(|r| !r.starts_with("PUT") && !r.starts_with("DELETE"))
    );
    let before: serde_json::Value = serde_json::from_slice(&baseline).unwrap();
    assert_eq!(baseline_index(&root).await["local"], before["local"]);
    assert_eq!(baseline_index(&root).await["entries"]["a.org"]["version"]["etag"], "W/\"same\"");
    assert_eq!(baseline_source(&root, "a.org", false).await.unwrap(), b"* Base\n");
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn discard_operations_preserve_fixed_history_and_require_sync_until_baseline_is_confirmed() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Work\n:PROPERTIES:\n:ID: stable\n:END:\nbase\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(root.join("a.org"), String::from_utf8(base.to_vec()).unwrap().replace("base", "local")).await.unwrap();
    let remote = String::from_utf8(base.to_vec()).unwrap().replace("base", "remote");
    state.lock().unwrap().files.insert("a.org".into(), Remote {data:remote.as_bytes().to_vec(),etag:"\"remote\"".into()});
    let conflict = sync(&mut repo, &policy, 2).await;
    let original_history = tokio::fs::read(root.join(".sync/history/2.json")).await.unwrap();
    let original_base = tokio::fs::read(root.join(".sync/remote_base/current.json")).await.unwrap();
    assert!(!crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
    let file = repo.file("a.org").await.unwrap();
    let group = crate::TaskOperationGroup {
        operations: file.conflict_ids().into_iter().map(|id|crate::TaskOperation::ConfilictSelection(crate::TaskConfilictSelection{path:None,target:None,id,action:crate::TaskConfilictAction::Discard})).collect(),
        file_versions:vec![crate::TaskFileVersion{repo_id:repo.id.clone(),file:"a.org".into(),version:LocalFileVersion::from_bytes(file.source_bytes()).content_hash}],
        queue_repo_ids:vec![repo.id.clone()],
    };
    let count=state.lock().unwrap().requests.len();
    let mut workspace=crate::OrgWorkspace::new(vec![repo]).unwrap();
    workspace.execute_task_operations(&group).await.unwrap();
    assert_eq!(state.lock().unwrap().requests.len(),count);
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(),remote.as_bytes());
    assert_eq!(tokio::fs::read(root.join(".sync/history/2.json")).await.unwrap(),original_history);
    assert_eq!(tokio::fs::read(root.join(".sync/remote_base/current.json")).await.unwrap(),original_base);
    let notices=workspace.query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap();
    assert_eq!(notices,vec![crate::CoreNotification::SyncRequired]);
    repo=workspace.repos.remove(0);
    let detail=repo.history_detail(&conflict.id).await.unwrap();
    assert_eq!(detail.files[0].outcome,WebDavSyncFileOutcome::Conflict);
    assert!(detail.files[0].backup.is_none());
    assert!(!root.join(".sync/history/2/conflicts/a.org/a.resolved.org").exists());
    sync(&mut repo,&policy,3).await;
    assert!(!crate::OrgWorkspace::new(vec![repo.clone()]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().iter().any(|notice| matches!(notice, crate::CoreNotification::SyncRequired)));
    assert!(crate::OrgWorkspace::new(vec![repo]).unwrap().query(&[crate::CoreQuery::Notification { query: Default::default() }]).await.unwrap().remove(0).into_notifications().unwrap().is_empty());
    assert_eq!(tokio::fs::read(root.join(".sync/history/2.json")).await.unwrap(),original_history);
    worker.abort();tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn setupfile_todo_context_is_read_from_snapshots_without_temporary_repository_writes() {
    let (mut repo, root) = repo().await;
    let task=b"#+SETUPFILE: ./.setup.org\r\n* OPEN Work\r\n:PROPERTIES:\r\n:ID: stable\r\n:END:\r\nbase\r\n";
    let (policy, state, worker) = server(&[
        (".setup.org", b"#+TODO: OPEN | FINISHED\n"),
        ("a.org", task),
    ])
    .await;
    sync(&mut repo, &policy, 1).await;
    let local = String::from_utf8(task.to_vec())
        .unwrap()
        .replace("* OPEN", "* FINISHED");
    tokio::fs::write(root.join("a.org"), &local).await.unwrap();
    {
        let mut dav = state.lock().unwrap();
        dav.files.insert(
            "a.org".into(),
            Remote {
                data: String::from_utf8(task.to_vec())
                    .unwrap()
                    .replace("base", "remote")
                    .into_bytes(),
                etag: "\"changed\"".into(),
            },
        );
    }
    let record = sync(&mut repo, &policy, 2).await;
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    assert_eq!(
        repo.file("a.org").await.unwrap().source_bytes(),
        local.replace("base", "remote").as_bytes()
    );
    assert_eq!(
        repo.file("a.org").await.unwrap().todo.done_keywords,
        vec!["FINISHED"]
    );
    assert!(repo.pending_sync_conflicts().await.unwrap().is_empty());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn downloads_release_repository_lock_and_merge_reads_edits_made_during_network() {
    let (mut source, root) = repo().await;
    let initial = b"* TODO A\n:PROPERTIES:\n:ID: a\n:END:\nold body\n";
    let (policy, state, worker) = server(&[("a.org", initial)]).await;
    sync(&mut source, &policy, 1).await;
    {
        let mut dav = state.lock().unwrap();
        let file = dav.files.get_mut("a.org").unwrap();
        file.data = b"* TODO A\n:PROPERTIES:\n:ID: a\n:END:\nremote body\n".to_vec();
        file.etag = "\"changed\"".into();
    }
    let entered = Arc::new(tokio::sync::Notify::new());
    let resume = Arc::new(tokio::sync::Notify::new());
    state.lock().unwrap().pause = Some(("GET".into(), entered.clone(), resume.clone()));
    let syncing = tokio::spawn(async move {
        source.sync(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default()).await
    });
    tokio::time::timeout(std::time::Duration::from_secs(3), entered.notified()).await.unwrap();
    let mut reader = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(1), reader.load::<WebDavSyncPolicy>()).await.unwrap().unwrap();
    assert!(root.join("sync").exists());
    let file = reader.file("a.org").await.unwrap();
    let task = crate::filter::tasks_from_repo(&reader).await.unwrap().remove(0);
    let mut workspace = crate::OrgWorkspace::new(vec![reader]).unwrap();
    let group = crate::TaskOperationGroup {
        operations: vec![crate::TaskOperation::Modification(crate::TaskModificationOperation {
            path: task.full_path().clone(),
            modifications: vec![crate::TaskModification::Todo(Some("DONE".into()))],
        })],
        file_versions: vec![crate::TaskFileVersion { repo_id: file.repo_id.clone(), file: file.path.clone(),
            version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash }],
        queue_repo_ids: vec![file.repo_id.clone()],
    };
    tokio::time::timeout(std::time::Duration::from_secs(1), workspace.execute_task_operations(&group)).await.unwrap().unwrap();
    resume.notify_one();
    let record = syncing.await.unwrap().unwrap();
    assert_eq!(record.result, Some(OrgRepoSyncResult::Succeeded));
    let content = tokio::fs::read_to_string(root.join("a.org")).await.unwrap();
    assert!(content.starts_with("* DONE A\n"), "{content}");
    assert!(content.contains("remote body"), "{content}");
    assert!(!root.join("sync").exists());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn uploads_release_repository_lock_and_never_overwrite_newer_local_versions() {
    let (mut source, root) = repo().await;
    let (policy, state, worker) = server(&[("a.org", b"* TODO Original\n")]).await;
    sync(&mut source, &policy, 1).await;
    tokio::fs::write(root.join("a.org"), b"* TODO Upload this\n").await.unwrap();
    let baseline = tokio::fs::read(root.join(".sync/remote_base/current.json")).await.unwrap();
    let entered = Arc::new(tokio::sync::Notify::new());
    let resume = Arc::new(tokio::sync::Notify::new());
    state.lock().unwrap().pause = Some(("PUT".into(), entered.clone(), resume.clone()));
    let syncing = tokio::spawn(async move {
        source.sync(&policy, 2, &SyncCancellation::default(), &SyncProgressReporter::default()).await
    });
    tokio::time::timeout(std::time::Duration::from_secs(3), entered.notified()).await.unwrap();
    let guard = tokio::time::timeout(std::time::Duration::from_secs(1), super::transaction::lock(&root)).await.unwrap().unwrap();
    tokio::fs::write(root.join("a.org"), b"* TODO Newer local edit\n").await.unwrap();
    drop(guard);
    resume.notify_one();
    assert!(syncing.await.unwrap().is_err());
    assert_eq!(tokio::fs::read(root.join("a.org")).await.unwrap(), b"* TODO Newer local edit\n");
    let before: serde_json::Value = serde_json::from_slice(&baseline).unwrap();
    assert_eq!(baseline_index(&root).await["local"], before["local"]);
    assert_eq!(baseline_source(&root, "a.org", true).await.unwrap(), b"* TODO Original\n");
    assert_eq!(baseline_source(&root, "a.org", false).await.unwrap(), b"* TODO Upload this\n");
    assert!(!root.join(".sync/history/2.json").exists());
    assert_eq!(state.lock().unwrap().files["a.org"].data, b"* TODO Upload this\n");
    let mut reader = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
    reader.load::<WebDavSyncPolicy>().await.unwrap();
    assert!(root.join("sync").exists());
    reader.load_files(&[]).await.unwrap();
    assert!(!root.join("sync").exists());
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn retry_after_local_commit_failure_keeps_the_old_ancestor_and_remote_state_change() {
    let (mut repo, root) = repo().await;
    let base = b"* TODO Task\n:PROPERTIES:\n:ID: stable\n:END:\nold note\n";
    let (policy, state, worker) = server(&[("a.org", base)]).await;
    sync(&mut repo, &policy, 1).await;
    tokio::fs::write(
        root.join("a.org"),
        String::from_utf8_lossy(base).replace("old note", "local note"),
    )
    .await
    .unwrap();
    state.lock().unwrap().files.insert(
        "a.org".into(),
        Remote {
            data: String::from_utf8_lossy(base)
                .replace("TODO", "DONE")
                .into_bytes(),
            etag: "\"changed\"".into(),
        },
    );
    struct EditAfterUpload(std::path::PathBuf);
    impl WebDavSyncMonitor for EditAfterUpload {
        fn on_event(&self, event: WebDavSyncEvent) {
            if matches!(event, WebDavSyncEvent::FileProcessed { .. }) {
                let local = std::fs::read_to_string(&self.0).unwrap();
                std::fs::write(&self.0, local.replace("local note", "newer local note")).unwrap();
            }
        }
    }
    let policy = policy.with_monitor(EditAfterUpload(root.join("a.org")));
    assert!(
        repo.sync(
            &policy,
            2,
            &SyncCancellation::default(),
            &SyncProgressReporter::default()
        )
        .await
        .is_err()
    );
    assert_eq!(baseline_source(&root, "a.org", true).await.unwrap(), base);
    let confirmed = baseline_source(&root, "a.org", false).await.unwrap();
    assert_eq!(confirmed, state.lock().unwrap().files["a.org"].data);
    assert!(String::from_utf8_lossy(&confirmed).contains("* DONE Task"));
    let policy = policy.with_monitor(NoopWebDavSyncMonitor);
    let mut reopened = OrgRepo::new(root.to_string_lossy().into()).unwrap();
    reopened.load::<WebDavSyncPolicy>().await.unwrap();
    assert_eq!(
        sync(&mut reopened, &policy, 3).await.result,
        Some(OrgRepoSyncResult::Succeeded)
    );
    let text = tokio::fs::read_to_string(root.join("a.org")).await.unwrap();
    assert!(text.contains("* DONE Task"), "{text}");
    assert!(text.contains("newer local note"), "{text}");
    assert_eq!(text.as_bytes(), state.lock().unwrap().files["a.org"].data);
    assert_eq!(
        baseline_source(&root, "a.org", false).await.unwrap(),
        text.as_bytes()
    );
    worker.abort();
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn uploaded_bytes_without_response_etag_are_read_back_and_paired_with_actual_version() {
    for transformed in [false, true] {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[]).await;
        tokio::fs::write(root.join("a.org"), b"* TODO Local\n")
            .await
            .unwrap();
        {
            let mut dav = state.lock().unwrap();
            dav.omit_put_etag = true;
            if transformed {
                dav.transform_put
                    .insert("a.org".into(), b"* TODO Transformed\n".to_vec());
            }
        }
        let result = sync(&mut repo, &policy, 1).await;
        assert_eq!(
            result.result,
            Some(if transformed {
                OrgRepoSyncResult::Failed
            } else {
                OrgRepoSyncResult::Succeeded
            })
        );
        let bytes = baseline_source(&root, "a.org", false).await.unwrap();
        let index = baseline_index(&root).await;
        let id = index["generation"].as_str().unwrap();
        let metadata: serde_json::Value = serde_json::from_slice(
            &tokio::fs::read(root.join(format!(
                ".sync/remote_base/generations/{id}/files/a.org.meta.json"
            )))
            .await
            .unwrap(),
        )
        .unwrap();
        let dav = state.lock().unwrap();
        assert_eq!(bytes, dav.files["a.org"].data);
        assert_eq!(metadata["version"]["etag"], dav.files["a.org"].etag);
        assert_eq!(
            metadata["hash"],
            LocalFileVersion::from_bytes(&bytes).content_hash
        );
        assert_eq!(metadata["version"]["size"], bytes.len());
        assert!(dav.requests.iter().any(|r| r.starts_with("GET ")));
        drop(dav);
        if transformed {
            assert_eq!(
                tokio::fs::read(root.join("a.org")).await.unwrap(),
                b"* TODO Local\n"
            );
            assert!(baseline_source(&root, "a.org", true).await.is_none());
        }
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}

#[tokio::test]
async fn downloaded_content_uses_the_get_response_etag_and_rejects_strong_version_mismatch() {
    for weak in [true, false] {
        let (mut repo, root) = repo().await;
        let (policy, state, worker) = server(&[("a.org", b"* TODO Remote\n")]).await;
        {
            let mut dav = state.lock().unwrap();
            dav.files.get_mut("a.org").unwrap().etag =
                if weak { "W/\"listed\"" } else { "\"listed\"" }.into();
            dav.get_etag.insert("a.org".into(), "\"actual\"".into());
        }
        let result = sync(&mut repo, &policy, 1).await;
        if weak {
            assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
            assert_eq!(
                baseline_index(&root).await["entries"]["a.org"]["version"]["etag"],
                "\"actual\""
            );
        } else {
            assert_eq!(result.result, Some(OrgRepoSyncResult::Failed));
            assert!(!root.join(".sync/remote_base/current.json").exists());
        }
        worker.abort();
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
