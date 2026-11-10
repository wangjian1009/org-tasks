//! 将选择记录转换为列表，规划普通 Deletion 与 Modification，不新增写入操作种类。
use super::{
    LocalFileVersion, OrgFile, TaskDeletion, TaskFileVersion, TaskMergePlan, TaskMergeRequest,
    TaskModification, TaskModificationOperation, TaskOperation, TaskOperationGroup,
    task_operation_executor::{edit_preview, locate, path_at},
};
use crate::CoreError;
use orgize::{
    SyntaxKind,
    ast::{CommentBlock, Headline, Link},
    rowan::ast::AstNode,
};

fn start(node: &Headline) -> usize {
    u32::from(node.start()) as usize
}
fn end(node: &Headline) -> usize {
    u32::from(node.end()) as usize
}

pub(super) fn is_archive(raw: &str) -> bool {
    raw.lines().next().is_some_and(|line| {
        line.trim()
            .eq_ignore_ascii_case("#+begin_comment org_tasks_merge_original")
    })
}

fn list(node: &Headline, depth: usize, output: &mut String, nl: &str) {
    let indent = "  ".repeat(depth);
    output.push_str(&format!("{indent}- {}{nl}", node.title_raw().trim_end()));
    if let Some(section) = node.section() {
        for element in section.syntax().children_with_tokens() {
            if matches!(
                element.kind(),
                SyntaxKind::DRAWER | SyntaxKind::PROPERTY_DRAWER | SyntaxKind::PLANNING
            ) || (element.kind() == SyntaxKind::COMMENT_BLOCK
                && is_archive(&element.to_string()))
            {
                continue;
            }
            for line in element.to_string().split_inclusive('\n') {
                output.push_str(&format!("{indent}  {line}"));
                if !line.ends_with('\n') {
                    output.push_str(nl);
                }
            }
        }
    }
    for child in node.headlines() {
        list(&child, depth + 1, output, nl);
    }
}

// 元数据放入标准 comment 块；已有归档平铺保留，避免重复合并时嵌套复制全部历史。
fn archive(node: &Headline, output: &mut String, nl: &str) {
    output.push_str(&format!(
        "#+begin_comment org_tasks_merge_original{nl}合并前元数据：{nl}"
    ));
    let mut metadata = String::new();
    for headline in node.syntax().descendants().filter_map(Headline::cast) {
        metadata.push_str(headline.raw().split_inclusive('\n').next().unwrap_or(""));
        if !metadata.ends_with('\n') {
            metadata.push_str(nl);
        }
        for element in headline
            .syntax()
            .children()
            .filter(|n| matches!(n.kind(), SyntaxKind::PLANNING | SyntaxKind::PROPERTY_DRAWER))
        {
            metadata.push_str(&element.to_string());
        }
        if let Some(section) = headline.section() {
            for element in section
                .syntax()
                .children()
                .filter(|n| n.kind() == SyntaxKind::DRAWER)
            {
                metadata.push_str(&element.to_string());
            }
        }
    }
    for line in metadata.split_inclusive('\n') {
        let text = line.trim_start_matches([' ', '\t']);
        let offset = line.len() - text.len();
        output.push_str(&line[..offset]);
        if text.starts_with('*')
            || text.starts_with("#+")
            || text.starts_with(",*")
            || text.starts_with(",#+")
        {
            output.push(',');
        }
        output.push_str(text);
        if !line.ends_with('\n') {
            output.push_str(nl);
        }
    }
    output.push_str(&format!("#+end_comment{nl}"));
    for previous in node
        .syntax()
        .descendants()
        .filter_map(CommentBlock::cast)
        .filter(|block| is_archive(&block.raw()))
    {
        output.push_str(&previous.raw());
        if !output.ends_with('\n') {
            output.push_str(nl);
        }
    }
}

