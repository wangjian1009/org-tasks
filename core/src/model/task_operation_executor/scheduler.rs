//! 请求协调器：遍历操作时按需启动文件任务，接收元信息而不自行读取或解析文件。
use super::file_worker::*;
use super::reader::{FileLoadSpec, ReadCache};
use super::*;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;

struct Scheduler {
    workers: BTreeMap<FileKey, mpsc::UnboundedSender<FileCommand>>,
    loading: BTreeSet<FileKey>,
    snapshots: BTreeMap<FileKey, Vec<RecordCopy>>,
    metadata: BTreeMap<FileKey, Option<OrgFileMetadata>>,
    versions: BTreeMap<FileKey, Option<String>>,
    conflicts: BTreeMap<FileKey, Vec<String>>,
    notifications: BTreeMap<FileKey, Vec<TaskDataChange>>,
    binding_paths: BTreeMap<FileKey, Vec<(usize, TaskPath)>>,
    bindings: Vec<Option<u64>>,
    dependencies: ReadDependencies,
    cache: ReadCache,
    events: mpsc::UnboundedReceiver<FileEvent>,
    sender: mpsc::UnboundedSender<FileEvent>,
    jobs: JoinSet<()>,
    pending: BTreeSet<OrderId>,
    optional: BTreeSet<OrderId>,
    completed: BTreeMap<OrderId, Result<FileExecuteResult, FileExecuteError>>,
    next_order: OrderId,
}

impl Drop for Scheduler {
    fn drop(&mut self) {
        for worker in self.workers.values() {
            let _ = worker.send(FileCommand::Discard);
        }
        self.jobs.abort_all();
    }
}

impl Scheduler {
    fn new() -> Self {
        let (sender, events) = mpsc::unbounded_channel();
        Self {
            workers: BTreeMap::new(),
            loading: BTreeSet::new(),
            snapshots: BTreeMap::new(),
            metadata: BTreeMap::new(),
            versions: BTreeMap::new(),
            conflicts: BTreeMap::new(),
            notifications: BTreeMap::new(),
            binding_paths: BTreeMap::new(),
            bindings: Vec::new(),
            dependencies: Vec::new(),
            cache: ReadCache::default(),
            sender,
            events,
            jobs: JoinSet::new(),
            pending: BTreeSet::new(),
            optional: BTreeSet::new(),
            completed: BTreeMap::new(),
            next_order: 0,
        }
    }

    fn ensure(
        &mut self,
        workspace: &WorkspaceState,
        group: &TaskOperationGroup,
        file: &FileKey,
    ) -> Result<(), CoreError> {
        if self.workers.contains_key(file) {
            return Ok(());
        }
        let repo = workspace
            .repo(&file.0)
            .ok_or(CoreError::InvalidInput("路径仓库不属于 workspace"))?
            .clone();
        let spec = FileLoadSpec {
            repo,
            path: file.1.clone(),
            versions: group
                .file_versions
                .iter()
                .filter(|v| v.repo_id == file.0 && v.file == file.1)
                .map(|v| v.version.clone())
                .collect(),
            new_files: group
                .operations
                .iter()
                .filter_map(|op| match op {
                    TaskOperation::FileNew(data)
                        if data.path.repo_id == file.0
                            && data.path.file.as_deref() == Some(file.1.as_str()) =>
                    {
                        Some(data.clone())
                    }
                    _ => None,
                })
                .collect(),
            export_records: self.binding_paths.contains_key(file),
            full_file: false,
            cache: self.cache.clone(),
        };
        let (sender, commands) = mpsc::unbounded_channel();
        self.loading.insert(file.clone());
        self.jobs
            .spawn(file_worker::run(spec, commands, self.sender.clone()));
        self.workers.insert(file.clone(), sender);
        Ok(())
    }

    async fn event(&mut self) -> Result<FileEvent, CoreError> {
        loop {
            tokio::select! {
                biased;
                event=self.events.recv()=>return event.ok_or(CoreError::InvalidState("文件任务结果通道已关闭")),
                job=self.jobs.join_next(),if !self.jobs.is_empty()=>{
                    if let Some(Err(error))=job{return Err(CoreError::Store(format!("文件任务执行异常: {error}")));}
                }
            }
        }
    }

