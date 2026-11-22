//! 一次请求内的单文件任务；业务执行只改内存，Save 将候选交还统一提交器。
use super::reader::FileLoadSpec;
use super::*;
use tokio::sync::{mpsc, oneshot};

pub(super) type OrderId = u64;

pub(super) enum FileCommand {
    Execute {
        order_id: OrderId,
        modification: FileModification,
    },
    Discard,
    Save,
}

pub(super) enum FileModification {
    Operation(TaskOperation),
    Insert {
        copy: Box<RecordCopy>,
        position: TaskPosition,
        strict: bool,
        after_hint: bool,
        properties: Vec<(String, Option<String>)>,
        tags: Option<Vec<String>>,
    },
    Extract {
        path: TaskPath,
    },
}

#[derive(Clone)]
pub(super) struct CopyHeading {
    pub title: String,
    pub state: Option<String>,
}

#[derive(Clone)]
pub(super) struct RecordCopy {
    pub token: Option<u64>,
    pub source: TaskDataSnapshot,
    pub source_text: String,
    pub category: Option<String>,
    pub project_name: Option<String>,
    pub file_title: Option<String>,
    pub file_id: Option<String>,
    pub headings: Vec<CopyHeading>,
    pub todo_defaults: TodoConfig,
    pub todo_setup: String,
    pub moved_tokens: Option<Vec<super::super::mutation_journal::TransferredNode>>,
}

impl RecordCopy {
    pub(super) fn trash_attributes(&self) -> Result<(Vec<(String, Option<String>)>, Vec<String>), CoreError> {
        let title = self.headings[0].title.clone();
        let state = serde_json::to_string(&self.headings[0].state)
            .map_err(|_| CoreError::InvalidState("无法记录任务状态"))?;
        let mut tags = self.source.task.own_tags().to_vec();
        let mut parent_tags = Vec::new();
        for tag in self.source.task.inherited_tags() {
            if !tags.contains(tag) {
                tags.push(tag.clone());
                parent_tags.push(tag.clone());
            }
        }
        let mut source_position = self.source.position.clone();
        let brother = source_position.after.take();
        let mut patches = self
            .source
            .task
            .properties()
            .keys()
            .filter(|name| name.starts_with("SOURCE_"))
            .map(|name| (name.clone(), None))
            .collect::<Vec<_>>();
        patches.extend(vec![
            ("ID".into(), None),
            (
                "SOURCE_ID".into(),
                self.source.task.property("ID").map(str::to_owned),
            ),
            (
                "SOURCE_FILE_TITLE".into(),
                Some(self.file_title.clone().unwrap_or_default()),
            ),
            (
                "SOURCE_FILE_ID".into(),
                Some(self.file_id.clone().unwrap_or_default()),
            ),
            (
                "SOURCE_BROTHER".into(),
                brother
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()
                    .map_err(|_| CoreError::InvalidState("无法记录前一兄弟节点"))?,
            ),
            (
                "SOURCE_PARENT_TAGS".into(),
                Some(
                    serde_json::to_string(&parent_tags)
                        .map_err(|_| CoreError::InvalidState("无法记录继承标签"))?,
                ),
            ),
            ("SOURCE_REPO".into(), Some(self.source.task.repo_id().into())),
            ("SOURCE_FILE".into(), Some(self.source.task.path().into())),
            (
                "SOURCE_OLPATH".into(),
                Some(self.source.position.parent.titles.join("/")),
            ),
            (
                "SOURCE_POSITION".into(),
                Some(
                    serde_json::to_string(&source_position)
                        .map_err(|_| CoreError::InvalidState("无法记录原位置"))?,
                ),
            ),
            (
                "SOURCE_TIME".into(),
                Some(
                    chrono::Local::now()
                        .format("[%Y-%m-%d %a %H:%M]")
                        .to_string(),
                ),
            ),
            ("SOURCE_TASK_TITLE".into(), Some(title)),
            ("SOURCE_TASK_STATE".into(), Some(state)),
            ("SOURCE_CATEGORY".into(), self.category.clone()),
            ("SOURCE_PROJECT_NAME".into(), self.project_name.clone()),
            (
                "SOURCE_TRASH_ID".into(),
                Some(super::super::service::generate_repo_id()?),
            ),
        ]);
        Ok((patches, tags))
    }
}

