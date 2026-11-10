//! 文件尾部的冲突容器；查询与普通编辑仅依据自有／祖先 CONFLICT 标签划定边界。
use super::{CoreError, OrgFile};
use orgize::ast::Headline;
use std::ops::Range;

pub(crate) const CONFLICT_CONTAINER_TITLE: &str = "同步冲突";
pub(crate) const CONFLICT_POINT_ID: &str = "CONFILICT_ID";

#[derive(Clone)]
pub(crate) struct ConflictPoint {
    pub id: String,
    pub source: String,
}

pub(crate) fn point_id(headline: &Headline) -> Option<String> {
    headline
        .properties()?
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(CONFLICT_POINT_ID))
        .map(|(_, value)| value.to_string())
}

pub(crate) fn container(file: &OrgFile) -> Option<Headline> {
    file.syntax().document().headlines().find(|headline| {
        headline.level() == 1
            && headline.tags().any(|tag| tag == super::CONFLICT_TAG)
            && headline.title_raw().trim_end() == CONFLICT_CONTAINER_TITLE
    })
}

pub(crate) fn points(file: &OrgFile) -> Result<Vec<ConflictPoint>, CoreError> {
    let Some(container) = container(file) else {
        return Ok(Vec::new());
    };
    let mut ids = std::collections::BTreeSet::new();
    container
        .headlines()
        .map(|headline| {
            let id =
                point_id(&headline).ok_or(CoreError::InvalidState("冲突点缺少 CONFILICT_ID"))?;
            if id.is_empty() || !ids.insert(id.clone()) {
                return Err(CoreError::InvalidState("冲突点 ID 为空或重复"));
            }
            let range = usize::from(headline.start())..usize::from(headline.end());
            Ok(ConflictPoint {
                id,
                source: String::from_utf8(file.source_bytes()[range].to_vec()).expect("UTF-8"),
            })
        })
        .collect()
}

/// 容器生成时单独追加一个分隔换行；分隔符属于整个冲突块，移除时一并恢复原始末尾状态。
pub(crate) fn block_range(file: &OrgFile, headline: &Headline) -> Range<usize> {
    let mut start = usize::from(headline.start());
    if start > 0 && file.source_bytes()[start - 1] == b'\n' {
        start -= 1;
        if start > 0 && file.source_bytes()[start - 1] == b'\r' {
            start -= 1;
        }
    }
    start..usize::from(headline.end())
}

pub(crate) fn main_source(file: &OrgFile) -> Vec<u8> {
    let Some(container) = container(file) else {
        return file.source_bytes().to_vec();
    };
    let range = block_range(file, &container);
    let mut source = file.source_bytes().to_vec();
    source.drain(range);
    source
}