    fn send(
        &mut self,
        file: &FileKey,
        modification: FileModification,
        optional: bool,
    ) -> Result<OrderId, CoreError> {
        let order_id = self.next_order;
        self.next_order += 1;
        let sent = self
            .workers
            .get(file)
            .ok_or(CoreError::InvalidState("文件任务未创建"))?
            .send(FileCommand::Execute {
                order_id,
                modification,
            });
        // 自动加载可能先失败并关闭收件箱；仍读取 Loaded 的原始错误，
        // 不用发送失败覆盖版本、路径或配置校验错误。
        if sent.is_err() && !self.loading.contains(file) {
            return Err(CoreError::InvalidState("文件任务执行通道已关闭"));
        }
        self.pending.insert(order_id);
        if optional {
            self.optional.insert(order_id);
        }
        Ok(order_id)
    }

    async fn receive(&mut self) -> Result<(), CoreError> {
        let event = self.event().await?;
        match event.reply {
            FileReply::Loaded(result) => {
                if !self.loading.remove(&event.file) {
                    return Err(CoreError::InvalidState("文件任务重复返回装载结果"));
                }
                let result = result?;
                if let Some(paths) = self.binding_paths.get(&event.file) {
                    for (index, path) in paths {
                        self.bindings[*index] = result
                            .records
                            .iter()
                            .find(|copy| copy.source.task.full_path() == path)
                            .and_then(|copy| copy.token);
                    }
                }
                self.metadata.insert(event.file.clone(), result.metadata);
                self.versions
                    .insert(event.file.clone(), result.file_version);
                self.conflicts.insert(event.file.clone(), result.conflicts);
                self.snapshots.insert(event.file, result.records);
                self.dependencies.extend(result.dependencies);
            }
            FileReply::Executed(mut result) => {
                let id = match &result {
                    Ok(v) => v.order_id,
                    Err(e) => e.order_id,
                };
                if !self.pending.remove(&id) {
                    return Err(CoreError::InvalidState("文件任务返回了未知操作编号"));
                }
                match &mut result {
                    Ok(value) => {
                        if !value.snapshot.is_empty() || !self.snapshots[&event.file].is_empty() {
                            self.snapshots
                                .insert(event.file.clone(), std::mem::take(&mut value.snapshot));
                        }
                        self.notifications
                            .insert(event.file, std::mem::take(&mut value.notification));
                    }
                    Err(error) if !self.optional.contains(&id) => return Err(error.error.clone()),
                    Err(_) => {}
                }
                self.completed.insert(id, result);
            }
            _ => return Err(CoreError::InvalidState("文件任务在执行阶段返回了保存结果")),
        }
        Ok(())
    }

    async fn wait_loaded(&mut self, file: &FileKey) -> Result<(), CoreError> {
        while self.loading.contains(file) {
            self.receive().await?;
        }
        Ok(())
    }
    async fn drain(&mut self) -> Result<(), CoreError> {
        while !self.pending.is_empty() || !self.loading.is_empty() {
            self.receive().await?;
        }
        self.completed.clear();
        self.optional.clear();
        Ok(())
    }
    async fn wait(
        &mut self,
        id: OrderId,
    ) -> Result<Result<FileExecuteResult, FileExecuteError>, CoreError> {
        while !self.completed.contains_key(&id) {
            self.receive().await?;
        }
        self.optional.remove(&id);
        Ok(self.completed.remove(&id).expect("已收到操作回复"))
    }
    fn copy(&self, path: &TaskPath, token: Option<u64>) -> Result<RecordCopy, CoreError> {
        self.snapshots
            .get(&key(path)?)
            .and_then(|records| {
                records.iter().find(|copy| {
                    token.map_or_else(
                        || copy.source.task.full_path() == path,
                        |token| copy.token == Some(token),
                    )
                })
            })
            .cloned()
            .ok_or(CoreError::InvalidInput("操作来源不存在或受到冲突保护"))
    }

