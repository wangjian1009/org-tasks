use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{Local, TimeZone};
use clap::{ArgAction, Args, Parser, Subcommand};
use md5::{Digest, Md5};
use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavSyncContextDetail, WebDavSyncFileDetail, WebDavSyncPolicy,
};
use org_tasks_core::{
    FilterTask, OrgRepo, OrgRepoSyncController, OrgRepoSyncFileAction,
    OrgRepoSyncFileRecord, OrgRepoSyncFileState, OrgRepoSyncLifecycle, OrgRepoSyncProgress,
    OrgRepoSyncRecord, OrgRepoSyncSnapshot, OrgWorkspace,
};
use orgize::ast::Headline;
use orgize::rowan::ast::AstNode;

#[derive(Parser)]
#[command(name = "org-tasks", version, about = "Org Tasks 命令行工具")]
struct Cli {
    #[arg(long, global = true)]
    repo_dir: Option<PathBuf>,
    /// 全局默认 TODO 设置文本；文件中的声明覆盖它。省略时从 Rust Default 获取。
    #[arg(long, global = true)]
    todo_defaults: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Sync(SyncCommand),
    /// 查看并解决同步冲突
    Conflict(crate::conflict::ConflictCommand),
    History(HistoryCommand),
    File(FileCommand),
    Task(TaskCommand),
}

#[derive(Args)]
struct SyncCommand {
    #[command(subcommand)]
    target: SyncTarget,
}

#[derive(Subcommand)]
enum SyncTarget {
    Webdav(WebDavArgs),
}

#[derive(Args)]
struct HistoryCommand {
    #[command(subcommand)]
    target: HistoryTarget,
}

#[derive(Subcommand)]
enum HistoryTarget {
    List,
    Show(HistoryShowArgs),
}

#[derive(Args)]
struct HistoryShowArgs {
    id: String,
}

#[derive(Args)]
struct FileCommand {
    #[command(subcommand)]
    target: FileTarget,
}

#[derive(Subcommand)]
enum FileTarget {
    List,
    Dump(FileDumpArgs),
}

#[derive(Args)]
struct FileDumpArgs {
    path: String,
}

#[derive(Args)]
struct TaskCommand {
    #[command(subcommand)]
    target: TaskTarget,
}

#[derive(Subcommand)]
enum TaskTarget {
    All,
    Search(TaskSearchArgs),
    /// 输出所有仓库、文件与标题的完整路径和可空任务身份
    Paths,
    /// 执行 JSON 操作组，全部内存操作成功后统一保存
    Apply(TaskApplyArgs),
}

#[derive(Args)]
struct TaskApplyArgs {
    /// TaskOperationGroup JSON 文件
    #[arg(long)]
    operations: PathBuf,
    /// 额外仓库目录，支持跨仓库操作，可重复传入
    #[arg(long)]
    repository: Vec<PathBuf>,
}

#[derive(Args)]
struct TaskSearchArgs {
    expression: String,
}

#[derive(Args)]
pub(crate) struct WebDavConnectionArgs {
    /// WebDAV 目录的 HTTPS 地址
    #[arg(long)]
    webdav_url: String,
    /// WebDAV 用户名
    #[arg(long)]
    webdav_user: String,
    /// WebDAV 密码或应用专用密码
    #[arg(long)]
    webdav_passwd: String,
}

impl WebDavConnectionArgs {
    pub(crate) fn policy(self) -> Result<WebDavSyncPolicy, String> {
        if !self.webdav_url.starts_with("https://") {
            return Err("--webdav-url 必须使用 HTTPS".into());
        }
        let endpoint = WebDavEndpoint::new(self.webdav_url).map_err(|error| error.to_string())?;
        WebDavSyncPolicy::new(endpoint, self.webdav_user, self.webdav_passwd)
            .map_err(|error| error.to_string())
    }
}

#[derive(Args)]
struct WebDavArgs {
    #[command(flatten)]
    connection: WebDavConnectionArgs,
    #[arg(long)]
    silent: bool,
    #[arg(short = 'v', action = ArgAction::Count)]
    verbose: u8,
}

