//! 只在同一文件内把 B→L 的变化重放到 R；所有片段均取自 orgize 来源区间。
use crate::{CoreError, LocalFileVersion, OrgFile};
use orgize::{SyntaxKind, ast::Headline, rowan::ast::AstNode};
use std::collections::{BTreeMap, BTreeSet};

/// 合并同一 Org 文件的三份 UTF-8 原文；不访问文件系统、仓库或网络。
///
/// 空内容代表零字节 Org 文件，整文件是否存在由同步层判断。
/// 各份内容自行声明 TODO 配置；不读取 SETUPFILE 指向的外部文件。
/// 无法自动应用的修改保留为普通 CONFLICT 候选子树。
pub fn merge(
    base_data: &[u8],
    local_data: &[u8],
    remote_data: &[u8],
) -> Result<Vec<u8>, CoreError> {
    let parse = |data: &[u8]| OrgFile::new("merge".into(), "content.org".into(), data.to_vec());
    merge_files(
        &parse(base_data)?,
        &parse(local_data)?,
        &parse(remote_data)?,
    )
}

#[derive(Clone, Debug)]
struct Node {
    key: String,
    parent: Option<String>,
    level: usize,
    source: String,
}
struct Document {
    preamble: String,
    nodes: Vec<Node>,
}
fn hash(source: &[u8]) -> String {
    LocalFileVersion::from_bytes(source).content_hash
}
fn parse(file: &OrgFile) -> Document {
    let mut parents = Vec::<(usize, String)>::new();
    let mut occurrences = BTreeMap::<String, usize>::new();
    let headlines = file
        .syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    let prefix = headlines
        .first()
        .map_or(file.source_bytes().len(), |h| u32::from(h.start()) as usize);
    let mut nodes = Vec::new();
    for headline in headlines {
        while parents
            .last()
            .is_some_and(|(level, _)| *level >= headline.level())
        {
            parents.pop();
        }
        let explicit = headline
            .properties()
            .and_then(|p| {
                p.iter()
                    .find(|(key, _)| key.eq_ignore_ascii_case("ID"))
                    .map(|(_, value)| value.to_string())
            })
            .filter(|id| !id.trim().is_empty());
        // 同步的逻辑身份不包含仓库、文件、TODO 状态；无 ID 时保留文件内完整路径回退。
        let identity = explicit.map(|id| format!("id:{id}")).unwrap_or_else(|| {
            format!(
                "path:{}",
                serde_json::to_string(&(
                    parents.iter().map(|(_, key)| key).collect::<Vec<_>>(),
                    headline.title_raw().trim_end()
                ))
                .unwrap()
            )
        });
        let occurrence = occurrences.entry(identity.clone()).or_default();
        let key = format!("{identity}:{}", *occurrence);
        *occurrence += 1;
        let start = u32::from(headline.start()) as usize;
        let end = headline
            .headlines()
            .next()
            .map_or(u32::from(headline.end()) as usize, |h| {
                u32::from(h.start()) as usize
            });
        let parent = parents.last().map(|(_, key)| key.clone());
        nodes.push(Node {
            key: key.clone(),
            parent,
            level: headline.level(),
            source: String::from_utf8(file.source_bytes()[start..end].to_vec()).unwrap(),
        });
        parents.push((headline.level(), key));
    }
    Document {
        preamble: String::from_utf8(file.source_bytes()[..prefix].to_vec()).unwrap(),
        nodes,
    }
}
fn by_key(doc: &Document) -> BTreeMap<String, Node> {
    doc.nodes
        .iter()
        .cloned()
        .map(|n| (n.key.clone(), n))
        .collect()
}
fn same(a: &Node, b: &Node) -> bool {
    a.source == b.source && a.parent == b.parent && a.level == b.level
}
fn descendant(key: &str, parent: &str, nodes: &BTreeMap<String, Node>) -> bool {
    let mut seen = BTreeSet::new();
    let mut current = nodes.get(key).and_then(|n| n.parent.as_deref());
    while let Some(key) = current {
        if key == parent {
            return true;
        }
        if !seen.insert(key) {
            return false;
        }
        current = nodes.get(key).and_then(|n| n.parent.as_deref());
    }
    false
}
fn reparse(file: &OrgFile, bytes: Vec<u8>) -> Result<OrgFile, CoreError> {
    OrgFile::with_todo_defaults_and_setup(
        file.repo_id.clone(),
        file.path.clone(),
        bytes,
        file.todo_defaults.clone(),
        file.todo_setup.clone(),
    )
}

/// 包括任务及无状态 note，只识别本节点自有 CONFLICT 标签，不用继承标签或字符串搜索猜测。
pub(crate) fn conflict_ids(file: &OrgFile) -> BTreeSet<String> {
    file.syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .filter(|h| h.tags().any(|tag| tag == crate::model::CONFLICT_TAG))
        .filter_map(|h| {
            h.properties().and_then(|p| {
                p.iter()
                    .find(|(key, _)| key.eq_ignore_ascii_case("CONFLICT_ID"))
                    .map(|(_, v)| v.to_string())
            })
        })
        .collect()
}
pub(crate) fn has_conflicts(file: &OrgFile) -> bool {
    !conflict_ids(file).is_empty()
}

/// 文件头只保存当前状态；标记的增删不触碰其他关键字、正文或源码块。
pub(crate) fn with_conflict_header(file: &OrgFile) -> Result<Vec<u8>, CoreError> {
    let has = has_conflicts(file);
    let source = std::str::from_utf8(file.source_bytes())
        .map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8 编码"))?;
    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut edits = Vec::new();
    let mut found = false;
    for keyword in file
        .syntax()
        .document()
        .keywords()
        .filter(|k| k.key().eq_ignore_ascii_case("CONFLICT"))
    {
        let replacement = if has && !found {
            format!("#+CONFLICT: true{newline}")
        } else {
            String::new()
        };
        found = true;
        edits.push((
            usize::from(keyword.start())..usize::from(keyword.end()),
            replacement,
        ));
    }
    let mut result = source.to_string();
    for (range, replacement) in edits.into_iter().rev() {
        result.replace_range(range, &replacement);
    }
    if has && !found {
        let at = if result.starts_with('\u{feff}') { 3 } else { 0 };
        result.insert_str(at, &format!("#+CONFLICT: true{newline}"));
    }
    Ok(result.into_bytes())
}

