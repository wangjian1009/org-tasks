//! 文件尾部的冲突容器；查询与普通编辑仅依据自有／祖先 CONFLICT 标签划定边界。
use super::{CoreError, OrgFile};
use orgize::ast::Headline;
use std::ops::Range;

pub(crate) const CONFLICT_CONTAINER_TITLE: &str = "同步冲突";
pub(crate) const CONFLICT_POINT_ID: &str = "CONFILICT_ID";

#[derive(Clone, Debug)]
pub(crate) struct ConflictPoint {
    pub id: String,
    pub source: String,
}

pub(crate) fn point_id(headline: &Headline) -> Option<String> {
    super::properties::own(headline, CONFLICT_POINT_ID)
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
        format!("{newline}* {CONFLICT_CONTAINER_TITLE} :CONFLICT:ARCHIVE:{newline}").as_bytes(),
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
    keyword(point, "CONFLICT_REASON")
}
fn keyword(point: &Headline, key: &str) -> Option<String> {
    point
        .section()?
        .syntax()
        .descendants()
        .filter_map(Keyword::cast)
        .find(|k| k.key().eq_ignore_ascii_case(key))
        .map(|k| k.value().trim().into())
}
fn property(headline: &Headline, key: &str) -> Option<String> {
    super::properties::own(headline, key)
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
    if let Some(id) = property(&child, "ID").filter(|id| !id.trim().is_empty()) {
        let matches = nodes
            .iter()
            .filter(|(_, h)| property(h, "ID").as_ref() == Some(&id))
            .collect::<Vec<_>>();
        if matches.len() == 1 {
            return Some(ConflictTarget::Existing(matches[0].0.clone()));
        }
        // 显式身份失配或重复时不能退回同名任务，以免替换另一个节点。
        return None;
    }

    // 无 Org ID 的有效任务按规范化标题尝试唯一定位；普通笔记仍需明确选择。
    let is_task = child.todo_keyword().is_some_and(|state| {
        let state = state.to_string();
        file.todo
            .pending_keywords
            .iter()
            .any(|value| value == &state)
            || file.todo.done_keywords.iter().any(|value| value == &state)
    });
    if is_task {
        let title = crate::model::task_identity::path_title(&child);
        let title_matches = nodes
            .iter()
            .filter(|(_, headline)| {
                headline.todo_keyword().is_some_and(|state| {
                    let state = state.to_string();
                    file.todo
                        .pending_keywords
                        .iter()
                        .any(|value| value == &state)
                        || file.todo.done_keywords.iter().any(|value| value == &state)
                }) && crate::model::task_identity::path_title(headline) == title
            })
            .collect::<Vec<_>>();
        if title_matches.len() == 1 {
            return Some(ConflictTarget::Existing(title_matches[0].0.clone()));
        }
    }

    // 缺少稳定 ID 或唯一任务定位时必须由用户明确选择目标。
    None
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
            .map(|point| describe(self, &point, self))
            .collect()
    }
}

fn describe(
    main: &OrgFile,
    point: &Headline,
    material: &OrgFile,
) -> Result<FileConflict, CoreError> {
    let why = reason(point).ok_or(CoreError::InvalidInput("冲突点缺少原因"))?;
    let suggested_target = target_for(main, point, &why);
    let target_headline = match &suggested_target {
        Some(ConflictTarget::Existing(path)) => main
            .path_headlines()
            .into_iter()
            .find(|(candidate, _)| candidate == path)
            .map(|(_, headline)| headline),
        _ => None,
    };
    let ancestors = keyword(point, "CONFLICT_ANCESTORS")
        .and_then(|value| serde_json::from_str::<Vec<String>>(&value).ok())
        .unwrap_or_default();
    let anchor = target_headline
        .clone()
        .or_else(|| crate::merge::conflict_display_parent(main, &ancestors));
    let display_anchor = anchor.as_ref().map(|headline| {
        super::conflict_preview::source_range(
            main,
            usize::from(headline.start()),
            usize::from(headline.end()),
        )
    });
    let candidate_bytes = if why == "delete" {
        target_headline
            .as_ref()
            .map(|headline| headline.raw().into_bytes())
            .or_else(|| candidate(main, point, &why).ok())
    } else {
        candidate(main, point, &why).ok()
    };
    let candidate_content = candidate_bytes
        .map(|bytes| String::from_utf8(bytes).expect("UTF-8"))
        .unwrap_or_default();
    let candidate_html = OrgFile::with_todo_defaults_and_setup(
        main.repo_id.clone(),
        main.path.clone(),
        candidate_content.as_bytes().to_vec(),
        main.todo_defaults.clone(),
        main.todo_setup.clone(),
    )?
    .render_html();
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
    ) && candidate(main, point, &why).is_ok()
    {
        available_actions.push(TaskConfilictAction::UseLocal);
    }
    Ok(FileConflict {
        id: point_id(point).ok_or(CoreError::InvalidInput("冲突点缺少定位 ID"))?,
        title: point.title_raw().trim_end().into(),
        reason: why,
        source_range: super::conflict_preview::source_range(
            material,
            usize::from(point.start()),
            usize::from(point.end()),
        ),
        requires_target: suggested_target.is_none(),
        suggested_target,
        available_actions,
        display_anchor,
        display_at_target: target_headline.is_some(),
        candidate_content,
        candidate_html,
    })
}