pub async fn run() -> Result<(), String> {
    let cli = Cli::parse();
    let repo_dir = cli
        .repo_dir
        .ok_or_else(|| "--repo-dir 是必填参数".to_string())?;
    let mut repo = open_repo(repo_dir)?;
    let defaults = cli
        .todo_defaults
        .as_deref()
        .map(org_tasks_core::TodoConfig::from_settings)
        .transpose()
        .map_err(|error| error.to_string())?
        .unwrap_or_default();
    repo.set_todo_defaults(defaults)
        .map_err(|error| error.to_string())?;
    let history_records = if matches!(&cli.command, Command::Sync(_)) {
        Vec::new()
    } else {
        repo.load::<WebDavSyncPolicy>()
            .await
            .map_err(|error| error.to_string())?
    };
    match cli.command {
        Command::Sync(command) => match command.target {
            SyncTarget::Webdav(args) => sync_webdav(repo, args).await,
        },
        Command::Conflict(command) => crate::conflict::run(repo, history_records, command).await,
        Command::History(command) => history(history_records, command),
        Command::File(command) => file(repo, command).await,
        Command::Task(command) => task(repo, command).await,
    }
}

async fn task(repo: OrgRepo, command: TaskCommand) -> Result<(), String> {
    let mut workspace = OrgWorkspace::new(vec![repo]).map_err(|error| error.to_string())?;
    match command.target {
        TaskTarget::All => print_tasks(
            workspace
                .query(&org_tasks_core::TaskQuery::default())
                .map_err(|error| error.to_string())?
                .tasks,
        ),
        TaskTarget::Search(args) => print_tasks(
            workspace
                .query(&org_tasks_core::TaskQuery {
                    expression: args.expression,
                    ..Default::default()
                })
                .map_err(|error| error.to_string())?
                .tasks,
        ),
        TaskTarget::Paths => print_json(&task_nodes(&workspace)),
        TaskTarget::Apply(args) => {
            for directory in args.repository {
                let mut repo = open_repo(directory)?;
                repo.set_todo_defaults(workspace.repos()[0].todo_defaults.clone()).map_err(|e|e.to_string())?;
                repo.load::<WebDavSyncPolicy>().await.map_err(|e|e.to_string())?;
                workspace.add_repo(repo).map_err(|e|e.to_string())?;
            }
            let bytes = tokio::fs::read(args.operations).await.map_err(|e|format!("无法读取操作组: {e}"))?;
            let group: org_tasks_core::TaskOperationGroup = serde_json::from_slice(&bytes).map_err(|e|format!("操作组格式无效: {e}"))?;
            let result = workspace.execute_task_operations(&group).await.map_err(|e|e.to_string())?;
            print_json(&serde_json::json!({"fallback": result.fallback, "paths": result.paths,
                "history": workspace.task_operation_history, "nodes": task_nodes(&workspace)}))
        }
    }
}

fn task_nodes(workspace: &OrgWorkspace) -> Vec<serde_json::Value> {
    let mut nodes=Vec::new();
    for repo in workspace.repos() {
        nodes.push(serde_json::json!({"kind":"repository","fullPath":repo.full_path(),"taskId":null}));
        let records=repo.nodes();
        for file in repo.files() {
            nodes.push(serde_json::json!({"kind":"file","fullPath":file.full_path(),"taskId":null,
                "fileVersion":org_tasks_core::LocalFileVersion::from_bytes(file.source_bytes()).content_hash}));
            // 路径与身份均来自 Core 投影，CLI 不解析或重建标题树。
            for task in records.iter().filter(|task| task.path() == file.path) {
                nodes.push(serde_json::json!({"kind":if task.task_id().is_some(){"task"}else{"heading"},
                    "fullPath":task.full_path(),"taskId":task.task_id()}));
            }
        }
    }
    nodes
}

fn print_json(value: &impl serde::Serialize) -> Result<(), String> {
    println!("{}",serde_json::to_string_pretty(value).map_err(|e|e.to_string())?);
    Ok(())
}

