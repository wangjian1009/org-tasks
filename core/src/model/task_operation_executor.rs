use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use orgize::{SyntaxKind, ast::Headline, rowan::ast::AstNode};
use tokio::fs;

use super::write_intent::{read_optional, write_new};
use super::*;
use crate::CoreError;

type FileKey = (OrgRepoId, String);

struct WorkingFile {
    disk: PathBuf,
    original: Option<Vec<u8>>,
    exists: bool,
    file: OrgFile,
}

impl OrgWorkspace {
    /// 全组先在隔离文件快照中执行，成功提交后才发布内存与回退历史。
    pub async fn execute_task_operations(
        &mut self,
        group: &TaskOperationGroup,
    ) -> Result<TaskOperationResult, CoreError> {
        if group.operations.is_empty() {
            return Err(CoreError::InvalidInput("操作组不能为空"));
        }
        for id in &group.queue_repo_ids {
            if self.repo(id).is_none() {
                return Err(CoreError::InvalidInput("上传意图仓库不属于 workspace"));
            }
        }
        let mut files = load_files(self, group).await?;
        let mut paths = Vec::new();
        for operation in &group.operations {
            paths.push(execute(&mut files, operation)?);
        }
        let fallback = TaskFallbackGroup {
            files: files
                .iter()
                .filter(|(_, item)| item.original.as_deref() != Some(item.file.source_bytes()))
                .map(|((repo_id, path), item)| TaskFileFallback {
                    repo_id: repo_id.clone(),
                    file: path.clone(),
                    before: item
                        .original
                        .as_ref()
                        .map(|bytes| String::from_utf8(bytes.clone()).expect("已解析 UTF-8")),
                    after: String::from_utf8(item.file.source_bytes().to_vec())
                        .expect("已解析 UTF-8"),
                })
                .collect(),
        };
        commit(self, group, &files).await?;
        for ((id, path), item) in files {
            let repo = self.repo_mut(&id).expect("已验证仓库");
            if let Some(previous) = repo.files.iter_mut().find(|file| file.path == path) {
                *previous = item.file;
            } else {
                repo.files.push(item.file);
            }
        }
        self.task_operation_history
            .entries
            .push(TaskOperationRecord {
                operation_group: group.clone(),
                fallback_group: fallback.clone(),
            });
        let updated_repositories = fallback
            .files
            .iter()
            .map(|file| &file.repo_id)
            .collect::<BTreeSet<_>>();
        for repo_id in updated_repositories {
            super::sync_events::publish(self.repo(repo_id).expect("已验证仓库"));
        }
        Ok(TaskOperationResult { paths, fallback })
    }
}

fn key(path: &TaskPath) -> Result<FileKey, CoreError> {
    path.validate()?;
    Ok((
        path.repo_id.clone(),
        path.file
            .clone()
            .ok_or(CoreError::InvalidInput("操作必须指定文件"))?,
    ))
}

async fn load_files(
    workspace: &OrgWorkspace,
    group: &TaskOperationGroup,
) -> Result<BTreeMap<FileKey, WorkingFile>, CoreError> {
    let mut keys = BTreeSet::new();
    for operation in &group.operations {
        let (source, position) = match operation {
            TaskOperation::Creation(data) => (None, Some(&data.position)),
            TaskOperation::Modification(data) => (Some(&data.path), None),
            TaskOperation::Movement(data) => (Some(&data.path), Some(&data.position)),
            TaskOperation::Deletion(data) => (Some(&data.path), None),
        };
        if let Some(path) = source {
            keys.insert(key(path)?);
        }
        if let Some(position) = position {
            keys.insert(key(&position.parent)?);
            if let Some(after) = &position.after {
                keys.insert(key(after)?);
            }
        }
    }
    for version in &group.file_versions {
        keys.insert(key(&TaskPath::file(
            version.repo_id.clone(),
            version.file.clone(),
        ))?);
    }
    let mut files = BTreeMap::new();
    let mut disks = BTreeSet::new();
    for (repo_id, path) in keys {
        let repo = workspace
            .repo(&repo_id)
            .ok_or(CoreError::InvalidInput("路径仓库不属于 workspace"))?;
        if repo.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        // 加载阶段不创建目录，失败不得留下任何文件系统改动。
        let disk = checked_disk(Path::new(&repo.root_directory), &path).await?;
        if !disks.insert(disk.clone()) {
            return Err(CoreError::InvalidInput("仓库文件路径不能互相重叠"));
        }
        let original = read_optional(&disk).await?;
        let file = repo.parse_file(path.clone(), original.clone().unwrap_or_default())?;
        files.insert(
            (repo_id, path),
            WorkingFile {
                disk,
                exists: original.is_some(),
                original,
                file,
            },
        );
    }
    for version in &group.file_versions {
        let item = &files[&(version.repo_id.clone(), version.file.clone())];
        if item
            .original
            .as_ref()
            .map(|source| LocalFileVersion::from_bytes(source).content_hash)
            .as_deref()
            != Some(version.version.as_str())
        {
            return Err(CoreError::InvalidState("任务文件版本已变化，请刷新后重试"));
        }
    }
    Ok(files)
}

async fn checked_disk(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
    let root = fs::canonicalize(root).await.map_err(store_error)?;
    let mut disk = root;
    let parts = path.split('/').collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        disk.push(part);
        match fs::symlink_metadata(&disk).await {
            Ok(meta)
                if meta.file_type().is_symlink()
                    || (index + 1 < parts.len() && !meta.is_dir())
                    || (index + 1 == parts.len() && !meta.is_file()) =>
            {
                return Err(CoreError::InvalidInput(
                    "任务路径不能包含符号链接或非普通文件",
                ));
            }
            Ok(_) => (),
            Err(error)
                if error.kind() == std::io::ErrorKind::NotFound && index + 1 == parts.len() =>
            {
                ()
            }
            Err(error) => return Err(store_error(error)),
        }
    }
    Ok(disk)
}

