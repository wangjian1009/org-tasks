//! 仓库外单文档预览；记录成功操作，结束后由应用通过统一数据接口提交。
use super::*;
use crate::{CoreError, FilterTask};
use orgize::{ast::Headline, rowan::ast::AstNode, SyntaxKind};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Range,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};
use tokio::{fs, sync::Mutex};

pub(super) fn error(code: &'static str, message: &'static str) -> CoreError {
    CoreError::Preview { code, message }
}
fn io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法读写冲突预览文件: {}", error.kind()))
}
fn version(file: &OrgFile) -> String {
    LocalFileVersion::from_bytes(file.source_bytes()).content_hash
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    rename_all = "camelCase",
    tag = "type",
    content = "data",
    deny_unknown_fields
)]
pub enum ConflictTarget {
    Existing(TaskPath),
    Insert(TaskPosition),
    ReplaceMain,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConflictPreviewRequest {
    pub file: TaskPath,
    pub conflict_id: String,
    pub source_version: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConflictPreviewFinishOptions {
    pub preview_version: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConflictPreviewProjectionRequest {
    pub conflict_id: String,
    pub preview_version: String,
    pub target: Option<ConflictTarget>,
}
/// 只读候选投影；所有坐标属于返回的主树快照，不指向冲突包装。
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictPreviewProjection {
    pub conflict_id: String,
    pub working_version: String,
    pub status: &'static str,
    pub before_text: String,
    pub after_text: String,
    pub content: String,
    pub rendered_html: String,
    pub changes: ConflictPreviewChanges,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileConflict {
    pub id: String,
    pub title: String,
    pub reason: String,
    pub source_range: SourceRange,
    pub available_actions: Vec<TaskConfilictAction>,
    pub suggested_target: Option<ConflictTarget>,
    pub requires_target: bool,
    /// 展示锚点属于主树；不代表已经确认了应用目标。
    pub display_anchor: Option<SourceRange>,
    pub display_at_target: bool,
    pub candidate_content: String,
    pub candidate_html: String,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictPreviewChanges {
    pub source_version: String,
    pub preview_version: String,
    pub changes: Vec<ConflictPreviewChange>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictPreviewChange {
    pub kind: &'static str,
    /// 差异所属的最小任务字段；文档级结构变化使用 `document`。
    pub field: &'static str,
    pub area: &'static str,
    pub before: Option<SourceRange>,
    pub after: Option<SourceRange>,
    pub before_path: Option<TaskPath>,
    pub after_path: Option<TaskPath>,
    pub lines: Vec<ConflictPreviewDiffLine>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictPreviewDiffLine {
    pub kind: &'static str,
    pub before_line: Option<usize>,
    pub after_line: Option<usize>,
    pub text: String,
}

#[derive(Debug, Default)]
pub(super) struct PreviewSlot {
    active: Option<PreviewState>,
}
#[derive(Debug)]
struct PreviewState {
    id: String,
    directory: PathBuf,
    original: OrgFile,
    conflicts: Vec<conflict::ConflictPoint>,
    resolved: std::collections::BTreeSet<String>,
    generation: u64,
    operations: Vec<TaskOperation>,
}
impl Drop for PreviewState {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
#[derive(Clone, Debug, Default)]
pub(crate) struct PreviewStore {
    root: Option<PathBuf>,
    arena: Option<Arc<PreviewArena>>,
    pub(super) slot: Arc<Mutex<PreviewSlot>>,
    generation: Arc<AtomicU64>,
}
impl PartialEq for PreviewStore {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.slot, &other.slot)
    }
}
impl Eq for PreviewStore {}
impl PreviewStore {
    pub(super) fn invalidate(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }
    pub(super) fn validate_repo(&self, repo: &OrgRepo) -> Result<(), CoreError> {
        if repo.id == "<preview>" {
            return Err(CoreError::InvalidInput("仓库身份不能使用 <preview>"));
        }
        if let Some(root) = &self.root {
            let repo_root = std::fs::canonicalize(&repo.root_directory).map_err(io)?;
            if root.starts_with(&repo_root) || repo_root.starts_with(root) {
                return Err(error("previewUnavailable", "预览目录必须在全部仓库之外"));
            }
        }
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct ConflictPreview {
    id: String,
    source_path: TaskPath,
    source_version: String,
    conflict_id: String,
    full_path: TaskPath,
    store: PreviewStore,
    finished: Arc<Mutex<Option<(String, TaskOperationGroup)>>>,
}
impl ConflictPreview {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn source_path(&self) -> &TaskPath {
        &self.source_path
    }
    pub fn source_version(&self) -> &str {
        &self.source_version
    }
    pub fn conflict_id(&self) -> &str {
        &self.conflict_id
    }
    pub fn full_path(&self) -> TaskPath {
        self.full_path.clone()
    }
    fn state<'a>(&self, slot: &'a PreviewSlot) -> Result<&'a PreviewState, CoreError> {
        slot.active
            .as_ref()
            .filter(|state| {
                state.id == self.id
                    && state.generation == self.store.generation.load(Ordering::SeqCst)
            })
            .ok_or(error("previewExpired", "预览已失效，请重新创建"))
    }
    pub async fn file(&self) -> Result<OrgFile, CoreError> {
        let slot = self.store.slot.lock().await;
        read_working(self.state(&slot)?).await
    }
    pub async fn source_file(&self) -> Result<OrgFile, CoreError> {
        let slot = self.store.slot.lock().await;
        Ok(self.state(&slot)?.original.clone())
    }
    /// 冲突材料独立于主树，返回尚未选择的点及基于当前主树计算的目标。
    pub async fn conflicts(&self) -> Result<Vec<FileConflict>, CoreError> {
        let slot = self.store.slot.lock().await;
        let state = self.state(&slot)?;
        let file = read_working(state).await?;
        state
            .conflicts
            .iter()
            .filter(|point| !state.resolved.contains(&point.id))
            .map(|point| conflict::describe_point(&file, point))
            .collect()
    }
    pub async fn changes(&self) -> Result<ConflictPreviewChanges, CoreError> {
        let slot = self.store.slot.lock().await;
        let state = self.state(&slot)?;
        let file = read_working(state).await?;
        let changes = if state.original.source_bytes() == file.source_bytes() {
            Vec::new()
        } else {
            diff_tasks(
                &state.original,
                &file,
                state.original.source_bytes(),
                file.source_bytes(),
                0,
                0,
                "main",
            )
        };
        Ok(ConflictPreviewChanges {
            source_version: self.source_version.clone(),
            preview_version: version(&file),
            changes,
        })
    }
    /// 复用正式取舍规则计算候选，但不写 working.org、不消费材料、不记录操作。
    pub async fn project(
        &self,
        request: ConflictPreviewProjectionRequest,
    ) -> Result<ConflictPreviewProjection, CoreError> {
        let slot = self.store.slot.lock().await;
        let state = self.state(&slot)?;
        let file = read_working(state).await?;
        let working_version = version(&file);
        if request.preview_version != working_version {
            return Err(error("previewVersionMismatch", "预览已变化，请重新读取"));
        }
        let point = state
            .conflicts
            .iter()
            .find(|point| point.id == request.conflict_id && !state.resolved.contains(&point.id))
            .ok_or(CoreError::InvalidInput("冲突点不存在或已选择"))?;
        let description = conflict::describe_point(&file, point)?;
        let mut projected = file.clone();
        let mut before_text = String::new();
        let mut after_text = String::new();
        let mut changes = Vec::new();
        let status = if !description
            .available_actions
            .contains(&TaskConfilictAction::UseLocal)
        {
            "unavailable"
        } else {
            after_text = conflict::candidate_source(&file, point)?;
            let target = request.target.or(description.suggested_target).or_else(|| {
                matches!(description.reason.as_str(), "reorder" | "structure")
                    .then_some(ConflictTarget::ReplaceMain)
            });
            if let Some(target) = target {
                conflict::select_point(
                    &mut projected,
                    point,
                    &TaskConfilictSelection {
                        path: Some(file.full_path()),
                        id: point.id.clone(),
                        action: TaskConfilictAction::UseLocal,
                        target: Some(target),
                    },
                )?;
                after_text.clear();
                if file.source_bytes() != projected.source_bytes() {
                    let changes_for_target = diff_tasks(
                        &file,
                        &projected,
                        file.source_bytes(),
                        projected.source_bytes(),
                        0,
                        0,
                        "main",
                    );
                    before_text = changes_for_target
                        .iter()
                        .flat_map(|change| change.lines.iter())
                        .filter(|line| line.kind == "removed")
                        .map(|line| line.text.as_str())
                        .collect();
                    after_text = changes_for_target
                        .iter()
                        .flat_map(|change| change.lines.iter())
                        .filter(|line| line.kind == "added")
                        .map(|line| line.text.as_str())
                        .collect();
                    changes.extend(changes_for_target);
                }
                "ready"
            } else {
                "targetRequired"
            }
        };
        Ok(ConflictPreviewProjection {
            conflict_id: point.id.clone(),
            working_version,
            status,
            before_text,
            after_text,
            content: String::from_utf8(projected.source_bytes().to_vec()).expect("UTF-8"),
            rendered_html: projected.render_html(),
            changes: ConflictPreviewChanges {
                source_version: self.source_version.clone(),
                preview_version: version(&projected),
                changes,
            },
        })
    }
    pub async fn discard(&self) -> Result<(), CoreError> {
        let mut slot = self.store.slot.lock().await;
        if slot
            .active
            .as_ref()
            .is_some_and(|state| state.id == self.id)
        {
            slot.active = None;
        }
        Ok(())
    }
    /// 结束预览只返回操作组；真实文件由调用方通过统一数据接口提交。
    pub async fn finish(
        &self,
        options: ConflictPreviewFinishOptions,
    ) -> Result<TaskOperationGroup, CoreError> {
        let mut finished = self.finished.lock().await;
        if let Some((version, group)) = finished.as_ref() {
            if version != &options.preview_version {
                return Err(error("previewVersionMismatch", "结束预览的版本不一致"));
            }
            return Ok(group.clone());
        }
        let mut slot = self.store.slot.lock().await;
        let state = self.state(&slot)?;
        let file = read_working(state).await?;
        if version(&file) != options.preview_version {
            return Err(error("previewVersionMismatch", "预览已变化，请重新读取"));
        }
        let resolved = state
            .operations
            .iter()
            .filter_map(|operation| match operation {
                TaskOperation::ConfilictSelection(selection) => Some(selection.id.as_str()),
                _ => None,
            })
            .collect::<std::collections::BTreeSet<_>>();
        if resolved.is_empty() {
            return Err(error("conflictDecisionRequired", "请先选择冲突的处理方式"));
        }
        if resolved.iter().any(|id| !state.resolved.contains(*id))
            || resolved.len() != state.resolved.len()
        {
            return Err(CoreError::InvalidState("预览冲突取舍与操作记录不一致"));
        }
        if file.has_conflict() {
            return Err(CoreError::InvalidInput("预览主树不能包含冲突节点"));
        }
        let group = TaskOperationGroup {
            operations: state
                .operations
                .iter()
                .cloned()
                .map(|operation| remap_operation(operation, &state.id, &self.source_path))
                .collect::<Result<Vec<_>, _>>()?,
            file_versions: vec![TaskFileVersion {
                repo_id: self.source_path.repo_id.clone(),
                file: self.source_path.file.clone().unwrap(),
                version: self.source_version.clone(),
            }],
            queue_repo_ids: Vec::new(),
        };
        if group.operations.is_empty() {
            return Err(error("conflictDecisionRequired", "预览尚未记录操作"));
        }
        *finished = Some((options.preview_version, group.clone()));
        slot.active = None;
        Ok(group)
    }
}

async fn read_working(state: &PreviewState) -> Result<OrgFile, CoreError> {
    checked_root(&state.directory)?;
    let path = state.directory.join("working.org");
    let info = fs::symlink_metadata(&path).await.map_err(io)?;
    if !info.is_file() || info.file_type().is_symlink() {
        return Err(error("previewExpired", "预览文件已失效"));
    }
    let mut file = state.original.clone();
    file.repo_id = "<preview>".into();
    file.path = state.id.clone();
    file.source_bytes = fs::read(path).await.map_err(io)?;
    file.reparse()?;
    Ok(file)
}
impl OrgWorkspace {
    pub fn with_preview_root(mut self, root: PathBuf) -> Result<Self, CoreError> {
        self.set_preview_root(root)?;
        Ok(self)
    }
    pub fn set_preview_root(&mut self, root: PathBuf) -> Result<(), CoreError> {
        if self.preview.root.as_ref().is_some_and(|p| p == &root) {
            return Ok(());
        }
        if !root.is_absolute() {
            return Err(error("previewUnavailable", "预览目录必须是绝对路径"));
        }
        // 先检查已存在祖先，防止为了校验就在仓库内创建目录。
        let mut ancestor = root.as_path();
        let mut suffix = Vec::new();
        while !ancestor.exists() {
            suffix.push(
                ancestor
                    .file_name()
                    .ok_or(error("previewUnavailable", "预览路径无效"))?
                    .to_owned(),
            );
            ancestor = ancestor
                .parent()
                .ok_or(error("previewUnavailable", "预览路径无效"))?;
        }
        let mut resolved = checked_root(ancestor)?;
        for part in suffix.into_iter().rev() {
            resolved.push(part);
        }
        let probe = PreviewStore {
            root: Some(resolved),
            ..Default::default()
        };
        for repo in &self.repos {
            probe.validate_repo(repo)?;
        }
        std::fs::create_dir_all(&root).map_err(io)?;
        let root = checked_root(&root)?;
        let arena = Arc::new(PreviewArena::new(&root)?);
        let store = PreviewStore {
            root: Some(root),
            arena: Some(arena),
            ..Default::default()
        };
        for repo in &self.repos {
            store.validate_repo(repo)?;
        }
        self.preview.invalidate();
        self.preview = store;
        Ok(())
    }
    pub async fn create_conflict_preview(
        &mut self,
        request: ConflictPreviewRequest,
    ) -> Result<ConflictPreview, CoreError> {
        request.file.validate()?;
        if !request.file.titles.is_empty() || request.file.repo_id == "<preview>" {
            return Err(CoreError::InvalidInput("预览源必须是真实文件根路径"));
        }
        let root = self
            .preview
            .root
            .as_ref()
            .ok_or(error("previewUnavailable", "尚未配置预览临时目录"))?;
        checked_root(root)?;
        for repo in &self.repos {
            self.preview.validate_repo(repo)?;
        }
        let mut slot = self.preview.slot.lock().await;
        let repo = self
            .repo(&request.file.repo_id)
            .ok_or(error("previewExpired", "源仓库不可用"))?;
        let source_root = fs::canonicalize(&repo.root_directory).await.map_err(io)?;
        let _guard = super::access::enter(&source_root, &repo.id).await?;
        let path = request
            .file
            .file
            .as_ref()
            .ok_or(CoreError::InvalidInput("预览必须指定文件"))?;
        let disk = super::task_operation_executor::checked_disk(&source_root, path).await?;
        let source = super::write_intent::read_optional(&disk)
            .await?
            .ok_or(error("sourceVersionMismatch", "源文件已不存在"))?;
        if LocalFileVersion::from_bytes(&source).content_hash != request.source_version {
            return Err(error("sourceVersionMismatch", "原文件已变化，请重新读取"));
        }
        let setup = super::service::load_setup_settings(&source_root, path, &source).await?;
        let mut original = repo.parse_file_with_setup(path.clone(), source, setup)?;
        if !original
            .conflicts()?
            .iter()
            .any(|p| p.id == request.conflict_id)
        {
            return Err(CoreError::InvalidInput("冲突点不存在或已变化"));
        }
        let conflicts = conflict::points(&original)?;
        original.source_bytes = conflict::main_source(&original);
        original.reparse()?;
        if original.has_conflict() {
            return Err(CoreError::InvalidInput("文件主树中存在无法分离的冲突节点"));
        }
        slot.active = None;
        let id = super::service::generate_repo_id()?;
        let directory = self
            .preview
            .arena
            .as_ref()
            .ok_or(error("previewUnavailable", "预览目录未初始化"))?
            .directory
            .join(&id);
        checked_root(directory.parent().unwrap())?;
        fs::create_dir(&directory).await.map_err(io)?;
        let state = PreviewState {
            id: id.clone(),
            directory,
            original,
            conflicts,
            resolved: Default::default(),
            generation: self.preview.generation.load(Ordering::SeqCst),
            operations: Vec::new(),
        };
        super::write_intent::write_new(
            &state.directory.join("working.org"),
            state.original.source_bytes(),
        )
        .await?;
        let full_path = TaskPath::file("<preview>".into(), id.clone());
        let preview = ConflictPreview {
            id,
            source_path: request.file,
            source_version: request.source_version,
            conflict_id: request.conflict_id,
            full_path,
            store: self.preview.clone(),
            finished: Default::default(),
        };
        slot.active = Some(state);
        Ok(preview)
    }
    pub async fn file_at(&self, path: &TaskPath) -> Result<OrgFile, CoreError> {
        path.validate()?;
        if !path.titles.is_empty() {
            return Err(CoreError::InvalidInput("读取文档必须使用文件根路径"));
        }
        if path.repo_id == "<preview>" {
            let slot = self.preview.slot.lock().await;
            let state = slot
                .active
                .as_ref()
                .filter(|s| {
                    path.file.as_ref() == Some(&s.id)
                        && s.generation == self.preview.generation.load(Ordering::SeqCst)
                })
                .ok_or(error("previewExpired", "预览已失效"))?;
            read_working(state).await
        } else {
            let repo = self
                .repo(&path.repo_id)
                .ok_or(CoreError::InvalidInput("文件不属于工作区"))?;
            let relative = path
                .file
                .as_ref()
                .ok_or(CoreError::InvalidInput("读取必须指定文件"))?;
            let root = Path::new(&repo.root_directory);
            let _guard = super::access::enter(root, &repo.id).await?;
            repo.file_unlocked(relative).await
        }
    }
    pub(super) async fn execute_preview_operations(
        &mut self,
        group: &TaskOperationGroup,
    ) -> Result<(), CoreError> {
        let mut slot = self.preview.slot.lock().await;
        let state = slot
            .active
            .as_mut()
            .filter(|s| s.generation == self.preview.generation.load(Ordering::SeqCst))
            .ok_or(error("previewExpired", "预览已失效"))?;
        let file = read_working(state).await?;
        if group.operations.is_empty() || !group.queue_repo_ids.is_empty() {
            return Err(error(
                "mixedPreviewOperation",
                "预览操作组为空或包含上传意图",
            ));
        }
        for path in operation_paths(group) {
            path.validate()?;
            if path.repo_id != "<preview>" || path.file.as_ref() != Some(&state.id) {
                return Err(error("mixedPreviewOperation", "预览不能与真实文件混合操作"));
            }
        }
        if !group
            .file_versions
            .iter()
            .any(|v| v.repo_id == "<preview>" && v.file == state.id && v.version == version(&file))
            || group.file_versions.iter().any(|v| {
                v.version != version(&file) || v.repo_id != "<preview>" || v.file != state.id
            })
        {
            return Err(error(
                "previewVersionMismatch",
                "预览版本已变化，请重新读取",
            ));
        }
        for operation in &group.operations {
            if let TaskOperation::ConfilictSelection(selection) = operation {
                if selection.path.as_ref() != Some(&file.full_path()) {
                    return Err(CoreError::InvalidInput(
                        "预览冲突选择必须显式指定文件根路径",
                    ));
                }
            }
        }
        let mut updated = file;
        let mut resolved = state.resolved.clone();
        for operation in &group.operations {
            if let TaskOperation::ConfilictSelection(selection) = operation {
                let point = state
                    .conflicts
                    .iter()
                    .find(|point| point.id == selection.id && !resolved.contains(&point.id))
                    .ok_or(CoreError::InvalidInput("冲突点不存在或已选择"))?;
                conflict::select_point(&mut updated, point, selection)?;
                resolved.insert(point.id.clone());
            } else {
                let step = TaskOperationGroup {
                    operations: vec![operation.clone()],
                    ..Default::default()
                };
                updated = super::task_operation_executor::edit_preview(updated, &step)?;
            }
            if updated.has_conflict() {
                return Err(CoreError::InvalidInput("预览主树不能包含冲突节点"));
            }
        }
        let temporary = state.directory.join("next.tmp");
        super::write_intent::write_new(&temporary, updated.source_bytes()).await?;
        fs::rename(&temporary, state.directory.join("working.org"))
            .await
            .map_err(io)?;
        state.resolved = resolved;
        state.operations.extend(group.operations.iter().cloned());
        Ok(())
    }
}
fn checked_root(root: &Path) -> Result<PathBuf, CoreError> {
    let mut prefix = PathBuf::new();
    for component in root.components() {
        prefix.push(component);
        let meta = std::fs::symlink_metadata(&prefix).map_err(io)?;
        if meta.file_type().is_symlink() {
            return Err(error("previewUnavailable", "预览路径不能包含符号链接"));
        }
    }
    std::fs::canonicalize(root).map_err(io)
}
pub(super) fn operation_paths(group: &TaskOperationGroup) -> Vec<&TaskPath> {
    let mut paths = Vec::new();
    for op in &group.operations {
        match op {
            TaskOperation::Creation(v) => {
                paths.push(&v.position.parent);
                paths.extend(v.position.after.iter());
            }
            TaskOperation::Modification(v) => paths.push(&v.path),
            TaskOperation::Deletion(v) => paths.push(&v.path),
            TaskOperation::Movement(v) => {
                paths.push(&v.path);
                paths.push(&v.position.parent);
                paths.extend(v.position.after.iter());
            }
            TaskOperation::ConfilictSelection(v) => {
                paths.extend(v.path.iter());
                if let Some(target) = &v.target {
                    match target {
                        ConflictTarget::Existing(p) => paths.push(p),
                        ConflictTarget::Insert(p) => {
                            paths.push(&p.parent);
                            paths.extend(p.after.iter());
                        }
                        ConflictTarget::ReplaceMain => {}
                    }
                }
            }
        }
    }
    paths
}
pub(super) fn has_preview_path(group: &TaskOperationGroup) -> bool {
    operation_paths(group)
        .iter()
        .any(|p| p.repo_id == "<preview>")
        || group.file_versions.iter().any(|v| v.repo_id == "<preview>")
}
impl OrgFile {
    pub fn editable_node_paths(&self) -> Vec<TaskPath> {
        self.path_headlines()
            .into_iter()
            .filter(|(_, h)| !Self::is_conflict_headline(h))
            .map(|(p, _)| p)
            .collect()
    }
    pub fn nodes(&self) -> Vec<FilterTask> {
        let repo = OrgRepo {
            id: self.repo_id.clone(),
            root_directory: String::new(),
            todo_defaults: TodoConfig::default(),
        };
        crate::filter::tasks_from_file(&repo, self)
    }
    pub fn insertion_positions(&self) -> Vec<TaskPosition> {
        let nodes = self
            .path_headlines()
            .into_iter()
            .filter(|(_, h)| !Self::is_conflict_headline(h))
            .collect::<Vec<_>>();
        let mut positions = vec![TaskPosition {
            parent: self.full_path(),
            after: None,
        }];
        for (path, node) in &nodes {
            positions.push(TaskPosition {
                parent: path.clone(),
                after: None,
            });
            let parent = node
                .syntax()
                .ancestors()
                .skip(1)
                .find_map(orgize::ast::Headline::cast);
            let parent = parent
                .and_then(|p| {
                    nodes
                        .iter()
                        .find(|(_, h)| h == &p)
                        .map(|(path, _)| path.clone())
                })
                .unwrap_or_else(|| self.full_path());
            positions.push(TaskPosition {
                parent,
                after: Some(path.clone()),
            });
        }
        positions
    }
    pub fn node(&self, path: &TaskPath) -> Result<FilterTask, CoreError> {
        self.nodes()
            .into_iter()
            .find(|t| t.full_path() == path)
            .ok_or(CoreError::InvalidInput("可编辑标题不存在，请重新读取"))
    }
}
pub(super) fn source_range(file: &OrgFile, start: usize, end: usize) -> SourceRange {
    fn at(source: &[u8], offset: usize) -> SourcePosition {
        let prefix = &source[..offset];
        let line = prefix.iter().filter(|&&b| b == b'\n').count() + 1;
        let column = prefix
            .iter()
            .rposition(|&b| b == b'\n')
            .map_or(offset, |i| offset - i - 1);
        SourcePosition {
            line: line as u32,
            column: column as u32,
            byte_offset: offset as u64,
        }
    }
    SourceRange {
        start: at(file.source_bytes(), start),
        end: at(file.source_bytes(), end),
    }
}
#[derive(Clone)]
struct TaskDiffUnit {
    own: Range<usize>,
    headline: Headline,
}

#[derive(Clone)]
struct TaskDiffField {
    name: &'static str,
    range: Range<usize>,
}

#[derive(Clone)]
struct LogRow {
    raw: String,
    start: usize,
    time: String,
}

fn task_diff_units(file: &OrgFile) -> BTreeMap<String, TaskDiffUnit> {
    file.path_headlines()
        .into_iter()
        .map(|(path, headline)| {
            let key = super::properties::own(&headline, "ID")
                .filter(|id| !id.trim().is_empty())
                .map(|id| format!("id:{id}"))
                .unwrap_or_else(|| {
                    format!(
                        "path:{}",
                        serde_json::to_string(&path).expect("任务路径可序列化")
                    )
                });
            let start = usize::from(headline.start());
            let end = headline
                .headlines()
                .next()
                .map_or(usize::from(headline.end()), |child| {
                    usize::from(child.start())
                });
            (
                key.clone(),
                TaskDiffUnit {
                    own: start..end,
                    headline,
                },
            )
        })
        .collect()
}

fn planning_line_range(file: &OrgFile, unit: &TaskDiffUnit, name: &str) -> Range<usize> {
    let source = &file.source_bytes()[unit.own.start..unit.own.end];
    let mut offset = unit.own.start;
    for line in source.split_inclusive(|byte| *byte == b'\n') {
        let content = line
            .strip_suffix(b"\n")
            .unwrap_or(line)
            .strip_suffix(b"\r")
            .unwrap_or_else(|| line.strip_suffix(b"\n").unwrap_or(line));
        let marker = format!("{name}:");
        if let Some(position) = content
            .windows(marker.len())
            .position(|window| window.eq_ignore_ascii_case(marker.as_bytes()))
        {
            return offset + position..offset + content.len();
        }
        offset += line.len();
    }
    unit.own.start..unit.own.start
}

fn task_body_start(file: &OrgFile, unit: &TaskDiffUnit, line_end: usize) -> usize {
    let source = &file.source_bytes()[line_end..unit.own.end];
    let mut cursor = line_end;
    let mut relative = 0;
    while relative < source.len() {
        let line = &source[relative..][..source[relative..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(source.len() - relative, |offset| offset + 1)];
        let trimmed = String::from_utf8_lossy(line).trim().to_ascii_uppercase();
        if ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
            .iter()
            .any(|name| trimmed.starts_with(name))
        {
            relative += line.len();
            cursor += line.len();
            continue;
        }
        if trimmed == ":PROPERTIES:" || trimmed == ":LOGBOOK:" {
            relative += line.len();
            cursor += line.len();
            while relative < source.len() {
                let next = &source[relative..][..source[relative..]
                    .iter()
                    .position(|byte| *byte == b'\n')
                    .map_or(source.len() - relative, |offset| offset + 1)];
                relative += next.len();
                cursor += next.len();
                if String::from_utf8_lossy(next)
                    .trim()
                    .eq_ignore_ascii_case(":END:")
                {
                    break;
                }
            }
            continue;
        }
        break;
    }
    cursor
}

fn task_diff_fields(file: &OrgFile, unit: &TaskDiffUnit) -> Vec<TaskDiffField> {
    let headline = &unit.headline;
    let line_end = file.source_bytes()[unit.own.start..unit.own.end]
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(unit.own.end, |offset| unit.own.start + offset + 1);
    let span = |node: Option<orgize::SyntaxNode>| {
        node.map_or(unit.own.start..unit.own.start, |node| {
            usize::from(node.text_range().start())..usize::from(node.text_range().end())
        })
    };
    let child = |kind| {
        span(
            headline
                .syntax()
                .children()
                .find(|node| node.kind() == kind),
        )
    };
    let todo = headline
        .todo_keyword()
        .map_or(unit.own.start..unit.own.start, |node| {
            usize::from(node.syntax().text_range().start())
                ..usize::from(node.syntax().text_range().end())
        });
    let log_start = file.source_bytes()[line_end..unit.own.end]
        .windows(b":LOGBOOK:".len())
        .position(|window| window.eq_ignore_ascii_case(b":LOGBOOK:"))
        .map(|offset| line_end + offset);
    let body_start = task_body_start(file, unit, line_end);
    let text_end = log_start
        .filter(|start| *start >= body_start)
        .unwrap_or(unit.own.end);
    let planning = |name: &str| planning_line_range(file, unit, name);
    vec![
        TaskDiffField {
            name: "todo",
            range: todo,
        },
        TaskDiffField {
            name: "priority",
            range: child(SyntaxKind::HEADLINE_PRIORITY),
        },
        TaskDiffField {
            name: "title",
            range: child(SyntaxKind::HEADLINE_TITLE),
        },
        TaskDiffField {
            name: "schedule",
            range: planning("SCHEDULED"),
        },
        TaskDiffField {
            name: "deadline",
            range: planning("DEADLINE"),
        },
        TaskDiffField {
            name: "closed",
            range: planning("CLOSED"),
        },
        TaskDiffField {
            name: "text",
            range: body_start..text_end,
        },
    ]
}

fn log_rows(file: &OrgFile, unit: &TaskDiffUnit) -> Vec<LogRow> {
    let source = &file.source_bytes()[unit.own.start..unit.own.end];
    let Some(relative_start) = source
        .windows(b":LOGBOOK:".len())
        .position(|window| window.eq_ignore_ascii_case(b":LOGBOOK:"))
    else {
        return Vec::new();
    };
    let start = unit.own.start + relative_start;
    let Some(relative_end) = source[relative_start..]
        .windows(b":END:".len())
        .position(|window| window.eq_ignore_ascii_case(b":END:"))
    else {
        return Vec::new();
    };
    let end = start + relative_end;
    let mut rows = Vec::new();
    let mut offset = start;
    for line in file.source_bytes()[start..end].split_inclusive(|byte| *byte == b'\n') {
        let trimmed = line
            .strip_suffix(b"\n")
            .unwrap_or(line)
            .strip_suffix(b"\r")
            .unwrap_or_else(|| line.strip_suffix(b"\n").unwrap_or(line));
        if !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case(b":LOGBOOK:") {
            let raw = String::from_utf8(line.to_vec()).expect("LOGBOOK 必须是 UTF-8");
            let time = raw
                .find('[')
                .and_then(|left| {
                    raw[left + 1..]
                        .find(']')
                        .map(|right| raw[left + 1..left + 1 + right].to_owned())
                })
                .unwrap_or_default();
            rows.push(LogRow {
                raw,
                start: offset,
                time,
            });
        }
        offset += line.len();
    }
    rows.sort_by(|left, right| left.time.cmp(&right.time).then(left.raw.cmp(&right.raw)));
    rows
}

fn tag_text(tags: &[String]) -> String {
    if tags.is_empty() {
        String::new()
    } else {
        format!(":{}:", tags.join(":"))
    }
}

fn tag_changes(
    before: &OrgFile,
    after: &OrgFile,
    before_unit: &TaskDiffUnit,
    after_unit: &TaskDiffUnit,
    a: &[u8],
    b: &[u8],
    ao: usize,
    bo: usize,
    area: &'static str,
) -> Vec<ConflictPreviewChange> {
    let before_tags = before_unit
        .headline
        .tags()
        .map(|tag| tag.to_string())
        .collect::<BTreeSet<_>>();
    let after_tags = after_unit
        .headline
        .tags()
        .map(|tag| tag.to_string())
        .collect::<BTreeSet<_>>();
    let added = after_tags
        .difference(&before_tags)
        .cloned()
        .collect::<Vec<_>>();
    let removed = before_tags
        .difference(&after_tags)
        .cloned()
        .collect::<Vec<_>>();
    let span = |unit: &TaskDiffUnit| {
        unit.headline
            .syntax()
            .children()
            .find(|node| node.kind() == SyntaxKind::HEADLINE_TAGS)
            .map_or(unit.own.start..unit.own.start, |node| {
                usize::from(node.text_range().start())..usize::from(node.text_range().end())
            })
    };
    let before_span = span(before_unit);
    let after_span = span(after_unit);
    let mut changes = Vec::new();
    if !removed.is_empty() {
        let text = tag_text(&removed);
        changes.push(line_diff(
            before,
            after,
            &a[before_span.clone()],
            text.as_bytes(),
            ao + before_span.start,
            bo + after_span.start,
            area,
            "tagsRemoved",
        ));
    }
    if !added.is_empty() {
        let text = tag_text(&added);
        changes.push(line_diff(
            before,
            after,
            text.as_bytes(),
            &b[after_span.clone()],
            ao + before_span.start,
            bo + after_span.start,
            area,
            "tagsAdded",
        ));
    }
    changes
}

fn log_changes(
    before: &OrgFile,
    after: &OrgFile,
    before_unit: &TaskDiffUnit,
    after_unit: &TaskDiffUnit,
    a: &[u8],
    b: &[u8],
    ao: usize,
    bo: usize,
    area: &'static str,
) -> Vec<ConflictPreviewChange> {
    let mut before_rows = log_rows(before, before_unit);
    let after_rows = log_rows(after, after_unit);
    let mut changes = Vec::new();
    for row in &after_rows {
        if let Some(index) = before_rows
            .iter()
            .position(|candidate| candidate.raw == row.raw)
        {
            before_rows.remove(index);
        } else {
            changes.push(line_diff(
                before,
                after,
                &[],
                &b[row.start..row.start + row.raw.len()],
                ao + before_unit.own.start,
                bo + row.start,
                area,
                "logAdded",
            ));
        }
    }
    for row in before_rows {
        changes.push(line_diff(
            before,
            after,
            &a[row.start..row.start + row.raw.len()],
            &[],
            ao + row.start,
            bo + after_unit.own.start,
            area,
            "logDeleted",
        ));
    }
    changes.sort_by(|left, right| {
        left.before
            .as_ref()
            .map(|range| range.start.line)
            .cmp(&right.before.as_ref().map(|range| range.start.line))
    });
    changes
}

fn diff_tasks(
    before: &OrgFile,
    after: &OrgFile,
    a: &[u8],
    b: &[u8],
    ao: usize,
    bo: usize,
    area: &'static str,
) -> Vec<ConflictPreviewChange> {
    let before_units = task_diff_units(before);
    let after_units = task_diff_units(after);
    let mut keys = BTreeSet::new();
    keys.extend(before_units.keys().cloned());
    keys.extend(after_units.keys().cloned());
    let mut changes = Vec::new();
    for key in keys {
        match (before_units.get(&key), after_units.get(&key)) {
            (Some(before_unit), Some(after_unit)) => {
                for (before_field, after_field) in task_diff_fields(before, before_unit)
                    .into_iter()
                    .zip(task_diff_fields(after, after_unit))
                {
                    if a.get(before_field.range.clone()) == b.get(after_field.range.clone()) {
                        continue;
                    }
                    changes.push(line_diff(
                        before,
                        after,
                        &a[before_field.range.clone()],
                        &b[after_field.range.clone()],
                        ao + before_field.range.start,
                        bo + after_field.range.start,
                        area,
                        before_field.name,
                    ));
                }
                changes.extend(tag_changes(
                    before,
                    after,
                    before_unit,
                    after_unit,
                    a,
                    b,
                    ao,
                    bo,
                    area,
                ));
                changes.extend(log_changes(
                    before,
                    after,
                    before_unit,
                    after_unit,
                    a,
                    b,
                    ao,
                    bo,
                    area,
                ));
            }
            (Some(before_unit), None) => changes.push(line_diff(
                before,
                after,
                &a[before_unit.own.clone()],
                &[],
                ao + before_unit.own.start,
                bo,
                area,
                "record",
            )),
            (None, Some(after_unit)) => changes.push(line_diff(
                before,
                after,
                &[],
                &b[after_unit.own.clone()],
                ao,
                bo + after_unit.own.start,
                area,
                "record",
            )),
            (None, None) => unreachable!(),
        }
    }
    if changes.is_empty() && a != b {
        changes.push(line_diff(before, after, a, b, ao, bo, area, "document"));
    }
    changes
}

fn line_diff(
    before: &OrgFile,
    after: &OrgFile,
    a: &[u8],
    b: &[u8],
    ao: usize,
    bo: usize,
    area: &'static str,
    field: &'static str,
) -> ConflictPreviewChange {
    let a = std::str::from_utf8(a).unwrap();
    let b = std::str::from_utf8(b).unwrap();
    let al = a.split_inclusive('\n').collect::<Vec<_>>();
    let bl = b.split_inclusive('\n').collect::<Vec<_>>();
    let prefix = al.iter().zip(&bl).take_while(|(a, b)| a == b).count();
    let suffix = al[prefix..]
        .iter()
        .rev()
        .zip(bl[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let astart = ao + al[..prefix].iter().map(|s| s.len()).sum::<usize>();
    let bstart = bo + bl[..prefix].iter().map(|s| s.len()).sum::<usize>();
    let aend = ao + a.len()
        - al[al.len() - suffix..]
            .iter()
            .map(|s| s.len())
            .sum::<usize>();
    let bend = bo + b.len()
        - bl[bl.len() - suffix..]
            .iter()
            .map(|s| s.len())
            .sum::<usize>();
    let ar = source_range(before, astart, aend);
    let br = source_range(after, bstart, bend);
    let mut lines = Vec::new();
    for (i, line) in al[prefix..al.len() - suffix].iter().enumerate() {
        lines.push(ConflictPreviewDiffLine {
            kind: "removed",
            before_line: Some(ar.start.line as usize + i),
            after_line: None,
            text: (*line).into(),
        });
    }
    for (i, line) in bl[prefix..bl.len() - suffix].iter().enumerate() {
        lines.push(ConflictPreviewDiffLine {
            kind: "added",
            before_line: None,
            after_line: Some(br.start.line as usize + i),
            text: (*line).into(),
        });
    }
    fn anchor(file: &OrgFile, offset: usize) -> Option<TaskPath> {
        file.path_headlines()
            .into_iter()
            .filter(|(_, h)| u32::from(h.start()) as usize <= offset)
            .last()
            .map(|(p, _)| p)
    }
    ConflictPreviewChange {
        kind: if astart == aend {
            "insert"
        } else if bstart == bend {
            "delete"
        } else {
            "replace"
        },
        field,
        area,
        before: Some(ar),
        after: Some(br),
        before_path: anchor(before, astart),
        after_path: anchor(after, bstart),
        lines,
    }
}

pub(super) fn valid_preview_id(id: &str) -> bool {
    id.len() == 36
        && id.char_indices().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

#[cfg(test)]
mod diff_tests {
    use super::*;

    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }

    #[test]
    fn compares_task_fields_without_promoting_child_text_to_parent() {
        let before = file("* TODO Parent :old:\nSCHEDULED: <2026-01-01 Thu>\nDEADLINE: <2026-01-02 Fri>\nCLOSED: [2026-01-03 Sat]\n:LOGBOOK:\n- Note taken on [2026-01-01 Thu]\n:END:\n原文\n** TODO Child\n子任务原文\n");
        let after = file("* DONE Parent :new:\nSCHEDULED: <2026-02-01 Sun>\nDEADLINE: <2026-02-02 Mon>\nCLOSED: [2026-02-03 Tue]\n:LOGBOOK:\n- Note taken on [2026-02-04 Wed]\n:END:\n新正文\n** TODO Child\n子任务新文字\n");
        let changes = diff_tasks(
            &before,
            &after,
            before.source_bytes(),
            after.source_bytes(),
            0,
            0,
            "main",
        );
        assert!(changes.iter().any(|change| change.field == "todo"));
        assert!(changes.iter().any(|change| change.field == "tagsAdded"));
        assert!(changes.iter().any(|change| change.field == "tagsRemoved"));
        assert!(changes.iter().any(|change| change.field == "schedule"));
        assert!(changes.iter().any(|change| change.field == "deadline"));
        assert!(changes.iter().any(|change| change.field == "closed"));
        assert!(changes.iter().any(|change| change.field == "logAdded"));
        assert!(changes.iter().any(|change| change.field == "logDeleted"));
        assert!(changes.iter().any(|change| change.field == "text"));
        assert_eq!(
            changes
                .iter()
                .filter(|change| change
                    .before_path
                    .as_ref()
                    .is_some_and(|path| path.titles == vec!["Parent"]))
                .count(),
            9
        );
        assert!(changes.iter().any(|change| {
            change
                .before_path
                .as_ref()
                .is_some_and(|path| path.titles == vec!["Parent", "Child"])
        }));
    }
}

fn remap_operation(
    mut operation: TaskOperation,
    id: &str,
    source: &TaskPath,
) -> Result<TaskOperation, CoreError> {
    fn path(path: &mut TaskPath, id: &str, source: &TaskPath) -> Result<(), CoreError> {
        if path.repo_id != "<preview>" || path.file.as_deref() != Some(id) {
            return Err(error("mixedPreviewOperation", "记录中包含预览之外的路径"));
        }
        path.repo_id = source.repo_id.clone();
        path.file = source.file.clone();
        Ok(())
    }
    fn position(p: &mut TaskPosition, id: &str, source: &TaskPath) -> Result<(), CoreError> {
        path(&mut p.parent, id, source)?;
        if let Some(after) = &mut p.after {
            path(after, id, source)?;
        }
        Ok(())
    }
    match &mut operation {
        TaskOperation::Creation(v) => position(&mut v.position, id, source)?,
        TaskOperation::Modification(v) => path(&mut v.path, id, source)?,
        TaskOperation::Deletion(v) => path(&mut v.path, id, source)?,
        TaskOperation::Movement(v) => {
            path(&mut v.path, id, source)?;
            position(&mut v.position, id, source)?;
        }
        TaskOperation::ConfilictSelection(v) => {
            path(
                v.path
                    .as_mut()
                    .ok_or(CoreError::InvalidInput("记录的冲突操作缺少路径"))?,
                id,
                source,
            )?;
            if let Some(target) = &mut v.target {
                match target {
                    ConflictTarget::Existing(p) => path(p, id, source)?,
                    ConflictTarget::Insert(p) => position(p, id, source)?,
                    ConflictTarget::ReplaceMain => {}
                }
            }
        }
    }
    Ok(operation)
}

/// 每个 workspace 单独持有租约，只清理已经退出的会话目录。
#[derive(Debug)]
struct PreviewArena {
    directory: PathBuf,
    _lease: std::fs::File,
}
impl PreviewArena {
    fn new(root: &Path) -> Result<Self, CoreError> {
        #[cfg(unix)]
        for entry in std::fs::read_dir(root).map_err(io)? {
            let Ok(entry) = entry else {
                continue;
            };
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name
                .strip_prefix("workspace-")
                .is_some_and(valid_preview_id)
                || !entry
                    .file_type()
                    .map(|t| t.is_dir() && !t.is_symlink())
                    .unwrap_or(false)
            {
                continue;
            }
            let lease = entry.path().join(".lease");
            if std::fs::symlink_metadata(&lease)
                .map(|m| m.is_file() && !m.file_type().is_symlink())
                .unwrap_or(false)
            {
                if let Ok(file) = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&lease)
                {
                    if lease_lock(&file) {
                        let _ = std::fs::remove_dir_all(entry.path());
                    }
                }
            }
        }
        let directory = root.join(format!("workspace-{}", super::service::generate_repo_id()?));
        std::fs::create_dir(&directory).map_err(io)?;
        let lease = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(directory.join(".lease"))
            .map_err(io)?;
        #[cfg(unix)]
        if !lease_lock(&lease) {
            let _ = std::fs::remove_dir_all(&directory);
            return Err(error("previewUnavailable", "无法锁定预览会话"));
        }
        Ok(Self {
            directory,
            _lease: lease,
        })
    }
}
impl Drop for PreviewArena {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
#[cfg(unix)]
fn lease_lock(file: &std::fs::File) -> bool {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn flock(fd: std::ffi::c_int, operation: std::ffi::c_int) -> std::ffi::c_int;
    }
    unsafe { flock(file.as_raw_fd(), 2 | 4) == 0 }
}
