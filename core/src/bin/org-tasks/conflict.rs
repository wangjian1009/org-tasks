//! CLI 仅收集选择并显示结果；比较、备份、版本校验和提交均调用 Rust core。
use std::io::{self, BufRead, Write};

use clap::{Args, Subcommand};
use org_tasks_core::webdav::{
    WebDavMergeComparison, WebDavMergeOutcome, WebDavMergeResolution, WebDavSyncContextDetail,
    WebDavSyncFileDetail, WebDavSyncPolicy, conflict_syncs,
};
use org_tasks_core::{
    OrgMergeChange, OrgMergeVersion, OrgRepo, OrgRepoSyncRecord, OrgRepoSyncResult,
};

use crate::cli::{WebDavConnectionArgs, print_record, timestamp_ms};

type History = Vec<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>;

#[derive(Args)]
pub(crate) struct ConflictCommand {
    #[command(subcommand)]
    target: ConflictTarget,
}

#[derive(Subcommand)]
enum ConflictTarget {
    /// 按同步记录列出尚未解决的冲突，不访问远端
    List {
        /// 以 JSON 输出同步 ID 和冲突文件路径
        #[arg(long)]
        json: bool,
    },
    /// 在内存中比较整次同步，选择任务后备份并应用；取消或输入结束时不提交
    Resolve(ResolveArgs),
}

#[derive(Args)]
struct ResolveArgs {
    /// 待解决冲突所属的同步记录 ID，可从 conflict list 查看
    sync_id: String,
    #[command(flatten)]
    connection: WebDavConnectionArgs,
    /// 明确同意最终提交；仍需完成每个差异项的选择
    #[arg(long)]
    yes: bool,
    /// 显示结果中的本地与远端版本元数据
    #[arg(short = 'v')]
    verbose: bool,
}

pub(crate) async fn run(
    mut repo: OrgRepo,
    history: History,
    command: ConflictCommand,
) -> Result<(), String> {
    match command.target {
        ConflictTarget::List { json } => {
            let stdout = io::stdout();
            print_conflicts(&history, json, &mut stdout.lock())
        }
        ConflictTarget::Resolve(args) => {
            let policy = args.connection.policy()?;
            let stdin = io::stdin();
            let stdout = io::stdout();
            let outcome = resolve(
                &mut repo,
                &policy,
                &args.sync_id,
                args.yes,
                &mut stdin.lock(),
                &mut stdout.lock(),
            )
            .await?;
            println!("合并同步记录: {}", outcome.record.id);
            print_record(&outcome.record, args.verbose);
            for backup in &outcome.backups {
                println!(
                    "本地备份: {} → {}",
                    visible(&backup.path),
                    visible(&backup.backup_path)
                );
            }
            if outcome.record.result != Some(OrgRepoSyncResult::Succeeded) {
                return Err("部分冲突未解决；已保留备份和失败项，请重新比较后处理".into());
            }
            Ok(())
        }
    }
}

fn print_conflicts(history: &History, json: bool, output: &mut impl Write) -> Result<(), String> {
    let conflicts = conflict_syncs(history);
    if json {
        serde_json::to_writer_pretty(&mut *output, &conflicts)
            .map_err(|_| "无法输出冲突列表 JSON".to_string())?;
        writeln!(output).map_err(output_error)?;
    } else if conflicts.is_empty() {
        writeln!(output, "没有待处理的同步冲突。").map_err(output_error)?;
    } else {
        for sync in conflicts {
            writeln!(
                output,
                "同步: {}（{} 个冲突文件）",
                visible(&sync.sync_id),
                sync.paths.len()
            )
            .map_err(output_error)?;
            for path in sync.paths {
                writeln!(output, "  {}", visible(&path)).map_err(output_error)?;
            }
        }
    }
    Ok(())
}