fn locate(file: &OrgFile, path: &TaskPath) -> Result<Headline, CoreError> {
    file.path_headlines()
        .into_iter()
        .find(|(candidate, _)| candidate == path)
        .map(|(_, headline)| headline)
        .ok_or(CoreError::InvalidInput(
            "标题路径不存在，请使用当前完整路径",
        ))
}

fn start(headline: &Headline) -> usize {
    u32::from(headline.start()) as usize
}
fn end(headline: &Headline) -> usize {
    u32::from(headline.end()) as usize
}

fn position(file: &OrgFile, request: &TaskPosition) -> Result<(usize, usize), CoreError> {
    if key(&request.parent)? != (file.repo_id.clone(), file.path.clone()) {
        return Err(CoreError::InvalidInput("目标位置不属于当前文件"));
    }
    let parent = if request.parent.titles.is_empty() {
        None
    } else {
        Some(locate(file, &request.parent)?)
    };
    let (offset, level) = match &parent {
        Some(parent) => (
            parent
                .headlines()
                .next()
                .map(|child| start(&child))
                .unwrap_or(end(parent)),
            parent.level() + 1,
        ),
        None => (
            file.syntax()
                .document()
                .first_headline()
                .map(|item| start(&item))
                .unwrap_or(file.source_bytes().len()),
            1,
        ),
    };
    if let Some(after_path) = &request.after {
        let after = locate(file, after_path)?;
        let actual_parent = after.syntax().ancestors().skip(1).find_map(Headline::cast);
        if actual_parent.as_ref().map(start) != parent.as_ref().map(start) {
            return Err(CoreError::InvalidInput("after 必须是 parent 的直属子节点"));
        }
        Ok((end(&after), level))
    } else {
        Ok((offset, level))
    }
}

fn replace(
    file: &mut OrgFile,
    range: std::ops::Range<usize>,
    content: &[u8],
) -> Result<(), CoreError> {
    file.source_bytes.splice(range, content.iter().copied());
    file.reparse()
}

fn newline(file: &OrgFile) -> &'static str {
    if file.source_bytes().windows(2).any(|pair| pair == b"\r\n") {
        "\r\n"
    } else {
        "\n"
    }
}

fn insert(file: &mut OrgFile, offset: usize, content: &str) -> Result<(), CoreError> {
    let mut content = content.to_owned();
    let nl = newline(file);
    if offset > 0 && file.source_bytes()[offset - 1] != b'\n' {
        content.insert_str(0, nl);
    }
    if !content.ends_with('\n') {
        content.push_str(nl);
    }
    replace(file, offset..offset, content.as_bytes())
}