fn print_tasks(tasks: Vec<FilterTask>) -> Result<(), String> {
    println!("文件:位置\t状态\t优先级\t标题\t标签");
    for task in tasks {
        let priority = task
            .priority()
            .as_deref()
            .map(|value| format!("[#{value}]"))
            .unwrap_or_else(|| "-".into());
        let tags = task
            .own_tags()
            .iter()
            .chain(task.inherited_tags())
            .cloned()
            .collect::<Vec<_>>();
        let tags = if tags.is_empty() {
            "-".into()
        } else {
            format!(":{}:", tags.join(":"))
        };
        println!(
            "{}:{}:{}\t{}\t{}\t{}\t{}",
            task.path(),
            task.line(),
            task.column(),
            task.state().unwrap_or("-"),
            priority,
            task.title(),
            tags,
        );
    }
    Ok(())
}

async fn file(repo: OrgRepo, command: FileCommand) -> Result<(), String> {
    match command.target {
        FileTarget::List => list_files(&repo).await,
        FileTarget::Dump(args) => dump_file(&repo, &args.path),
    }
}

async fn list_files(repo: &OrgRepo) -> Result<(), String> {
    if repo.files().is_empty() {
        println!("没有 Org 文件。");
        return Ok(());
    }
    println!("文件  任务数  大小  MD5  最后修改时间  TODO 来源与状态");
    for file in repo.files() {
        let metadata = tokio::fs::metadata(PathBuf::from(&repo.root_directory).join(&file.path))
            .await
            .map_err(|error| format!("无法读取文件元数据 {}: {error}", file.path))?;
        let modified = metadata
            .modified()
            .map_err(|error| format!("无法读取文件修改时间 {}: {error}", file.path))?;
        println!(
            "{}  {}  {}  {}  {}  {:?}: {} | {}",
            file.path,
            task_count(file),
            format_size(i64::try_from(file.source_bytes().len()).unwrap_or(i64::MAX)),
            md5_hex(file.source_bytes()),
            format_system_time(modified),
            file.todo.source,
            file.todo.pending_keywords.join(" "),
            file.todo.done_keywords.join(" "),
        );
    }
    Ok(())
}

fn dump_file(repo: &OrgRepo, path: &str) -> Result<(), String> {
    let file = repo
        .files()
        .iter()
        .find(|file| file.path == path)
        .ok_or_else(|| format!("未找到 Org 文件: {path}"))?;
    println!("{}", file.path);
    println!(
        "TODO 元信息: {}",
        serde_json::to_string_pretty(&file.todo).map_err(|_| "无法编码 TODO 元信息".to_string())?
    );
    println!("{:#?}", file.syntax().document().syntax());
    Ok(())
}

fn task_count(file: &org_tasks_core::OrgFile) -> usize {
    file.syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .filter(|headline| headline.todo_keyword().is_some())
        .count()
}

fn md5_hex(bytes: &[u8]) -> String {
    format!("{:x}", Md5::digest(bytes))
}

fn format_system_time(time: SystemTime) -> String {
    chrono::DateTime::<Local>::from(time)
        .format("%Y-%m-%d %H:%M:%S%.3f %:z")
        .to_string()
}

fn open_repo(repo_dir: PathBuf) -> Result<OrgRepo, String> {
    if !repo_dir.is_dir() {
        return Err("--repo-dir 必须是已存在的目录".into());
    }
    let root_directory = repo_dir
        .to_str()
        .ok_or_else(|| "--repo-dir 必须是 UTF-8 路径".to_string())?
        .to_owned();
    OrgRepo::new(root_directory).map_err(|error| error.to_string())
}

