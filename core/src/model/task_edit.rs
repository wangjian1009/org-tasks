use std::path::{Path, PathBuf};

use orgize::{ast::Headline, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};
use tokio::fs;

use super::creation::{read_optional, write_new};
use super::{
    LocalFileVersion, OrgFile, OrgRepo, OrgRepoId, OrgRepoWriteIntent, OrgWorkspace, SourcePosition,
};
use crate::{CoreError, filter::tasks_from_repo};

/// 任务所在文件的版本与逻辑身份；位置变化后不能误操作另一条记录。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskSource {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub task_id: String,
    pub file_version: String,
}

/// parent 为空时放入文件顶部；clear_todo 清理根标题的状态、优先级和规划信息。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskDestination {
    pub repo_id: OrgRepoId,
    pub path: String,
    pub file_version: String,
    pub parent: Option<SourcePosition>,
    #[serde(default)]
    pub clear_todo: bool,
}

/// destination 为空表示删除，否则保真移动整个子树。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskEdit {
    pub source: TaskSource,
    pub destination: Option<TaskDestination>,
    #[serde(default)]
    pub queue_repo_ids: Vec<OrgRepoId>,
}

struct Change {
    repo_id: OrgRepoId,
    path: String,
    disk: PathBuf,
    original: Vec<u8>,
    file: OrgFile,
    temporary: PathBuf,
    intent: Option<PathBuf>,
}

impl OrgWorkspace {
    pub fn task_source(&self, task_id: &str) -> Result<TaskSource, CoreError> {
        for repo in self.repos() {
            if let Some(task) = tasks_from_repo(repo)
                .into_iter()
                .find(|task| task.id == task_id)
            {
                let file = repo
                    .files()
                    .iter()
                    .find(|file| file.path == task.path)
                    .unwrap();
                return Ok(TaskSource {
                    repo_id: repo.id.clone(),
                    path: task.path,
                    task_id: task.id,
                    file_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                });
            }
        }
        Err(CoreError::InvalidInput("源任务已不存在，请刷新收件箱"))
    }

    pub fn task_source_for(&self, task: &crate::FilterTask) -> Result<TaskSource, CoreError> {
        let file = self
            .repo(&task.repo_id)
            .and_then(|repo| repo.files().iter().find(|file| file.path == task.path))
            .ok_or(CoreError::InvalidInput("任务文件已不存在"))?;
        Ok(TaskSource {
            repo_id: task.repo_id.clone(),
            path: task.path.clone(),
            task_id: task.id.clone(),
            file_version: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
        })
    }