fn execute(
    files: &mut BTreeMap<FileKey, WorkingFile>,
    operation: &TaskOperation,
) -> Result<Option<TaskPath>, CoreError> {
    match operation {
        TaskOperation::Creation(data) => {
            let item = files
                .get_mut(&key(&data.position.parent)?)
                .expect("已加载文件");
            let (offset, level) = position(&item.file, &data.position)?;
            validate_title(&data.title)?;
            validate_state(&item.file, data.state.as_deref())?;
            validate_priority(data.priority.as_deref())?;
            validate_tags(&data.tags)?;
            let mut content = format!(
                "{} {}{}{}{}{}",
                "*".repeat(level),
                data.state
                    .as_ref()
                    .map(|s| format!("{s} "))
                    .unwrap_or_default(),
                data.priority
                    .as_ref()
                    .map(|s| format!("[#{s}] "))
                    .unwrap_or_default(),
                data.title,
                if data.tags.is_empty() {
                    String::new()
                } else {
                    format!(" :{}:", data.tags.join(":"))
                },
                newline(&item.file)
            );
            for (field, value) in [
                ("SCHEDULED", &data.scheduled),
                ("DEADLINE", &data.deadline),
                ("CLOSED", &data.closed),
            ] {
                if let Some(value) = value {
                    validate_timestamp(value)?;
                    content.push_str(&format!("{field}: {value}{}", newline(&item.file)));
                }
            }
            validate_body(&data.body)?;
            if data.record_created {
                let created = chrono::Local::now().format("[%Y-%m-%d %a %H:%M]");
                content.push_str(&format!(
                    ":PROPERTIES:{}:CREATED: {created}{}:END:{}",
                    newline(&item.file),
                    newline(&item.file),
                    newline(&item.file)
                ));
            }
            content.push_str(&normalize_newlines(&data.body, newline(&item.file)));
            let probe = item.file_source(&content)?;
            if probe.syntax().document().headlines().count() != 1
                || probe.path_headlines().len() != 1
            {
                return Err(CoreError::InvalidInput("创建正文不能引入额外标题"));
            }
            let inserted = offset
                + if offset > 0 && item.file.source_bytes()[offset - 1] != b'\n' {
                    newline(&item.file).len()
                } else {
                    0
                };
            insert(&mut item.file, offset, &content)?;
            let node = item
                .file
                .path_headlines()
                .into_iter()
                .map(|(_, node)| node)
                .find(|node| start(node) == inserted)
                .ok_or(CoreError::InvalidInput("创建后标题无法定位"))?;
            if node.title_raw().trim_end() != data.title.trim_end()
                || node.todo_keyword().map(|token| token.to_string()) != data.state
                || node.priority().map(|token| token.to_string()) != data.priority
                || node
                    .tags()
                    .map(|token| token.to_string())
                    .collect::<Vec<_>>()
                    != data.tags
            {
                return Err(CoreError::InvalidInput(
                    "标题或状态不能被 Org 重新解释为其他字段",
                ));
            }
            item.exists = true;
            Ok(Some(path_at(&item.file, inserted)?))
        }
        TaskOperation::Modification(data) => {
            let item = files.get_mut(&key(&data.path)?).expect("已加载文件");
            let mut offset = start(&locate(&item.file, &data.path)?);
            if data.modifications.is_empty() {
                return Err(CoreError::InvalidInput("字段修改列表不能为空"));
            }
            for modification in &data.modifications {
                let headline = item
                    .file
                    .path_headlines()
                    .into_iter()
                    .map(|(_, node)| node)
                    .find(|node| start(node) == offset)
                    .ok_or(CoreError::InvalidState("修改后标题无法定位"))?;
                modify(&mut item.file, &headline, modification)?;
                let updated = item
                    .file
                    .path_headlines()
                    .into_iter()
                    .map(|(_, node)| node)
                    .find(|node| start(node) == offset)
                    .ok_or(CoreError::InvalidInput("字段修改破坏了标题结构"))?;
                match modification {
                    TaskModification::Title(value)
                        if updated.title_raw().trim_end()
                            != value.as_deref().unwrap_or("").trim_end()
                            || updated.todo_keyword().map(|token| token.to_string())
                                != headline.todo_keyword().map(|token| token.to_string())
                            || updated.priority() != headline.priority()
                            || updated
                                .tags()
                                .map(|token| token.to_string())
                                .collect::<Vec<_>>()
                                != headline
                                    .tags()
                                    .map(|token| token.to_string())
                                    .collect::<Vec<_>>() =>
                    {
                        return Err(CoreError::InvalidInput(
                            "标题或状态不能被 Org 重新解释为其他字段",
                        ));
                    }
                    TaskModification::Todo(value)
                        if updated.todo_keyword().map(|token| token.to_string()) != *value
                            || updated.title_raw() != headline.title_raw() =>
                    {
                        return Err(CoreError::InvalidInput(
                            "标题或状态不能被 Org 重新解释为其他字段",
                        ));
                    }
                    _ => (),
                }
                // 所有字段操作只影响本标题及其正文，标题起点不变。
                offset = start(&headline);
            }
            Ok(Some(path_at(&item.file, offset)?))
        }
        TaskOperation::Deletion(data) => {
            let item = files.get_mut(&key(&data.path)?).expect("已加载文件");
            let headline = locate(&item.file, &data.path)?;
            replace(&mut item.file, start(&headline)..end(&headline), &[])?;
            Ok(None)
        }
        TaskOperation::Movement(data) => {
            let source_key = key(&data.path)?;
            let target_key = key(&data.position.parent)?;
            if !files[&target_key].exists {
                return Err(CoreError::InvalidInput("移动目标文件不存在"));
            }
            let source = &files[&source_key].file;
            let headline = locate(source, &data.path)?;
            let (mut offset, level) = position(&files[&target_key].file, &data.position)?;
            let range = start(&headline)..end(&headline);
            if source_key == target_key {
                for path in std::iter::once(&data.position.parent).chain(data.position.after.iter())
                {
                    if !path.titles.is_empty() && range.contains(&start(&locate(source, path)?)) {
                        return Err(CoreError::InvalidInput("不能移动到自身、后代或自身之后"));
                    }
                }
            }
            let mut content = headline.raw();
            let mut edits = headline
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
                .map(|node| {
                    (
                        start(&node) - range.start,
                        node.level(),
                        "*".repeat(level + node.level() - headline.level()),
                    )
                })
                .collect::<Vec<_>>();
            edits.sort_by_key(|(offset, _, _)| std::cmp::Reverse(*offset));
            for (offset, length, stars) in edits {
                content.replace_range(offset..offset + length, &stars);
            }
            // 用目标 TODO 配置验证整个移动子树的语义不会变化。
            let mut probe = files[&target_key].file.clone();
            let inserted_start = offset
                + if offset > 0 && probe.source_bytes()[offset - 1] != b'\n' {
                    newline(&probe).len()
                } else {
                    0
                };
            insert(&mut probe, offset, &content)?;
            let inserted = probe
                .path_headlines()
                .into_iter()
                .map(|(_, node)| node)
                .find(|node| start(node) == inserted_start)
                .ok_or(CoreError::InvalidInput("目标位置无法插入标题"))?;
            let original_nodes = headline
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
                .collect::<Vec<_>>();
            let moved_nodes = inserted
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
                .collect::<Vec<_>>();
            if original_nodes.len() != moved_nodes.len()
                || original_nodes.iter().zip(&moved_nodes).any(|(a, b)| {
                    a.title_raw() != b.title_raw()
                        || a.todo_keyword().map(|s| s.to_string())
                            != b.todo_keyword().map(|s| s.to_string())
                })
            {
                return Err(CoreError::InvalidInput(
                    "目标文件不能保留移动子树的标题或 TODO 状态",
                ));
            }
            replace(
                &mut files.get_mut(&source_key).unwrap().file,
                range.clone(),
                &[],
            )?;
            if source_key == target_key && offset >= range.end {
                offset -= range.len();
            }
            let target = &mut files.get_mut(&target_key).unwrap().file;
            let inserted = offset
                + if offset > 0 && target.source_bytes()[offset - 1] != b'\n' {
                    newline(target).len()
                } else {
                    0
                };
            insert(target, offset, &content)?;
            Ok(Some(path_at(target, inserted)?))
        }
    }
}

fn path_at(file: &OrgFile, offset: usize) -> Result<TaskPath, CoreError> {
    file.path_headlines()
        .into_iter()
        .find(|(_, node)| start(node) == offset)
        .map(|(path, _)| path)
        .ok_or(CoreError::InvalidState("操作后标题无法重新定位"))
}

impl WorkingFile {
    fn file_source(&self, source: &str) -> Result<OrgFile, CoreError> {
        let mut probe = self.file.clone();
        probe.source_bytes = source.as_bytes().to_vec();
        probe.reparse()?;
        Ok(probe)
    }
}

