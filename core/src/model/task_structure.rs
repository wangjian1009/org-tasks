//! 在隔离语法树中将结构编辑意图解析为普通任务操作。
use std::collections::{BTreeMap, BTreeSet};

use orgize::{ast::Headline, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};

use super::{
    OrgFile, OrgRepo, TaskCreation, TaskFileVersion, TaskModification, TaskModificationOperation,
    TaskMovement, TaskOperation, TaskOperationGroup, TaskPath, TaskPosition,
    mutation_journal::{MutationJournal, ordinal_at},
    task_operation_executor::{edit_preview_operations, locate, position},
};
use crate::CoreError;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskStructureRequest {
    pub file: TaskPath,
    pub file_version: String,
    pub edits: Vec<TaskStructureEdit>,
}

/// 已有节点使用初始查询返回的任务 ID。新节点使用本请求内唯一的草稿 ID。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum TaskStructureEdit {
    Add {
        id: String,
        parent: Option<String>,
        title: String,
        task: bool,
    },
    Rename {
        id: String,
        title: String,
    },
    Move {
        ids: Vec<String>,
        parent: Option<String>,
        after: Option<String>,
    },
}

struct Planner {
    file: Option<OrgFile>,
    tokens: BTreeMap<String, u64>,
    journal: MutationJournal,
    operations: Vec<TaskOperation>,
}

impl Planner {
    fn file(&self) -> &OrgFile {
        self.file.as_ref().expect("规划中的文件")
    }

    fn path(&self, id: &str) -> Result<TaskPath, CoreError> {
        let token = self
            .tokens
            .get(id)
            .ok_or(CoreError::InvalidInput("结构节点不存在"))?;
        let ordinal = self
            .file()
            .mutation_journal
            .as_ref()
            .and_then(|journal| journal.ordinal_for_token(*token))
            .ok_or(CoreError::InvalidState("结构节点身份已变化"))?;
        self.file()
            .editable_node_paths()
            .into_iter()
            .nth(ordinal)
            .ok_or(CoreError::InvalidState("无法定位结构节点"))
    }

    fn apply(&mut self, operation: TaskOperation) -> Result<TaskPath, CoreError> {
        let (file, path) = edit_preview_operations(
            self.file.take().expect("规划中的文件"),
            std::slice::from_ref(&operation),
        )?;
        self.journal.validate(std::iter::once(&file))?;
        self.file = Some(file);
        self.operations.push(operation);
        path.ok_or(CoreError::InvalidState("结构操作未返回节点路径"))
    }

    fn edit(&mut self, edit: &TaskStructureEdit) -> Result<(), CoreError> {
        match edit {
            TaskStructureEdit::Add {
                id,
                parent,
                title,
                task,
            } => {
                if id.is_empty() || self.tokens.contains_key(id) {
                    return Err(CoreError::InvalidInput("草稿节点身份为空或重复"));
                }
                let parent = self.parent_path(parent.as_deref())?;
                let mut creation = TaskCreation::new(
                    TaskPosition {
                        parent,
                        after: None,
                    },
                    title.clone(),
                );
                if *task {
                    creation.state = Some(
                        self.file()
                            .todo
                            .initial_state
                            .clone()
                            .ok_or(CoreError::InvalidInput("项目文件没有可用的待办状态"))?,
                    );
                }
                let path = self.apply(TaskOperation::Creation(creation))?;
                let inserted = locate(self.file(), &path)?;
                if inserted.headlines().next().is_some() {
                    return Err(CoreError::InvalidInput(
                        "该位置的标题层级会使现有节点成为新节点的子项",
                    ));
                }
                let offset = usize::from(inserted.start());
                let token = self
                    .file()
                    .mutation_journal
                    .as_ref()
                    .unwrap()
                    .token_at(ordinal_at(self.file(), offset))
                    .ok_or(CoreError::InvalidState("新增节点身份缺失"))?;
                self.tokens.insert(id.clone(), token);
            }
            TaskStructureEdit::Rename { id, title } => {
                let path = self.path(id)?;
                self.apply(TaskOperation::Modification(TaskModificationOperation {
                    path,
                    modifications: vec![TaskModification::Title(Some(title.clone()))],
                    note: None,
                }))?;
            }
            TaskStructureEdit::Move { ids, parent, after } => {
                self.move_nodes(ids, parent.as_deref(), after.as_deref())?;
            }
        }
        Ok(())
    }

    fn parent_path(&self, id: Option<&str>) -> Result<TaskPath, CoreError> {
        id.map(|key| self.path(key))
            .transpose()
            .map(|path| path.unwrap_or_else(|| self.file().full_path()))
    }