    pub async fn edit_task(&mut self, edit: &TaskEdit) -> Result<(), CoreError> {
        let (source_repo, source, source_disk) = self
            .checked_task_file(
                &edit.source.repo_id,
                &edit.source.path,
                &edit.source.file_version,
            )
            .await?;
        let mut projection = source_repo.clone();
        projection.files = vec![source.clone()];
        let task = tasks_from_repo(&projection)
            .into_iter()
            .find(|task| task.id == edit.source.task_id)
            .ok_or(CoreError::InvalidInput("源任务已不存在，请刷新收件箱"))?;
        let headline = source
            .syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .find(|headline| u32::from(headline.start()) as u64 == task.byte_offset)
            .ok_or(CoreError::InvalidInput("源任务位置已失效"))?;
        let start = u32::from(headline.start()) as usize;
        let end = u32::from(headline.end()) as usize;
        let mut remaining = source.source_bytes().to_vec();
        remaining.drain(start..end);
        let nonce = super::service::generate_repo_id()?;
        let mut changes = Vec::new();
        if let Some(destination) = &edit.destination {
            let (target_repo, target, target_disk) = self
                .checked_task_file(
                    &destination.repo_id,
                    &destination.path,
                    &destination.file_version,
                )
                .await?;
            let same = source_disk == target_disk;
            let (mut offset, level) = if let Some(position) = destination.parent {
                // 提交时仍必须是当前文件中显式标记的放置位置。
                if !target_repo.refile_targets().iter().any(|item| {
                    item.path == target.path
                        && item.position == position
                        && item.file_version == destination.file_version
                }) {
                    return Err(CoreError::InvalidState("任务目标已变化，请重新选择"));
                }
                let parent = target
                    .syntax()
                    .document()
                    .syntax()
                    .descendants()
                    .filter_map(Headline::cast)
                    .find(|item| u32::from(item.start()) as u64 == position.byte_offset)
                    .ok_or(CoreError::InvalidInput("任务目标位置无效"))?;
                if same && (start..end).contains(&(u32::from(parent.start()) as usize)) {
                    return Err(CoreError::InvalidInput("不能把任务移动到自身或其子节点"));
                }
                (
                    parent
                        .headlines()
                        .next()
                        .map(|child| u32::from(child.start()) as usize)
                        .unwrap_or(u32::from(parent.end()) as usize),
                    parent.level() + 1,
                )
            } else {
                (
                    target
                        .syntax()
                        .document()
                        .first_headline()
                        .map(|item| u32::from(item.start()) as usize)
                        .unwrap_or(target.source_bytes().len()),
                    1,
                )
            };
            let mut moved = moved_subtree(&headline, level, destination.clear_todo);
            let mut target_bytes = if same {
                remaining.clone()
            } else {
                target.source_bytes().to_vec()
            };
            if same && offset >= end {
                offset -= end - start;
            }
            let newline = if target.source_bytes().windows(2).any(|pair| pair == b"\r\n") {
                "\r\n"
            } else {
                "\n"
            };
            if offset > 0 && target_bytes[offset - 1] != b'\n' {
                moved.insert_str(0, newline);
            }
            if !moved.ends_with('\n') {
                moved.push_str(newline);
            }
            let inserted_start = offset
                + if moved.starts_with(newline) {
                    newline.len()
                } else {
                    0
                };
            target_bytes.splice(offset..offset, moved.bytes());
            let updated = target_repo.parse_file(target.path.clone(), target_bytes)?;
            // 拒绝目标 TODO 配置把状态字解释成标题，或无法插入真实标题的语法环境。
            let mut check = target_repo.clone();
            check.files = vec![updated.clone()];
            if !tasks_from_repo(&check).iter().any(|item| {
                item.byte_offset as usize == inserted_start
                    && item.title == task.title
                    && (destination.clear_todo || item.state == task.state)
            }) {
                return Err(CoreError::InvalidInput(
                    "目标文件不能保留此任务标题或 TODO 状态，请检查文件配置",
                ));
            }
            changes.push(change(
                &target_repo,
                &target,
                target_disk,
                updated,
                &nonce,
                edit,
            ));
            if !same {
                let updated = source_repo.parse_file(source.path.clone(), remaining)?;
                changes.push(change(
                    &source_repo,
                    &source,
                    source_disk,
                    updated,
                    &nonce,
                    edit,
                ));
            }
        } else {
            let updated = source_repo.parse_file(source.path.clone(), remaining)?;
            changes.push(change(
                &source_repo,
                &source,
                source_disk,
                updated,
                &nonce,
                edit,
            ));
        }
        // 先写目标再移除源任务。失败时回滚；备份也覆盖进程中断时的恢复需要。
        commit(&changes, &nonce, self).await?;
        for change in changes {
            let repo = self.repo_mut(&change.repo_id).unwrap();
            if let Some(file) = repo.files.iter_mut().find(|file| file.path == change.path) {
                *file = change.file;
            }
        }
        Ok(())
    }

    async fn checked_task_file(
        &self,
        id: &OrgRepoId,
        path: &str,
        version: &str,
    ) -> Result<(OrgRepo, OrgFile, PathBuf), CoreError> {
        let repo = self
            .repo(id)
            .ok_or(CoreError::InvalidInput("任务所属仓库已失效"))?;
        super::validate_relative_path(path)?;
        if !path.to_ascii_lowercase().ends_with(".org")
            || path.split('/').any(|p| p == ".sync" || p == "..")
        {
            return Err(CoreError::InvalidInput("任务文件路径无效"));
        }
        if repo.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        // 整理只接受已有文件，不因失效路径重新创建目录。
        let mut disk = PathBuf::from(&repo.root_directory);
        let parts = path.split('/').collect::<Vec<_>>();
        for (index, part) in parts.iter().enumerate() {
            disk.push(part);
            let metadata = fs::symlink_metadata(&disk)
                .await
                .map_err(|_| CoreError::InvalidState("任务文件已不存在或无法访问，请刷新"))?;
            if metadata.file_type().is_symlink()
                || (index + 1 < parts.len() && !metadata.is_dir())
                || (index + 1 == parts.len() && !metadata.is_file())
            {
                return Err(CoreError::InvalidInput(
                    "任务文件不能包含符号链接或非普通文件",
                ));
            }
        }
        let bytes = read_optional(&disk)
            .await?
            .ok_or(CoreError::InvalidState("任务文件已不存在，请刷新"))?;
        if LocalFileVersion::from_bytes(&bytes).content_hash != version {
            return Err(CoreError::InvalidState("任务文件已变化，请刷新后重试"));
        }
        let file = repo.parse_file(path.into(), bytes)?;
        let mut snapshot = repo.clone();
        if let Some(old) = snapshot.files.iter_mut().find(|file| file.path == path) {
            *old = file.clone();
        } else {
            snapshot.files.push(file.clone());
        }
        Ok((snapshot, file, disk))
    }
}

