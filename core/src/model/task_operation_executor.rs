use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use orgize::{SyntaxKind, ast::Headline, rowan::ast::AstNode};
use tokio::fs;

use super::write_intent::{read_optional, write_new};
use super::*;
use crate::CoreError;

pub(super) type FileKey = (OrgRepoId, String);

struct WorkingFile {
    disk: PathBuf,
    original: Option<Vec<u8>>,
    exists: bool,
    file: OrgFile,
}

impl OrgWorkspace {
    /// 按当前原文与版本规划普通操作，不写盘或发布历史。
    pub async fn task_merge_operations(&self, request: &TaskMergeRequest) -> Result<TaskMergePlan, CoreError> {
        let first = request.paths.first().ok_or(CoreError::InvalidInput("请至少选择两条记录"))?;
        let file = first.file.clone().ok_or(CoreError::InvalidInput("合并必须指定文件"))?;
        if request.paths.iter().any(|path| path.repo_id != first.repo_id || path.file != first.file) {
            return Err(CoreError::InvalidInput("合并记录必须位于同一文件"));
        }
        let repo = self.repo(&first.repo_id).ok_or(CoreError::InvalidInput("路径仓库不属于 workspace"))?;
        let _guard = super::access::enter(Path::new(&repo.root_directory), &repo.id).await?;
        let loading = TaskOperationGroup {
            operations: request.paths.iter().map(|path| TaskOperation::Deletion(TaskDeletion { path: path.clone() })).collect(),
            file_versions: vec![TaskFileVersion { repo_id: first.repo_id.clone(), file, version: request.file_version.clone() }],
            ..Default::default()
        };
        let files = load_files(self, &loading).await?;
        super::task_merging::operations(&files[&key(first)?].file, request)
    }