async fn sync_webdav(repo: OrgRepo, args: WebDavArgs) -> Result<(), String> {
    let silent = args.silent;
    let verbose = args.verbose > 0;
    let policy = args.connection.policy()?;
    if !silent {
        println!("同步开始。");
    }

    let controller = OrgRepoSyncController::new(repo, policy);
    controller
        .start(timestamp_ms()?)
        .await
        .map_err(|error| error.to_string())?;
    let mut last_progress = None;
    let mut displayed_http_events = 0;
    let mut displayed_record_id = None;
    loop {
        let snapshot = controller.snapshot();
        if !silent {
            print_snapshot(
                &snapshot,
                verbose,
                &mut last_progress,
                &mut displayed_http_events,
                &mut displayed_record_id,
            );
        }
        match snapshot.lifecycle {
            OrgRepoSyncLifecycle::Running | OrgRepoSyncLifecycle::Cancelling => {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            OrgRepoSyncLifecycle::Succeeded => return Ok(()),
            OrgRepoSyncLifecycle::Cancelled => return Err("同步已取消".into()),
            OrgRepoSyncLifecycle::Failed => return Err("同步失败，请检查进度输出".into()),
            OrgRepoSyncLifecycle::Idle => return Err("同步未启动".into()),
        }
    }
}

fn history(
    history: Vec<org_tasks_core::OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>,
    command: HistoryCommand,
) -> Result<(), String> {
    match command.target {
        HistoryTarget::List => {
            if history.is_empty() {
                println!("没有同步历史。");
            } else {
                for record in &history {
                    let summary = summarize_files(record);
                    println!(
                        "{}  开始={}  耗时={}  结果={}  文件: 新增={} 修改={} 删除={} 不变={} 冲突={} 失败={}",
                        record.id,
                        format_timestamp(record.started_at),
                        format_duration(record.finished_at.map(|value| value - record.started_at)),
                        result_label(record),
                        summary.added,
                        summary.modified,
                        summary.deleted,
                        summary.unchanged,
                        summary.conflicted,
                        summary.failed,
                    );
                }
            }
            Ok(())
        }
        HistoryTarget::Show(args) => {
            let record = history
                .iter()
                .find(|record| record.id == args.id)
                .ok_or_else(|| format!("未找到同步历史: {}", args.id))?;
            println!(
                "历史记录: {}\n开始={}  耗时={}",
                record.id,
                format_timestamp(record.started_at),
                format_duration(record.finished_at.map(|value| value - record.started_at)),
            );
            let summary = summarize_files(record);
            println!(
                "文件: 新增={} 修改={} 删除={} 不变={} 冲突={} 失败={}",
                summary.added,
                summary.modified,
                summary.deleted,
                summary.unchanged,
                summary.conflicted,
                summary.failed,
            );
            print_record(record, true);
            Ok(())
        }
    }
}

pub(crate) fn timestamp_ms() -> Result<i64, String> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "系统时间早于 Unix epoch".to_string())?;
    i64::try_from(duration.as_millis()).map_err(|_| "当前时间超出支持范围".to_string())
}

#[derive(Default)]
struct FileSummary {
    added: usize,
    modified: usize,
    deleted: usize,
    unchanged: usize,
    conflicted: usize,
    failed: usize,
}

fn summarize_files(
    record: &OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
) -> FileSummary {
    let mut summary = FileSummary::default();
    for file in &record.files {
        match file.state {
            OrgRepoSyncFileState::Conflict => summary.conflicted += 1,
            OrgRepoSyncFileState::Failed => summary.failed += 1,
            OrgRepoSyncFileState::RemoteDeleted => summary.deleted += 1,
            _ => match file.action {
                OrgRepoSyncFileAction::Downloaded | OrgRepoSyncFileAction::Created => {
                    summary.added += 1
                }
                OrgRepoSyncFileAction::Uploaded => summary.modified += 1,
                OrgRepoSyncFileAction::Deleted => summary.deleted += 1,
                OrgRepoSyncFileAction::Unchanged => summary.unchanged += 1,
                OrgRepoSyncFileAction::Conflicted => summary.conflicted += 1,
                OrgRepoSyncFileAction::Skipped => summary.failed += 1,
            },
        }
    }
    summary
}

fn format_timestamp(timestamp: i64) -> String {
    Local
        .timestamp_millis_opt(timestamp)
        .single()
        .map(|value| value.format("%Y-%m-%d %H:%M:%S%.3f %:z").to_string())
        .unwrap_or_else(|| "未知".into())
}

fn format_duration(duration: Option<i64>) -> String {
    let Some(milliseconds) = duration.filter(|value| *value >= 0) else {
        return "未知".into();
    };
    if milliseconds < 1_000 {
        format!("{milliseconds} ms")
    } else if milliseconds < 60_000 {
        format!("{:.1} s", milliseconds as f64 / 1_000.0)
    } else {
        format!(
            "{} 分 {} 秒",
            milliseconds / 60_000,
            (milliseconds / 1_000) % 60
        )
    }
}