    async fn save_candidates(mut self) -> Result<FileCandidates, CoreError> {
        self.drain().await?;
        for worker in self.workers.values() {
            worker
                .send(FileCommand::Save)
                .map_err(|_| CoreError::InvalidState("文件任务保存通道已关闭"))?;
        }
        let mut files = BTreeMap::new();
        let mut completions = BTreeMap::new();
        while files.len() < self.workers.len() {
            let event = self.event().await?;
            let FileReply::SaveReady(result) = event.reply else {
                return Err(CoreError::InvalidState("文件任务保存回复无效"));
            };
            let plan = result?;
            completions.insert(event.file.clone(), plan.committed);
            if files.insert(event.file, plan.candidate).is_some() {
                return Err(CoreError::InvalidState("文件任务重复提交候选"));
            }
        }
        let dependencies = std::mem::take(&mut self.dependencies);
        Ok(FileCandidates {
            files,
            dependencies,
            completions,
            scheduler: self,
        })
    }
}

pub(super) struct FileCandidates {
    pub files: BTreeMap<FileKey, SaveCandidate>,
    pub dependencies: ReadDependencies,
    completions: BTreeMap<FileKey, oneshot::Sender<Result<Option<FileStamp>, CoreError>>>,
    scheduler: Scheduler,
}

pub(super) struct CommittedFiles {
    pub file_changes: BTreeMap<FileKey, FileDataChange>,
    pub task_changes: Vec<TaskDataChange>,
}

impl FileCandidates {
    pub async fn complete(
        mut self,
        stamps: BTreeMap<PathBuf, FileStamp>,
    ) -> Result<CommittedFiles, CoreError> {
        let count = self.completions.len();
        for (key, completion) in std::mem::take(&mut self.completions) {
            let item = &self.files[&key];
            let stamp = stamps
                .get(&item.disk)
                .cloned()
                .or_else(|| item.stamp.clone());
            completion
                .send(Ok(stamp))
                .map_err(|_| CoreError::InvalidState("文件任务提交确认通道已关闭"))?;
        }
        let mut file_changes = BTreeMap::new();
        let mut ordinary = Vec::new();
        let mut moved = BTreeMap::new();
        for _ in 0..count {
            let event = self.scheduler.event().await?;
            let FileReply::Saved(result) = event.reply else {
                return Err(CoreError::InvalidState("文件任务提交回复无效"));
            };
            if let Some(change) = result.file_change {
                file_changes.insert(event.file, change);
            }
            for change in result.task_changes {
                if matches!(
                    change.kind,
                    TaskDataChangeKind::Moved | TaskDataChangeKind::Deleted
                ) {
                    if let Some(before) = &change.before {
                        let identity = (
                            before.task.repo_id().to_owned(),
                            before.task.id().to_owned(),
                        );
                        let previous = moved.get(&identity).map(|v: &TaskDataChange| v.kind);
                        if change.kind == TaskDataChangeKind::Deleted
                            || (previous != Some(TaskDataChangeKind::Deleted)
                                && (change.after.is_some() || previous.is_none()))
                        {
                            moved.insert(identity, change);
                        }
                        continue;
                    }
                }
                ordinary.push(change);
            }
        }
        ordinary.extend(moved.into_values());
        Ok(CommittedFiles {
            file_changes,
            task_changes: ordinary,
        })
    }
}

