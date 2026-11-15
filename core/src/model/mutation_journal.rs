//! 操作组内的语义变更日志。节点令牌仅在本次执行中有效，不使用路径或偏移作为身份。
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use orgize::ast::Headline;

use super::{OrgFile, OrgRepo, TaskDataChange, TaskDataChangeKind, TaskDataSnapshot, TaskPosition};

type Token = u64;

#[derive(Debug, Default)]
struct State {
    next: Token,
    before: BTreeMap<Token, TaskDataSnapshot>,
    pending: BTreeMap<Token, TaskDataChangeKind>,
}

/// 所有文件共享同一日志，跨文件移动时把原有令牌移交给目标文件。
#[derive(Clone, Debug, Default)]
pub(super) struct MutationJournal(Arc<Mutex<State>>);

#[derive(Debug)]
pub(super) struct FileJournal {
    journal: MutationJournal,
    nodes: Vec<Token>,
}

impl MutationJournal {
    pub fn validate<'a>(
        &self,
        files: impl Iterator<Item = &'a OrgFile>,
    ) -> Result<(), crate::CoreError> {
        for file in files {
            if file
                .mutation_journal
                .as_ref()
                .is_none_or(|tracker| tracker.nodes.len() != headlines(file).len())
            {
                return Err(crate::CoreError::InvalidState("语义操作未同步维护节点令牌"));
            }
        }
        Ok(())
    }

    pub fn attach(&self, repo: &OrgRepo, file: &mut OrgFile) {
        let mut state = self.0.lock().unwrap();
        let nodes = snapshots(repo, file)
            .into_iter()
            .map(|snapshot| {
                let token = state.next;
                state.next += 1;
                state.before.insert(token, snapshot);
                token
            })
            .collect();
        file.mutation_journal = Some(FileJournal {
            journal: self.clone(),
            nodes,
        });
    }

    /// 这里只为执行中已经登记的事件补齐最终投影，不通过快照差分推断操作。
    pub fn finish<'a>(
        &self,
        files: impl Iterator<Item = (&'a OrgRepo, &'a OrgFile)>,
    ) -> Vec<TaskDataChange> {
        let mut after = BTreeMap::new();
        for (repo, file) in files {
            let tracker = file.mutation_journal.as_ref().expect("事务文件已登记");
            let snapshots = snapshots(repo, file);
            assert_eq!(
                tracker.nodes.len(),
                snapshots.len(),
                "语义操作必须同步维护节点令牌"
            );
            after.extend(tracker.nodes.iter().copied().zip(snapshots));
        }
        let state = self.0.lock().unwrap();
        state
            .pending
            .iter()
            .map(|(token, kind)| TaskDataChange {
                kind: *kind,
                before: state.before.get(token).cloned(),
                after: after.remove(token),
            })
            .collect()
    }
}

impl FileJournal {
    /// 任意真实写入同时改变文件版本。保留同文件全部节点的新投影，覆盖位置、重名序号和继承变化。
    pub fn touch(&self) {
        let mut state = self.journal.0.lock().unwrap();
        for token in &self.nodes {
            state
                .pending
                .entry(*token)
                .or_insert(TaskDataChangeKind::Updated);
        }
    }

    pub fn create(&mut self, ordinal: usize, count: usize) {
        let mut state = self.journal.0.lock().unwrap();
        let mut tokens = Vec::new();
        for _ in 0..count {
            let token = state.next;
            state.next += 1;
            state.pending.insert(token, TaskDataChangeKind::Created);
            tokens.push(token);
        }
        self.nodes.splice(ordinal..ordinal, tokens);
    }

    pub fn delete(&mut self, range: std::ops::Range<usize>) {
        let mut state = self.journal.0.lock().unwrap();
        for token in self.nodes.drain(range) {
            if state.before.contains_key(&token) {
                state.pending.insert(token, TaskDataChangeKind::Deleted);
            } else {
                // 本组内新建后又删除的节点没有已提交实体。
                state.pending.remove(&token);
            }
        }
    }

    pub fn take_moved(&mut self, range: std::ops::Range<usize>) -> Vec<Token> {
        let mut state = self.journal.0.lock().unwrap();
        let tokens = self.nodes.drain(range).collect::<Vec<_>>();
        for token in &tokens {
            if state.before.contains_key(token) {
                state.pending.insert(*token, TaskDataChangeKind::Moved);
            }
        }
        tokens
    }

    pub fn insert_moved(&mut self, ordinal: usize, tokens: Vec<Token>) {
        self.nodes.splice(ordinal..ordinal, tokens);
    }

    /// 完整主树替换没有节点一一对应的语义，明确删除旧树、创建新树，不猜测移动或身份。
    pub fn replace_tree(&mut self, count: usize) {
        self.delete(0..self.nodes.len());
        self.create(0, count);
    }
}

pub(super) fn headlines(file: &OrgFile) -> Vec<Headline> {
    file.path_headlines()
        .into_iter()
        .map(|(_, node)| node)
        .filter(|node| !OrgFile::is_conflict_headline(node))
        .collect()
}

pub(super) fn subtree_range(file: &OrgFile, headline: &Headline) -> std::ops::Range<usize> {
    let nodes = headlines(file);
    let first = nodes
        .iter()
        .position(|node| node.start() == headline.start())
        .expect("已定位节点");
    let count = nodes[first..]
        .iter()
        .take_while(|node| node.start() < headline.end())
        .count();
    first..first + count
}

pub(super) fn ordinal_at(file: &OrgFile, offset: usize) -> usize {
    headlines(file)
        .iter()
        .take_while(|node| usize::from(node.start()) < offset)
        .count()
}

fn snapshots(repo: &OrgRepo, file: &OrgFile) -> Vec<TaskDataSnapshot> {
    let tasks = crate::filter::tasks_from_file(repo, file);
    let mut ancestors: Vec<usize> = Vec::new();
    let mut previous = BTreeMap::new();
    let mut result = Vec::<TaskDataSnapshot>::new();
    for task in tasks {
        while ancestors
            .last()
            .is_some_and(|index| result[*index].task.level() >= task.level())
        {
            ancestors.pop();
        }
        let parent = ancestors
            .last()
            .map(|index| result[*index].task.full_path().clone())
            .unwrap_or_else(|| file.full_path());
        let after = previous.insert(parent.clone(), task.full_path().clone());
        let position = TaskPosition { parent, after };
        ancestors.push(result.len());
        result.push(TaskDataSnapshot { task, position });
    }
    result
}