fn print_snapshot(
    snapshot: &OrgRepoSyncSnapshot<WebDavSyncContextDetail, WebDavSyncFileDetail>,
    verbose: bool,
    last_progress: &mut Option<OrgRepoSyncProgress>,
    displayed_http_events: &mut usize,
    displayed_record_id: &mut Option<String>,
) {
    if last_progress.as_ref().is_none_or(|previous| {
        previous.stage != snapshot.progress.stage
            || previous.completed != snapshot.progress.completed
            || previous.total != snapshot.progress.total
            || previous.current_path != snapshot.progress.current_path
    }) {
        print_progress(&snapshot.progress);
        *last_progress = Some(snapshot.progress.clone());
    }
    if verbose {
        for summary in snapshot
            .progress
            .http_events
            .iter()
            .skip(*displayed_http_events)
        {
            println!("HTTP: {summary}");
        }
        *displayed_http_events = snapshot.progress.http_events.len();
    }
    if let Some(record) = &snapshot.latest_record
        && displayed_record_id.as_deref() != Some(&record.id)
    {
        print_record(record, verbose);
        *displayed_record_id = Some(record.id.clone());
    }
}

fn print_progress(progress: &OrgRepoSyncProgress) {
    let stage = match progress.stage.as_str() {
        "Idle" => "准备中",
        "Listing" => "列举远端文件",
        "Synchronizing" => "同步文件",
        "Finished" => "同步完成",
        "Cancelled" => "正在取消",
        other => other,
    };
    let path = progress
        .current_path
        .as_deref()
        .map(|path| format!("，文件={path}"))
        .unwrap_or_default();
    println!("{stage}: {}/{}{}", progress.completed, progress.total, path);
}

pub(crate) fn print_record(
    record: &OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
    verbose: bool,
) {
    println!(
        "同步结果: {}，文件数={}",
        result_label(record),
        record.files.len()
    );
    for file in &record.files {
        print_file_record(file, verbose);
    }
}

fn print_file_record(file: &OrgRepoSyncFileRecord<WebDavSyncFileDetail>, verbose: bool) {
    let outcome = match file.state {
        OrgRepoSyncFileState::Failed => "失败",
        OrgRepoSyncFileState::Conflict => "冲突",
        _ => "成功",
    };
    let changed = if file.action == OrgRepoSyncFileAction::Unchanged {
        "否"
    } else {
        "是"
    };
    let remote = webdav_detail(file);
    let size = remote
        .as_ref()
        .and_then(|version| version.size)
        .map(format_size)
        .unwrap_or_else(|| "未知".into());
    println!(
        "[{outcome}] {}，操作={}，状态={}，变化={}，大小={size}",
        file.relative_path,
        action_label(file.action),
        state_label(file.state),
        changed,
    );
    if let Some(error) = &file.error {
        println!("  错误: {} ({:?})", error.message, error.category);
    }
    if verbose {
        if let Some(local) = &file.local_version {
            println!("  本地版本: {}", local.content_hash);
        }
        if let Some(remote) = remote {
            println!(
                "  远端版本: etag={}，修改时间={}，大小={}",
                remote.etag.as_deref().unwrap_or("未知"),
                remote
                    .modified_at
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "未知".into()),
                remote
                    .size
                    .map(format_size)
                    .unwrap_or_else(|| "未知".into()),
            );
        }
    }
}

fn result_label(
    record: &OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
) -> &'static str {
    match record.result {
        Some(org_tasks_core::OrgRepoSyncResult::Succeeded) => "成功",
        Some(org_tasks_core::OrgRepoSyncResult::Failed) => "失败",
        Some(org_tasks_core::OrgRepoSyncResult::Cancelled) => "已取消",
        Some(org_tasks_core::OrgRepoSyncResult::Interrupted) => "已中断",
        None => "未完成",
    }
}

fn action_label(action: OrgRepoSyncFileAction) -> &'static str {
    match action {
        OrgRepoSyncFileAction::Unchanged => "未变化",
        OrgRepoSyncFileAction::Downloaded => "下载",
        OrgRepoSyncFileAction::Uploaded => "上传",
        OrgRepoSyncFileAction::Created => "创建远端文件",
        OrgRepoSyncFileAction::Deleted => "删除",
        OrgRepoSyncFileAction::Conflicted => "冲突",
        OrgRepoSyncFileAction::Skipped => "跳过",
    }
}