pub(super) async fn run(
    workspace: &WorkspaceState,
    group: &TaskOperationGroup,
) -> Result<FileCandidates, CoreError> {
    let mut scheduler = Scheduler::new();
    scheduler.bindings = vec![None; group.operations.len()];
    for (index, operation) in group.operations.iter().enumerate() {
        let path = match operation {
            TaskOperation::Trash(data) => Some(&data.path),
            TaskOperation::Restore(data) => Some(&data.path),
            _ => None,
        };
        if let Some(path) = path {
            scheduler
                .binding_paths
                .entry(key(path)?)
                .or_default()
                .push((index, path.clone()));
        }
    }
    for (index, operation) in group.operations.iter().enumerate() {
        match operation {
            TaskOperation::Trash(data) => {
                scheduler.drain().await?;
                let source_key = key(&data.path)?;
                let target_path =
                    TaskPath::file(data.target.repo_id.clone(), data.target.path.clone());
                let target_key = key(&target_path)?;
                if source_key == target_key {
                    return Err(CoreError::InvalidInput("废纸篓不能是来源文件"));
                }
                scheduler.ensure(workspace, group, &source_key)?;
                scheduler.wait_loaded(&source_key).await?;
                let copy = scheduler.copy(&data.path, scheduler.bindings[index])?;
                let current_source_path = copy.source.task.full_path().clone();
                if copy.headings.len() != 1 {
                    return Err(CoreError::InvalidInput("废纸篓操作只支持没有子节点的记录"));
                }
                let (patches, tags) = copy.trash_attributes()?;
                scheduler.ensure(workspace, group, &target_key)?;
                scheduler.send(
                    &target_key,
                    FileModification::Insert {
                        copy: Box::new(copy),
                        position: TaskPosition {
                            parent: target_path,
                            after: None,
                        },
                        strict: false,
                        after_hint: true,
                        properties: patches,
                        tags: Some(tags),
                    },
                    false,
                )?;
                scheduler.send(
                    &source_key,
                    FileModification::Operation(TaskOperation::Deletion(TaskDeletion {
                        path: current_source_path,
                    })),
                    false,
                )?;
                scheduler.drain().await?;
            }
            TaskOperation::Restore(data) => {
                scheduler.drain().await?;
                let source_key = key(&data.path)?;
                scheduler.ensure(workspace, group, &source_key)?;
                scheduler.wait_loaded(&source_key).await?;
                let mut copy = scheduler.copy(&data.path, scheduler.bindings[index])?;
                let current_source_path = copy.source.task.full_path().clone();
                if copy.headings.len() != 1 {
                    return Err(CoreError::InvalidInput("废纸篓操作只支持没有子节点的记录"));
                }
                if copy.source.task.property("SOURCE_TRASH_ID").is_none() {
                    return Err(CoreError::InvalidInput("记录不包含删除来源信息"));
                }
                let mut position: TaskPosition = serde_json::from_str(
                    copy.source
                        .task
                        .property("SOURCE_POSITION")
                        .ok_or(CoreError::InvalidInput("恢复来源位置不存在"))?,
                )
                .map_err(|_| CoreError::InvalidInput("恢复来源位置无效"))?;
                position.after = copy
                    .source
                    .task
                    .property("SOURCE_BROTHER")
                    .map(serde_json::from_str)
                    .transpose()
                    .map_err(|_| CoreError::InvalidInput("恢复来源兄弟位置无效"))?;
                let target_key = key(&position.parent)?;
                if source_key == target_key {
                    return Err(CoreError::InvalidInput("恢复来源位置指向废纸篓本身"));
                }
                // 原仓库、文件或位置不可用时作为恢复插入失败保留来源。
                if workspace.repo(&target_key.0).is_none() {
                    continue;
                }
                scheduler.ensure(workspace, group, &target_key)?;
                copy.headings[0].title = copy
                    .source
                    .task
                    .property("SOURCE_TASK_TITLE")
                    .ok_or(CoreError::InvalidInput("原任务标题不存在"))?
                    .into();
                copy.headings[0].state = serde_json::from_str(
                    copy.source
                        .task
                        .property("SOURCE_TASK_STATE")
                        .ok_or(CoreError::InvalidInput("原任务状态不存在"))?,
                )
                .map_err(|_| CoreError::InvalidInput("原任务状态无效"))?;
                let parent_tags: Vec<String> = copy
                    .source
                    .task
                    .property("SOURCE_PARENT_TAGS")
                    .map(serde_json::from_str)
                    .transpose()
                    .map_err(|_| CoreError::InvalidInput("恢复来源继承标签无效"))?
                    .unwrap_or_default();
                let tags = copy
                    .source
                    .task
                    .own_tags()
                    .iter()
                    .filter(|tag| !parent_tags.contains(tag))
                    .cloned()
                    .collect();
                let mut patches = copy
                    .source
                    .task
                    .properties()
                    .keys()
                    .filter(|name| name.starts_with("SOURCE_"))
                    .map(|name| (name.clone(), None))
                    .collect::<Vec<_>>();
                patches.push((
                    "ID".into(),
                    copy.source.task.property("SOURCE_ID").map(str::to_owned),
                ));
                let id = scheduler.send(
                    &target_key,
                    FileModification::Insert {
                        copy: Box::new(copy),
                        position,
                        strict: true,
                        after_hint: true,
                        properties: patches,
                        tags: Some(tags),
                    },
                    true,
                )?;
                if let Ok(result) = scheduler.wait(id).await? {
                    if result.result_path.is_none() {
                        return Err(CoreError::InvalidState("恢复插入没有返回节点位置"));
                    }
                    scheduler.send(
                        &source_key,
                        FileModification::Operation(TaskOperation::Deletion(TaskDeletion {
                            path: current_source_path,
                        })),
                        false,
                    )?;
                    scheduler.drain().await?;
                }
            }
            TaskOperation::Movement(data) if key(&data.path)? != key(&data.position.parent)? => {
                scheduler.drain().await?;
                let source_key = key(&data.path)?;
                let target_key = key(&data.position.parent)?;
                scheduler.ensure(workspace, group, &source_key)?;
                scheduler.ensure(workspace, group, &target_key)?;
                let id = scheduler.send(
                    &source_key,
                    FileModification::Extract {
                        path: data.path.clone(),
                    },
                    false,
                )?;
                let result = scheduler.wait(id).await?.map_err(|error| error.error)?;
                let copy = result
                    .extracted
                    .ok_or(CoreError::InvalidState("移动来源没有返回记录副本"))?;
                scheduler.send(
                    &target_key,
                    FileModification::Insert {
                        copy,
                        position: data.position.clone(),
                        strict: true,
                        after_hint: false,
                        properties: Vec::new(),
                        tags: None,
                    },
                    false,
                )?;
                scheduler.drain().await?;
            }
            _ => {
                let mut operation = operation.clone();
                if let TaskOperation::ConfilictSelection(data) = &mut operation {
                    if data.path.is_none() {
                        for repo in workspace.repos() {
                            for path in org_paths(Path::new(&repo.root_directory)).await? {
                                scheduler.ensure(workspace, group, &(repo.id.clone(), path))?;
                            }
                        }
                        scheduler.drain().await?;
                        let paths = scheduler
                            .conflicts
                            .iter()
                            .filter(|(_, ids)| ids.contains(&data.id))
                            .map(|(key, _)| key)
                            .collect::<Vec<_>>();
                        if paths.len() != 1 {
                            return Err(CoreError::InvalidInput("冲突点不存在或 ID 重复，请刷新"));
                        }
                        data.path = Some(TaskPath::file(paths[0].0.clone(), paths[0].1.clone()));
                    }
                }
                let file_key = match &operation {
                    TaskOperation::FileNew(data) => key(&data.path)?,
                    TaskOperation::FileHaderModification(data) => {
                        (data.file.repo_id.clone(), data.file.path.clone())
                    }
                    TaskOperation::Creation(data) => key(&data.position.parent)?,
                    TaskOperation::Modification(data) => key(&data.path)?,
                    TaskOperation::Note(data) => key(&data.path)?,
                    TaskOperation::Deletion(data) => key(&data.path)?,
                    TaskOperation::Movement(data) => key(&data.path)?,
                    TaskOperation::ConfilictSelection(data) => key(data
                        .path
                        .as_ref()
                        .ok_or(CoreError::InvalidState("冲突文件尚未解析"))?)?,
                    TaskOperation::FileDeletion(_) | TaskOperation::Trash(_) | TaskOperation::Restore(_) => unreachable!(),
                };
                scheduler.ensure(workspace, group, &file_key)?;
                scheduler.send(&file_key, FileModification::Operation(operation), false)?;
            }
        }
    }
    for version in &group.file_versions {
        scheduler.ensure(
            workspace,
            group,
            &(version.repo_id.clone(), version.file.clone()),
        )?;
    }
    scheduler.save_candidates().await
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn fixture() -> (PathBuf, OrgWorkspace, FileKey) {
        let root = std::env::temp_dir().join(format!(
            "lazy-file-scheduler-{}",
            super::super::super::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        fs::write(root.join("a.org"), "* TODO Original\n")
            .await
            .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        let key = (repo.id.clone(), "a.org".into());
        let workspace = OrgWorkspace::start(vec![repo]).await.unwrap();
        (root, workspace, key)
    }

    fn rename(file: &FileKey, old: &str, new: &str) -> FileModification {
        FileModification::Operation(TaskOperation::Modification(TaskModificationOperation {
            note: None,
            path: TaskPath {
                repo_id: file.0.clone(),
                file: Some(file.1.clone()),
                titles: vec![old.into()],
                occurrence: 1,
            },
            modifications: vec![TaskModification::Title(Some(new.into()))],
        }))
    }

    #[tokio::test]
    async fn worker_is_started_once_per_file_and_commands_do_not_wait_for_metadata() {
        let (root, workspace, file) = fixture().await;
        let state = workspace.state_for_test().await.unwrap();
        let group = TaskOperationGroup::default();
        let mut scheduler = Scheduler::new();
        scheduler.ensure(&state, &group, &file).unwrap();
        scheduler.ensure(&state, &group, &file).unwrap();
        assert_eq!(scheduler.workers.len(), 1);
        assert_eq!(scheduler.loading.len(), 1);
        assert!(scheduler.metadata.is_empty());
        scheduler
            .send(&file, rename(&file, "Original", "First"), false)
            .unwrap();
        scheduler
            .send(&file, rename(&file, "First", "Second"), false)
            .unwrap();
        scheduler.drain().await.unwrap();
        assert!(scheduler.metadata[&file].is_some());
        assert!(scheduler.versions[&file].is_some());
        let prepared = scheduler.save_candidates().await.unwrap();
        assert_eq!(prepared.files[&file].after, b"* TODO Second\n");
        assert_eq!(
            fs::read(root.join("a.org")).await.unwrap(),
            b"* TODO Original\n"
        );
        drop(prepared);
        workspace.stop().await.unwrap();
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn auto_load_error_is_not_replaced_by_a_closed_execute_channel() {
        let (root, workspace, file) = fixture().await;
        let state = workspace.state_for_test().await.unwrap();
        let group = TaskOperationGroup {
            file_versions: vec![TaskFileVersion {
                repo_id: file.0.clone(),
                file: file.1.clone(),
                version: "stale".into(),
            }],
            ..Default::default()
        };
        let mut scheduler = Scheduler::new();
        scheduler.ensure(&state, &group, &file).unwrap();
        // 让加载失败先发生，但主调度器尚未消费它的消息。
        while !scheduler.jobs.is_empty() {
            scheduler.jobs.join_next().await.unwrap().unwrap();
        }
        scheduler
            .send(&file, rename(&file, "Original", "Changed"), false)
            .unwrap();
        let error = scheduler.drain().await.unwrap_err();
        assert_eq!(
            error,
            CoreError::InvalidState("任务文件版本已变化，请刷新后重试")
        );
        assert_eq!(
            fs::read(root.join("a.org")).await.unwrap(),
            b"* TODO Original\n"
        );
        drop(scheduler);
        workspace.stop().await.unwrap();
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn file_task_panic_returns_error_instead_of_waiting_for_a_missing_reply() {
        let mut scheduler = Scheduler::new();
        scheduler.jobs.spawn(async { panic!("测试文件任务异常") });
        let result =
            tokio::time::timeout(std::time::Duration::from_secs(1), scheduler.event()).await;
        assert!(matches!(result, Ok(Err(CoreError::Store(_)))));
    }
}