fn validate_title(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() || value.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput("标题不能为空或包含控制字符"));
    }
    Ok(())
}
fn validate_state(file: &OrgFile, value: Option<&str>) -> Result<(), CoreError> {
    if value.is_some_and(|value| {
        !file
            .todo
            .pending_keywords
            .iter()
            .chain(&file.todo.done_keywords)
            .any(|state| state == value)
    }) {
        return Err(CoreError::InvalidInput("TODO 状态不属于目标文件配置"));
    }
    Ok(())
}
fn validate_priority(value: Option<&str>) -> Result<(), CoreError> {
    if value.is_some_and(|value| value.len() != 1 || !value.as_bytes()[0].is_ascii_uppercase()) {
        return Err(CoreError::InvalidInput("优先级必须是单个大写字母"));
    }
    Ok(())
}
fn validate_tags(values: &[String]) -> Result<(), CoreError> {
    if values.iter().any(|value| {
        value.is_empty()
            || !value
                .chars()
                .all(|c| c.is_alphanumeric() || matches!(c, '_' | '@' | '#' | '%'))
    }) {
        return Err(CoreError::InvalidInput("标签包含无效字符"));
    }
    Ok(())
}
fn validate_body(value: &str) -> Result<(), CoreError> {
    if value.contains('\0') {
        return Err(CoreError::InvalidInput("正文不能包含 NUL"));
    }
    // 临时解析只用于验证，宿主不参与 Org 解析。
    let probe = orgize::Org::parse(&format!("* probe\n{value}"));
    if probe
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .count()
        != 1
    {
        return Err(CoreError::InvalidInput("正文不能引入标题节点"));
    }
    Ok(())
}
fn normalize_newlines(value: &str, nl: &str) -> String {
    value
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\n', nl)
}
fn validate_timestamp(value: &str) -> Result<(), CoreError> {
    let parsed = orgize::Org::parse(value);
    let timestamp = parsed
        .first_node::<orgize::ast::Timestamp>()
        .ok_or(CoreError::InvalidInput("规划值必须是完整 Org 时间戳"))?;
    let year = timestamp.year_start().and_then(|s| s.parse::<i32>().ok());
    let month = timestamp.month_start().and_then(|s| s.parse::<u32>().ok());
    let day = timestamp.day_start().and_then(|s| s.parse::<u32>().ok());
    let invalid_time = [timestamp.hour_start(), timestamp.hour_end()]
        .into_iter()
        .flatten()
        .any(|token| token.parse::<u32>().map_or(true, |hour| hour > 23))
        || [timestamp.minute_start(), timestamp.minute_end()]
            .into_iter()
            .flatten()
            .any(|token| token.parse::<u32>().map_or(true, |minute| minute > 59));
    let invalid_end = timestamp.year_end().is_some()
        && timestamp
            .year_end()
            .and_then(|y| y.parse::<i32>().ok())
            .zip(timestamp.month_end().and_then(|m| m.parse::<u32>().ok()))
            .zip(timestamp.day_end().and_then(|d| d.parse::<u32>().ok()))
            .and_then(|((y, m), d)| chrono::NaiveDate::from_ymd_opt(y, m, d))
            .is_none();
    if timestamp.raw() != value
        || value.chars().any(char::is_control)
        || invalid_time
        || invalid_end
        || year
            .zip(month)
            .zip(day)
            .and_then(|((y, m), d)| chrono::NaiveDate::from_ymd_opt(y, m, d))
            .is_none()
    {
        return Err(CoreError::InvalidInput("规划值必须是有效的完整 Org 时间戳"));
    }
    Ok(())
}