pub(super) struct FileExecuteResult {
    pub order_id: OrderId,
    pub notification: Vec<TaskDataChange>,
    pub result_path: Option<TaskPath>,
    pub snapshot: Vec<RecordCopy>,
    pub extracted: Option<Box<RecordCopy>>,
}

pub(super) struct FileExecuteError {
    pub order_id: OrderId,
    pub error: CoreError,
}

pub(super) struct FileLoadResult {
    pub file_version: Option<String>,
    pub metadata: Option<OrgFileMetadata>,
    pub full_file: Option<OrgFile>,
    pub records: Vec<RecordCopy>,
    pub conflicts: Vec<String>,
    pub dependencies: ReadDependencies,
}

pub(super) struct FileSavePlan {
    pub candidate: SaveCandidate,
    pub committed: oneshot::Sender<Result<Option<FileStamp>, CoreError>>,
}

pub(super) struct FileSaveResult {
    pub file_change: Option<FileDataChange>,
    pub task_changes: Vec<TaskDataChange>,
}

pub(super) enum FileReply {
    Loaded(Result<FileLoadResult, CoreError>),
    Executed(Result<FileExecuteResult, FileExecuteError>),
    SaveReady(Result<FileSavePlan, CoreError>),
    Saved(FileSaveResult),
}

pub(super) struct FileEvent {
    pub file: FileKey,
    pub reply: FileReply,
}

pub(super) fn snapshot(repo: &OrgRepo, file: &OrgFile) -> Vec<RecordCopy> {
    let setup = format!(
        "{}\n{}",
        file.todo_setup,
        file.todo
            .declarations
            .iter()
            .map(|decl| format!("#+{}: {}", decl.keyword, decl.value))
            .collect::<Vec<_>>()
            .join("\n")
    );
    super::super::mutation_journal::snapshots(repo, file)
        .into_iter()
        .enumerate()
        .filter_map(|(ordinal, source)| {
            let node = locate(file, source.task.full_path()).ok()?;
            let headings = node
                .syntax()
                .descendants()
                .filter_map(Headline::cast)
                .map(|node| CopyHeading {
                    title: node.title_raw().trim_end().into(),
                    state: node.todo_keyword().map(|value| value.to_string()),
                })
                .collect();
            Some(RecordCopy {
                token: file
                    .mutation_journal
                    .as_ref()
                    .and_then(|journal| journal.token_at(ordinal)),
                source,
                source_text: node.raw(),
                category: file.category(),
                project_name: file.project(),
                file_title: file.title(),
                file_id: file.syntax().document().properties().and_then(|drawer| {
                    super::super::properties::entries(&drawer)
                        .find(|entry| entry.name == "ID" && !entry.append)
                        .map(|entry| entry.value)
                }),
                headings,
                todo_defaults: file.todo_defaults.clone(),
                todo_setup: setup.clone(),
                moved_tokens: None,
            })
        })
        .collect()
}