    /// 全组先在隔离文件快照中执行，成功提交后才发布内存与回退历史。
    pub async fn execute_task_operations(
        &mut self,
        group: &TaskOperationGroup,
    ) -> Result<(), CoreError> {
        if super::conflict_preview::has_preview_path(group) {
            return self.execute_preview_operations(group).await;
        }
        if group.operations.is_empty() {
            return Err(CoreError::InvalidInput("操作组不能为空"));
        }
        let source_group = group;
        let mut resolved_group = group.clone();
        for operation in &mut resolved_group.operations {
            if let TaskOperation::ConfilictSelection(selection) = operation {
                if selection.path.is_none() { selection.path = Some(selection_path(self, selection).await?); }
            }
        }
        let group = &resolved_group;
        for id in &group.queue_repo_ids {
            if self.repo(id).is_none() {
                return Err(CoreError::InvalidInput("上传意图仓库不属于 workspace"));
            }
        }
        let mut touched = BTreeSet::new();
        for operation in &group.operations {
            match operation {
                TaskOperation::ConfilictSelection(data) => {
                    touched.insert(selection_path(self, data).await?.repo_id);
                }
                TaskOperation::Creation(data) => {
                    touched.insert(data.position.parent.repo_id.clone());
                    if let Some(after) = &data.position.after {
                        touched.insert(after.repo_id.clone());
                    }
                }
                TaskOperation::Modification(data) => {
                    touched.insert(data.path.repo_id.clone());
                }
                TaskOperation::Deletion(data) => {
                    touched.insert(data.path.repo_id.clone());
                }
                TaskOperation::Movement(data) => {
                    touched.insert(data.path.repo_id.clone());
                    touched.insert(data.position.parent.repo_id.clone());
                    if let Some(after) = &data.position.after {
                        touched.insert(after.repo_id.clone());
                    }
                }
            }
        }
        touched.extend(group.file_versions.iter().map(|v| v.repo_id.clone()));
        let mut roots = BTreeMap::new();
        for id in touched {
            let repo = self
                .repo(&id)
                .ok_or(CoreError::InvalidInput("路径仓库不属于 workspace"))?;
            let root = tokio::fs::canonicalize(&repo.root_directory)
                    .await
                    .map_err(|_| CoreError::Store("操作仓库目录不可读取".into()))?
                    .to_string_lossy()
                    .into_owned();
            if roots.insert(root, repo.id.clone()).is_some_and(|previous| previous != repo.id) {
                return Err(CoreError::InvalidInput("同一磁盘目录不能具有不同仓库身份"));
            }
        }
        let mut guards = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        for root in roots.keys() {
            guards.push(crate::webdav::transaction::lock_before(Path::new(root), deadline).await?);
        }
        for (root, id) in &roots {
            super::access::recover(Path::new(root), id).await?;
        }
        let mut files = load_files(self, group).await?;
        for operation in &group.operations {
            execute(&mut files, operation)?;
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
        self.task_operation_history
            .entries
            .push(TaskOperationRecord {
                operation_group: source_group.clone(),
                fallback_group: fallback.clone(),
            });
        let updated_repositories = fallback
            .files
            .iter()
            .map(|file| &file.repo_id)
            .collect::<BTreeSet<_>>();
        drop(guards);
        for repo_id in updated_repositories {
            super::sync_events::publish(self.repo(repo_id).expect("已验证仓库"));
        }
        Ok(())
    }
}

async fn selection_path(workspace: &OrgWorkspace, data: &TaskConfilictSelection) -> Result<TaskPath, CoreError> {
    if let Some(path) = &data.path {
        path.validate()?;
        if !path.titles.is_empty() || path.file.is_none() { return Err(CoreError::InvalidInput("冲突选择必须指定文件根路径")); }
        return Ok(path.clone());
    }
    let id = &data.id;
    let mut paths = Vec::new();
    for repo in workspace.repos() {
        for file in repo.load_files(&[]).await? {
            if file.conflict_ids().iter().any(|value| value == id) { paths.push(file.full_path()); }
        }
    }
    if paths.len() != 1 {
        return Err(CoreError::InvalidInput("冲突点不存在或 ID 重复，请刷新"));
    }
    Ok(paths[0].clone())
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
            TaskOperation::ConfilictSelection(data) => {
                keys.insert(key(&selection_path(workspace, data).await?)?);
                (None, None)
            }
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
        let source = original.clone().unwrap_or_default();
        let setup = super::service::load_setup_settings(Path::new(&repo.root_directory), &path, &source).await?;
        let file = repo.parse_file_with_setup(path.clone(), source, setup)?;
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

pub(super) async fn checked_disk(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
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

pub(super) fn locate(file: &OrgFile, path: &TaskPath) -> Result<Headline, CoreError> {
    let headline = file
        .path_headlines()
        .into_iter()
        .find(|(candidate, _)| candidate == path)
        .map(|(_, headline)| headline)
        .ok_or(CoreError::InvalidInput(
            "标题路径不存在，请使用当前完整路径",
        ))?;
    if OrgFile::is_conflict_headline(&headline) {
        return Err(CoreError::InvalidInput("不能修改冲突节点或其子树的内容"));
    }
    Ok(headline)
}

pub(super) fn start(headline: &Headline) -> usize {
    u32::from(headline.start()) as usize
}
pub(super) fn end(headline: &Headline) -> usize {
    u32::from(headline.end()) as usize
}

pub(super) fn position(file: &OrgFile, request: &TaskPosition) -> Result<(usize, usize), CoreError> {
    if key(&request.parent)? != key(&file.full_path())? {
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

pub(super) fn replace(
    file: &mut OrgFile,
    range: std::ops::Range<usize>,
    content: &[u8],
) -> Result<(), CoreError> {
    super::editor::ensure_editable_range(file, range.start, range.end)?;
    file.source_bytes.splice(range, content.iter().copied());
    file.reparse()
}

pub(super) fn newline(file: &OrgFile) -> &'static str {
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
    if matches!(operation, TaskOperation::ConfilictSelection(_)) {
        return execute_inner(files, operation);
    }
    // 先在完整快照上校验，不能借临时分离容器绕过冲突路径保护。
    match operation {
        TaskOperation::Modification(data) => {
            locate(&files[&key(&data.path)?].file, &data.path)?;
        }
        TaskOperation::Deletion(data) => {
            locate(&files[&key(&data.path)?].file, &data.path)?;
        }
        TaskOperation::Movement(data) => {
            locate(&files[&key(&data.path)?].file, &data.path)?;
            position(&files[&key(&data.position.parent)?].file, &data.position)?;
        }
        TaskOperation::Creation(data) => {
            position(&files[&key(&data.position.parent)?].file, &data.position)?;
        }
        TaskOperation::ConfilictSelection(_) => unreachable!(),
    }
    // 普通操作只编辑主树；把容器及其专属分隔符原样放回，避免正文替换或插入吞掉分隔符。
    let mut blocks = Vec::new();
    for (key, item) in files.iter_mut() {
        if let Some(container) = super::conflict::container(&item.file) {
            let range = super::conflict::block_range(&item.file, &container);
            if range.end != item.file.source_bytes().len() {
                continue;
            }
            blocks.push((
                key.clone(),
                item.file.source_bytes()[range.clone()].to_vec(),
            ));
            item.file.source_bytes.drain(range);
            item.file.reparse()?;
        }
    }
    let path = execute_inner(files, operation)?;
    for (key, block) in blocks {
        let file = &mut files.get_mut(&key).unwrap().file;
        file.source_bytes.extend(block);
        file.reparse()?;
    }
    Ok(path)
}

fn execute_inner(
    files: &mut BTreeMap<FileKey, WorkingFile>,
    operation: &TaskOperation,
) -> Result<Option<TaskPath>, CoreError> {
    match operation {
        TaskOperation::ConfilictSelection(data) => {
            let keys = files
                .iter()
                .filter(|((repo_id, path), item)| data.path.as_ref().is_none_or(|p| &p.repo_id == repo_id && p.file.as_ref() == Some(path)) && item.file.conflict_ids().iter().any(|id| id == &data.id))
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>();
            if keys.len() != 1 {
                return Err(CoreError::InvalidInput("冲突点不存在或 ID 重复，请刷新"));
            }
            let item = files.get_mut(&keys[0]).unwrap();
            super::conflict::select(&mut item.file, data)
        }
        TaskOperation::Creation(data) => {
            let item = files
                .get_mut(&key(&data.position.parent)?)
                .expect("已加载文件");
            let (offset, level) = position(&item.file, &data.position)?;
            validate_title(&data.title)?;
            validate_state(&item.file, data.state.as_deref())?;
            item.file.validate_priority(data.priority.as_deref())?;
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
            let mut planning_fields = Vec::new();
            for (field, value) in [
                ("SCHEDULED", &data.scheduled),
                ("DEADLINE", &data.deadline),
            ] {
                if let Some(value) = value {
                    validate_timestamp(value)?;
                    planning_fields.push(format!("{field}: {value}"));
                }
            }
            if !planning_fields.is_empty() {
                content.push_str(&planning_fields.join(" "));
                content.push_str(newline(&item.file));
            }
            validate_body(&data.body)?;
            let now = chrono::Local::now().naive_local();
            let timestamp = now
                .format("[%Y-%m-%d %a %H:%M]")
                .to_string();
            content.push_str(&format!(
                ":PROPERTIES:{}:CREATED: {timestamp}{}:END:{}",
                newline(&item.file),
                newline(&item.file),
                newline(&item.file)
            ));
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
            super::task_state::log_created_completion(&mut item.file, &node, now)?;
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
                let ordinal = item.file.path_headlines().iter()
                    .position(|(_, node)| start(node) == offset)
                    .ok_or(CoreError::InvalidState("修改前标题无法定位"))?;
                let headline = item
                    .file
                    .path_headlines()
                    .into_iter()
                    .map(|(_, node)| node)
                    .find(|node| start(node) == offset)
                    .ok_or(CoreError::InvalidState("修改后标题无法定位"))?;
                modify(&mut item.file, &headline, modification)?;
                // 各字段在写入处校验边界；重复调度允许更新标题内的真实时间戳。
                let updated = item.file.path_headlines().into_iter().nth(ordinal)
                    .ok_or(CoreError::InvalidInput("字段修改破坏了标题结构"))?.1;
                // 字段修改期间保留本标题起点，父级统计在全部字段完成后更新。
                offset = start(&updated);
            }
            if data
                .modifications
                .iter()
                .any(|change| matches!(change, TaskModification::Todo(_)))
            {
                let changed = item
                    .file
                    .path_headlines()
                    .into_iter()
                    .map(|(_, node)| node)
                    .find(|node| start(node) == offset)
                    .ok_or(CoreError::InvalidState("修改后标题无法定位"))?;
                for (range, value) in super::title_statistics::parent_edits(&item.file, &changed)
                    .into_iter()
                    .rev()
                {
                    offset = offset - (range.end - range.start) + value.len();
                    replace(&mut item.file, range, value.as_bytes())?;
                }
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

pub(super) fn path_at(file: &OrgFile, offset: usize) -> Result<TaskPath, CoreError> {
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
pub(super) fn validate_state(file: &OrgFile, value: Option<&str>) -> Result<(), CoreError> {
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

fn update_title_counts(
    file: &mut OrgFile,
    offset: usize,
    trigger: super::title_statistics::Trigger,
) -> Result<(), CoreError> {
    let headline = file
        .path_headlines()
        .into_iter()
        .map(|(_, node)| node)
        .find(|node| start(node) == offset)
        .ok_or(CoreError::InvalidState("修改后标题无法定位"))?;
    for (range, value) in super::title_statistics::title_edits(file, &headline, trigger)
        .into_iter()
        .rev()
    {
        replace(file, range, value.as_bytes())?;
    }
    Ok(())
}

fn validate_timestamp(value: &str) -> Result<(), CoreError> {
    let masked = super::task_state::mask_repeater_windows(value);
    let parsed = orgize::Org::parse(&masked);
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
    if timestamp.raw() != masked
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
        TaskModification::Link(change) => super::text_link::modify_link(file, headline, change),
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
            )?;
            let updated = file
                .path_headlines()
                .into_iter()
                .map(|(_, node)| node)
                .find(|node| start(node) == start(headline))
                .ok_or(CoreError::InvalidInput("字段修改破坏了标题结构"))?;
            // 先验证输入仍是标题文字，再更新派生统计，不能放宽字段边界。
            if updated.title_raw().trim_end() != value.as_deref().unwrap_or("").trim_end()
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
                        .collect::<Vec<_>>()
            {
                return Err(CoreError::InvalidInput(
                    "标题或状态不能被 Org 重新解释为其他字段",
                ));
            }
            update_title_counts(file, start(headline), super::title_statistics::Trigger::Title)
        }
        TaskModification::Todo(value) => super::task_state::modify(file, headline, value.as_deref()),
        TaskModification::Priority(value) => {
            file.validate_priority(value.as_deref())?;
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
            let ranges = super::task_inline::note_ranges(file, headline);
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
        TaskModification::Checklist(change) => {
            modify_checklist(file, headline, change)?;
            if matches!(
                change,
                TaskChecklistChange::Add { .. }
                    | TaskChecklistChange::SetChecked { .. }
                    | TaskChecklistChange::Remove { .. }
            ) {
                // 条目编辑后重取语法节点，统计与 checkbox 在同一事务内提交和通知。
                update_title_counts(file, start(headline), super::title_statistics::Trigger::Checkbox)?;
            }
            Ok(())
        }
        TaskModification::ScheduleRepeat(value) => super::task_repeat::modify_repeat(file, headline, SyntaxKind::PLANNING_SCHEDULED, value),
        TaskModification::DeadlineRepeat(value) => super::task_repeat::modify_repeat(file, headline, SyntaxKind::PLANNING_DEADLINE, value),
        TaskModification::Schedule(value) => modify_planning_value(file, headline, "SCHEDULED", SyntaxKind::PLANNING_SCHEDULED, value),
        TaskModification::Deadline(value) => modify_planning_value(file, headline, "DEADLINE", SyntaxKind::PLANNING_DEADLINE, value),
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

fn modify_planning_value(file: &mut OrgFile, headline: &Headline, name: &str, kind: SyntaxKind, value: &Option<TaskPlanningValue>) -> Result<(), CoreError> {
    let existing = super::task_repeat::planning_timestamp(file, headline, kind);
    let updated = match value {
        None => None,
        Some(TaskPlanningValue::Timestamp(raw)) => { validate_timestamp(raw)?; Some(raw.clone()) },
        Some(TaskPlanningValue::Edit(edit)) => Some(planning_edit_value(existing.clone(), edit)?),
    };
    if let (Some(existing), Some(updated)) = (existing, &updated) {
        for (_, _, fields) in planning_lines(file, headline) {
            for (field, a, b) in fields {
                if field != kind { continue; }
                let raw = std::str::from_utf8(&file.source_bytes()[a..b]).expect("UTF-8");
                let offset = raw.find(['<', '[']).expect("已有时间戳");
                return replace(file, a + offset..a + offset + existing.len(), updated.as_bytes());
            }
        }
    }
    planning(file, headline, name, kind, &updated)
}

fn planning_edit_value(existing: Option<String>, edit: &TaskPlanningEdit) -> Result<String, CoreError> {
    let day = chrono::NaiveDate::parse_from_str(&edit.date, "%Y-%m-%d")
        .map_err(|_| CoreError::InvalidInput("日期必须是有效的 YYYY-MM-DD"))?;
    if edit.date.len() != 10 || !(1..=9999).contains(&chrono::Datelike::year(&day)) {
        return Err(CoreError::InvalidInput("日期必须是有效的 YYYY-MM-DD"));
    }
    let mut raw = existing.unwrap_or_else(|| format!("<{}>", edit.date));
    let masked = super::task_state::mask_repeater_windows(&raw);
    let parsed = orgize::Org::parse(&masked);
    let timestamp = parsed.first_node::<orgize::ast::Timestamp>()
        .ok_or(CoreError::InvalidInput("规划时间戳无效"))?;
    let offset = u32::from(timestamp.start()) as usize;
    let mut time_at = 11;
    if let Some(token) = timestamp.syntax().children_with_tokens().find(|node| node.kind() == SyntaxKind::TIMESTAMP_DAYNAME) {
        let a = u32::from(token.text_range().start()) as usize - offset;
        let b = u32::from(token.text_range().end()) as usize - offset;
        raw.replace_range(a..b, &day.format("%a").to_string());
        time_at = a + 3;
    }
    raw.replace_range(1..11, &edit.date);
    if let Some(time) = &edit.time {
        let replacement = match time {
            None => String::new(),
            Some(time) => {
                let start = parse_planning_time(&time.start)?;
                if let Some(end) = &time.end {
                    if parse_planning_time(end)? <= start { return Err(CoreError::InvalidInput("结束时间必须晚于开始时间")); }
                    format!("{}-{}", time.start, end)
                } else { time.start.clone() }
            }
        };
        // 只修改首个时间戳的时刻，跨日期范围的尾部和所有修饰符保持原样。
        let close = raw.find(['>', ']']).ok_or(CoreError::InvalidInput("规划时间戳无效"))?;
        let time_range = raw[..close].split_whitespace().find(|part| part.as_bytes().get(2) == Some(&b':'))
            .and_then(|part| raw[..close].find(part).map(|at| at..at + part.len()));
        if let Some(range) = time_range {
            if replacement.is_empty() {
                let mut at = range.start;
                while at > 11 && raw.as_bytes()[at - 1] == b' ' { at -= 1; }
                raw.replace_range(at..range.end, "");
            } else { raw.replace_range(range, &replacement); }
        } else if !replacement.is_empty() {
            raw.insert_str(time_at, &format!(" {replacement}"));
        }
    }
    validate_timestamp(&raw)?;
    // 小时重复离不开具体时刻，清除时拒绝而不破坏原规则。
    if edit.time == Some(None) && super::task_repeat::has_hourly_repeater(&raw) {
        return Err(CoreError::InvalidInput("按小时重复需要具体时刻，请先修改重复规则"));
    }
    Ok(raw)
}

fn parse_planning_time(value: &str) -> Result<chrono::NaiveTime, CoreError> {
    if value.len() != 5 || !value.bytes().enumerate().all(|(i, b)| if i == 2 { b == b':' } else { b.is_ascii_digit() }) {
        return Err(CoreError::InvalidInput("时间必须是 HH:MM"));
    }
    chrono::NaiveTime::parse_from_str(value, "%H:%M").map_err(|_| CoreError::InvalidInput("时间必须是有效的 HH:MM"))
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
        | TaskChecklistChange::Remove { id }
        | TaskChecklistChange::Move { id, .. } => id,
        _ => unreachable!(),
    };
    let item = items
        .into_iter()
        .find(|item| u32::from(item.start()).to_string() == *id)
        .ok_or(CoreError::InvalidInput("清单条目不存在或已改变"))?;
    match change {
        TaskChecklistChange::Edit { text, .. } => {
            let range = super::task_inline::item_text_range(file, &item);
            let content = if file.source_bytes().get(range.start.wrapping_sub(1)) == Some(&b']') {
                format!(" {text}")
            } else {
                text.clone()
            };
            replace(file, range, content.as_bytes())
        }
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
        TaskChecklistChange::Move { before_id, .. } => move_checklist_item(file, &item, before_id),
        _ => unreachable!(),
    }
}

fn move_checklist_item(
    file: &mut OrgFile,
    item: &orgize::ast::ListItem,
    before_id: &Option<String>,
) -> Result<(), CoreError> {
    let list = item
        .syntax()
        .parent()
        .and_then(orgize::ast::List::cast)
        .ok_or(CoreError::InvalidInput("清单条目的父列表无效"))?;
    let siblings: Vec<_> = list.items().collect();
    let source_index = siblings
        .iter()
        .position(|sibling| sibling.start() == item.start())
        .expect("同级条目");
    let target_index = match before_id {
        Some(id) => siblings
            .iter()
            .position(|sibling| u32::from(sibling.start()).to_string() == *id)
            .ok_or(CoreError::InvalidInput("只能在同一清单的同级条目之间排序"))?,
        None => siblings.len(),
    };
    if target_index == source_index || target_index == source_index + 1 {
        return Ok(());
    }
    let mut order: Vec<_> = (0..siblings.len()).collect();
    order.remove(source_index);
    order.insert(
        if target_index > source_index { target_index - 1 } else { target_index },
        source_index,
    );
    let first = order.iter().enumerate()
        .position(|(slot, index)| slot != *index).expect("顺序已变化");
    let last = order.iter().enumerate()
        .rposition(|(slot, index)| slot != *index).expect("顺序已变化");
    let ranges: Vec<_> = siblings.iter()
        .map(|sibling| u32::from(sibling.start()) as usize..checklist_line_end(file, sibling))
        .collect();
    let source = file.source_bytes();
    let mut result = Vec::new();
    // 分隔空行留在原槽位，避免随片段移动后堆成两条空行并拆散 Org 列表。
    for slot in first..=last {
        let content = &source[ranges[order[slot]].clone()];
        result.extend_from_slice(content);
        if slot < last {
            if !content.ends_with(b"\n") {
                result.extend_from_slice(newline(file).as_bytes());
            }
            result.extend_from_slice(&source[ranges[slot].end..ranges[slot + 1].start]);
        }
    }
    replace(file, ranges[first].start..ranges[last].end, &result)
}

pub(super) fn planning_lines(
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
        let masked = super::task_state::mask_repeater_windows(line);
        let syntax = orgize::Org::parse(&format!("{prefix}{masked}"));
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

pub(super) fn planning(
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
    for (line_start, line_end, fields) in &lines {
        let matching = fields
            .iter()
            .filter(|(field, _, _)| *field == kind)
            .collect::<Vec<_>>();
        if matching.is_empty() {
            continue;
        }
        if value.is_none() && matching.len() == fields.len() {
            edits.push((*line_start, *line_end, String::new()));
            found = true;
            continue;
        }
        for (_, field_start, field_end) in matching {
            let leading = file.source_bytes()[*field_start..*field_end].iter()
                .take_while(|byte| matches!(byte, b' ' | b'\t')).count();
            let prefix = std::str::from_utf8(&file.source_bytes()[*field_start..*field_start + leading]).expect("ASCII");
            let content = if !found {
                value
                    .as_ref()
                    .map(|value| format!("{prefix}{name}: {value}"))
                    .unwrap_or_default()
            } else {
                String::new()
            };
            let trailing = file.source_bytes()[*field_start..*field_end]
                .iter()
                .rev()
                .take_while(|byte| matches!(byte, b' ' | b'\t'))
                .count();
            let mut edit_start = *field_start;
            let mut edit_end = *field_end - trailing;
            if value.is_none() {
                let is_first = fields
                    .first()
                    .is_some_and(|(_, first_start, _)| *first_start == *field_start);
                if is_first {
                    while edit_end < *line_end
                        && matches!(file.source_bytes()[edit_end], b' ' | b'\t')
                    {
                        edit_end += 1;
                    }
                } else {
                    while edit_start > *line_start
                        && matches!(file.source_bytes()[edit_start - 1], b' ' | b'\t')
                    {
                        edit_start -= 1;
                    }
                }
            }
            edits.push((edit_start, edit_end, content));
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
    let changed = !edits.is_empty();
    for (a, b, content) in edits {
        replace(file, a..b, content.as_bytes())?;
    }
    if changed {
        compact_planning_lines(file, start(headline))?;
    }
    Ok(())
}

/// 状态或规划字段发生写入后，将连续的规划行收拢为 Org 常用的单行形式。
/// 仅在行内没有其他正文时合并，避免改动规划行后附带的用户内容。
fn compact_planning_lines(file: &mut OrgFile, offset: usize) -> Result<(), CoreError> {
    let headline = file
        .path_headlines()
        .into_iter()
        .map(|(_, node)| node)
        .find(|node| start(node) == offset)
        .ok_or(CoreError::InvalidInput("规划字段修改破坏了标题结构"))?;
    let lines = planning_lines(file, &headline);
    if lines.len() < 2 {
        return Ok(());
    }
    let source = file.source_bytes();
    let mut fields = Vec::new();
    for (a, b, line_fields) in &lines {
        let first = line_fields
            .first()
            .map(|(_, field_start, _)| *field_start)
            .unwrap_or(*a);
        let last = line_fields
            .last()
            .map(|(_, _, field_end)| *field_end)
            .unwrap_or(*b);
        if source[*a..first].iter().any(|byte| !byte.is_ascii_whitespace())
            || source[last..*b]
                .iter()
                .any(|byte| !byte.is_ascii_whitespace())
        {
            return Ok(());
        }
        for (_, field_start, field_end) in line_fields {
            let field = std::str::from_utf8(&source[*field_start..*field_end])
                .expect("已解析 UTF-8")
                .trim();
            if !field.is_empty() {
                fields.push(field.to_owned());
            }
        }
    }
    let (first_start, _, _) = lines.first().expect("至少存在两行规划");
    let (_, last_end, last_fields) = lines.last().expect("至少存在两行规划");
    let first_field_start = lines
        .first()
        .and_then(|(_, _, line_fields)| line_fields.first().map(|(_, a, _)| *a))
        .unwrap_or(*first_start);
    let last_field_end = last_fields
        .last()
        .map(|(_, _, b)| *b)
        .unwrap_or(*last_end);
    let mut content = std::str::from_utf8(&source[*first_start..first_field_start])
        .expect("已解析 UTF-8")
        .to_owned();
    content.push_str(&fields.join(" "));
    content.push_str(
        std::str::from_utf8(&source[last_field_end..*last_end])
            .expect("已解析 UTF-8"),
    );
    replace(file, *first_start..*last_end, content.as_bytes())
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

/// 临时文件复用完整操作执行器，但不提交仓库或广播更新。
pub(super) fn edit_preview(file: OrgFile, group: &TaskOperationGroup) -> Result<OrgFile, CoreError> {
    let file_key = key(&file.full_path())?;
    let mut files = BTreeMap::from([(file_key.clone(), WorkingFile {
        disk: PathBuf::new(), original: None, exists: true, file,
    })]);
    for operation in &group.operations { execute(&mut files, operation)?; }
    Ok(files.remove(&file_key).unwrap().file)
}