pub(super) fn operations(
    file: &OrgFile,
    request: &TaskMergeRequest,
) -> Result<TaskMergePlan, CoreError> {
    if request.paths.len() < 2 {
        return Err(CoreError::InvalidInput("请至少选择两条记录"));
    }
    if request.file_version != LocalFileVersion::from_bytes(file.source_bytes()).content_hash {
        return Err(CoreError::InvalidState("任务文件版本已变化，请刷新后重试"));
    }
    let first = &request.paths[0];
    if request
        .paths
        .iter()
        .any(|path| path.repo_id != first.repo_id || path.file != first.file)
    {
        return Err(CoreError::InvalidInput("只能合并同一文件内的记录"));
    }
    let selected = request
        .paths
        .iter()
        .map(|path| locate(file, path))
        .collect::<Result<Vec<_>, _>>()?;
    let main = &selected[0];
    let mut ordered = selected.clone();
    ordered.sort_by_key(start);
    if ordered
        .windows(2)
        .any(|pair| start(&pair[1]) < end(&pair[0]))
    {
        return Err(CoreError::InvalidInput(
            "不能重复选择或同时合并祖先与子记录",
        ));
    }
    for node in &selected {
        super::editor::ensure_editable_range(file, start(node), end(node))?;
        for removed in node
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .filter(|h| start(h) != start(main))
        {
            if removed.properties().is_some_and(|p| {
                p.iter().any(|(key, _)| {
                    key.eq_ignore_ascii_case("ID") || key.eq_ignore_ascii_case("CUSTOM_ID")
                })
            }) {
                return Err(CoreError::InvalidInput(
                    "合并列表不能移除带 ID 或 CUSTOM_ID 的记录，请改用移动",
                ));
            }
            let title = removed.title_raw().trim_end().to_owned();
            if file
                .syntax()
                .document()
                .syntax()
                .descendants()
                .filter_map(Link::cast)
                .any(|link| {
                    let value = link.path().to_string();
                    value == title
                        || value == format!("*{title}")
                        || value.ends_with(&format!("::*{title}"))
                })
            {
                return Err(CoreError::InvalidInput(
                    "所选记录有标题链接引用，请先调整引用或改用移动",
                ));
            }
        }
    }
    let nl = if file.source_bytes().windows(2).any(|p| p == b"\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut body = String::new();
    for node in &selected {
        list(node, 0, &mut body, nl);
    }
    body.push_str(nl);
    for node in &selected {
        archive(node, &mut body, nl);
    }
    let mut deleted = selected[1..].to_vec();
    deleted.extend(main.headlines());
    deleted.sort_by_key(|node| std::cmp::Reverse(start(node)));
    let new_start = start(main)
        - deleted
            .iter()
            .filter(|node| start(node) < start(main))
            .map(|node| end(node) - start(node))
            .sum::<usize>();
    let mut group = TaskOperationGroup {
        operations: deleted
            .iter()
            .map(|node| {
                Ok(TaskOperation::Deletion(TaskDeletion {
                    path: path_at(file, start(node))?,
                }))
            })
            .collect::<Result<Vec<_>, CoreError>>()?,
        file_versions: vec![TaskFileVersion {
            repo_id: file.repo_id.clone(),
            file: file.path.clone(),
            version: request.file_version.clone(),
        }],
        ..Default::default()
    };
    // 删除按原文逆序，重复标题出现序号不会影响尚未执行的删除；修改使用删除后的路径。
    let after_deletions = edit_preview(file.clone(), &group)?;
    group
        .operations
        .push(TaskOperation::Modification(TaskModificationOperation {
            path: path_at(&after_deletions, new_start)?,
            modifications: vec![
                TaskModification::Body(Some(body)),
                TaskModification::Title(Some(format!("合并: {}", main.title_raw().trim_end()))),
            ],
        }));
    let result = edit_preview(file.clone(), &group)?;
    Ok(TaskMergePlan {
        main_path: path_at(&result, new_start)?,
        operation_group: group,
    })
}