pub(super) async fn run(
    spec: FileLoadSpec,
    mut commands: mpsc::UnboundedReceiver<FileCommand>,
    results: mpsc::UnboundedSender<FileEvent>,
) {
    let key = (spec.repo.id.clone(), spec.path.clone());
    let journal = super::super::mutation_journal::MutationJournal::default();
    // 启动即加载，主任务不必等待 Loaded 就可以排入 Execute。
    let (mut loaded, dependencies) = match super::reader::load(&spec).await {
        Ok(value) => value,
        Err(error) => {
            let _ = results.send(FileEvent {
                file: key,
                reply: FileReply::Loaded(Err(error)),
            });
            return;
        }
    };
    journal.attach(&spec.repo, &mut loaded.file);
    let initial_headers = loaded.file.header_entries();
    let result = FileLoadResult {
        file_version: loaded
            .original
            .as_ref()
            .map(|bytes| LocalFileVersion::from_bytes(bytes).content_hash),
        metadata: loaded.before_metadata.clone(),
        full_file: spec.full_file.then(|| loaded.file.clone()),
        records: if spec.export_records {
            snapshot(&spec.repo, &loaded.file)
        } else {
            Vec::new()
        },
        conflicts: loaded.file.conflict_ids(),
        dependencies,
    };
    if results
        .send(FileEvent {
            file: key.clone(),
            reply: FileReply::Loaded(Ok(result)),
        })
        .is_err()
    {
        return;
    }
    let mut files = BTreeMap::from([(key.clone(), loaded)]);
    while let Some(command) = commands.recv().await {
        match command {
            FileCommand::Execute {
                order_id,
                modification,
            } => {
                let result = apply(&key, &mut files, modification, &initial_headers);
                let result = match result {
                    Ok((result_path, extracted)) => {
                        let item = &files[&key];
                        let notification = journal
                            .finish(std::iter::once((&spec.repo, &item.file)))
                            .into_iter()
                            .filter(|change| {
                                [&change.before, &change.after]
                                    .into_iter()
                                    .flatten()
                                    .any(|value| {
                                        value.task.repo_id() == key.0 && value.task.path() == key.1
                                    })
                            })
                            .collect();
                        Ok(FileExecuteResult {
                            order_id,
                            notification,
                            result_path,
                            extracted,
                            snapshot: if spec.export_records {
                                snapshot(&spec.repo, &item.file)
                            } else {
                                Vec::new()
                            },
                        })
                    }
                    Err(error) => Err(FileExecuteError { order_id, error }),
                };
                if results
                    .send(FileEvent {
                        file: key.clone(),
                        reply: FileReply::Executed(result),
                    })
                    .is_err()
                {
                    return;
                }
            }
            FileCommand::Discard => return,
            FileCommand::Save => {
                let mut item = files.remove(&key).expect("本文件已加载");
                if let Err(error) = journal.validate(std::iter::once(&item.file)) {
                    let _ = results.send(FileEvent {
                        file: key,
                        reply: FileReply::SaveReady(Err(error)),
                    });
                    return;
                }
                let candidate = SaveCandidate {
                    disk: item.disk.clone(),
                    original: item.original.clone(),
                    after: item.file.source_bytes().to_vec(),
                    stamp: item.stamp.clone(),
                    exists: item.exists,
                };
                let (committed, completion) = oneshot::channel();
                if results
                    .send(FileEvent {
                        file: key.clone(),
                        reply: FileReply::SaveReady(Ok(FileSavePlan {
                            candidate,
                            committed,
                        })),
                    })
                    .is_err()
                {
                    return;
                }
                let Ok(Ok(stamp)) = completion.await else {
                    return;
                };
                item.file.modified_at = stamp.as_ref().and_then(stamp_timestamp);
                // 最终 Metadata 与完整任务投影仍在文件任务内生成。
                let changed =
                    item.exists && item.original.as_deref() != Some(item.file.source_bytes());
                let file_change = changed.then(|| FileDataChange {
                    before: item.before_metadata.clone(),
                    after: item.file.metadata(item.file.scan_ignored),
                    before_version: item
                        .original
                        .as_ref()
                        .map(|bytes| LocalFileVersion::from_bytes(bytes).content_hash),
                    after_version: LocalFileVersion::from_bytes(item.file.source_bytes())
                        .content_hash,
                });
                let task_changes = journal.finish(std::iter::once((&spec.repo, &item.file)));
                let _ = results.send(FileEvent {
                    file: key,
                    reply: FileReply::Saved(FileSaveResult {
                        file_change,
                        task_changes,
                    }),
                });
                return;
            }
        }
    }
}

/// 只读规划也通过同一文件任务获得完整文件，调用者不自行读盘或 clone 文件。
pub(super) async fn read_full_file(mut spec: FileLoadSpec) -> Result<OrgFile, CoreError> {
    spec.full_file = true;
    let (commands, input) = mpsc::unbounded_channel();
    let (output, mut events) = mpsc::unbounded_channel();
    let mut task = tokio::spawn(run(spec, input, output));
    let event = tokio::select! {
        biased;
        event=events.recv()=>event.ok_or(CoreError::InvalidState("完整文件结果通道已关闭"))?,
        result=&mut task=>{result.map_err(|error|CoreError::Store(format!("完整文件任务异常: {error}")))?;return Err(CoreError::InvalidState("完整文件任务没有返回结果"));}
    };
    let _ = commands.send(FileCommand::Discard);
    task.await
        .map_err(|error| CoreError::Store(format!("完整文件任务异常: {error}")))?;
    let FileReply::Loaded(result) = event.reply else {
        return Err(CoreError::InvalidState("完整文件回复无效"));
    };
    result?
        .full_file
        .ok_or(CoreError::InvalidState("完整文件快照不存在"))
}