pub(super) fn modify(
    file: &mut OrgFile,
    headline: &Headline,
    modification: &TaskModification,
) -> Result<(), CoreError> {
    match modification {
        TaskModification::Title(value) => {
            if let Some(value) = value {
                validate_title(value)?;
            }
            let node = headline
                .syntax()
                .children()
                .find(|node| node.kind() == SyntaxKind::HEADLINE_TITLE)
                .ok_or(CoreError::InvalidInput("标题文字节点不存在"))?;
            let raw = node.to_string();
            let trailing = raw.len() - raw.trim_end_matches([' ', '\t']).len();
            replace(
                file,
                u32::from(node.text_range().start()) as usize
                    ..u32::from(node.text_range().end()) as usize - trailing,
                value.as_deref().unwrap_or("").as_bytes(),
            )
        }
        TaskModification::Todo(value) => {
            validate_state(file, value.as_deref())?;
            if let Some(token) = headline.todo_keyword() {
                let a = u32::from(token.text_range().start()) as usize;
                let mut b = a + token.len();
                if value.is_none() && file.source_bytes().get(b) == Some(&b' ') {
                    b += 1;
                }
                replace(file, a..b, value.as_deref().unwrap_or("").as_bytes())
            } else if let Some(value) = value {
                let a = start(headline) + headline.level() + 1;
                replace(file, a..a, format!("{value} ").as_bytes())
            } else {
                Ok(())
            }
        }
        TaskModification::Priority(value) => {
            validate_priority(value.as_deref())?;
            if let Some(node) = headline
                .syntax()
                .children()
                .find(|node| node.kind() == SyntaxKind::HEADLINE_PRIORITY)
            {
                let a = u32::from(node.text_range().start()) as usize;
                let mut b = u32::from(node.text_range().end()) as usize;
                if value.is_none() && file.source_bytes().get(b) == Some(&b' ') {
                    b += 1;
                }
                let content = value
                    .as_ref()
                    .map(|s| format!("[#{s}]"))
                    .unwrap_or_default();
                replace(file, a..b, content.as_bytes())
            } else if let Some(value) = value {
                let a = headline
                    .todo_keyword()
                    .map(|token| u32::from(token.text_range().end()) as usize + 1)
                    .unwrap_or(start(headline) + headline.level() + 1);
                replace(file, a..a, format!("[#{value}] ").as_bytes())
            } else {
                Ok(())
            }
        }
        TaskModification::Tags(value) => {
            let tags = value.clone().unwrap_or_default();
            validate_tags(&tags)?;
            let content = if tags.is_empty() {
                String::new()
            } else {
                format!(":{}:", tags.join(":"))
            };
            if let Some(node) = headline
                .syntax()
                .children()
                .find(|node| node.kind() == SyntaxKind::HEADLINE_TAGS)
            {
                replace(
                    file,
                    u32::from(node.text_range().start()) as usize
                        ..u32::from(node.text_range().end()) as usize,
                    content.as_bytes(),
                )
            } else if !content.is_empty() {
                let line_end = file.source_bytes()[start(headline)..]
                    .iter()
                    .position(|b| *b == b'\n')
                    .map(|n| start(headline) + n)
                    .unwrap_or(file.source_bytes().len());
                let a = if file.source_bytes().get(line_end.wrapping_sub(1)) == Some(&b'\r') {
                    line_end - 1
                } else {
                    line_end
                };
                replace(file, a..a, format!(" {content}").as_bytes())
            } else {
                Ok(())
            }
        }
        TaskModification::Body(value) => {
            let content = value.as_deref().unwrap_or("");
            validate_body(content)?;
            let mut content = normalize_newlines(content, newline(file));
            if !content.is_empty() && !content.ends_with('\n') {
                content.push_str(newline(file));
            }
            // 正文不包括规划行和属性抽屉；保留元数据及所有子标题。
            let section = headline.section();
            let a = section
                .as_ref()
                .map(|s| u32::from(s.start()) as usize)
                .unwrap_or_else(|| {
                    file.source_bytes()[start(headline)..]
                        .iter()
                        .position(|b| *b == b'\n')
                        .map(|n| start(headline) + n + 1)
                        .unwrap_or(file.source_bytes().len())
                });
            let b = section
                .as_ref()
                .map(|s| u32::from(s.end()) as usize)
                .unwrap_or(a);
            let mut body_start = a;
            if let Some((_, end, _)) = planning_lines(file, headline).last() {
                body_start = body_start.max(*end);
            }
            if let Some(properties) = headline.properties() {
                body_start = body_start.max(u32::from(properties.end()) as usize);
            }
            if body_start == file.source_bytes().len()
                && body_start > 0
                && file.source_bytes()[body_start - 1] != b'\n'
                && !content.is_empty()
            {
                content.insert_str(0, newline(file));
            }
            replace(file, body_start..b.max(body_start), content.as_bytes())
        }
        TaskModification::Notes(value) => {
            let value = value.as_deref().unwrap_or("");
            validate_body(value)?;
            let ranges = super::task_inline::note_ranges(headline);
            let at = ranges
                .first()
                .map(|range| range.start)
                .unwrap_or_else(|| inline_body_start(file, headline));
            let nl = newline(file).to_owned();
            let mut content = normalize_newlines(value, &nl);
            if !content.is_empty() && !content.ends_with('\n') {
                content.push_str(&nl);
            }
            for range in ranges.iter().rev() {
                replace(file, range.clone(), &[])?;
            }
            if at > 0 && file.source_bytes().get(at - 1) != Some(&b'\n') && !content.is_empty() {
                content.insert_str(0, &nl);
            }
            replace(file, at..at, content.as_bytes())
        }
        TaskModification::Checklist(change) => modify_checklist(file, headline, change),
        TaskModification::ScheduleDate(value) => {
            let value = planning_date_value(headline.scheduled(), value)?;
            planning(
                file,
                headline,
                "SCHEDULED",
                SyntaxKind::PLANNING_SCHEDULED,
                &value,
            )
        }
        TaskModification::DeadlineDate(value) => {
            let value = planning_date_value(headline.deadline(), value)?;
            planning(
                file,
                headline,
                "DEADLINE",
                SyntaxKind::PLANNING_DEADLINE,
                &value,
            )
        }
        TaskModification::Schedule(value) => planning(
            file,
            headline,
            "SCHEDULED",
            SyntaxKind::PLANNING_SCHEDULED,
            value,
        ),
        TaskModification::Deadline(value) => planning(
            file,
            headline,
            "DEADLINE",
            SyntaxKind::PLANNING_DEADLINE,
            value,
        ),
        TaskModification::Closed(value) => {
            planning(file, headline, "CLOSED", SyntaxKind::PLANNING_CLOSED, value)
        }
        TaskModification::Created(value) => created(file, headline, value),
        TaskModification::AddressLink(value) => {
            let change = value
                .as_ref()
                .ok_or(CoreError::InvalidInput("地址链接替换必须提供新旧地址"))?;
            if !(change.new_uri.starts_with("geo:") || change.new_uri.starts_with("addr:"))
                || change
                    .new_uri
                    .chars()
                    .any(|c| c.is_control() || matches!(c, '[' | ']'))
            {
                return Err(CoreError::InvalidInput("地址链接无效"));
            }
            let link = headline
                .syntax()
                .descendants()
                .filter_map(orgize::ast::Link::cast)
                .find(|link| link.path().as_ref() == change.old_uri)
                .ok_or(CoreError::InvalidInput("任务中没有指定地址链接"))?;
            let token = link.path();
            replace(
                file,
                u32::from(token.text_range().start()) as usize
                    ..u32::from(token.text_range().end()) as usize,
                change.new_uri.as_bytes(),
            )
        }
    }
}