fn state_label(state: OrgRepoSyncFileState) -> &'static str {
    match state {
        OrgRepoSyncFileState::Synchronized => "已同步",
        OrgRepoSyncFileState::LocalChanged => "本地已变化",
        OrgRepoSyncFileState::RemoteChanged => "远端已变化",
        OrgRepoSyncFileState::RemoteDeleted => "远端已删除",
        OrgRepoSyncFileState::Conflict => "冲突",
        OrgRepoSyncFileState::Failed => "失败",
    }
}

fn webdav_detail(
    file: &OrgRepoSyncFileRecord<WebDavSyncFileDetail>,
) -> Option<WebDavSyncFileDetail> {
    Some(file.detail.clone())
}

fn format_size(bytes: i64) -> String {
    const KIB: i64 = 1024;
    const MIB: i64 = KIB * 1024;
    if bytes >= MIB {
        format!("{:.1} MiB", bytes as f64 / MIB as f64)
    } else if bytes >= KIB {
        format!("{:.1} KiB", bytes as f64 / KIB as f64)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_history_show_with_only_global_repository_parameter() {
        let cli = Cli::try_parse_from([
            "org-tasks",
            "--repo-dir",
            "./org",
            "history",
            "show",
            "record-1",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::History(HistoryCommand {
                target: HistoryTarget::Show(HistoryShowArgs { id })
            }) if id == "record-1"
        ));
    }

    #[test]
    fn parses_webdav_parameters_only_for_webdav_sync() {
        let cli = Cli::try_parse_from([
            "org-tasks",
            "--repo-dir",
            "./org",
            "sync",
            "webdav",
            "--webdav-url",
            "https://dav.example.com/org/",
            "--webdav-user",
            "alice",
            "--webdav-passwd",
            "password",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::Sync(SyncCommand {
                target: SyncTarget::Webdav(_)
            })
        ));
    }

    #[test]
    fn parses_file_commands() {
        let list =
            Cli::try_parse_from(["org-tasks", "--repo-dir", "./org", "file", "list"]).unwrap();
        assert!(matches!(
            list.command,
            Command::File(FileCommand {
                target: FileTarget::List
            })
        ));

        let dump = Cli::try_parse_from([
            "org-tasks",
            "--repo-dir",
            "./org",
            "file",
            "dump",
            "inbox.org",
        ])
        .unwrap();
        assert!(matches!(
            dump.command,
            Command::File(FileCommand {
                target: FileTarget::Dump(FileDumpArgs { path })
            }) if path == "inbox.org"
        ));
    }

    #[test]
    fn parses_task_all_command() {
        let cli = Cli::try_parse_from(["org-tasks", "--repo-dir", "./org", "task", "all"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Task(TaskCommand {
                target: TaskTarget::All
            })
        ));
    }

    #[test]
    fn parses_task_search_command() {
        let cli = Cli::try_parse_from([
            "org-tasks",
            "--repo-dir",
            "./org",
            "task",
            "search",
            "i.todo t.work",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::Task(TaskCommand {
                target: TaskTarget::Search(TaskSearchArgs { expression })
            }) if expression == "i.todo t.work"
        ));
    }

    #[test]
    fn task_search_view_uses_core_filter_task_projection() {
        let file = org_tasks_core::OrgFile::new(
            "repo-1".into(),
            "inbox.org".into(),
            b"* TODO [#A] Parent :work:\n** DONE Child :done:\n".to_vec(),
        )
        .unwrap();
        let repo = OrgRepo {
            id: "repo-1".into(),
            root_directory: "/tmp/org".into(),
            todo_defaults: org_tasks_core::TodoConfig::default(),
            task_scan_rules: Default::default(),
            files: vec![file],
        };
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let tasks = workspace.query(&org_tasks_core::TaskQuery::default()).unwrap().tasks;
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].state(), Some("TODO"));
        assert_eq!(tasks[0].priority(), Some("A"));
        assert_eq!(tasks[0].own_tags(), ["work"]);
        assert_eq!(tasks[1].state(), Some("DONE"));
        assert_eq!(tasks[1].inherited_tags(), ["work"]);
    }

    #[test]
    fn md5_uses_standard_lowercase_hex() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
    }
}
