use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{Local, TimeZone};
use clap::{ArgAction, Args, Parser, Subcommand};
use org_tasks_core::webdav::{
    WebDavEndpoint, WebDavSyncContextDetail, WebDavSyncFileDetail, WebDavSyncPolicy,
};
use org_tasks_core::{
    OrgRepo, OrgRepoSyncController, OrgRepoSyncFileAction, OrgRepoSyncFileRecord,
    OrgRepoSyncFileState, OrgRepoSyncLifecycle, OrgRepoSyncProgress, OrgRepoSyncRecord,
    OrgRepoSyncSnapshot,
};

#[derive(Parser)]
#[command(name = "org-tasks", version, about = "Org Tasks 命令行工具")]
struct Cli {
    #[arg(long, global = true)]
    repo_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Sync(SyncCommand),
    History(HistoryCommand),
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
struct WebDavArgs {
    #[arg(long)]
    webdav_url: String,
    #[arg(long)]
    webdav_user: String,
    #[arg(long)]
    webdav_passwd: String,
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
    let (repo, history_records) = load_repo(repo_dir).await?;
    match cli.command {
        Command::Sync(command) => match command.target {
            SyncTarget::Webdav(args) => sync_webdav(repo, history_records, args).await,
        },
        Command::History(command) => history(history_records, command),
    }
}

async fn load_repo(
    repo_dir: PathBuf,
) -> Result<
    (
        OrgRepo,
        Vec<org_tasks_core::OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>,
    ),
    String,
> {
    if !repo_dir.is_dir() {
        return Err("--repo-dir 必须是已存在的目录".into());
    }
    let root_directory = repo_dir
        .to_str()
        .ok_or_else(|| "--repo-dir 必须是 UTF-8 路径".to_string())?
        .to_owned();
    let mut repo = OrgRepo::new(root_directory).map_err(|error| error.to_string())?;
    let history = repo
        .load::<WebDavSyncPolicy>()
        .await
        .map_err(|error| error.to_string())?;
    Ok((repo, history))
}

async fn sync_webdav(
    repo: OrgRepo,
    history: Vec<org_tasks_core::OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>,
    args: WebDavArgs,
) -> Result<(), String> {
    if !args.webdav_url.starts_with("https://") {
        return Err("--webdav-url 必须使用 HTTPS".into());
    }
    let silent = args.silent;
    let verbose = args.verbose > 0;
    let endpoint = WebDavEndpoint::new(args.webdav_url).map_err(|error| error.to_string())?;
    let policy = WebDavSyncPolicy::new(endpoint, args.webdav_user, args.webdav_passwd)
        .map_err(|error| error.to_string())?;
    if !silent {
        println!("同步开始: 本地文件={}。", repo.files().len());
    }

    let controller = OrgRepoSyncController::new(repo, history, policy);
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

fn timestamp_ms() -> Result<i64, String> {
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

fn print_record(
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
}