fn created(
    file: &mut OrgFile,
    headline: &Headline,
    value: &Option<String>,
) -> Result<(), CoreError> {
    if let Some(value) = value {
        validate_timestamp(value)?;
    }
    if let Some(drawer) = headline.properties() {
        let mut ranges = drawer
            .node_properties()
            .filter(|property| {
                property
                    .syntax()
                    .children_with_tokens()
                    .filter_map(|item| item.into_token())
                    .any(|token| {
                        token.kind() == SyntaxKind::TEXT
                            && token.text().eq_ignore_ascii_case("CREATED")
                    })
            })
            .map(|property| {
                u32::from(property.start()) as usize..u32::from(property.end()) as usize
            })
            .collect::<Vec<_>>();
        if !ranges.is_empty() {
            ranges.sort_by_key(|range| std::cmp::Reverse(range.start));
            let count = ranges.len();
            for (index, range) in ranges.into_iter().enumerate() {
                let content = if index + 1 == count {
                    value
                        .as_ref()
                        .map(|v| format!(":CREATED: {v}{}", newline(file)))
                        .unwrap_or_default()
                } else {
                    String::new()
                };
                replace(file, range, content.as_bytes())?;
            }
            Ok(())
        } else if let Some(value) = value {
            let a = u32::from(drawer.content_start()) as usize;
            replace(
                file,
                a..a,
                format!(":CREATED: {value}{}", newline(file)).as_bytes(),
            )
        } else {
            Ok(())
        }
    } else if let Some(value) = value {
        let a = planning_lines(file, headline)
            .last()
            .map(|(_, end, _)| *end)
            .unwrap_or_else(|| {
                file.source_bytes()[start(headline)..]
                    .iter()
                    .position(|b| *b == b'\n')
                    .map(|n| start(headline) + n + 1)
                    .unwrap_or(file.source_bytes().len())
            });
        let prefix = if a > 0 && file.source_bytes()[a - 1] != b'\n' {
            newline(file)
        } else {
            ""
        };
        replace(
            file,
            a..a,
            format!(
                "{prefix}:PROPERTIES:{}:CREATED: {value}{}:END:{}",
                newline(file),
                newline(file),
                newline(file)
            )
            .as_bytes(),
        )
    } else {
        Ok(())
    }
}

fn planning_date_value(
    existing: Option<orgize::ast::Timestamp>,
    value: &Option<String>,
) -> Result<Option<String>, CoreError> {
    let Some(value) = value else { return Ok(None) };
    let day = chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| CoreError::InvalidInput("日期必须是 YYYY-MM-DD"))?;
    if value.len() != 10 {
        return Err(CoreError::InvalidInput("日期必须是 YYYY-MM-DD"));
    }
    let Some(timestamp) = existing else {
        return Ok(Some(format!("<{value}>")));
    };
    let mut raw = timestamp.raw();
    let offset = u32::from(timestamp.start()) as usize;
    if let Some(token) = timestamp
        .syntax()
        .children_with_tokens()
        .find(|node| node.kind() == SyntaxKind::TIMESTAMP_DAYNAME)
    {
        let a = u32::from(token.text_range().start()) as usize - offset;
        let b = u32::from(token.text_range().end()) as usize - offset;
        raw.replace_range(a..b, &day.format("%a").to_string());
    }
    raw.replace_range(1..11, value);
    validate_timestamp(&raw)?;
    Ok(Some(raw))
}

fn inline_body_start(file: &OrgFile, headline: &Headline) -> usize {
    let mut at = file.source_bytes()[start(headline)..]
        .iter()
        .position(|b| *b == b'\n')
        .map(|n| start(headline) + n + 1)
        .unwrap_or(file.source_bytes().len());
    if let Some((_, end, _)) = planning_lines(file, headline).last() {
        at = at.max(*end);
    }
    if let Some(properties) = headline.properties() {
        at = at.max(u32::from(properties.end()) as usize);
    }
    at
}

fn checklist_line_end(file: &OrgFile, item: &orgize::ast::ListItem) -> usize {
    let a = u32::from(item.start()) as usize;
    let b = u32::from(item.end()) as usize;
    let raw = std::str::from_utf8(&file.source_bytes()[a..b]).expect("UTF-8");
    let content_end = a + raw.trim_end_matches(['\r', '\n']).len();
    file.source_bytes()[content_end..b]
        .iter()
        .position(|b| *b == b'\n')
        .map(|n| content_end + n + 1)
        .unwrap_or(b)
}

fn modify_checklist(
    file: &mut OrgFile,
    headline: &Headline,
    change: &TaskChecklistChange,
) -> Result<(), CoreError> {
    let text = match change {
        TaskChecklistChange::Add { text } | TaskChecklistChange::Edit { text, .. } => Some(text),
        _ => None,
    };
    if let Some(text) = text {
        if text.trim().is_empty() || text.chars().any(char::is_control) {
            return Err(CoreError::InvalidInput("清单条目不能为空或包含换行"));
        }
        // 新文本不能改变条目结构或吞并为描述列表。
        let org = orgize::Org::parse(&format!("- [ ] {text}\n"));
        let item = org
            .first_node::<orgize::ast::ListItem>()
            .ok_or(CoreError::InvalidInput("清单条目无效"))?;
        if item.tag().next().is_some() {
            return Err(CoreError::InvalidInput("清单条目不能变为描述列表"));
        }
    }
    let items = super::task_inline::checklist_items(headline);
    if let TaskChecklistChange::Add { text } = change {
        let lists = super::task_inline::checklist_lists(headline);
        let last = lists.last().and_then(|list| list.items().last());
        let at = last
            .as_ref()
            .map(|item| checklist_line_end(file, item))
            .unwrap_or_else(|| {
                headline
                    .section()
                    .map(|section| u32::from(section.end()) as usize)
                    .unwrap_or_else(|| inline_body_start(file, headline))
            });
        let nl = newline(file);
        let prefix = if last.is_none()
            && headline
                .section()
                .map(|s| s.syntax().children().any(|n| n.kind() == SyntaxKind::LIST))
                .unwrap_or(false)
        {
            if file.source_bytes().get(at.wrapping_sub(1)) == Some(&b'\n') {
                "\n\n"
            } else {
                "\n\n\n"
            }
        } else if at > 0 && file.source_bytes()[at - 1] != b'\n' {
            nl
        } else {
            ""
        };
        let prefix = normalize_newlines(prefix, nl);
        return replace(file, at..at, format!("{prefix}- [ ] {text}{nl}").as_bytes());
    }
    let id = match change {
        TaskChecklistChange::Edit { id, .. }
        | TaskChecklistChange::SetChecked { id, .. }
        | TaskChecklistChange::Remove { id } => id,
        _ => unreachable!(),
    };
    let item = items
        .into_iter()
        .find(|item| u32::from(item.start()).to_string() == *id)
        .ok_or(CoreError::InvalidInput("清单条目不存在或已改变"))?;
    match change {
        TaskChecklistChange::Edit { text, .. } => {
            let range = super::task_inline::item_text_range(file, &item);
            let content = if file.source_bytes().get(range.start.wrapping_sub(1)) == Some(&b']') { format!(" {text}") } else { text.clone() };
            replace(file, range, content.as_bytes())
        },
        TaskChecklistChange::SetChecked { checked, .. } => {
            let token = item.checkbox().expect("checkbox");
            replace(
                file,
                u32::from(token.text_range().start()) as usize
                    ..u32::from(token.text_range().end()) as usize,
                if *checked { b"X" } else { b" " },
            )
        }
        TaskChecklistChange::Remove { .. } => replace(
            file,
            u32::from(item.start()) as usize..checklist_line_end(file, &item),
            &[],
        ),
        _ => unreachable!(),
    }
}