async fn resolve(
    repo: &mut OrgRepo,
    policy: &WebDavSyncPolicy,
    sync_id: &str,
    yes: bool,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<WebDavMergeOutcome, String> {
    let mut comparison = policy
        .compare_merge(repo, sync_id)
        .await
        .map_err(|e| e.to_string())?;
    review(&mut comparison, yes, input, output)?;
    // 等待用户期间发生的全仓库/远端变化由 core 在任何写入之前拒绝。
    policy
        .apply_merge(repo, &comparison, timestamp_ms()?)
        .await
        .map_err(|e| e.to_string())
}

fn review(
    comparison: &mut WebDavMergeComparison,
    yes: bool,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<(), String> {
    writeln!(
        output,
        "同步: {}\n冲突文件={}，直接保留远端任务={}，差异项={}",
        visible(&comparison.sync_id),
        comparison.files.len(),
        comparison.unchanged_count,
        comparison.changes.len()
    )
    .map_err(output_error)?;
    writeln!(output, "差异以远端文件为基准，表示可接受或丢弃的本地任务变更；仅远端变化的任务直接保留，无 ID 的改名可能显示为删除和新增，文件前言单独决定。").map_err(output_error)?;
    for change in &mut comparison.changes {
        let kind = match change.kind {
            OrgMergeChange::Added => "新增",
            OrgMergeChange::Deleted => "删除",
            OrgMergeChange::Modified => "修改",
            _ => return Err("core 返回了不支持的差异类型".into()),
        };
        writeln!(
            output,
            "\n[{}] {} · {}",
            visible(&change.id),
            visible(&change.path),
            kind
        )
        .map_err(output_error)?;
        print_version("本地", change.local.as_ref(), output)?;
        print_version("远端", change.remote.as_ref(), output)?;
        loop {
            write!(
                output,
                "选择 l=保留本地，r=保留远端，d=不保留，q=取消（选择不存在的一端表示不保留此项）: "
            )
            .map_err(output_error)?;
            match read_answer(input, output)?.as_str() {
                "l" | "local" => {
                    change.resolution = Some(WebDavMergeResolution::Local);
                    break;
                }
                "r" | "remote" => {
                    change.resolution = Some(WebDavMergeResolution::Remote);
                    break;
                }
                "d" | "remove" => {
                    change.resolution = Some(WebDavMergeResolution::Remove);
                    break;
                }
                "q" | "quit" => return Err("已取消，未提交合并".into()),
                _ => writeln!(output, "请输入 l、r、d 或 q。").map_err(output_error)?,
            }
        }
    }
    writeln!(output, "\n按上述选择应用本次同步的全部差异；提交前将全部冲突原文件备份到 .sync/backups/<本次合并开始时间>/。")
        .map_err(output_error)?;

    if !yes {
        write!(output, "输入 yes 确认提交，其他输入取消: ").map_err(output_error)?;
        if read_answer(input, output)? != "yes" {
            return Err("已取消，未提交合并".into());
        }
    }
    output.flush().map_err(output_error)
}

fn read_answer(input: &mut impl BufRead, output: &mut impl Write) -> Result<String, String> {
    output.flush().map_err(output_error)?;
    let mut answer = String::new();
    if input
        .read_line(&mut answer)
        .map_err(|_| "无法读取终端输入，未提交合并".to_string())?
        == 0
    {
        return Err("输入结束，未提交合并".into());
    }
    Ok(answer.trim().to_ascii_lowercase())
}

fn print_version(
    label: &str,
    version: Option<&OrgMergeVersion>,
    output: &mut impl Write,
) -> Result<(), String> {
    if let Some(version) = version {
        writeln!(
            output,
            "{label}: {}\n{}",
            visible(&version.title),
            visible(&version.source)
        )
        .map_err(output_error)
    } else {
        writeln!(output, "{label}: 无此项").map_err(output_error)
    }
}

fn visible(value: &str) -> String {
    value
        .chars()
        .flat_map(|c| {
            if c.is_control() && c != '\n' && c != '\t' {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}

fn output_error(_: io::Error) -> String {
    "无法写入终端输出，已停止操作".into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use org_tasks_core::webdav::WebDavEndpoint;
    use org_tasks_core::{SyncCancellation, SyncProgressReporter};
    use std::collections::BTreeMap;
    use std::io::{Cursor, Read};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    struct Remote {
        files: BTreeMap<String, Vec<u8>>,
        reject_put: bool,
        writes: usize,
    }
    struct Fixture {
        repo: OrgRepo,
        policy: WebDavSyncPolicy,
        root: PathBuf,
        sync_id: String,
        remote: Arc<Mutex<Remote>>,
        server: tokio::task::JoinHandle<()>,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            self.server.abort();
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    async fn fixture(local: &[(&str, &str)], remote: &[(&str, &str)]) -> Fixture {
        static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "org-tasks-cli-conflict-{}-{}-{}",
            std::process::id(),
            NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        tokio::fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        for (path, source) in local {
            tokio::fs::write(root.join(path), source).await.unwrap();
        }
        let remote = Arc::new(Mutex::new(Remote {
            files: remote
                .iter()
                .map(|(p, s)| (p.to_string(), s.as_bytes().to_vec()))
                .collect(),
            reject_put: false,
            writes: 0,
        }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint =
            WebDavEndpoint::new(format!("http://{}/org/", listener.local_addr().unwrap())).unwrap();
        let state = remote.clone();
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                let end = loop {
                    let count = stream.read(&mut buffer).await.unwrap();
                    if count == 0 {
                        return;
                    }
                    bytes.extend_from_slice(&buffer[..count]);
                    if let Some(i) = bytes.windows(4).position(|b| b == b"\r\n\r\n") {
                        break i + 4;
                    }
                };
                let headers = String::from_utf8_lossy(&bytes[..end]).to_string();
                let lower = headers.to_ascii_lowercase();
                let length = lower
                    .lines()
                    .find_map(|l| {
                        l.strip_prefix("content-length:")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while bytes.len() < end + length {
                    let count = stream.read(&mut buffer).await.unwrap();
                    if count == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buffer[..count]);
                }
                let mut request = headers.split_whitespace();
                let method = request.next().unwrap();
                let path = request
                    .next()
                    .unwrap()
                    .trim_start_matches("/org/")
                    .to_owned();
                let (status, body) = {
                    let mut state = state.lock().unwrap();
                    match method {
                        "PROPFIND" => {
                            let entries = state.files.iter().map(|(p, s)| format!(
                                "<d:response><d:href>/org/{p}</d:href><d:propstat><d:prop><d:getetag>\"v1\"</d:getetag><d:getcontentlength>{}</d:getcontentlength></d:prop></d:propstat></d:response>", s.len())).collect::<String>();
                            (
                                207,
                                format!(
                                    "<d:multistatus xmlns:d=\"DAV:\">{entries}</d:multistatus>"
                                )
                                .into_bytes(),
                            )
                        }
                        "GET" => (200, state.files[&path].clone()),
                        "PUT" if !state.reject_put && lower.contains("if-match: \"v1\"") => {
                            state.writes += 1;
                            state.files.insert(path, bytes[end..end + length].to_vec());
                            (204, Vec::new())
                        }
                        "PUT" => (412, Vec::new()),
                        _ => (500, Vec::new()),
                    }
                };
                stream.write_all(format!("HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n", body.len()).as_bytes()).await.unwrap();
                stream.write_all(&body).await.unwrap();
            }
        });
        let policy = WebDavSyncPolicy::new(endpoint, "user".into(), "secret".into()).unwrap();
        let record = repo
            .sync(
                &policy,
                1,
                &SyncCancellation::default(),
                &SyncProgressReporter::default(),
            )
            .await
            .unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Failed));
        Fixture {
            repo,
            policy,
            root,
            sync_id: record.id,
            remote,
            server,
        }
    }

    #[tokio::test]
    async fn lists_pending_syncs_offline_and_resolves_all_files_with_timestamped_backups() {
        let mut fixture = fixture(
            &[
                ("a.org", "* TODO Local A\r\n"),
                ("b.org", "* TODO Local B\n"),
            ],
            &[
                ("a.org", "* TODO Remote A\r\n"),
                ("b.org", "* TODO Remote B\n"),
            ],
        )
        .await;
        let history = fixture.repo.load::<WebDavSyncPolicy>().await.unwrap();
        let mut output = Vec::new();
        print_conflicts(&history, true, &mut output).unwrap();
        let listed: serde_json::Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(listed[0]["syncId"], fixture.sync_id);
        assert_eq!(listed[0]["paths"].as_array().unwrap().len(), 2);
        let comparison = fixture
            .policy
            .compare_merge(&mut fixture.repo, &fixture.sync_id)
            .await
            .unwrap();
        let answers = "r\n".repeat(comparison.changes.len()) + "yes\n";
        let result = resolve(
            &mut fixture.repo,
            &fixture.policy,
            &fixture.sync_id,
            false,
            &mut Cursor::new(answers),
            &mut output,
        )
        .await
        .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(result.backups.len(), 2);
        for backup in result.backups {
            assert!(
                backup
                    .backup_path
                    .starts_with(&format!(".sync/backups/{}/", result.record.started_at))
            );
            assert!(backup.backup_path.contains(".org"));
            assert!(
                std::fs::read_to_string(fixture.root.join(backup.backup_path))
                    .unwrap()
                    .contains("Local")
            );
        }
        assert_eq!(
            std::fs::read(fixture.root.join("a.org")).unwrap(),
            b"* TODO Remote A\r\n"
        );
        assert_eq!(fixture.remote.lock().unwrap().writes, 0);
        let history = fixture.repo.load::<WebDavSyncPolicy>().await.unwrap();
        assert!(conflict_syncs(&history).is_empty());
        assert_eq!(fixture.repo.files.len(), 2);
        assert!(!String::from_utf8(output).unwrap().contains("secret"));
    }

    #[tokio::test]
    async fn interactive_task_choices_keep_unchanged_and_handle_add_modify_delete() {
        let local = "* TODO Same\n* TODO Edit\nlocal body\n* TODO Removed\n";
        let remote = "* TODO Same\n* TODO Edit\nremote body\n* TODO New\n";
        let mut fixture = fixture(&[("inbox.org", local)], &[("inbox.org", remote)]).await;
        let comparison = fixture
            .policy
            .compare_merge(&mut fixture.repo, &fixture.sync_id)
            .await
            .unwrap();
        assert_eq!(comparison.unchanged_count, 1);
        let mut answers = String::from("invalid\n");
        for change in &comparison.changes {
            answers.push_str(if change.kind == OrgMergeChange::Modified {
                "l\n"
            } else {
                "r\n"
            });
        }
        answers.push_str("yes\n");
        let mut output = Vec::new();
        let result = resolve(
            &mut fixture.repo,
            &fixture.policy,
            &fixture.sync_id,
            false,
            &mut Cursor::new(answers),
            &mut output,
        )
        .await
        .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Succeeded));
        let expected = b"* TODO Same\n* TODO Edit\nlocal body\n* TODO New\n";
        assert_eq!(
            std::fs::read(fixture.root.join("inbox.org")).unwrap(),
            expected
        );
        assert_eq!(fixture.remote.lock().unwrap().files["inbox.org"], expected);
        assert_eq!(fixture.remote.lock().unwrap().writes, 1);
        let output = String::from_utf8(output).unwrap();
        for text in [
            "新增",
            "修改",
            "删除",
            "change-1",
            "直接保留远端任务=1",
            "请输入 l、r、d 或 q",
        ] {
            assert!(output.contains(text));
        }
    }

    #[tokio::test]
    async fn cancel_eof_and_yes_without_choices_never_commit_or_create_backups() {
        for (yes, answers) in [
            (false, "q\n"),
            (true, ""),
            (false, "r\nr\nno\n"),
            (false, "r\nr\n"),
        ] {
            let mut fixture = fixture(
                &[("inbox.org", "* TODO Local\n")],
                &[("inbox.org", "* TODO Remote\n")],
            )
            .await;
            let result = resolve(
                &mut fixture.repo,
                &fixture.policy,
                &fixture.sync_id,
                yes,
                &mut Cursor::new(answers),
                &mut Vec::new(),
            )
            .await;
            assert!(result.is_err());
            assert_eq!(
                std::fs::read(fixture.root.join("inbox.org")).unwrap(),
                b"* TODO Local\n"
            );
            assert!(!fixture.root.join(".sync/backups").exists());
            assert_eq!(
                fixture.repo.load::<WebDavSyncPolicy>().await.unwrap().len(),
                1
            );
            assert_eq!(fixture.remote.lock().unwrap().writes, 0);
        }
    }

    struct ChangeDuringInput {
        input: Cursor<&'static [u8]>,
        changed_path: PathBuf,
    }
    impl Read for ChangeDuringInput {
        fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
            Read::read(&mut self.input, b)
        }
    }
    impl BufRead for ChangeDuringInput {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            self.input.fill_buf()
        }
        fn consume(&mut self, amount: usize) {
            self.input.consume(amount)
        }
        fn read_line(&mut self, buf: &mut String) -> io::Result<usize> {
            std::fs::write(&self.changed_path, b"* TODO Concurrent edit\n")?;
            self.input.read_line(buf)
        }
    }

    #[tokio::test]
    async fn concurrent_repository_edit_while_prompting_is_rejected_by_core() {
        let mut fixture = fixture(
            &[("inbox.org", "* TODO Local\n")],
            &[("inbox.org", "* TODO Remote\n")],
        )
        .await;
        let mut input = ChangeDuringInput {
            input: Cursor::new(b"r\nr\nyes\n"),
            changed_path: fixture.root.join("other.org"),
        };
        let result = resolve(
            &mut fixture.repo,
            &fixture.policy,
            &fixture.sync_id,
            false,
            &mut input,
            &mut Vec::new(),
        )
        .await;
        assert!(result.err().unwrap().contains("仓库或远端配置已发生变化"));
        assert!(!fixture.root.join(".sync/backups").exists());
        assert_eq!(
            std::fs::read(fixture.root.join("inbox.org")).unwrap(),
            b"* TODO Local\n"
        );
        assert_eq!(fixture.remote.lock().unwrap().writes, 0);
    }

    #[tokio::test]
    async fn conditional_upload_failure_keeps_backup_local_content_and_pending_conflict() {
        let mut fixture = fixture(
            &[("inbox.org", "* TODO Local\n")],
            &[("inbox.org", "* TODO Remote\n")],
        )
        .await;
        let id=fixture.repo.id.clone();
        let mut workspace=org_tasks_core::OrgWorkspace::new(vec![fixture.repo.clone()]).unwrap();
        let group:org_tasks_core::TaskOperationGroup=serde_json::from_value(serde_json::json!({
            "operations":[{"type":"Creation","data":{"position":{"parent":{"repoId":id,"file":"inbox.org"}},"title":"Offline","state":"TODO"}}],"queueRepoIds":[id]})).unwrap();
        workspace.execute_task_operations(&group).await.unwrap();
        fixture.repo=workspace.repos.remove(0);
        let comparison = fixture
            .policy
            .compare_merge(&mut fixture.repo, &fixture.sync_id)
            .await
            .unwrap();
        let answers = "l\n".repeat(comparison.changes.len());
        let original = std::fs::read(fixture.root.join("inbox.org")).unwrap();
        fixture.remote.lock().unwrap().reject_put = true;
        let result = resolve(
            &mut fixture.repo,
            &fixture.policy,
            &fixture.sync_id,
            true,
            &mut Cursor::new(answers),
            &mut Vec::new(),
        )
        .await
        .unwrap();
        assert_eq!(result.record.result, Some(OrgRepoSyncResult::Failed));
        assert_eq!(
            std::fs::read(fixture.root.join(&result.backups[0].backup_path)).unwrap(),
            original
        );
        assert_eq!(
            std::fs::read(fixture.root.join("inbox.org")).unwrap(),
            original
        );
        assert_eq!(fixture.repo.pending_writes().await.unwrap().len(), 1);
        assert_eq!(
            conflict_syncs(&fixture.repo.load::<WebDavSyncPolicy>().await.unwrap()).len(),
            1
        );
    }
}