pub(crate) fn append_points(file: &OrgFile, main: &[u8], points: &[ConflictPoint]) -> Vec<u8> {
    if points.is_empty() {
        return main.to_vec();
    }
    let newline = if file.source_bytes().windows(2).any(|v| v == b"\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut source = main.to_vec();
    source.extend_from_slice(
        format!("{newline}* {CONFLICT_CONTAINER_TITLE} :CONFLICT:{newline}").as_bytes(),
    );
    for point in points {
        source.extend_from_slice(point.source.as_bytes());
        if !point.source.ends_with('\n') {
            source.extend_from_slice(newline.as_bytes());
        }
    }
    source
}

pub(crate) fn discard(file: &mut OrgFile, id: &str) -> Result<(), CoreError> {
    let container = container(file).ok_or(CoreError::InvalidInput("文件没有冲突容器"))?;
    let children = container.headlines().collect::<Vec<_>>();
    let targets = children
        .iter()
        .filter(|headline| point_id(headline).as_deref() == Some(id))
        .collect::<Vec<_>>();
    if targets.len() != 1 {
        return Err(CoreError::InvalidInput("冲突点不存在或 ID 重复，请刷新"));
    }
    let range = if children.len() == 1 {
        block_range(file, &container)
    } else {
        usize::from(targets[0].start())..usize::from(targets[0].end())
    };
    file.source_bytes.drain(range);
    file.reparse()
}

impl OrgFile {
    /// 与文件对象一起取得的定位信息，不提供另一套差异展示接口。
    pub fn conflict_ids(&self) -> Vec<String> {
        container(self)
            .into_iter()
            .flat_map(|headline| headline.headlines())
            .filter_map(|headline| point_id(&headline))
            .collect()
    }
}

use super::{ConflictTarget, FileConflict, TaskConfilictAction, TaskConfilictSelection, TaskPath};
use orgize::{
    ast::{ExampleBlock, Keyword},
    rowan::ast::AstNode,
};

fn reason(point: &Headline) -> Option<String> {
    point
        .section()?
        .syntax()
        .descendants()
        .filter_map(Keyword::cast)
        .find(|k| k.key().eq_ignore_ascii_case("CONFLICT_REASON"))
        .map(|k| k.value().trim().into())
}
fn property(headline: &Headline, key: &str) -> Option<String> {
    headline
        .properties()?
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v.to_string())
}
fn candidate(file: &OrgFile, point: &Headline, reason: &str) -> Result<Vec<u8>, CoreError> {
    if matches!(reason, "structure" | "reorder") {
        let block = point
            .section()
            .and_then(|s| s.syntax().descendants().find_map(ExampleBlock::cast))
            .ok_or(CoreError::InvalidInput("完整文件候选缺失"))?;
        // 同步生成器只对以 *、#+、逗号开头的行增加一个逗号。
        let raw = block.raw();
        let lines = raw.split_inclusive('\n').collect::<Vec<_>>();
        let content = lines
            .get(1..lines.len().saturating_sub(1))
            .ok_or(CoreError::InvalidInput("完整文件候选不完整"))?
            .iter()
            .map(|line| {
                line.strip_prefix(',')
                    .filter(|s| s.starts_with('*') || s.starts_with("#+") || s.starts_with(','))
                    .unwrap_or(line)
            })
            .collect::<String>();
        let parsed = OrgFile::with_todo_defaults(
            file.repo_id.clone(),
            file.path.clone(),
            content.into_bytes(),
            file.todo_defaults.clone(),
        )?;
        conflict_material_valid(&parsed)?;
        Ok(main_source(&parsed))
    } else {
        let children = point.headlines().collect::<Vec<_>>();
        if children.len() != 1 {
            return Err(CoreError::InvalidInput("冲突候选必须有且只有一个根节点"));
        }
        Ok(children[0].raw().into_bytes())
    }
}
fn conflict_material_valid(file: &OrgFile) -> Result<(), CoreError> {
    points(file)?;
    Ok(())
}
fn target_for(file: &OrgFile, point: &Headline, why: &str) -> Option<ConflictTarget> {
    if matches!(
        why,
        "create" | "missing-parent" | "modify-missing" | "structure" | "reorder"
    ) {
        return None;
    }
    let child = point.headlines().next()?;
    let nodes = file
        .path_headlines()
        .into_iter()
        .filter(|(_, h)| !OrgFile::is_conflict_headline(h))
        .collect::<Vec<_>>();
    let id = property(&child, "ID")?;
    let matches = nodes
        .into_iter()
        .filter(|(_, h)| property(h, "ID").as_ref() == Some(&id))
        .collect::<Vec<_>>();
    // 缺少稳定 ID 时无法从包装还原原父级，必须由用户明确选择目标。
    if matches.len() == 1 {
        Some(ConflictTarget::Existing(matches[0].0.clone()))
    } else {
        None
    }
}
impl OrgFile {
    pub fn conflicts(&self) -> Result<Vec<FileConflict>, CoreError> {
        let Some(root) = container(self) else {
            if self.has_conflict() {
                return Err(CoreError::InvalidInput("冲突容器格式不完整"));
            }
            return Ok(Vec::new());
        };
        points(self)?;
        if usize::from(root.end()) != self.source_bytes().len() {
            return Err(CoreError::InvalidInput("冲突容器必须位于文件末尾"));
        }
        root.headlines()
            .map(|point| {
                let why = reason(&point).ok_or(CoreError::InvalidInput("冲突点缺少原因"))?;
                let suggested_target = target_for(self, &point, &why);
                let mut available_actions = vec![TaskConfilictAction::Discard];
                if matches!(
                    why.as_str(),
                    "modify"
                        | "create"
                        | "delete"
                        | "modify-missing"
                        | "missing-parent"
                        | "reorder"
                        | "structure"
                ) && candidate(self, &point, &why).is_ok()
                {
                    available_actions.push(TaskConfilictAction::UseLocal);
                }
                Ok(FileConflict {
                    id: point_id(&point).unwrap(),
                    title: point.title_raw().trim_end().into(),
                    reason: why,
                    source_range: super::conflict_preview::source_range(
                        self,
                        usize::from(point.start()),
                        usize::from(point.end()),
                    ),
                    requires_target: suggested_target.is_none(),
                    suggested_target,
                    available_actions,
                })
            })
            .collect()
    }
}
pub(super) fn select(
    file: &mut OrgFile,
    selection: &TaskConfilictSelection,
) -> Result<Option<TaskPath>, CoreError> {
    let descriptions = file.conflicts()?;
    let description = descriptions
        .iter()
        .find(|p| p.id == selection.id)
        .ok_or(CoreError::InvalidInput("冲突点不存在"))?;
    if selection.action == TaskConfilictAction::Discard {
        if selection.target.is_some() {
            return Err(CoreError::InvalidInput("保留当前不能附带目标"));
        }
        discard(file, &selection.id)?;
        return Ok(None);
    }
    if !description
        .available_actions
        .contains(&TaskConfilictAction::UseLocal)
    {
        return Err(CoreError::InvalidInput("候选材料不完整，无法采用本地"));
    }
    let target = selection
        .target
        .clone()
        .or_else(|| description.suggested_target.clone())
        .ok_or(super::conflict_preview::error(
            "conflictTargetRequired",
            "请选择明确的处理目标",
        ))?;
    let point = container(file)
        .unwrap()
        .headlines()
        .find(|h| point_id(h).as_deref() == Some(&selection.id))
        .unwrap();
    let content = candidate(file, &point, &description.reason)?;
    let original = file.clone();
    // 全部验证成功后才发布副本；其他点的包装与分隔符逐字节保留。
    let mut next = file.clone();
    let block = container(&next).unwrap();
    let block = block_range(&next, &block);
    let material = next.source_bytes()[block.clone()].to_vec();
    next.source_bytes.truncate(block.start);
    next.reparse()?;
    let path = match target {
        ConflictTarget::Existing(path) => {
            if !matches!(description.reason.as_str(), "modify" | "delete") {
                return Err(super::conflict_preview::error(
                    "invalidConflictTarget",
                    "此冲突需要选择插入位置",
                ));
            }
            let node = super::task_operation_executor::locate(&next, &path)?;
            let start = usize::from(node.start());
            let end = usize::from(node.end());
            let content = if description.reason == "delete" {
                Vec::new()
            } else {
                crate::merge::at_level(&next, std::str::from_utf8(&content).unwrap(), node.level())?
                    .into_bytes()
            };
            next.source_bytes.splice(start..end, content);
            next.reparse()?;
            if description.reason == "delete" {
                None
            } else {
                Some(super::task_operation_executor::path_at(&next, start)?)
            }
        }
        ConflictTarget::Insert(position) => {
            if !matches!(
                description.reason.as_str(),
                "create" | "modify-missing" | "missing-parent"
            ) {
                return Err(super::conflict_preview::error(
                    "invalidConflictTarget",
                    "此冲突需要选择替换或删除目标",
                ));
            }
            let (offset, level) = super::task_operation_executor::position(&next, &position)?;
            let mut content =
                crate::merge::at_level(&next, std::str::from_utf8(&content).unwrap(), level)?
                    .into_bytes();
            let start = if offset > 0 && next.source_bytes()[offset - 1] != b'\n' {
                let newline = if original.source_bytes().windows(2).any(|v| v == b"\r\n") {
                    b"\r\n".as_slice()
                } else {
                    b"\n".as_slice()
                };
                content.splice(0..0, newline.iter().copied());
                offset + newline.len()
            } else {
                offset
            };
            next.source_bytes.splice(offset..offset, content);
            next.reparse()?;
            Some(super::task_operation_executor::path_at(&next, start)?)
        }
        ConflictTarget::ReplaceMain => {
            if !matches!(description.reason.as_str(), "reorder" | "structure") {
                return Err(super::conflict_preview::error(
                    "invalidConflictTarget",
                    "只有完整文件候选才能替换主树",
                ));
            }
            next.source_bytes = content;
            next.reparse()?;
            Some(next.full_path())
        }
    };
    // 候选不得把 CONFLICT 标签带入主树，或产生重复 Org ID。
    if next.has_conflict() {
        return Err(CoreError::InvalidInput("候选包含冲突区，不能直接作为主树"));
    }
    let mut ids = std::collections::BTreeSet::new();
    for (_, node) in next.path_headlines() {
        if let Some(id) = property(&node, "ID") {
            if !ids.insert(id) {
                return Err(CoreError::InvalidInput(
                    "采用候选会产生重复 Org ID，请调整目标",
                ));
            }
        }
    }
    next.source_bytes.extend(material);
    next.reparse()?;
    discard(&mut next, &selection.id)?;
    *file = next;
    Ok(path)
}