#[derive(Clone, Debug)]
struct Edit {
    start: usize,
    end: usize,
    text: String,
}
fn edits(base: &[&str], target: &[&str]) -> Option<Vec<Edit>> {
    if base.len().saturating_mul(target.len()) > 2_000_000 {
        return None;
    }
    let width = target.len() + 1;
    let mut lcs = vec![0usize; (base.len() + 1) * width];
    for i in (0..base.len()).rev() {
        for j in (0..target.len()).rev() {
            lcs[i * width + j] = if base[i] == target[j] {
                lcs[(i + 1) * width + j + 1] + 1
            } else {
                lcs[(i + 1) * width + j].max(lcs[i * width + j + 1])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut result = Vec::new();
    let mut active: Option<Edit> = None;
    while i < base.len() || j < target.len() {
        if i < base.len() && j < target.len() && base[i] == target[j] {
            if let Some(edit) = active.take() {
                result.push(edit);
            }
            i += 1;
            j += 1;
        } else if j < target.len()
            && (i == base.len() || lcs[i * width + j + 1] >= lcs[(i + 1) * width + j])
        {
            active
                .get_or_insert(Edit {
                    start: i,
                    end: i,
                    text: String::new(),
                })
                .text
                .push_str(target[j]);
            j += 1;
        } else {
            let edit = active.get_or_insert(Edit {
                start: i,
                end: i,
                text: String::new(),
            });
            i += 1;
            edit.end = i;
        }
    }
    if let Some(edit) = active {
        result.push(edit);
    }
    Some(result)
}
fn overlap(a: &Edit, b: &Edit) -> bool {
    if a.start == a.end && b.start == b.end {
        return a.start == b.start;
    }
    if a.start == a.end {
        return b.start < a.start && a.start < b.end;
    }
    if b.start == b.end {
        return a.start < b.start && b.start < a.end;
    }
    a.start < b.end && b.start < a.end
}
fn text_merge(base: &str, local: &str, remote: &str) -> Option<String> {
    if local == base || local == remote {
        return Some(remote.into());
    }
    if remote == base {
        return Some(local.into());
    }
    let base_lines = base.split_inclusive('\n').collect::<Vec<_>>();
    let mut merged = edits(
        &base_lines,
        &remote.split_inclusive('\n').collect::<Vec<_>>(),
    )?;
    for edit in edits(
        &base_lines,
        &local.split_inclusive('\n').collect::<Vec<_>>(),
    )? {
        if merged
            .iter()
            .any(|r| r.start == edit.start && r.end == edit.end && r.text == edit.text)
        {
            continue;
        }
        if merged.iter().any(|r| overlap(r, &edit)) {
            return None;
        }
        merged.push(edit);
    }
    merged.sort_by_key(|e| (e.start, e.end));
    let mut output = String::new();
    let mut cursor = 0;
    for edit in merged {
        if edit.start < cursor {
            return None;
        }
        output.push_str(&base_lines[cursor..edit.start].concat());
        output.push_str(&edit.text);
        cursor = edit.end;
    }
    output.push_str(&base_lines[cursor..].concat());
    Some(output)
}
fn atom(base: &str, local: &str, remote: &str) -> Option<String> {
    if local == base {
        Some(remote.into())
    } else if remote == base || remote == local {
        Some(local.into())
    } else {
        None
    }
}

fn fragment(file: &OrgFile, source: &str) -> orgize::Org {
    orgize::ParseConfig {
        todo_keywords: (
            file.todo.pending_keywords.clone(),
            file.todo.done_keywords.clone(),
        ),
        ..Default::default()
    }
    .parse(source)
}
fn heading_parts(file: &OrgFile, source: &str) -> Result<Vec<String>, CoreError> {
    let parsed = fragment(file, source);
    let h = parsed
        .first_node::<Headline>()
        .ok_or(CoreError::InvalidState("任务来源缺少标题"))?;
    let title = h
        .syntax()
        .children()
        .find(|n| n.kind() == SyntaxKind::HEADLINE_TITLE);
    let priority = h
        .syntax()
        .children()
        .find(|n| n.kind() == SyntaxKind::HEADLINE_PRIORITY);
    let tags = h
        .syntax()
        .children()
        .find(|n| n.kind() == SyntaxKind::HEADLINE_TAGS);
    let line_end = source.find('\n').map_or(source.len(), |i| i + 1);
    let title_start = title.as_ref().map_or_else(
        || source[..line_end].trim_end_matches(['\r', '\n']).len(),
        |n| u32::from(n.text_range().start()) as usize,
    );
    let state_start = h
        .todo_keyword()
        .map(|n| u32::from(n.text_range().start()) as usize);
    let priority_start = priority
        .as_ref()
        .map(|n| u32::from(n.text_range().start()) as usize);
    let tags_start = tags
        .as_ref()
        .map(|n| u32::from(n.text_range().start()) as usize);
    let header_end = source[..line_end].trim_end_matches(['\r', '\n']).len();
    let prefix_end = state_start.or(priority_start).unwrap_or(title_start);
    let state_end = priority_start.unwrap_or(title_start);
    // 标签前的分隔空白属于标签片段，避免新增标签被误判成同时修改标题。
    let title_end = source[..tags_start.unwrap_or(header_end)]
        .trim_end_matches([' ', '\t'])
        .len()
        .max(title_start);
    let parts = vec![
        source[..prefix_end].into(),
        state_start.map_or(String::new(), |a| source[a..state_end].into()),
        priority_start.map_or(String::new(), |a| source[a..title_start].into()),
        source[title_start..title_end].into(),
        source[title_end..header_end].into(),
        source[header_end..line_end].into(),
        source[line_end..].into(),
    ];
    if parts.concat() != source {
        return Err(CoreError::InvalidState("标题来源区间不完整"));
    }
    Ok(parts)
}
fn node_merge(
    base_file: &OrgFile,
    local_file: &OrgFile,
    remote_file: &OrgFile,
    base: &Node,
    local: &Node,
    remote: &Node,
) -> Result<Option<Node>, CoreError> {
    let b = heading_parts(base_file, &base.source)?;
    let l = heading_parts(local_file, &local.source)?;
    let r = heading_parts(remote_file, &remote.source)?;
    let mut source = String::new();
    for index in 0..b.len() {
        let value = if index == 6 {
            text_merge(&b[index], &l[index], &r[index])
        } else {
            atom(&b[index], &l[index], &r[index])
        };
        let Some(value) = value else {
            return Ok(None);
        };
        source.push_str(&value);
    }
    let parent = if local.parent == base.parent {
        remote.parent.clone()
    } else if remote.parent == base.parent || remote.parent == local.parent {
        local.parent.clone()
    } else {
        return Ok(None);
    };
    let level = if local.level == base.level {
        remote.level
    } else if remote.level == base.level || remote.level == local.level {
        local.level
    } else {
        return Ok(None);
    };
    Ok(Some(Node {
        key: remote.key.clone(),
        parent,
        level,
        source,
    }))
}
fn set_property(file: &OrgFile, source: &str, key: &str, value: &str) -> Result<String, CoreError> {
    let parsed = fragment(file, source);
    let h = parsed
        .first_node::<Headline>()
        .ok_or(CoreError::InvalidState("冲突来源缺少标题"))?;
    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut output = source.to_string();
    if let Some(drawer) = h.properties() {
        let a = u32::from(drawer.start()) as usize;
        let b = u32::from(drawer.end()) as usize;
        let mut replacement = String::new();
        let mut found = false;
        for line in source[a..b].split_inclusive('\n') {
            let raw = line.trim_end_matches(['\r', '\n']);
            if raw.split_once(':').is_some_and(|(prefix, rest)| {
                prefix.is_empty()
                    && rest
                        .split_once(':')
                        .is_some_and(|(name, _)| name.eq_ignore_ascii_case(key))
            }) {
                replacement.push_str(&format!(":{key}: {value}{newline}"));
                found = true;
            } else {
                if raw.eq_ignore_ascii_case(":END:") && !found {
                    replacement.push_str(&format!(":{key}: {value}{newline}"));
                    found = true;
                }
                replacement.push_str(line);
            }
        }
        output.replace_range(a..b, &replacement);
    } else {
        let at = source.find('\n').map_or(source.len(), |i| i + 1);
        output.insert_str(
            at,
            &format!(
                "{}:PROPERTIES:{newline}:{key}: {value}{newline}:END:{newline}",
                if at > 0 && !source[..at].ends_with('\n') {
                    newline
                } else {
                    ""
                }
            ),
        );
    }
    Ok(output)
}
fn mark(
    file: &OrgFile,
    source: &str,
    id: &str,
    origin: &str,
    operation: &str,
) -> Result<String, CoreError> {
    let parsed = fragment(file, source);
    let h = parsed
        .first_node::<Headline>()
        .ok_or(CoreError::InvalidState("冲突来源缺少标题"))?;
    let mut output = source.to_string();
    let title = h
        .syntax()
        .children()
        .find(|n| n.kind() == SyntaxKind::HEADLINE_TITLE);
    let title_at = title
        .as_ref()
        .map_or(h.level() + 1, |n| u32::from(n.text_range().end()) as usize);
    let title_raw = title.as_ref().map_or(String::new(), |n| n.to_string());
    let at = title_at - (title_raw.len() - title_raw.trim_end_matches([' ', '\t']).len());
    // 标签先于标题插入，所有偏移均属于同一份未经修改的 AST。
    if !h.tags().any(|t| t == crate::model::CONFLICT_TAG) {
        if let Some(tags) = h
            .syntax()
            .children()
            .find(|n| n.kind() == SyntaxKind::HEADLINE_TAGS)
        {
            let at = u32::from(tags.text_range().end()) as usize;
            output.insert_str(at, &format!("{}:", crate::model::CONFLICT_TAG));
        } else {
            let end = source.find('\n').unwrap_or(source.len());
            let end = if source[..end].ends_with('\r') {
                end - 1
            } else {
                end
            };
            output.insert_str(end, &format!(" :{}:", crate::model::CONFLICT_TAG));
        }
    }
    if !title_raw.contains("(conflict)") {
        output.insert_str(at, " (conflict)");
    }
    output = set_property(file, &output, "ID", &format!("conflict-{id}"))?;
    output = set_property(file, &output, "CONFLICT_ID", id)?;
    output = set_property(
        file,
        &output,
        "CONFLICT_ORIGIN",
        &serde_json::to_string(origin).unwrap(),
    )?;
    set_property(file, &output, "CONFLICT_OPERATION", operation)
}
fn conflict_key(base: &OrgFile, local: &OrgFile, key: &str, operation: &str) -> String {
    hash(
        &serde_json::to_vec(&(
            hash(base.source_bytes()),
            hash(local.source_bytes()),
            key,
            operation,
        ))
        .unwrap(),
    )
}
fn clone_conflict(
    file: &OrgFile,
    local: &Document,
    key: &str,
    id: &str,
    operation: &str,
    output: &mut Vec<Node>,
) -> Result<(), CoreError> {
    let lookup = by_key(local);
    let Some(root) = lookup.get(key) else {
        return Ok(());
    };
    let nodes = local
        .nodes
        .iter()
        .filter(|n| n.key == key || descendant(&n.key, key, &lookup));
    for node in nodes {
        let copy_key = format!("copy:{id}:{}", node.key);
        let parent = if node.key == key {
            None
        } else {
            node.parent.as_ref().map(|p| format!("copy:{id}:{p}"))
        };
        let level = node.level - root.level + 1;
        let mut source = node.source.clone();
        source.replace_range(..node.level, &"*".repeat(level));
        if node.key == key {
            let original = local
                .nodes
                .iter()
                .filter(|n| n.key == key || descendant(&n.key, key, &lookup))
                .map(|n| n.source.as_str())
                .collect::<String>();
            source = mark(file, &source, id, &node.key, operation)?;
            source = set_property(
                file,
                &source,
                "CONFLICT_SOURCE",
                &serde_json::to_string(&original).unwrap(),
            )?;
            source = set_property(
                file,
                &source,
                "CONFLICT_PARENT",
                &serde_json::to_string(&node.parent).unwrap(),
            )?;
        } else {
            source = set_property(
                file,
                &source,
                "ID",
                &format!("conflict-{id}-{}", hash(node.key.as_bytes())),
            )?;
        }
        output.push(Node {
            key: copy_key,
            parent,
            level,
            source,
        });
    }
    Ok(())
}
fn append(output: &mut String, source: &str) {
    if !output.is_empty() && !output.ends_with('\n') && !source.is_empty() {
        output.push('\n');
    }
    output.push_str(source);
}
fn render(preamble: &str, nodes: &[Node]) -> Result<Vec<u8>, CoreError> {
    let map = nodes
        .iter()
        .map(|n| (n.key.as_str(), n))
        .collect::<BTreeMap<_, _>>();
    let mut seen = BTreeSet::new();
    fn visit<'a>(
        n: &'a Node,
        nodes: &'a [Node],
        map: &BTreeMap<&'a str, &'a Node>,
        seen: &mut BTreeSet<&'a str>,
        out: &mut String,
    ) -> Result<(), CoreError> {
        if !seen.insert(n.key.as_str()) {
            return Err(CoreError::InvalidState("操作重放产生循环层级"));
        }
        append(out, &n.source);
        for child in nodes
            .iter()
            .filter(|c| c.parent.as_deref() == Some(n.key.as_str()))
        {
            if child.level <= n.level {
                return Err(CoreError::InvalidState("操作重放产生无效父子层级"));
            }
            visit(child, nodes, map, seen, out)?;
        }
        Ok(())
    }
    let mut output = preamble.to_string();
    for n in nodes.iter().filter(|n| n.parent.is_none()) {
        visit(n, nodes, &map, &mut seen, &mut output)?;
    }
    if seen.len() != nodes.len() {
        return Err(CoreError::InvalidState("操作重放缺少父标题"));
    }
    Ok(output.into_bytes())
}
fn sequence(doc: &Document, parent: Option<&str>, keys: &BTreeSet<String>) -> Vec<String> {
    doc.nodes
        .iter()
        .filter(|n| n.parent.as_deref() == parent && keys.contains(&n.key))
        .map(|n| n.key.clone())
        .collect()
}
fn insert_local_node(nodes: &mut Vec<Node>, local: &Document, node: Node) {
    let index = local.nodes.iter().position(|n| n.key == node.key).unwrap();
    let before = local.nodes[..index]
        .iter()
        .rev()
        .find(|n| n.parent == node.parent && nodes.iter().any(|r| r.key == n.key));
    if let Some(before) = before {
        let lookup = nodes.iter().cloned().map(|n| (n.key.clone(), n)).collect();
        let mut at = nodes.iter().position(|n| n.key == before.key).unwrap() + 1;
        while at < nodes.len() && descendant(&nodes[at].key, &before.key, &lookup) {
            at += 1;
        }
        nodes.insert(at, node);
    } else {
        let at = nodes
            .iter()
            .position(|n| n.parent == node.parent)
            .unwrap_or(nodes.len());
        nodes.insert(at, node);
    }
}

fn outline_paths(file: &OrgFile, nodes: &[Node]) -> BTreeMap<String, Vec<String>> {
    let titles = nodes
        .iter()
        .map(|node| {
            let syntax = fragment(file, &node.source);
            let title = syntax
                .first_node::<Headline>()
                .map_or_else(String::new, |h| h.title_raw().trim_end().to_string());
            (node.key.clone(), title)
        })
        .collect::<BTreeMap<_, _>>();
    let lookup = nodes
        .iter()
        .map(|n| (n.key.as_str(), n))
        .collect::<BTreeMap<_, _>>();
    nodes
        .iter()
        .map(|node| {
            let mut path = vec![titles[&node.key].clone()];
            let mut parent = node.parent.as_deref();
            let mut seen = BTreeSet::new();
            while let Some(key) = parent {
                if !seen.insert(key) {
                    break;
                }
                let Some(node) = lookup.get(key) else {
                    break;
                };
                path.push(titles[&node.key].clone());
                parent = node.parent.as_deref();
            }
            path.reverse();
            (node.key.clone(), path)
        })
        .collect()
}
fn subtree_end(nodes: &[Node], key: &str) -> usize {
    let lookup = nodes.iter().cloned().map(|n| (n.key.clone(), n)).collect();
    let mut at = nodes
        .iter()
        .position(|n| n.key == key)
        .map_or(nodes.len(), |i| i + 1);
    while at < nodes.len() && descendant(&nodes[at].key, key, &lookup) {
        at += 1;
    }
    at
}
fn path_anchor(
    nodes: &[Node],
    paths: &BTreeMap<String, Vec<String>>,
    path: &[String],
    key: Option<&str>,
) -> Option<usize> {
    if let Some(key) = key {
        if let Some(index) = nodes
            .iter()
            .position(|n| n.key == key && paths.get(&n.key).is_some_and(|p| p == path))
        {
            return Some(index);
        }
    }
    nodes
        .iter()
        .position(|n| paths.get(&n.key).is_some_and(|p| p == path))
}
// 候选紧邻原 path 的子树；原节点消失时按原同级邻居、最近存活祖先逐级回退。
fn place_copies(
    base: &OrgFile,
    local: &OrgFile,
    remote: &OrgFile,
    b: &Document,
    l: &Document,
    r: &Document,
    output: &mut Vec<Node>,
    copies: Vec<Node>,
) -> Result<(), CoreError> {
    let bpaths = outline_paths(base, &b.nodes);
    let lpaths = outline_paths(local, &l.nodes);
    let rpaths = outline_paths(remote, &r.nodes);
    let copy_lookup = copies
        .iter()
        .cloned()
        .map(|n| (n.key.clone(), n))
        .collect::<BTreeMap<_, _>>();
    for root in copies.iter().filter(|n| n.parent.is_none()) {
        let syntax = fragment(local, &root.source);
        let headline = syntax
            .first_node::<Headline>()
            .ok_or(CoreError::InvalidState("冲突候选缺少根标题"))?;
        let origin = property(&headline, "CONFLICT_ORIGIN")
            .and_then(|value| serde_json::from_str::<String>(&value).ok());
        let desired = origin
            .as_ref()
            .and_then(|key| {
                bpaths
                    .get(key)
                    .or_else(|| lpaths.get(key))
                    .or_else(|| rpaths.get(key))
            })
            .cloned()
            .unwrap_or_default();
        let paths = outline_paths(remote, output);
        let exact = path_anchor(output, &paths, &desired, origin.as_deref());
        let logical = origin
            .as_ref()
            .and_then(|key| output.iter().position(|n| &n.key == key));
        let mut location = exact.or(logical).map(|index| {
            let anchor = &output[index];
            (
                subtree_end(output, &anchor.key),
                anchor.parent.clone(),
                anchor.level,
            )
        });
        let source = origin.as_ref().and_then(|key| {
            if bpaths.contains_key(key) {
                Some((b, &bpaths))
            } else if lpaths.contains_key(key) {
                Some((l, &lpaths))
            } else if rpaths.contains_key(key) {
                Some((r, &rpaths))
            } else {
                None
            }
        });
        if location.is_none() {
            if let (Some(key), Some((doc, source_paths))) = (origin.as_deref(), source) {
                if let Some(node) = doc.nodes.iter().find(|n| n.key == key) {
                    let siblings = doc
                        .nodes
                        .iter()
                        .filter(|n| n.parent == node.parent)
                        .collect::<Vec<_>>();
                    let original = siblings.iter().position(|n| n.key == key).unwrap();
                    for distance in 1..siblings.len() {
                        let neighbours = [
                            original.checked_sub(distance).map(|i| (i, true)),
                            original
                                .checked_add(distance)
                                .filter(|i| *i < siblings.len())
                                .map(|i| (i, false)),
                        ];
                        for neighbour in neighbours.into_iter().flatten() {
                            let (index, before) = neighbour;
                            let anchor = siblings[index];
                            if let Some(index) = path_anchor(
                                output,
                                &paths,
                                &source_paths[&anchor.key],
                                Some(&anchor.key),
                            ) {
                                let current = &output[index];
                                location = Some((
                                    if before {
                                        subtree_end(output, &current.key)
                                    } else {
                                        index
                                    },
                                    current.parent.clone(),
                                    current.level,
                                ));
                                break;
                            }
                        }
                        if location.is_some() {
                            break;
                        }
                    }
                }
            }
        }
        if location.is_none() && desired.len() > 1 {
            for length in (1..desired.len()).rev() {
                if let Some(index) = path_anchor(output, &paths, &desired[..length], None) {
                    let parent = &output[index];
                    location = Some((
                        subtree_end(output, &parent.key),
                        Some(parent.key.clone()),
                        parent.level + 1,
                    ));
                    break;
                }
            }
        }
        // 文件前言候选紧跟前言，其他完全无法定位的候选才放到文件末尾。
        let fallback = if property(&headline, "CONFLICT_OPERATION").as_deref() == Some("preamble") {
            0
        } else {
            output.len()
        };
        let (at, parent, level) = location.unwrap_or((fallback, None, 1));
        let mut tree = Vec::new();
        for candidate in copies
            .iter()
            .filter(|n| n.key == root.key || descendant(&n.key, &root.key, &copy_lookup))
        {
            let mut candidate = candidate.clone();
            let new_level = level + candidate.level - root.level;
            candidate
                .source
                .replace_range(..candidate.level, &"*".repeat(new_level));
            candidate.level = new_level;
            if candidate.key == root.key {
                candidate.parent = parent.clone();
                candidate.source = set_property(
                    local,
                    &candidate.source,
                    "CONFLICT_PATH",
                    &serde_json::to_string(&desired).unwrap(),
                )?;
            }
            tree.push(candidate);
        }
        output.splice(at..at, tree);
    }
    Ok(())
}

/// 字段级增删改在远端片段上执行；无法安全应用的本地版本成为普通 Org 冲突记录。
pub(crate) fn merge_files(
    base: &OrgFile,
    local: &OrgFile,
    remote: &OrgFile,
) -> Result<Vec<u8>, CoreError> {
    let bytes = merge_nodes(base, local, remote)?;
    with_conflict_header(&reparse(remote, bytes)?)
}

fn merge_nodes(base: &OrgFile, local: &OrgFile, remote: &OrgFile) -> Result<Vec<u8>, CoreError> {
    if local.source_bytes() == base.source_bytes() || local.source_bytes() == remote.source_bytes()
    {
        return Ok(remote.source_bytes().to_vec());
    }
    if remote.source_bytes() == base.source_bytes() {
        return Ok(local.source_bytes().to_vec());
    }
    let duplicate_ids = |file: &OrgFile| {
        let mut seen = BTreeSet::new();
        file.syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .filter_map(|h| property(&h, "ID"))
            .any(|id| !seen.insert(id))
    };
    if duplicate_ids(base) || duplicate_ids(local) || duplicate_ids(remote) {
        return structural_conflict(base, local, remote);
    }
    let b = parse(base);
    let l = parse(local);
    let r = parse(remote);
    let bm = by_key(&b);
    let lm = by_key(&l);
    let rm = by_key(&r);
    let existing = conflict_ids(remote);
    let mut copies = Vec::new();
    let mut output = r.nodes.clone();
    let mut suppressed = BTreeSet::<String>::new();
    let make_conflict =
        |key: &str, operation: &str, copies: &mut Vec<Node>| -> Result<(), CoreError> {
            let id = conflict_key(base, local, key, operation);
            if !existing.contains(&id) {
                clone_conflict(local, &l, key, &id, operation, copies)?;
            }
            Ok(())
        };
    for node in &b.nodes {
        if suppressed.iter().any(|key| {
            descendant(&node.key, key, &lm)
                || (!lm.contains_key(&node.key) && descendant(&node.key, key, &bm))
        }) {
            continue;
        }
        match (lm.get(&node.key), rm.get(&node.key)) {
            (None, None) => {}
            (None, Some(remote_node)) => {
                let subtree_unchanged = r
                    .nodes
                    .iter()
                    .filter(|n| n.key == node.key || descendant(&n.key, &node.key, &rm))
                    .all(|n| bm.get(&n.key).is_some_and(|base| same(base, n)))
                    && b.nodes
                        .iter()
                        .filter(|n| descendant(&n.key, &node.key, &bm))
                        .all(|n| rm.contains_key(&n.key));
                if subtree_unchanged {
                    output.retain(|n| n.key != node.key);
                } else {
                    let id = conflict_key(base, local, &node.key, "delete");
                    if !existing.contains(&id) {
                        // 原远端任务保持原样；删除意图也通过新增候选树表达，只标记候选树根。
                        clone_conflict(remote, &r, &remote_node.key, &id, "delete", &mut copies)?;
                    }
                    suppressed.insert(node.key.clone());
                }
            }
            (Some(local_node), None) => {
                if !same(node, local_node) {
                    make_conflict(&node.key, "modify-missing", &mut copies)?;
                    suppressed.insert(node.key.clone());
                }
            }
            (Some(local_node), Some(remote_node)) => {
                if same(node, local_node) {
                    continue;
                }
                if let Some(merged) =
                    node_merge(base, local, remote, node, local_node, remote_node)?
                {
                    if let Some(target) = output.iter_mut().find(|n| n.key == node.key) {
                        *target = merged;
                    }
                } else {
                    make_conflict(&node.key, "modify", &mut copies)?;
                    suppressed.insert(node.key.clone());
                }
            }
        }
    }
    for node in &l.nodes {
        if bm.contains_key(&node.key)
            || suppressed.iter().any(|key| descendant(&node.key, key, &lm))
        {
            continue;
        }
        if let Some(remote_node) = rm.get(&node.key) {
            if !same(node, remote_node) {
                make_conflict(&node.key, "create", &mut copies)?;
                suppressed.insert(node.key.clone());
            }
        } else {
            insert_local_node(&mut output, &l, node.clone());
        }
    }
    // 父节点消失时保留完整本地子树为顶层冲突，避免生成无法解析的孤儿节点。
    loop {
        let keys = output
            .iter()
            .map(|n| n.key.clone())
            .collect::<BTreeSet<_>>();
        let missing = output
            .iter()
            .find(|n| n.parent.as_ref().is_some_and(|p| !keys.contains(p)))
            .map(|n| n.key.clone());
        let Some(key) = missing else {
            break;
        };
        make_conflict(&key, "missing-parent", &mut copies)?;
        let lookup = output.iter().cloned().map(|n| (n.key.clone(), n)).collect();
        output.retain(|n| n.key != key && !descendant(&n.key, &key, &lookup));
    }
    let mut preamble = if let Some(preamble) = text_merge(&b.preamble, &l.preamble, &r.preamble) {
        preamble
    } else {
        let id = conflict_key(base, local, "preamble", "preamble");
        if !existing.contains(&id) {
            let escaped = l
                .preamble
                .lines()
                .map(|line| {
                    if line.starts_with('*') || line.starts_with("#+") {
                        format!(",{line}\n")
                    } else {
                        format!("{line}\n")
                    }
                })
                .collect::<String>();
            let source = mark(
                remote,
                &format!("* 文件前言\n#+begin_example\n{escaped}#+end_example\n"),
                &id,
                "preamble",
                "preamble",
            )?;
            let source = set_property(
                remote,
                &source,
                "CONFLICT_SOURCE",
                &serde_json::to_string(&l.preamble).unwrap(),
            )?;
            copies.push(Node {
                key: format!("preamble:{id}"),
                parent: None,
                level: 1,
                source,
            });
        }
        r.preamble.clone()
    };
    // 同级排序也是操作。两端顺序各自变化且不同则保留远端顺序并记录本地候选。
    let parents = l
        .nodes
        .iter()
        .map(|n| n.parent.clone())
        .collect::<BTreeSet<_>>();
    for parent in parents {
        let keys = b
            .nodes
            .iter()
            .filter(|n| n.parent == parent && lm.contains_key(&n.key) && rm.contains_key(&n.key))
            .map(|n| n.key.clone())
            .collect::<BTreeSet<_>>();
        let bs = sequence(&b, parent.as_deref(), &keys);
        let ls = sequence(&l, parent.as_deref(), &keys);
        let rs = sequence(&r, parent.as_deref(), &keys);
        if ls != bs {
            if rs == bs || rs == ls {
                let rank = ls
                    .iter()
                    .enumerate()
                    .map(|(i, key)| (key.as_str(), i))
                    .collect::<BTreeMap<_, _>>();
                let slots = output
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| n.parent == parent && keys.contains(&n.key))
                    .map(|(i, _)| i)
                    .collect::<Vec<_>>();
                let mut ordered = slots.iter().map(|i| output[*i].clone()).collect::<Vec<_>>();
                ordered.sort_by_key(|n| rank.get(n.key.as_str()).copied().unwrap_or(usize::MAX));
                for (index, node) in slots.into_iter().zip(ordered) {
                    output[index] = node;
                }
            } else {
                let id = conflict_key(base, local, parent.as_deref().unwrap_or("root"), "reorder");
                if !existing.contains(&id) {
                    let source = format!(
                        "* 文件顺序\n#+begin_example\n{}#+end_example\n",
                        local
                            .source_bytes()
                            .split(|b| *b == b'\n')
                            .map(|line| format!(",{}\n", String::from_utf8_lossy(line)))
                            .collect::<String>()
                    );
                    let source = mark(remote, &source, &id, "order", "reorder")?;
                    let source = set_property(
                        remote,
                        &source,
                        "CONFLICT_SOURCE",
                        &serde_json::to_string(std::str::from_utf8(local.source_bytes()).unwrap())
                            .unwrap(),
                    )?;
                    copies.push(Node {
                        key: format!("order:{id}"),
                        parent: None,
                        level: 1,
                        source,
                    });
                }
            }
        }
    }
    place_copies(base, local, remote, &b, &l, &r, &mut output, copies)?;
    let bytes = match render(&preamble, &output) {
        Ok(bytes) => bytes,
        Err(_) => return structural_conflict(base, local, remote),
    };
    let parsed = reparse(remote, bytes.clone())?;
    // 无法表达的结构变化转为保留完整本地原文的普通冲突 note，避免丢失局部操作。
    if parse(&parsed).nodes.len() != output.len() {
        return structural_conflict(base, local, remote);
    }
    preamble.clear();
    Ok(bytes)
}

fn structural_conflict(
    base: &OrgFile,
    local: &OrgFile,
    remote: &OrgFile,
) -> Result<Vec<u8>, CoreError> {
    let id = conflict_key(base, local, "document", "structure");
    if conflict_ids(remote).contains(&id) {
        return Ok(remote.source_bytes().to_vec());
    }
    let mut candidate = mark(remote, "* 文件结构\n", &id, "document", "structure")?;
    candidate = set_property(
        remote,
        &candidate,
        "CONFLICT_SOURCE",
        &serde_json::to_string(std::str::from_utf8(local.source_bytes()).unwrap()).unwrap(),
    )?;
    let mut output = String::from_utf8(remote.source_bytes().to_vec()).unwrap();
    append(&mut output, &candidate);
    reparse(remote, output.as_bytes().to_vec())?;
    Ok(output.into_bytes())
}

#[derive(Clone)]
pub(crate) struct ConflictVersion {
    pub key: String,
    pub local: Option<crate::OrgMergeVersion>,
    pub remote: Option<crate::OrgMergeVersion>,
    pub preamble: bool,
    operation: String,
    candidate: std::ops::Range<usize>,
    origin: Option<std::ops::Range<usize>>,
}
fn property(headline: &Headline, key: &str) -> Option<String> {
    headline.properties().and_then(|p| {
        p.iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.to_string())
    })
}
fn version(source: String) -> crate::OrgMergeVersion {
    let parsed = orgize::Org::parse(&source);
    let headline = parsed.first_node::<Headline>();
    crate::OrgMergeVersion {
        title: headline
            .as_ref()
            .map_or_else(|| "文件内容".into(), |h| h.title_raw().trim_end().into()),
        level: headline.map_or(0, |h| h.level()),
        parent: None,
        source,
    }
}
pub(crate) fn versions(file: &OrgFile) -> Result<Vec<ConflictVersion>, CoreError> {
    let doc = parse(file);
    let headlines = file
        .syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    let mut ranges = BTreeMap::new();
    for (node, headline) in doc.nodes.iter().zip(&headlines) {
        ranges.insert(
            node.key.as_str(),
            u32::from(headline.start()) as usize..u32::from(headline.end()) as usize,
        );
    }
    let mut output = Vec::new();
    for (node, headline) in doc.nodes.iter().zip(&headlines) {
        if !headline.tags().any(|t| t == crate::model::CONFLICT_TAG) {
            continue;
        }
        let Some(id) = property(headline, "CONFLICT_ID") else {
            continue;
        };
        let operation = property(headline, "CONFLICT_OPERATION")
            .ok_or(CoreError::InvalidState("冲突记录缺少操作类型"))?;
        let local_source = property(headline, "CONFLICT_SOURCE")
            .map(|s| {
                serde_json::from_str::<String>(&s)
                    .map_err(|_| CoreError::InvalidState("冲突候选原文无效"))
            })
            .transpose()?;
        let origin_key = property(headline, "CONFLICT_ORIGIN")
            .map(|s| {
                serde_json::from_str::<String>(&s)
                    .map_err(|_| CoreError::InvalidState("冲突来源身份无效"))
            })
            .transpose()?;
        let origin = origin_key
            .as_ref()
            .and_then(|key| ranges.get(key.as_str()))
            .cloned();
        let candidate = ranges[node.key.as_str()].clone();
        let preamble = matches!(operation.as_str(), "preamble" | "structure" | "reorder");
        let local = if operation == "delete" {
            None
        } else {
            local_source.clone().map(version)
        };
        let remote = if operation == "delete" {
            local_source.map(version)
        } else if preamble {
            Some(version(if operation == "preamble" {
                doc.preamble.clone()
            } else {
                String::from_utf8(file.source_bytes().to_vec()).unwrap()
            }))
        } else {
            origin.as_ref().map(|range| {
                version(String::from_utf8(file.source_bytes()[range.clone()].to_vec()).unwrap())
            })
        };
        output.push(ConflictVersion {
            key: id,
            local,
            remote,
            preamble,
            operation,
            candidate,
            origin,
        });
    }
    Ok(output)
}
fn at_level(file: &OrgFile, source: &str, level: usize) -> Result<String, CoreError> {
    let syntax = fragment(file, source);
    let headlines = syntax
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    let Some(first) = headlines.first() else {
        return Ok(source.into());
    };
    let original = first.level();
    let mut result = source.to_string();
    for h in headlines.into_iter().rev() {
        let at = u32::from(h.start()) as usize;
        result.replace_range(
            at..at + h.level(),
            &"*".repeat(h.level() - original + level),
        );
    }
    Ok(result)
}
pub(crate) fn resolve(
    file: &OrgFile,
    choices: &[crate::OrgMergeChoice],
) -> Result<Vec<u8>, CoreError> {
    let bytes = resolve_nodes(file, choices)?;
    with_conflict_header(&reparse(file, bytes)?)
}