fn planning_lines(
    file: &OrgFile,
    headline: &Headline,
) -> Vec<(usize, usize, Vec<(SyntaxKind, usize, usize)>)> {
    let source = file.source_bytes();
    let mut cursor = source[start(headline)..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map(|n| start(headline) + n + 1)
        .unwrap_or(source.len());
    let mut lines = Vec::new();
    while cursor < end(headline) {
        let line_end = source[cursor..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|n| cursor + n + 1)
            .unwrap_or(source.len());
        let line = std::str::from_utf8(&source[cursor..line_end]).expect("已解析 UTF-8");
        let prefix = "* probe\n";
        let syntax = orgize::Org::parse(&format!("{prefix}{line}"));
        let Some(planning) = syntax.first_node::<orgize::ast::Planning>() else {
            break;
        };
        let fields = planning
            .syntax()
            .children()
            .filter(|node| {
                matches!(
                    node.kind(),
                    SyntaxKind::PLANNING_SCHEDULED
                        | SyntaxKind::PLANNING_DEADLINE
                        | SyntaxKind::PLANNING_CLOSED
                )
            })
            .map(|node| {
                (
                    node.kind(),
                    cursor + u32::from(node.text_range().start()) as usize - prefix.len(),
                    cursor + u32::from(node.text_range().end()) as usize - prefix.len(),
                )
            })
            .collect::<Vec<_>>();
        if fields.is_empty() {
            break;
        }
        lines.push((cursor, line_end, fields));
        cursor = line_end;
    }
    lines
}

fn planning(
    file: &mut OrgFile,
    headline: &Headline,
    name: &str,
    kind: SyntaxKind,
    value: &Option<String>,
) -> Result<(), CoreError> {
    if let Some(value) = value {
        validate_timestamp(value)?;
    }
    let lines = planning_lines(file, headline);
    let mut edits = Vec::new();
    let mut found = false;
    for (a, b, fields) in &lines {
        let matching = fields
            .iter()
            .filter(|(field, _, _)| *field == kind)
            .collect::<Vec<_>>();
        if matching.is_empty() {
            continue;
        }
        if value.is_none() && matching.len() == fields.len() {
            edits.push((*a, *b, String::new()));
            found = true;
            continue;
        }
        for (_, a, b) in matching {
            let content = if !found {
                value
                    .as_ref()
                    .map(|value| format!("{name}: {value}"))
                    .unwrap_or_default()
            } else {
                String::new()
            };
            let trailing = file.source_bytes()[*a..*b]
                .iter()
                .rev()
                .take_while(|byte| matches!(byte, b' ' | b'\t'))
                .count();
            edits.push((*a, *b - trailing, content));
            found = true;
        }
    }
    if !found {
        if let Some(value) = value {
            if let Some((a, _, _)) = lines.first() {
                edits.push((*a, *a, format!("{name}: {value} ")));
            } else {
                let a = file.source_bytes()[start(headline)..]
                    .iter()
                    .position(|byte| *byte == b'\n')
                    .map(|n| start(headline) + n + 1)
                    .unwrap_or(file.source_bytes().len());
                let prefix = if a > 0 && file.source_bytes()[a - 1] != b'\n' {
                    newline(file)
                } else {
                    ""
                };
                edits.push((a, a, format!("{prefix}{name}: {value}{}", newline(file))));
            }
        }
    }
    edits.sort_by_key(|(a, _, _)| std::cmp::Reverse(*a));
    for (a, b, content) in edits {
        replace(file, a..b, content.as_bytes())?;
    }
    Ok(())
}

struct Prepared {
    target: PathBuf,
    temporary: PathBuf,
    rollback: PathBuf,
    original: Option<Vec<u8>>,
    after: Vec<u8>,
}

async fn commit(
    workspace: &OrgWorkspace,
    group: &TaskOperationGroup,
    files: &BTreeMap<FileKey, WorkingFile>,
) -> Result<(), CoreError> {
    commit_prepared(workspace, group, files, None).await
}

async fn commit_prepared(
    workspace: &OrgWorkspace,
    group: &TaskOperationGroup,
    files: &BTreeMap<FileKey, WorkingFile>,
    fail_after: Option<usize>,
) -> Result<(), CoreError> {
    let nonce = super::service::generate_repo_id()?;
    let mut prepared: Vec<Prepared> = Vec::new();
    let mut created_dirs = Vec::new();
    let mut written = 0;
    let result = async {
        for ((repo_id, path), item) in files {
            if item.original.as_deref() == Some(item.file.source_bytes()) {
                continue;
            }
            if read_optional(&item.disk).await? != item.original {
                return Err(CoreError::InvalidState("任务文件已被外部修改"));
            }
            let temporary = item
                .disk
                .with_file_name(format!(".{nonce}-{}.tmp", prepared.len()));
            let rollback = item
                .disk
                .with_file_name(format!(".{nonce}-{}.rollback", prepared.len()));
            prepared.push(Prepared {
                target: item.disk.clone(),
                temporary,
                rollback,
                original: item.original.clone(),
                after: item.file.source_bytes().to_vec(),
            });
            if group.queue_repo_ids.contains(repo_id) {
                let root = Path::new(&workspace.repo(repo_id).unwrap().root_directory);
                let directory = root.join(".sync/outbox");
                for controlled in [root.join(".sync"), directory.clone()] {
                    match fs::symlink_metadata(&controlled).await {
                        Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                            return Err(CoreError::InvalidInput(
                                "同步控制路径必须是仓库内的真实目录",
                            ));
                        }
                        Ok(_) => (),
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                        Err(error) => return Err(store_error(error)),
                    }
                }
                if !fs::try_exists(&directory).await.map_err(store_error)? {
                    fs::create_dir(&directory).await.map_err(store_error)?;
                    created_dirs.push(directory.clone());
                }
                let target = directory.join(format!("{nonce}-{}.json", prepared.len()));
                let content = serde_json::to_vec(&OrgRepoWriteIntent {
                    relative_path: path.clone(),
                    content_hash: LocalFileVersion::from_bytes(item.file.source_bytes())
                        .content_hash,
                })
                .map_err(|_| CoreError::InvalidState("无法序列化上传意图"))?;
                prepared.push(Prepared {
                    temporary: target.with_extension("tmp"),
                    rollback: target.with_extension("rollback"),
                    target,
                    original: None,
                    after: content,
                });
            }
        }
        for item in &prepared {
            write_new(&item.temporary, &item.after).await?;
            if let Some(original) = &item.original {
                write_new(&item.rollback, original).await?;
            }
        }
        // 所有临时文件与回退字节准备成功后再修改任意正式路径。
        for item in &prepared {
            if read_optional(&item.target).await? != item.original {
                return Err(CoreError::InvalidState("提交前文件已被外部修改"));
            }
        }
        for item in &prepared {
            if fail_after == Some(written) {
                return Err(CoreError::Store("测试注入提交故障".into()));
            }
            if read_optional(&item.target).await? != item.original {
                return Err(CoreError::InvalidState("提交时文件已被外部修改"));
            }
            fs::rename(&item.temporary, &item.target)
                .await
                .map_err(store_error)?;
            written += 1;
        }
        Ok(())
    }
    .await;
    if result.is_err() {
        for item in prepared[..written].iter().rev() {
            if read_optional(&item.target).await?.as_deref() != Some(item.after.as_slice()) {
                return Err(CoreError::Store(
                    "回滚期间检测到外部写入，保留回退文件供恢复".into(),
                ));
            }
            if item.original.is_some() {
                fs::rename(&item.rollback, &item.target)
                    .await
                    .map_err(store_error)?;
            } else {
                fs::remove_file(&item.target).await.map_err(store_error)?;
            }
        }
    }
    for item in &prepared {
        let _ = fs::remove_file(&item.temporary).await;
        let _ = fs::remove_file(&item.rollback).await;
    }
    if result.is_err() {
        for directory in created_dirs.iter().rev() {
            let _ = fs::remove_dir(directory).await;
        }
    }
    result
}
fn store_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法执行任务操作组: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn failures_during_each_commit_step_restore_all_files_and_outbox() {
        for failure in 0..4 {
            let root = std::env::temp_dir().join(format!(
                "task-operation-rollback-{}",
                super::super::service::generate_repo_id().unwrap()
            ));
            fs::create_dir(&root).await.unwrap();
            fs::write(root.join("a.org"), b"* A\n").await.unwrap();
            fs::write(root.join("b.org"), b"* B\r\n").await.unwrap();
            let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
            repo.load::<crate::webdav::WebDavSyncPolicy>()
                .await
                .unwrap();
            let id = repo.id.clone();
            let workspace = OrgWorkspace::new(vec![repo]).unwrap();
            let group = TaskOperationGroup {
                operations: vec![
                    TaskOperation::Deletion(TaskDeletion {
                        path: TaskPath {
                            repo_id: id.clone(),
                            file: Some("a.org".into()),
                            titles: vec!["A".into()],
                            occurrence: 1,
                        },
                    }),
                    TaskOperation::Deletion(TaskDeletion {
                        path: TaskPath {
                            repo_id: id.clone(),
                            file: Some("b.org".into()),
                            titles: vec!["B".into()],
                            occurrence: 1,
                        },
                    }),
                ],
                queue_repo_ids: vec![id],
                ..Default::default()
            };
            let mut files = load_files(&workspace, &group).await.unwrap();
            for operation in &group.operations {
                execute(&mut files, operation).unwrap();
            }
            assert!(
                commit_prepared(&workspace, &group, &files, Some(failure))
                    .await
                    .is_err()
            );
            assert_eq!(fs::read(root.join("a.org")).await.unwrap(), b"* A\n");
            assert_eq!(fs::read(root.join("b.org")).await.unwrap(), b"* B\r\n");
            assert!(!root.join(".sync/outbox").exists());
            assert_eq!(std::fs::read_dir(&root).unwrap().count(), 3);
            fs::remove_dir_all(root).await.unwrap();
        }
    }
}