fn apply(
    key: &FileKey,
    files: &mut BTreeMap<FileKey, WorkingFile>,
    modification: FileModification,
    initial_headers: &[FileHeaderEntry],
) -> Result<(Option<TaskPath>, Option<Box<RecordCopy>>), CoreError> {
    match modification {
        FileModification::Insert {
            copy,
            position: target,
            strict,
            after_hint,
            properties,
            tags,
        } => {
            let mut copy = copy;
            patch_copy(&mut copy, &properties, tags)?;
            insert_copy(
                files.get_mut(key).expect("已装载文件"),
                &copy,
                &target,
                strict,
                after_hint,
            )
            .map(|path| (Some(path), None))
        }
        FileModification::Extract { path } => {
            let item = files.get_mut(key).expect("已装载文件");
            let repo = OrgRepo {
                id: key.0.clone(),
                root_directory: String::new(),
                todo_defaults: item.file.todo_defaults.clone(),
            };
            // 使用原文件的投影信息取得副本，节点身份在这里不用于查询成员比较。
            let mut copy = snapshot(&repo, &item.file)
                .into_iter()
                .find(|copy| copy.source.task.full_path() == &path)
                .ok_or(CoreError::InvalidInput("移动来源不存在"))?;
            let node = locate(&item.file, &path)?;
            let range = start(&node)..end(&node);
            let nodes = super::super::mutation_journal::subtree_range(&item.file, &node);
            copy.moved_tokens = item
                .file
                .mutation_journal
                .as_mut()
                .map(|tracker| tracker.export_moved(nodes));
            replace(&mut item.file, range, &[])?;
            Ok((None, Some(Box::new(copy))))
        }
        FileModification::Operation(mut operation) => {
            if let TaskOperation::FileHaderModification(data) = &mut operation {
                let current = files[key].file.header_entries();
                if current.len() != initial_headers.len()
                    || current.iter().zip(initial_headers).any(|(a, b)| {
                        a.name != b.name || a.keyword != b.keyword || a.value != b.value
                    })
                {
                    return Err(CoreError::InvalidState(
                        "本组先前操作已改变文件头，请重新载入",
                    ));
                }
                // 文件头条目按操作组初始版本定位，允许先前正文编辑改变源码偏移。
                for change in &mut data.changes {
                    let index = initial_headers
                        .iter()
                        .position(|entry| entry.id == change.entry_id)
                        .ok_or(CoreError::InvalidState("文件属性条目不属于预期版本"))?;
                    change.entry_id = current[index].id.clone();
                }
            }
            // 输入的基础操作必须只接触本文件；跨文件操作由调度器分解。
            let keys = super::super::conflict_preview::operation_paths(&TaskOperationGroup {
                operations: vec![operation.clone()],
                ..Default::default()
            })
            .into_iter()
            .map(super::key)
            .collect::<Result<Vec<_>, _>>()?;
            if keys.iter().any(|file| file != key) {
                return Err(CoreError::InvalidInput("文件任务不能执行跨文件操作"));
            }
            let result = execute(files, &operation);
            result.map(|path| (path, None))
        }
    }
}

