//! 文件头投影与局部值修改；所有定位均来自同一版本的 orgize 语法树。
use super::*;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Range,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileHeaderValueKind {
    Text,
    Category,
    FileTags,
    TagConfig,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileHeaderEditSpec {
    pub kind: FileHeaderValueKind,
    pub protected_tags: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileHeaderEntry {
    pub id: String,
    pub name: String,
    pub value: String,
    pub keyword: bool,
    pub tags: Vec<String>,
    pub edit: Option<FileHeaderEditSpec>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
struct HeaderKey {
    source: String,
    name: String,
}

#[derive(Clone)]
struct LocatedEntry {
    entry: FileHeaderEntry,
    key: HeaderKey,
    range: Range<usize>,
    start: usize,
}

fn trimmed_range(source: &[u8], range: Range<usize>) -> Range<usize> {
    let value = std::str::from_utf8(&source[range.clone()]).expect("UTF-8");
    let start = range.start + value.len() - value.trim_start().len();
    let end = range.end - (value.len() - value.trim_end().len());
    start..end.max(start)
}

fn edit_spec(name: &str, keyword: bool, tags: &[String]) -> Option<FileHeaderEditSpec> {
    let base_name = if keyword {
        name
    } else {
        name.strip_suffix('+').unwrap_or(name)
    };
    let kind = match base_name.to_ascii_uppercase().as_str() {
        "PROJECT_NAME" => FileHeaderValueKind::Text,
        "TITLE" if keyword => FileHeaderValueKind::Text,
        "CATEGORY" if keyword => FileHeaderValueKind::Category,
        "FILETAGS" if keyword => FileHeaderValueKind::FileTags,
        "TAGS" if keyword => FileHeaderValueKind::TagConfig,
        _ => return None,
    };
    Some(FileHeaderEditSpec {
        kind,
        protected_tags: if kind == FileHeaderValueKind::FileTags {
            tags.iter()
                .filter(|tag| matches!(tag.as_str(), "project" | "todo"))
                .cloned()
                .collect()
        } else {
            Vec::new()
        },
    })
}

fn entries(file: &OrgFile) -> Vec<LocatedEntry> {
    let version = LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
    let mut result = Vec::new();
    let mut push =
        |name: String, keyword: bool, source: &str, range: Range<usize>, start: usize| {
            let range = trimmed_range(file.source_bytes(), range);
            let value = std::str::from_utf8(&file.source_bytes()[range.clone()])
                .expect("UTF-8")
                .to_owned();
            let tags = if keyword && name.eq_ignore_ascii_case("TAGS") {
                tags::header_tag_names(&value)
            } else if keyword && name.eq_ignore_ascii_case("FILETAGS") {
                tags::header_file_tag_names(&value)
            } else {
                Vec::new()
            };
            let identity =
                serde_json::to_vec(&(&file.repo_id, &file.path, &version, source, start))
                    .expect("身份可序列化");
            let id = format!(
                "header-{}",
                LocalFileVersion::from_bytes(&identity).content_hash
            );
            let edit = edit_spec(&name, keyword, &tags);
            result.push(LocatedEntry {
                key: HeaderKey {
                    source: source.into(),
                    name: name.to_ascii_uppercase(),
                },
                entry: FileHeaderEntry {
                    id,
                    name,
                    value,
                    keyword,
                    tags,
                    edit,
                },
                range,
                start,
            });
        };
    for keyword in file.syntax().document().keywords() {
        let key = keyword.key();
        let token = keyword.value();
        let range = token.text_range();
        let mut value_range = usize::from(range.start())..usize::from(range.end());
        if key.eq_ignore_ascii_case("PROPERTY") {
            let text = token.trim_start();
            let (name, _) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
            if name.is_empty() {
                continue;
            }
            value_range.start += token.len() - text.len() + name.len();
            push(
                name.into(),
                false,
                "property",
                value_range,
                usize::from(keyword.start()),
            );
        } else {
            push(
                key.to_string(),
                true,
                "keyword",
                value_range,
                usize::from(keyword.start()),
            );
        }
    }
    if let Some(drawer) = file.syntax().document().properties() {
        for property in properties::entries(&drawer) {
            let name = if property.append {
                format!("{}+", property.name)
            } else {
                property.name
            };
            push(
                name,
                false,
                "drawer",
                usize::from(property.value_range.start())..usize::from(property.value_range.end()),
                usize::from(property.value_range.start()),
            );
        }
    }
    result.sort_by_key(|item| item.start);
    result
}

impl OrgFile {
    pub fn header_entries(&self) -> Vec<FileHeaderEntry> {
        entries(self).into_iter().map(|item| item.entry).collect()
    }
}

fn checked_value(item: &LocatedEntry, value: &FileHeaderValue) -> Result<String, CoreError> {
    let spec = item
        .entry
        .edit
        .as_ref()
        .ok_or(CoreError::InvalidInput("该文件属性暂不支持编辑"))?;
    let value = match (spec.kind, value) {
        (FileHeaderValueKind::FileTags, FileHeaderValue::Tags(values)) => {
            if values
                .iter()
                .any(|value| tags::header_file_tag_names(value) != [value.clone()])
            {
                return Err(CoreError::InvalidInput("文件标签包含无效字符"));
            }
            if spec.protected_tags.iter().any(|tag| !values.contains(tag)) {
                return Err(CoreError::InvalidInput(
                    "不能删除文件原有的 project 或 todo 标签",
                ));
            }
            let mut next = item
                .entry
                .tags
                .iter()
                .filter(|tag| values.contains(tag))
                .cloned()
                .collect::<Vec<_>>();
            for tag in values {
                if !next.contains(tag) {
                    next.push(tag.clone());
                }
            }
            if next == item.entry.tags {
                return Ok(item.entry.value.clone());
            }
            if next.is_empty() {
                String::new()
            } else {
                let mut parts = item
                    .entry
                    .value
                    .split(':')
                    .filter(|part| next.iter().any(|tag| tag == part.trim()))
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                for tag in &next {
                    if !item.entry.tags.contains(tag) {
                        parts.push(tag.clone());
                    }
                }
                format!(":{}:", parts.join(":"))
            }
        }
        (FileHeaderValueKind::TagConfig, FileHeaderValue::Tags(values)) => {
            if values
                .iter()
                .any(|name| tags::header_file_tag_names(name) != [name.clone()])
            {
                return Err(CoreError::InvalidInput("候选标签包含无效字符"));
            }
            let desired = values.iter().collect::<BTreeSet<_>>();
            if desired == item.entry.tags.iter().collect::<BTreeSet<_>>() {
                return Ok(item.entry.value.clone());
            }
            let original = &item.entry.value;
            let mut removals = Vec::new();
            for token in original.split_whitespace() {
                if let Some(name) = tags::configured_tag(token) {
                    if !values.iter().any(|value| value == name) {
                        let offset = token.as_ptr() as usize - original.as_ptr() as usize;
                        removals.push(offset..offset + token.len());
                    }
                }
            }
            let mut next = original.clone();
            for range in removals.into_iter().rev() {
                next.replace_range(range, "");
            }
            for name in values {
                if !item.entry.tags.contains(name) && !tags::header_tag_names(&next).contains(name)
                {
                    if !next.is_empty() && !next.ends_with(char::is_whitespace) {
                        next.push(' ');
                    }
                    next.push_str(name);
                }
            }
            next.trim().to_owned()
        }
        (FileHeaderValueKind::FileTags, _) | (_, FileHeaderValue::Tags(_)) => {
            return Err(CoreError::InvalidInput("文件属性值类型不匹配"));
        }
        (_, FileHeaderValue::Text(value)) => value.clone(),
    };
    let preserve_tabs = spec.kind == FileHeaderValueKind::TagConfig;
    if value
        .chars()
        .any(|c| c.is_control() && !(preserve_tabs && c == '\t'))
    {
        return Err(CoreError::InvalidInput("文件属性值不能包含换行或控制字符"));
    }
    if value.trim() != value {
        return Err(CoreError::InvalidInput("文件属性值不能包含首尾空白"));
    }
    if spec.kind == FileHeaderValueKind::Category && value.eq_ignore_ascii_case("ARCHIVE") {
        return Err(CoreError::InvalidInput(
            "ARCHIVE 是保留分类，不能在分类编辑中设置",
        ));
    }
    if spec.kind == FileHeaderValueKind::TagConfig {
        validate_tag_config(&value, false)?;
    }
    Ok(value)
}

fn validate_tag_config(value: &str, balance: bool) -> Result<(), CoreError> {
    let mut group = false;
    for token in value.split_whitespace() {
        match token {
            "{" | "}" if !balance => {}
            "{" if !group => group = true,
            "}" if group => group = false,
            "\\n" => {}
            "{" | "}" => return Err(CoreError::InvalidInput("TAGS 分组花括号不匹配")),
            _ if tags::header_tag_names(token).is_empty() => {
                return Err(CoreError::InvalidInput("TAGS 候选或快捷键无效"));
            }
            _ => {}
        }
    }
    if balance && group {
        return Err(CoreError::InvalidInput("TAGS 分组花括号不匹配"));
    }
    Ok(())
}

fn replace_value(file: &mut OrgFile, range: Range<usize>, value: &str) -> Result<(), CoreError> {
    let prefix = if range.is_empty()
        && !value.is_empty()
        && range.start > 0
        && !file.source_bytes()[range.start - 1].is_ascii_whitespace()
    {
        " "
    } else {
        ""
    };
    task_operation_executor::replace(file, range, format!("{prefix}{value}").as_bytes())
}

pub(super) fn apply(
    file: &mut OrgFile,
    changes: &[FileHeaderValueChange],
) -> Result<(), CoreError> {
    if changes.is_empty() {
        return Err(CoreError::InvalidInput("文件属性修改不能为空"));
    }
    let located = entries(file);
    let mut seen = BTreeSet::new();
    let mut patches = Vec::new();
    let mut tags_changed = false;
    for change in changes {
        if !seen.insert(&change.entry_id) {
            return Err(CoreError::InvalidInput("同一文件属性不能重复修改"));
        }
        let item = located
            .iter()
            .find(|item| item.entry.id == change.entry_id)
            .ok_or(CoreError::InvalidState("文件属性条目已失效，请重新载入"))?;
        let value = checked_value(item, &change.value)?;
        if value == item.entry.value {
            continue;
        }
        tags_changed |= item
            .entry
            .edit
            .as_ref()
            .is_some_and(|spec| spec.kind == FileHeaderValueKind::TagConfig);
        patches.push((item.range.clone(), value));
    }
    patches.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    for (range, value) in patches {
        replace_value(file, range, &value)?;
    }
    if tags_changed {
        let all = file
            .file_keywords
            .values("TAGS")
            .collect::<Vec<_>>()
            .join(" ");
        validate_tag_config(&all, true)?;
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HeaderConflictChange {
    key: HeaderKey,
    value: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HeaderConflict {
    source: String,
    changes: Vec<HeaderConflictChange>,
    ambiguous: bool,
}

fn grouped(file: &OrgFile) -> BTreeMap<HeaderKey, Vec<LocatedEntry>> {
    let mut result = BTreeMap::<HeaderKey, Vec<LocatedEntry>>::new();
    for item in entries(file) {
        result.entry(item.key.clone()).or_default().push(item);
    }
    result
}
fn values(items: Option<&Vec<LocatedEntry>>) -> Vec<&str> {
    items
        .into_iter()
        .flatten()
        .map(|item| item.entry.value.as_str())
        .collect()
}

// 普通前言继续采用远端；仅把可唯一定位的本地配置值回放到已合并的远端主树。
pub(crate) fn merge_headers(
    base: &OrgFile,
    local: &OrgFile,
    remote: &OrgFile,
    merged: &mut OrgFile,
    prefer_remote_file_id: bool,
) -> Result<Option<String>, CoreError> {
    let b = grouped(base);
    let l = grouped(local);
    let r = grouped(remote);
    let current = grouped(merged);
    let keys = b.keys().chain(l.keys()).cloned().collect::<BTreeSet<_>>();
    let mut patches = Vec::new();
    let mut conflicts = Vec::new();
    let mut ambiguous = false;
    for key in keys {
        let bv = values(b.get(&key));
        let lv = values(l.get(&key));
        let rv = values(r.get(&key));
        if prefer_remote_file_id
            && key.source == "drawer"
            && key.name == "ID"
            && matches!(lv.as_slice(), [id] if !id.is_empty())
            && matches!(rv.as_slice(), [id] if !id.is_empty())
        {
            continue;
        }
        if lv == bv || lv == rv {
            continue;
        }
        let structure = bv.len() != lv.len() || bv.len() != rv.len();
        if structure || lv.len() != 1 {
            // 重复声明只在远端保持基线顺序和值时按对应行回放，否则保留完整本地候选。
            if !structure && bv == rv {
                if let Some(items) = current.get(&key) {
                    for (index, item) in items.iter().enumerate() {
                        if lv[index] != bv[index] {
                            patches.push((item.range.clone(), lv[index].to_owned()));
                        }
                    }
                }
            } else {
                ambiguous = true;
            }
            continue;
        }
        if bv == rv {
            if let Some(item) = current.get(&key).and_then(|items| items.first()) {
                patches.push((item.range.clone(), lv[0].to_owned()));
            }
        } else {
            conflicts.push(HeaderConflictChange {
                key,
                value: lv[0].to_owned(),
            });
        }
    }
    patches.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    for (range, value) in patches {
        replace_value(merged, range, &value)?;
    }
    if conflicts.is_empty() && !ambiguous {
        return Ok(None);
    }
    let mut source_entries = local
        .syntax()
        .document()
        .keywords()
        .map(|keyword| (usize::from(keyword.start()), keyword.raw()))
        .collect::<Vec<_>>();
    if let Some(drawer) = local.syntax().document().properties() {
        source_entries.push((usize::from(drawer.start()), drawer.raw()));
    }
    source_entries.sort_by_key(|(offset, _)| *offset);
    let source = source_entries
        .into_iter()
        .map(|(_, raw)| raw)
        .collect::<String>();
    serde_json::to_string_pretty(&HeaderConflict {
        source,
        changes: conflicts,
        ambiguous,
    })
    .map(Some)
    .map_err(|_| CoreError::InvalidState("文件头冲突编码失败"))
}

fn header_conflict(point: &orgize::ast::Headline) -> Result<HeaderConflict, CoreError> {
    use orgize::{ast::ExampleBlock, rowan::ast::AstNode};
    let block = point
        .section()
        .and_then(|s| s.syntax().descendants().find_map(ExampleBlock::cast))
        .ok_or(CoreError::InvalidInput("文件属性候选缺失"))?;
    let raw = block.raw();
    let lines = raw.split_inclusive('\n').collect::<Vec<_>>();
    let content = lines
        .get(1..lines.len().saturating_sub(1))
        .ok_or(CoreError::InvalidInput("文件属性候选不完整"))?
        .concat();
    serde_json::from_str(&content).map_err(|_| CoreError::InvalidInput("文件属性候选无效"))
}

pub(super) fn candidate_source(point: &orgize::ast::Headline) -> Result<String, CoreError> {
    Ok(header_conflict(point)?.source)
}

pub(super) fn apply_candidate(
    file: &mut OrgFile,
    point: &orgize::ast::Headline,
) -> Result<(), CoreError> {
    let candidate = header_conflict(point)?;
    if candidate.ambiguous || candidate.changes.is_empty() {
        return Err(CoreError::InvalidState(
            "文件属性声明存在歧义，请逐项编辑后保留当前结果",
        ));
    }
    let targets = grouped(file);
    let mut patches = Vec::new();
    for change in candidate.changes {
        let items = targets
            .get(&change.key)
            .filter(|items| items.len() == 1)
            .ok_or(CoreError::InvalidState("文件属性目标已变化"))?;
        if change.value.chars().any(|c| c.is_control()) {
            return Err(CoreError::InvalidInput("文件属性候选包含非法换行"));
        }
        patches.push((items[0].range.clone(), change.value));
    }
    patches.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    for (range, value) in patches {
        replace_value(file, range, &value)?;
    }
    Ok(())
}
