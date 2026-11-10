//! 仓库外单文档预览；记录成功操作，结束后由应用通过统一数据接口提交。
use super::*;
use crate::{CoreError, FilterTask};
use orgize::rowan::ast::AstNode;
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
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
    pub async fn changes(&self) -> Result<ConflictPreviewChanges, CoreError> {
        let slot = self.store.slot.lock().await;
        let state = self.state(&slot)?;
        let file = read_working(state).await?;
        let mut changes = Vec::new();
        let before_main = conflict::main_source(&state.original);
        let after_main = conflict::main_source(&file);
        if before_main != after_main {
            changes.push(diff(
                &state.original,
                &file,
                &before_main,
                &after_main,
                0,
                0,
                "main",
            ));
        }
        let before_material = &state.original.source_bytes()[before_main.len()..];
        let after_material = &file.source_bytes()[after_main.len()..];
        if before_material != after_material {
            changes.push(diff(
                &state.original,
                &file,
                before_material,
                after_material,
                before_main.len(),
                after_main.len(),
                "conflictMaterial",
            ));
        }
        Ok(ConflictPreviewChanges {
            source_version: self.source_version.clone(),
            preview_version: version(&file),
            changes,
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
        let expected = conflict::points(&state.original)?
            .into_iter()
            .filter(|p| !resolved.contains(p.id.as_str()))
            .map(|p| (p.id, p.source))
            .collect::<Vec<_>>();
        let actual = conflict::points(&file)?
            .into_iter()
            .map(|p| (p.id, p.source))
            .collect::<Vec<_>>();
        if expected != actual {
            return Err(CoreError::InvalidInput("预览不能修改未选择的冲突点"));
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
        let original = repo.parse_file_with_setup(path.clone(), source, setup)?;
        if !original
            .conflicts()?
            .iter()
            .any(|p| p.id == request.conflict_id)
        {
            return Err(CoreError::InvalidInput("冲突点不存在或已变化"));
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
        let updated = super::task_operation_executor::edit_preview(file, group)?;
        let temporary = state.directory.join("next.tmp");
        super::write_intent::write_new(&temporary, updated.source_bytes()).await?;
        fs::rename(&temporary, state.directory.join("working.org"))
            .await
            .map_err(io)?;
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
fn diff(
    before: &OrgFile,
    after: &OrgFile,
    a: &[u8],
    b: &[u8],
    ao: usize,
    bo: usize,
    area: &'static str,
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