fn parse_point(
    template: &OrgFile,
    point: &ConflictPoint,
) -> Result<(OrgFile, Headline), CoreError> {
    let mut material = template.clone();
    material.source_bytes = point.source.as_bytes().to_vec();
    material.reparse()?;
    let headline = material
        .syntax()
        .document()
        .first_headline()
        .ok_or(CoreError::InvalidInput("冲突材料缺少标题"))?;
    if point_id(&headline).as_deref() != Some(point.id.as_str()) {
        return Err(CoreError::InvalidInput("冲突材料的定位 ID 不一致"));
    }
    Ok((material, headline))
}

pub(super) fn describe_point(
    main: &OrgFile,
    point: &ConflictPoint,
) -> Result<FileConflict, CoreError> {
    let (material, headline) = parse_point(main, point)?;
    describe(main, &headline, &material)
}

pub(super) fn candidate_source(main: &OrgFile, point: &ConflictPoint) -> Result<String, CoreError> {
    let (_, headline) = parse_point(main, point)?;
    let why = reason(&headline).ok_or(CoreError::InvalidInput("冲突点缺少原因"))?;
    // 删除意图的候选保存的是待删节点，应用后的内容应为空。
    if why == "delete" {
        return Ok(String::new());
    }
    let bytes = candidate(main, &headline, &why)?;
    Ok(String::from_utf8(bytes).expect("UTF-8"))
}

pub(super) fn select(
    file: &mut OrgFile,
    selection: &TaskConfilictSelection,
) -> Result<Option<TaskPath>, CoreError> {
    file.conflicts()?;
    let point = points(file)?
        .into_iter()
        .find(|point| point.id == selection.id)
        .ok_or(CoreError::InvalidInput("冲突点不存在"))?;
    let root = container(file).ok_or(CoreError::InvalidInput("文件没有冲突容器"))?;
    let range = block_range(file, &root);
    let material = file.source_bytes()[range.clone()].to_vec();
    let mut main = file.clone();
    main.source_bytes.truncate(range.start);
    main.reparse()?;
    let path = select_point(&mut main, &point, selection)?;
    main.source_bytes.extend(material);
    main.reparse()?;
    discard(&mut main, &selection.id)?;
    *file = main;
    Ok(path)
}

/// 材料单独解析，整个选择过程的可编辑文件始终只有主树。
pub(super) fn select_point(
    file: &mut OrgFile,
    point: &ConflictPoint,
    selection: &TaskConfilictSelection,
) -> Result<Option<TaskPath>, CoreError> {
    if file.has_conflict() {
        return Err(CoreError::InvalidInput("预览主树不能包含冲突节点"));
    }
    let description = describe_point(file, point)?;
    if selection.id != point.id {
        return Err(CoreError::InvalidInput("冲突点不存在"));
    }
    if selection.action == TaskConfilictAction::Discard {
        if selection.target.is_some() {
            return Err(CoreError::InvalidInput("保留当前不能附带目标"));
        }
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
    let (_material, headline) = parse_point(file, point)?;
    let content = candidate(file, &headline, &description.reason)?;
    let original = file.clone();
    let mut next = file.clone();
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
            let content = if description.reason == "delete" {
                Vec::new()
            } else {
                let adjusted = crate::merge::at_level(
                    &next,
                    std::str::from_utf8(&content).unwrap(),
                    node.level(),
                )?;
                let candidate = OrgFile::with_todo_defaults_and_setup(
                    next.repo_id.clone(),
                    next.path.clone(),
                    adjusted.into_bytes(),
                    next.todo_defaults.clone(),
                    next.todo_setup.clone(),
                )?;
                let candidate_root = candidate
                    .syntax()
                    .document()
                    .headlines()
                    .next()
                    .ok_or(CoreError::InvalidState("冲突候选缺少根标题"))?;
                let candidate_end = candidate_root
                    .headlines()
                    .next()
                    .map_or(usize::from(candidate_root.end()), |child| {
                        usize::from(child.start())
                    });
                candidate.source_bytes()[usize::from(candidate_root.start())..candidate_end]
                    .to_vec()
            };
            let target_end = node
                .headlines()
                .next()
                .map_or(usize::from(node.end()), |child| usize::from(child.start()));
            next.source_bytes.splice(start..target_end, content);
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
    *file = next;
    Ok(path)
}