fn patch_copy(
    copy: &mut RecordCopy,
    patches: &[(String, Option<String>)],
    tags: Option<Vec<String>>,
) -> Result<(), CoreError> {
    let mut file = OrgFile::with_todo_defaults_and_setup(
        copy.source.task.repo_id().into(),
        copy.source.task.path().into(),
        copy.source_text.as_bytes().to_vec(),
        copy.todo_defaults.clone(),
        copy.todo_setup.clone(),
    )?;
    for (name, value) in patches {
        let node = file
            .path_headlines()
            .into_iter()
            .next()
            .ok_or(CoreError::InvalidInput("副本缺少记录"))?
            .1;
        super::super::task_state::modify_property(&mut file, &node, name, value.as_deref())?;
    }
    if let Some(tags) = tags {
        let node = file
            .path_headlines()
            .into_iter()
            .next()
            .ok_or(CoreError::InvalidInput("副本缺少记录"))?
            .1;
        modify(&mut file, &node, &TaskModification::Tags(Some(tags)))?;
    }
    copy.source_text = String::from_utf8(file.source_bytes).expect("Org 文件为 UTF-8");
    Ok(())
}

fn insert_copy(
    item: &mut WorkingFile,
    copy: &RecordCopy,
    target: &TaskPosition,
    strict: bool,
    after_hint: bool,
) -> Result<TaskPath, CoreError> {
    if !item.exists {
        return Err(CoreError::InvalidInput("恢复目标文件不存在"));
    }
    let (offset, level) = if after_hint {
        position_hint(&item.file, target)?
    } else {
        position(&item.file, target)?
    };
    let mut content = copy.source_text.clone();
    // 副本可能已添加属性，使用独立解析器重新计算标题偏移，不修改工作文件。
    let source = OrgFile::with_todo_defaults_and_setup(
        item.file.repo_id.clone(),
        item.file.path.clone(),
        content.as_bytes().to_vec(),
        copy.todo_defaults.clone(),
        copy.todo_setup.clone(),
    )?;
    let first = source
        .path_headlines()
        .into_iter()
        .next()
        .ok_or(CoreError::InvalidInput("副本缺少记录"))?
        .1;
    let base_level = first.level();
    let mut edits = source
        .path_headlines()
        .into_iter()
        .map(|(_, node)| {
            (
                start(&node),
                node.level(),
                "*".repeat(level + node.level() - base_level),
            )
        })
        .collect::<Vec<_>>();
    edits.sort_by_key(|(offset, _, _)| std::cmp::Reverse(*offset));
    for (offset, old, stars) in edits {
        content.replace_range(offset..offset + old, &stars);
    }
    let inserted = offset
        + if offset > 0 && item.file.source_bytes()[offset - 1] != b'\n' {
            newline(&item.file).len()
        } else {
            0
        };
    let mut probe = item.file.clone();
    insert(&mut probe, offset, &content)?;
    let node = probe
        .path_headlines()
        .into_iter()
        .find(|(_, node)| start(node) == inserted)
        .ok_or(CoreError::InvalidInput("目标位置不能插入副本"))?
        .1;
    let nodes = node
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    if strict
        && (nodes.len() != copy.headings.len()
            || nodes.iter().zip(&copy.headings).any(|(actual, expected)| {
                actual.title_raw().trim_end() != expected.title
                    || actual.todo_keyword().map(|value| value.to_string()) != expected.state
            }))
    {
        return Err(CoreError::InvalidInput(
            "目标文件不能保留记录的标题或 TODO 状态",
        ));
    }
    let ordinal = super::super::mutation_journal::ordinal_at(&item.file, inserted);
    insert(&mut item.file, offset, &content)?;
    if let Some(tracker) = &mut item.file.mutation_journal {
        if let Some(tokens) = &copy.moved_tokens {
            tracker.import_moved(ordinal, tokens);
        } else {
            tracker.create(ordinal, nodes.len());
        }
    }
    path_at(&item.file, inserted)
}

#[cfg(test)]
mod tests {
    use super::super::reader::ReadCache;
    use super::*;

