//! 冲突丢弃复用普通任务操作组，不建立独立解决会话。
use clap::{Args, Subcommand};
use org_tasks_core::{webdav::{WebDavSyncContextDetail, WebDavSyncFileDetail}, *};
type History = Vec<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>>;
#[derive(Args)]
pub(crate) struct ConflictCommand { #[command(subcommand)] target: ConflictTarget }
#[derive(Subcommand)]
enum ConflictTarget {
    /// 列出当前文件中的冲突定位 ID
    List { #[arg(long)] json: bool },
    /// 丢弃指定文件的全部冲突点，只修改本地文件
    Discard { path: String },
}
pub(crate) async fn run(repo: OrgRepo, _history: History, command: ConflictCommand) -> Result<(), String> {
    match command.target {
        ConflictTarget::List { json } => {
            let files = repo.load_files(&[]).await.map_err(|e|e.to_string())?.iter().filter(|file| file.has_conflict())
                .map(|file| serde_json::json!({ "path": file.path, "ids": file.conflict_ids() })).collect::<Vec<_>>();
            if json { println!("{}", serde_json::to_string_pretty(&files).map_err(|e|e.to_string())?); }
            else { for file in files { println!("{}", file); } }
        }
        ConflictTarget::Discard { path } => {
            let file = repo.file(&path).await.map_err(|e| e.to_string())?;
            let ids = file.conflict_ids();
            if ids.is_empty() { return Err("此文件没有可丢弃的冲突点".into()); }
            let group = TaskOperationGroup {
                operations: ids.into_iter().map(|id| TaskOperation::ConfilictSelection(TaskConfilictSelection { path:None, target:None,id,action:TaskConfilictAction::Discard})).collect(),
                file_versions: vec![TaskFileVersion { repo_id:repo.id.clone(), file:path, version:LocalFileVersion::from_bytes(file.source_bytes()).content_hash }],
                queue_repo_ids: vec![repo.id.clone()],
            };
            OrgWorkspace::new(vec![repo]).map_err(|e|e.to_string())?.execute_task_operations(&group).await.map_err(|e|e.to_string())?;
            println!("已丢弃全部冲突，后续同步上传本地结果。");
        }
    }
    Ok(())
}