    fn move_nodes(
        &mut self,
        ids: &[String],
        parent: Option<&str>,
        after: Option<&str>,
    ) -> Result<(), CoreError> {
        if ids.is_empty() || ids.iter().collect::<BTreeSet<_>>().len() != ids.len() {
            return Err(CoreError::InvalidInput("请选择不同的结构节点"));
        }
        let mut selected = ids
            .iter()
            .map(|id| {
                let node = locate(self.file(), &self.path(id)?)?;
                Ok((node.start(), node.end(), id.as_str()))
            })
            .collect::<Result<Vec<_>, CoreError>>()?;
        selected.sort_by_key(|(start, _, _)| *start);
        if selected.windows(2).any(|pair| pair[1].0 < pair[0].1) {
            return Err(CoreError::InvalidInput("不能同时移动父节点及其后代"));
        }
        for target in parent.into_iter().chain(after) {
            let offset = locate(self.file(), &self.path(target)?)?.start();
            if selected
                .iter()
                .any(|(start, end, _)| *start <= offset && offset < *end)
            {
                return Err(CoreError::InvalidInput("不能移动到自身或后代"));
            }
        }
        let mut previous = after;
        for (_, _, id) in selected {
            let path = self.path(id)?;
            let destination = TaskPosition {
                parent: self.parent_path(parent)?,
                after: previous.map(|id| self.path(id)).transpose()?,
            };
            let (offset, _) = position(self.file(), &destination)?;
            let node = locate(self.file(), &path)?;
            let current_parent = node.syntax().ancestors().skip(1).find_map(Headline::cast);
            let target_parent = if destination.parent.titles.is_empty() {
                None
            } else {
                Some(locate(self.file(), &destination.parent)?)
            };
            if offset != usize::from(node.start()) || current_parent != target_parent {
                let source_count = node
                    .syntax()
                    .descendants()
                    .filter_map(Headline::cast)
                    .count();
                let moved = self.apply(TaskOperation::Movement(TaskMovement {
                    path,
                    position: destination,
                }))?;
                let moved_count = locate(self.file(), &moved)?
                    .syntax()
                    .descendants()
                    .filter_map(Headline::cast)
                    .count();
                if source_count != moved_count {
                    return Err(CoreError::InvalidInput("该落点会改变未选中的节点层级"));
                }
            }
            previous = Some(id);
        }
        Ok(())
    }
}

pub(super) fn operations(
    repo: &OrgRepo,
    mut file: OrgFile,
    request: &TaskStructureRequest,
) -> Result<TaskOperationGroup, CoreError> {
    let journal = MutationJournal::default();
    journal.attach(repo, &mut file);
    let tracker = file.mutation_journal.as_ref().unwrap();
    let tokens = crate::filter::tasks_from_file(repo, &file)
        .into_iter()
        .enumerate()
        .map(|(ordinal, task)| {
            tracker
                .token_at(ordinal)
                .map(|token| (task.id().to_owned(), token))
                .ok_or(CoreError::InvalidState("结构快照的节点身份不完整"))
        })
        .collect::<Result<_, _>>()?;
    let mut planner = Planner {
        file: Some(file),
        tokens,
        journal,
        operations: Vec::new(),
    };
    for edit in &request.edits {
        planner.edit(edit)?;
    }
    Ok(TaskOperationGroup {
        operation_id: None,
        operations: planner.operations,
        file_versions: vec![TaskFileVersion {
            repo_id: request.file.repo_id.clone(),
            file: request.file.file.clone().expect("已验证文件路径"),
            version: request.file_version.clone(),
        }],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{LocalFileVersion, OrgWorkspace};

    #[tokio::test]
    async fn planning_resolves_duplicate_paths_and_applies_all_edits_atomically() {
        let sequence = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("org-structure-{sequence}"));
        std::fs::create_dir(&root).unwrap();
        let source = "#+TODO: NEXT | DONE\r\n导言\r\n* 章节\r\n** 同名\r\n原正文一\r\n** 同名\r\n原正文二\r\n*** NEXT 后代\r\n* 目标\r\n原正文三\r\n";
        let path = root.join("p.org");
        std::fs::write(&path, source).unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        repo.load_identity().await.unwrap();
        let file_path = TaskPath::file(repo.id.clone(), "p.org".into());
        let workspace = OrgWorkspace::start(vec![repo.clone()]).await.unwrap();
        let before = workspace.file_at(&file_path).await.unwrap();
        let nodes = crate::filter::tasks_from_file(&repo, &before);
        let second = nodes[2].id().to_owned();
        let first = nodes[1].id().to_owned();
        let chapter = nodes[0].id().to_owned();
        let target = nodes[4].id().to_owned();
        let mut request = TaskStructureRequest {
            file: file_path.clone(),
            file_version: LocalFileVersion::from_bytes(before.source_bytes()).content_hash,
            edits: vec![
                TaskStructureEdit::Add {
                    id: "draft".into(),
                    parent: None,
                    title: "新节点".into(),
                    task: true,
                },
                TaskStructureEdit::Move {
                    ids: vec![second.clone(), first.clone()],
                    parent: Some("draft".into()),
                    after: None,
                },
                TaskStructureEdit::Rename {
                    id: second.clone(),
                    title: "保留后代".into(),
                },
                TaskStructureEdit::Move {
                    ids: vec![chapter],
                    parent: None,
                    after: Some(target),
                },
            ],
        };
        let group = workspace.task_structure_operations(&request).await.unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
        let valid = request.edits.clone();
        request.edits.push(TaskStructureEdit::Move {
            ids: vec!["draft".into()],
            parent: Some(second),
            after: None,
        });
        assert!(workspace.task_structure_operations(&request).await.is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
        request.edits = valid;
        workspace.execute_task_operations(&group).await.unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(after.starts_with("#+TODO: NEXT | DONE\r\n导言\r\n* NEXT 新节点\r\n"));
        assert!(after.contains("** 同名\r\n原正文一\r\n** 保留后代\r\n原正文二\r\n*** NEXT 后代\r\n* 目标\r\n原正文三\r\n* 章节\r\n"));
        assert!(workspace.task_structure_operations(&request).await.is_err());
        assert!(workspace.execute_task_operations(&group).await.is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), after);
        workspace.stop().await.unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }
}