    async fn fixture() -> (PathBuf, OrgRepo) {
        let root = std::env::temp_dir().join(format!(
            "file-worker-load-{}",
            super::super::super::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        fs::write(
            root.join("tasks.org"),
            "#+TITLE: Original file\n* TODO Original\n",
        )
        .await
        .unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        (root, repo)
    }
    fn spec(repo: OrgRepo, full_file: bool) -> FileLoadSpec {
        FileLoadSpec {
            repo,
            path: "tasks.org".into(),
            versions: Vec::new(),
            new_files: Vec::new(),
            export_records: false,
            full_file,
            cache: ReadCache::default(),
        }
    }

    #[tokio::test]
    async fn commands_can_be_queued_before_auto_load_and_only_save_commits_the_final_candidate() {
        let (root, repo) = fixture().await;
        let file_key: FileKey = (repo.id.clone(), "tasks.org".into());
        let (send, commands) = mpsc::unbounded_channel();
        let (results, mut receive) = mpsc::unbounded_channel();
        let task = tokio::spawn(run(spec(repo, false), commands, results));
        let path = |title: &str| TaskPath {
            repo_id: file_key.0.clone(),
            file: Some(file_key.1.clone()),
            titles: vec![title.into()],
            occurrence: 1,
        };
        // 主任务不等待加载通知，就可以连续排入修改。
        for (id, old, new) in [(41, "Original", "First"), (42, "First", "Second")] {
            send.send(FileCommand::Execute {
                order_id: id,
                modification: FileModification::Operation(TaskOperation::Modification(
                    TaskModificationOperation {
                        note: None,
                        path: path(old),
                        modifications: vec![TaskModification::Title(Some(new.into()))],
                    },
                )),
            })
            .unwrap();
        }
        let FileReply::Loaded(Ok(loaded)) = receive.recv().await.unwrap().reply else {
            panic!("缺少加载结果")
        };
        assert_eq!(
            loaded.metadata.unwrap().title.as_deref(),
            Some("Original file")
        );
        assert!(loaded.file_version.is_some());
        assert!(loaded.full_file.is_none());
        for id in [41, 42] {
            let FileReply::Executed(Ok(result)) = receive.recv().await.unwrap().reply else {
                panic!("缺少执行结果")
            };
            assert_eq!(result.order_id, id);
            assert!(!result.notification.is_empty());
        }
        let original = b"#+TITLE: Original file\n* TODO Original\n";
        assert_eq!(fs::read(root.join("tasks.org")).await.unwrap(), original);
        assert!(!task.is_finished());
        send.send(FileCommand::Save).unwrap();
        let FileReply::SaveReady(Ok(plan)) = receive.recv().await.unwrap().reply else {
            panic!("缺少保存候选")
        };
        assert_eq!(
            plan.candidate.original.as_deref(),
            Some(original.as_slice())
        );
        assert!(String::from_utf8_lossy(&plan.candidate.after).contains("Second"));
        assert_eq!(fs::read(root.join("tasks.org")).await.unwrap(), original);
        let disk = plan.candidate.disk.clone();
        let candidates = BTreeMap::from([(file_key, plan.candidate)]);
        let stamps = commit_prepared(&candidates, None).await.unwrap();
        plan.committed.send(Ok(stamps.get(&disk).cloned())).unwrap();
        let FileReply::Saved(saved) = receive.recv().await.unwrap().reply else {
            panic!("缺少最终元信息")
        };
        assert!(saved.file_change.unwrap().after.modified_at.is_some());
        assert!(saved.task_changes.iter().any(|change| {
            change
                .after
                .as_ref()
                .is_some_and(|value| value.task.title() == "Second")
        }));
        task.await.unwrap();
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn loading_metadata_and_full_file_are_generated_inside_the_started_worker() {
        let (root, repo) = fixture().await;
        let (send, commands) = mpsc::unbounded_channel();
        let (results, mut receive) = mpsc::unbounded_channel();
        let task = tokio::spawn(run(spec(repo, true), commands, results));
        // 当前线程尚未让出执行权，文件任务启动前的改动必须出现在读取结果中。
        let source = b"#+TITLE: Updated before task runs\n* TODO Loaded inside worker\n";
        std::fs::write(root.join("tasks.org"), source).unwrap();
        let FileReply::Loaded(Ok(loaded)) = receive.recv().await.unwrap().reply else {
            panic!("缺少文件结果")
        };
        assert_eq!(
            loaded.metadata.unwrap().title.as_deref(),
            Some("Updated before task runs")
        );
        assert_eq!(loaded.full_file.unwrap().source_bytes(), source);
        send.send(FileCommand::Discard).unwrap();
        task.await.unwrap();
        fs::remove_dir_all(root).await.unwrap();
    }
}
