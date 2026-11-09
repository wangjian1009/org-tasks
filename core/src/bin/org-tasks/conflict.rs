//! CLI 只展示单文件差异并收集完整选择；比较、版本校验及离线保存均由 Core 执行。
use std::io::{self, BufRead, Write};

use clap::{Args, Subcommand};
use org_tasks_core::webdav::{
    SyncConflictComparison, SyncConflictResolution, SyncConflictTarget, WebDavSyncContextDetail,
    WebDavSyncFileDetail,
};
use org_tasks_core::{
    OrgMergeChange, OrgMergeChoice, OrgMergeSide, OrgMergeVersion, OrgRepo, OrgRepoSyncRecord,
};

type History = Vec<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>;

#[derive(Args)]
pub(crate) struct ConflictCommand {
    #[command(subcommand)]
    target: ConflictTarget,
}

#[derive(Subcommand)]
enum ConflictTarget {
    /// 列出最近成功同步中尚未解决的冲突，不访问远端
    List {
        /// 以 JSON 输出同步 ID 和冲突文件路径
        #[arg(long)]
        json: bool,
    },
    /// 比较指定日志的固定远端文件与当前本地文件，完整选择后一次保存
    Resolve(ResolveArgs),
}

#[derive(Args)]
struct ResolveArgs {
    /// 冲突所属的同步记录 ID
    sync_id: String,
    /// 冲突原文件的仓库内相对路径
    path: String,
    /// 完成每个差异项选择后直接提交
    #[arg(long)]
    yes: bool,
}

pub(crate) async fn run(
    mut repo: OrgRepo,
    _history: History,
    command: ConflictCommand,
) -> Result<(), String> {
    match command.target {
        ConflictTarget::List { json } => {
            let conflicts = repo
                .pending_sync_conflicts()
                .await
                .map_err(|e| e.to_string())?;
            let mut output = io::stdout().lock();
            if json {
                serde_json::to_writer_pretty(&mut output, &conflicts)
                    .map_err(|_| "无法输出冲突列表 JSON".to_string())?;
                writeln!(output).map_err(output_error)?;
            } else if conflicts.is_empty() {
                writeln!(output, "没有待处理的同步冲突。").map_err(output_error)?;
            } else {
                for conflict in conflicts {
                    writeln!(output, "同步: {}", visible(&conflict.sync_id))
                        .map_err(output_error)?;
                    for path in conflict.paths {
                        writeln!(output, "  {}", visible(&path)).map_err(output_error)?;
                    }
                }
            }
        }
        ConflictTarget::Resolve(args) => {
            let target = SyncConflictTarget {
                sync_id: args.sync_id,
                path: args.path,
            };
            let comparison = repo
                .compare_conflict(&target)
                .await
                .map_err(|e| e.to_string())?;
            let request = review(
                &comparison,
                args.yes,
                &mut io::stdin().lock(),
                &mut io::stdout().lock(),
            )?;
            repo.resolve_conflict(&request)
                .await
                .map_err(|e| e.to_string())?;
            println!("已保存本地解决结果；后续同步将校验远端版本。");
        }
    }
    Ok(())
}

fn review(
    comparison: &SyncConflictComparison,
    yes: bool,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<SyncConflictResolution, String> {
    writeln!(
        output,
        "同步: {}\n文件: {}\n未变化任务={}，差异项={}",
        visible(&comparison.target.sync_id),
        visible(&comparison.target.path),
        comparison.unchanged_count,
        comparison.changes.len()
    )
    .map_err(output_error)?;
    writeln!(
        output,
        "远端使用该次日志备份，本地使用当前仓库文件；退出将丢弃全部选择。"
    )
    .map_err(output_error)?;
    let mut choices = Vec::new();
    for change in &comparison.changes {
        let kind = match change.kind {
            OrgMergeChange::Added => "新增",
            OrgMergeChange::Modified => "修改",
            OrgMergeChange::Deleted => "删除",
            _ => return Err("Core 返回了不支持的差异类型".into()),
        };
        writeln!(output, "\n[{}] {}", visible(&change.key), kind).map_err(output_error)?;
        print_version("本地", change.local.as_ref(), output)?;
        print_version("远端备份", change.remote.as_ref(), output)?;
        let side = loop {
            write!(output, "选择 l=保留本地，r=保留远端，d=不保留，q=取消: ")
                .map_err(output_error)?;
            match read_answer(input, output)?.as_str() {
                "l" | "local" => break OrgMergeSide::Local,
                "r" | "remote" => break OrgMergeSide::Remote,
                "d" | "remove" => break OrgMergeSide::Remove,
                "q" | "quit" => return Err("已取消，未保存解决结果".into()),
                _ => writeln!(output, "请输入 l、r、d 或 q。").map_err(output_error)?,
            }
        };
        choices.push(OrgMergeChoice {
            key: change.key.clone(),
            side,
        });
    }
    if !yes {
        write!(output, "输入 yes 一次保存全部选择，其他输入取消: ").map_err(output_error)?;
        if read_answer(input, output)? != "yes" {
            return Err("已取消，未保存解决结果".into());
        }
    }
    output.flush().map_err(output_error)?;
    Ok(SyncConflictResolution {
        target: comparison.target.clone(),
        expected_local_hash: comparison.local_hash.clone(),
        expected_remote_hash: comparison.remote_hash.clone(),
        expected_local_missing: comparison.local_missing,
        choices,
    })
}

fn read_answer(input: &mut impl BufRead, output: &mut impl Write) -> Result<String, String> {
    output.flush().map_err(output_error)?;
    let mut answer = String::new();
    if input
        .read_line(&mut answer)
        .map_err(|_| "无法读取终端输入，未提交选择".to_string())?
        == 0
    {
        return Err("输入结束，未提交选择".into());
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
    "无法完成终端输出，未提交选择".into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use org_tasks_core::webdav::SyncConflictChange;
    fn comparison() -> SyncConflictComparison {
        SyncConflictComparison {
            repo_id: "repo".into(),
            target: SyncConflictTarget {
                sync_id: "one".into(),
                path: "a.org".into(),
            },
            local_hash: "local".into(),
            remote_hash: "remote".into(),
            local_missing: false,
            unchanged_count: 1,
            changes: vec![SyncConflictChange {
                key: "task".into(),
                kind: OrgMergeChange::Modified,
                preamble: false,
                local: None,
                remote: None,
            }],
        }
    }
    #[test]
    fn cancellation_eof_and_rejected_final_confirmation_do_not_produce_request() {
        for input in ["q\n", "", "l\nno\n"] {
            assert!(
                review(
                    &comparison(),
                    false,
                    &mut io::Cursor::new(input),
                    &mut Vec::new()
                )
                .is_err()
            );
        }
    }
    #[test]
    fn request_contains_only_choices_and_original_version_guards() {
        let request = review(
            &comparison(),
            false,
            &mut io::Cursor::new("l\nyes\n"),
            &mut Vec::new(),
        )
        .unwrap();
        assert_eq!(request.choices[0].side, OrgMergeSide::Local);
        assert_eq!(request.expected_local_hash, "local");
        assert_eq!(request.expected_remote_hash, "remote");
        assert!(
            serde_json::to_value(request)
                .unwrap()
                .get("changes")
                .is_none()
        );
    }
}