fn resolve_nodes(file: &OrgFile, choices: &[crate::OrgMergeChoice]) -> Result<Vec<u8>, CoreError> {
    let conflicts = versions(file)?;
    let mut decisions = BTreeMap::new();
    for choice in choices {
        if decisions.insert(choice.key.as_str(), choice.side).is_some() {
            return Err(CoreError::InvalidInput("合并选择包含重复任务"));
        }
    }
    if decisions.len() != conflicts.len()
        || conflicts
            .iter()
            .any(|c| !decisions.contains_key(c.key.as_str()))
    {
        return Err(CoreError::InvalidInput(
            "请完成全部冲突选择，不能遗漏或加入未知任务",
        ));
    }
    let mut replacements = Vec::<(std::ops::Range<usize>, String)>::new();
    let mut appended = String::new();
    let mut whole_file = None;
    for conflict in conflicts {
        let side = decisions[conflict.key.as_str()];
        if conflict.preamble {
            replacements.push((conflict.candidate.clone(), String::new()));
            if side == crate::OrgMergeSide::Local {
                let local = conflict
                    .local
                    .ok_or(CoreError::InvalidState("冲突候选丢失"))?;
                if conflict.operation == "preamble" {
                    let prefix = parse(file).preamble.len();
                    replacements.push((0..prefix, local.source));
                } else {
                    if whole_file.is_some() {
                        return Err(CoreError::InvalidInput("一次只能采用一个整文件结构候选"));
                    }
                    whole_file = Some(local.source.into_bytes());
                }
            }
            continue;
        }
        if conflict.operation == "delete" {
            if conflict
                .origin
                .as_ref()
                .is_some_and(|origin| *origin != conflict.candidate)
            {
                replacements.push((conflict.candidate, String::new()));
                if side != crate::OrgMergeSide::Remote {
                    replacements.push((conflict.origin.unwrap(), String::new()));
                }
            } else {
                let content = if side == crate::OrgMergeSide::Remote {
                    conflict.remote.map(|v| v.source).unwrap_or_default()
                } else {
                    String::new()
                };
                replacements.push((conflict.candidate, content));
            }
            continue;
        }
        replacements.push((conflict.candidate, String::new()));
        if side != crate::OrgMergeSide::Remote {
            if let Some(origin) = conflict.origin {
                let old = fragment(
                    file,
                    std::str::from_utf8(&file.source_bytes()[origin.clone()]).unwrap(),
                );
                let level = old.first_node::<Headline>().map_or(1, |h| h.level());
                let content = if side == crate::OrgMergeSide::Local {
                    at_level(
                        file,
                        &conflict
                            .local
                            .ok_or(CoreError::InvalidState("冲突候选丢失"))?
                            .source,
                        level,
                    )?
                } else {
                    String::new()
                };
                replacements.push((origin, content));
            } else if side == crate::OrgMergeSide::Local {
                append(
                    &mut appended,
                    &at_level(
                        file,
                        &conflict
                            .local
                            .ok_or(CoreError::InvalidState("冲突候选丢失"))?
                            .source,
                        1,
                    )?,
                );
            }
        }
    }
    if let Some(bytes) = whole_file {
        reparse(file, bytes.clone())?;
        return Ok(bytes);
    }
    replacements.sort_by_key(|(range, _)| (range.start, range.end));
    for pair in replacements.windows(2) {
        if pair[0].0.end > pair[1].0.start {
            return Err(CoreError::InvalidInput(
                "所选父子冲突范围重叠，请先整理对应任务",
            ));
        }
    }
    let mut output = String::from_utf8(file.source_bytes().to_vec()).unwrap();
    for (range, content) in replacements.into_iter().rev() {
        output.replace_range(range, &content);
    }
    append(&mut output, &appended);
    let bytes = output.into_bytes();
    reparse(file, bytes.clone())?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn file(text: &str) -> OrgFile {
        OrgFile::new("repo".into(), "a.org".into(), text.as_bytes().to_vec()).unwrap()
    }
    fn task(state: &str, body: &str) -> String {
        format!("* {state} Work\n:PROPERTIES:\n:ID: stable\n:END:\n{body}\n")
    }
    #[test]
    fn state_and_remote_body_are_merged_without_formatting() {
        let b = task("TODO", "base");
        let l = task("DONE", "base");
        let r = task("TODO", "remote body");
        let result = merge_nodes(&file(&b), &file(&l), &file(&r)).unwrap();
        assert_eq!(result, task("DONE", "remote body").as_bytes());
    }
    #[test]
    fn same_field_retains_remote_and_a_stable_local_conflict_copy() {
        let b = task("TODO", "base");
        let l = task("TODO", "local");
        let r = task("TODO", "remote");
        let result = merge_nodes(&file(&b), &file(&l), &file(&r)).unwrap();
        let text = String::from_utf8(result.clone()).unwrap();
        assert!(text.starts_with(&r));
        assert!(text.contains("local"));
        assert!(text.contains("(conflict)"));
        assert_eq!(conflict_ids(&file(&text)).len(), 1);
        let retried = merge_nodes(&file(&b), &file(&l), &file(&text)).unwrap();
        assert_eq!(retried, result);
    }
    #[test]
    fn local_delete_remote_modify_is_recorded_without_erasing_remote_subtree() {
        let b = task("TODO", "base");
        let r = task("TODO", "changed");
        let result = merge_nodes(&file(&b), &file(""), &file(&r)).unwrap();
        let text = String::from_utf8(result).unwrap();
        assert!(text.contains("changed"));
        assert!(text.contains("CONFLICT_OPERATION: delete"));
    }
    #[test]
    fn missing_task_creates_a_candidate_and_missing_delete_is_idempotent() {
        let b = task("TODO", "base");
        let l = task("DONE", "local");
        let result = merge_nodes(&file(&b), &file(&l), &file("* Remote note\n")).unwrap();
        let text = String::from_utf8(result).unwrap();
        assert!(text.contains("Remote note"));
        assert!(text.contains("local"));
        assert!(text.contains(":CONFLICT:"));
        assert_eq!(
            merge_nodes(&file(&b), &file(""), &file("* Remote note\n")).unwrap(),
            b"* Remote note\n"
        );
    }
    #[test]
    fn independent_notes_crlf_and_body_lines_survive() {
        let b = "#+TITLE: Notes\r\n* A\r\nleft\r\nright\r\n* B\r\nunchanged  \r\n";
        let l = b.replace("left", "local");
        let r = b.replace("right", "remote");
        assert_eq!(
            merge_nodes(&file(b), &file(&l), &file(&r)).unwrap(),
            l.replace("right", "remote").as_bytes()
        );
    }
    #[test]
    fn local_sibling_reorder_is_applied_while_remote_body_changes_are_preserved() {
        let b = "* A\none\n* B\ntwo\n";
        let l = "* B\ntwo\n* A\none\n";
        let r = "* A\nremote\n* B\ntwo\n";
        assert_eq!(
            merge_nodes(&file(b), &file(l), &file(r)).unwrap(),
            b"* B\ntwo\n* A\nremote\n"
        );
    }
    #[test]
    fn existing_selection_api_can_accept_or_discard_a_delete_intent_without_losing_remote_content()
    {
        let b = "* TODO Work\n:PROPERTIES:\n:ID: stable\n:END:\nbase\n* Other\n";
        let l = "* Other\n";
        let r = b.replace("base", "remote");
        let merged =
            file(&String::from_utf8(merge_nodes(&file(b), &file(l), &file(&r)).unwrap()).unwrap());
        let changes = versions(&merged).unwrap();
        assert_eq!(changes.len(), 1);
        assert!(changes[0].local.is_none());
        let keep = resolve(
            &merged,
            &[crate::OrgMergeChoice {
                key: changes[0].key.clone(),
                side: crate::OrgMergeSide::Remote,
            }],
        )
        .unwrap();
        assert_eq!(keep, r.as_bytes());
        let remove = resolve(
            &merged,
            &[crate::OrgMergeChoice {
                key: changes[0].key.clone(),
                side: crate::OrgMergeSide::Local,
            }],
        )
        .unwrap();
        assert_eq!(remove, l.as_bytes());
    }
    #[test]
    fn cycles_and_ambiguous_ids_preserve_complete_local_candidates_as_conflict_notes() {
        let b = "* TODO A\n:PROPERTIES:\n:ID: a\n:END:\n* TODO B\n:PROPERTIES:\n:ID: b\n:END:\n";
        let l = "* TODO B\n:PROPERTIES:\n:ID: b\n:END:\n** TODO A\n:PROPERTIES:\n:ID: a\n:END:\n";
        let r = "* TODO A\n:PROPERTIES:\n:ID: a\n:END:\n** TODO B\n:PROPERTIES:\n:ID: b\n:END:\n";
        let merged =
            file(&String::from_utf8(merge_nodes(&file(b), &file(l), &file(r)).unwrap()).unwrap());
        assert!(has_conflicts(&merged));
        assert!(
            std::str::from_utf8(merged.source_bytes())
                .unwrap()
                .starts_with(r)
        );
        let changes = versions(&merged).unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].local.as_ref().unwrap().source, l);
        assert_eq!(
            resolve(
                &merged,
                &[crate::OrgMergeChoice {
                    key: changes[0].key.clone(),
                    side: crate::OrgMergeSide::Local
                }]
            )
            .unwrap(),
            l.as_bytes()
        );
    }
    #[test]
    fn in_buffer_todo_configuration_keeps_state_and_body_changes_independent() {
        let b = "#+TODO: OPEN | FINISHED\r\n* OPEN Work\r\n:PROPERTIES:\r\n:ID: stable\r\n:END:\r\nbase\r\n";
        let l = b.replace("* OPEN", "* FINISHED");
        let r = b.replace("base", "remote");
        assert_eq!(
            merge_nodes(&file(b), &file(&l), &file(&r)).unwrap(),
            l.replace("base", "remote").as_bytes()
        );
    }
}