fn moved_subtree(headline: &Headline, level: usize, clear_todo: bool) -> String {
    let original_start = u32::from(headline.start()) as usize;
    let original_level = headline.level();
    let mut content = headline.raw();
    let mut edits = headline
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .map(|child| {
            (
                u32::from(child.start()) as usize - original_start,
                child.level(),
                "*".repeat(level + child.level() - original_level),
            )
        })
        .collect::<Vec<_>>();
    if clear_todo {
        if let Some(keyword) = headline.todo_keyword() {
            let start = u32::from(keyword.text_range().start()) as usize - original_start;
            let end = start + keyword.len();
            let space = content
                .as_bytes()
                .get(end)
                .is_some_and(|byte| *byte == b' ');
            edits.push((start, keyword.len() + usize::from(space), String::new()));
        }
        if let Some(priority) = headline
            .syntax()
            .children()
            .find(|node| node.kind() == orgize::SyntaxKind::HEADLINE_PRIORITY)
        {
            let start = u32::from(priority.text_range().start()) as usize - original_start;
            let end = u32::from(priority.text_range().end()) as usize - original_start;
            let space = content
                .as_bytes()
                .get(end)
                .is_some_and(|byte| *byte == b' ');
            edits.push((start, end - start + usize::from(space), String::new()));
        }
    }
    edits.sort_by_key(|(offset, _, _)| std::cmp::Reverse(*offset));
    for (offset, length, replacement) in edits {
        content.replace_range(offset..offset + length, &replacement);
    }
    if clear_todo {
        // 仅移除根标题开头的真实规划行；连续规划行逐次重新解析，正文和子标题不受影响。
        while let Some(planning) = orgize::Org::parse(&content)
            .first_node::<Headline>()
            .and_then(|root| root.planning())
        {
            content.replace_range(
                u32::from(planning.start()) as usize..u32::from(planning.end()) as usize,
                "",
            );
        }
    }
    content
}

fn change(
    repo: &OrgRepo,
    original: &OrgFile,
    disk: PathBuf,
    file: OrgFile,
    nonce: &str,
    edit: &TaskEdit,
) -> Change {
    Change {
        repo_id: repo.id.clone(),
        path: file.path.clone(),
        temporary: disk.with_file_name(format!(
            ".{nonce}.{}.task.tmp",
            LocalFileVersion::from_bytes(original.path.as_bytes()).content_hash
        )),
        disk,
        original: original.source_bytes().to_vec(),
        file,
        intent: edit.queue_repo_ids.contains(&repo.id).then(|| {
            Path::new(&repo.root_directory)
                .join(".sync/outbox")
                .join(format!(
                    "{nonce}-{}.json",
                    LocalFileVersion::from_bytes(original.path.as_bytes()).content_hash
                ))
        }),
    }
}

async fn commit(
    changes: &[Change],
    nonce: &str,
    workspace: &OrgWorkspace,
) -> Result<(), CoreError> {
    let mut written = Vec::new();
    let result = async {
        for change in changes {
            if read_optional(&change.disk).await?.as_deref() != Some(change.original.as_slice()) {
                return Err(CoreError::InvalidState("任务文件已变化，请刷新后重试"));
            }
            let repo = workspace.repo(&change.repo_id).unwrap();
            let backup = Path::new(&repo.root_directory)
                .join(".sync/backups")
                .join(format!("task-edit-{nonce}"))
                .join(&change.path);
            fs::create_dir_all(backup.parent().unwrap())
                .await
                .map_err(store_error)?;
            write_new(&backup, &change.original).await?;
            write_new(&change.temporary, change.file.source_bytes()).await?;
            if let Some(intent) = &change.intent {
                fs::create_dir_all(intent.parent().unwrap())
                    .await
                    .map_err(store_error)?;
                let payload = serde_json::to_vec(&OrgRepoWriteIntent {
                    relative_path: change.path.clone(),
                    content_hash: LocalFileVersion::from_bytes(change.file.source_bytes())
                        .content_hash,
                })
                .map_err(|_| CoreError::InvalidState("无法生成任务写入意图"))?;
                write_new(intent, &payload).await?;
            }
        }
        for (index, change) in changes.iter().enumerate() {
            if read_optional(&change.disk).await?.as_deref() != Some(change.original.as_slice()) {
                return Err(CoreError::InvalidState("任务文件已变化，请刷新后重试"));
            }
            fs::rename(&change.temporary, &change.disk)
                .await
                .map_err(store_error)?;
            written.push(index);
        }
        Ok(())
    }
    .await;
    if result.is_err() {
        for index in written.into_iter().rev() {
            let change = &changes[index];
            if read_optional(&change.disk).await?.as_deref() == Some(change.file.source_bytes()) {
                write_new(&change.temporary, &change.original).await?;
                fs::rename(&change.temporary, &change.disk)
                    .await
                    .map_err(store_error)?;
            }
        }
        for change in changes {
            let _ = fs::remove_file(&change.temporary).await;
            if let Some(intent) = &change.intent {
                let _ = fs::remove_file(intent).await;
            }
        }
    }
    result
}

fn store_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法保存任务整理结果: {error}"))
}
