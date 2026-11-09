use super::fixture::{self, Inspect, Placement};
use super::{Result, ensure};
use org_tasks_core::OrgFile;
use orgize::{ast::Headline, rowan::ast::AstNode};
use std::collections::BTreeSet;
use std::path::Path;

pub fn property(headline: &Headline, key: &str) -> Option<String> {
    headline
        .properties()?
        .get(key)
        .map(|value| value.to_string())
}

fn headings(file: &OrgFile) -> Vec<Headline> {
    file.syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect()
}

fn parents(headline: &Headline) -> Vec<String> {
    let mut titles = headline
        .syntax()
        .ancestors()
        .skip(1)
        .filter_map(Headline::cast)
        .map(|h| h.title_raw().trim_end().to_string())
        .collect::<Vec<_>>();
    titles.reverse();
    titles
}

/// 只处理候选子树中的真实属性节点，不触碰源码块、正文或原任务 ID。
pub fn readable(bytes: &[u8]) -> Result<Vec<u8>> {
    let file = OrgFile::new("fixture".into(), "A.org".into(), bytes.into())?;
    let nodes = headings(&file);
    let roots = nodes
        .iter()
        .filter(|h| property(h, "CONFLICT_ID").is_some())
        .collect::<Vec<_>>();
    let mut edits = Vec::new();
    let mut serial = 0;
    for h in &nodes {
        if !roots
            .iter()
            .any(|root| h.start() >= root.start() && h.start() < root.end())
        {
            continue;
        }
        if let Some(drawer) = h.properties() {
            for node in drawer.node_properties() {
                let raw = node.raw();
                let key = raw
                    .trim_start()
                    .strip_prefix(':')
                    .and_then(|s| s.split_once(':'))
                    .map(|(key, _)| key)
                    .ok_or("属性节点无效")?;
                let range = usize::from(node.start())..usize::from(node.end());
                if key == "ID" {
                    serial += 1;
                    let value = drawer.get("ID").ok_or("缺少候选 ID")?;
                    edits.push((
                        usize::from(value.text_range().start())
                            ..usize::from(value.text_range().end()),
                        format!("<generated-{serial}>"),
                    ));
                } else if [
                    "CONFLICT_ID",
                    "CONFLICT_ORIGIN",
                    "CONFLICT_SOURCE",
                    "CONFLICT_PARENT",
                    "CONFLICT_PATH",
                ]
                .contains(&key)
                {
                    edits.push((range, String::new()));
                }
            }
        }
    }
    edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    let mut output = String::from_utf8(bytes.to_vec())?;
    for (range, replacement) in edits {
        output.replace_range(range, &replacement);
    }
    Ok(output.into_bytes())
}

pub fn compare(label: &str, actual: &[u8], expected: &[u8], normalize: bool) -> Result<()> {
    let actual = if normalize {
        readable(actual)?
    } else {
        actual.to_vec()
    };
    if actual != expected {
        let first = actual
            .iter()
            .zip(expected)
            .position(|(a, b)| a != b)
            .unwrap_or(actual.len().min(expected.len()));
        return Err(format!(
            "{label} 字节不同，首个差异位于 {first}\n--- 预期\n{}\n+++ 实际\n{}",
            String::from_utf8_lossy(expected),
            String::from_utf8_lossy(&actual)
        )
        .into());
    }
    Ok(())
}

pub fn inspect(file: &OrgFile, case: &Path, assertions: &[Inspect]) -> Result<()> {
    let mut aliases = BTreeSet::new();
    for assertion in assertions {
        match assertion {
            Inspect::ConflictSubtree {
                origin_id,
                candidate_alias,
                operation,
                root_only_tag,
                placement,
                parent_titles,
                origin_titles,
                source,
                after_id,
                before_id,
            } => {
                ensure(aliases.insert(candidate_alias), "候选别名重复")?;
                ensure(root_only_tag == "CONFLICT", "冲突标签必须为 CONFLICT")?;
                let nodes = headings(file);
                let candidates = nodes
                    .iter()
                    .filter(|h| {
                        property(h, "CONFLICT_OPERATION").as_deref() == Some(operation)
                            && property(h, "CONFLICT_PATH")
                                .and_then(|p| serde_json::from_str::<Vec<String>>(&p).ok())
                                .as_ref()
                                == Some(origin_titles)
                    })
                    .collect::<Vec<_>>();
                ensure(
                    candidates.len() == 1,
                    format!("{candidate_alias} 候选匹配数量: {}", candidates.len()),
                )?;
                let candidate = candidates[0];
                ensure(
                    parents(candidate) == *parent_titles,
                    format!("{candidate_alias} 父路径错误"),
                )?;
                ensure(
                    candidate.tags().any(|tag| tag == "CONFLICT"),
                    "候选根未打标",
                )?;
                ensure(
                    candidate.title_raw().contains("(conflict)"),
                    "候选标题缺少后缀",
                )?;
                let id = property(candidate, "CONFLICT_ID").ok_or("缺少冲突身份")?;
                ensure(!id.is_empty(), "冲突身份为空")?;
                ensure(
                    property(candidate, "ID") == Some(format!("conflict-{id}")),
                    "候选根 ID 不对应冲突身份",
                )?;
                let expected = fixture::read(case, source)?;
                let stored: String = serde_json::from_str(
                    &property(candidate, "CONFLICT_SOURCE").ok_or("缺少来源正文")?,
                )?;
                ensure(
                    stored.as_bytes() == expected,
                    format!("{candidate_alias} 来源正文不准确"),
                )?;
                // 副本的原标签由完整 golden 保证；逐节点检查自有标签，避免把继承当作打标。
                for child in nodes
                    .iter()
                    .filter(|h| h.start() > candidate.start() && h.start() < candidate.end())
                {
                    ensure(
                        !child.tags().any(|tag| tag == "CONFLICT"),
                        "候选子节点被额外打标",
                    )?;
                }
                if let Some(origin_id) = origin_id {
                    let origin = nodes
                        .iter()
                        .find(|h| property(h, "ID").as_ref() == Some(origin_id));
                    if *placement == Placement::AfterOriginSubtree {
                        let origin = origin.ok_or("原节点丢失")?;
                        ensure(
                            candidate.start() == origin.end(),
                            "候选未紧随原节点的整个子树",
                        )?;
                        ensure(candidate.level() == origin.level(), "候选与原节点层级不同")?;
                    }
                } else {
                    ensure(
                        *placement != Placement::AfterOriginSubtree,
                        "位置断言缺少原节点 ID",
                    )?;
                }
                if let Some(id) = after_id {
                    let anchor = nodes
                        .iter()
                        .find(|h| property(h, "ID").as_ref() == Some(id))
                        .ok_or("前锚点丢失")?;
                    ensure(candidate.start() == anchor.end(), "候选未紧随前锚点子树")?;
                }
                if let Some(id) = before_id {
                    let anchor = nodes
                        .iter()
                        .find(|h| property(h, "ID").as_ref() == Some(id))
                        .ok_or("后锚点丢失")?;
                    ensure(candidate.end() == anchor.start(), "候选未紧靠后锚点")?;
                }
            }
        }
    }
    // 原始文档中的重复 ID 有专门的歧义规则；这里只要求生成的 ID 唯一且不撞原 ID。
    {
        let nodes = headings(file);
        let mut generated = BTreeSet::new();
        let mut originals = BTreeSet::new();
        let roots = nodes
            .iter()
            .filter(|h| property(h, "CONFLICT_ID").is_some())
            .collect::<Vec<_>>();
        for node in &nodes {
            if let Some(id) = property(node, "ID") {
                if roots
                    .iter()
                    .any(|root| node.start() >= root.start() && node.start() < root.end())
                {
                    ensure(generated.insert(id), "生成的候选 ID 重复")?;
                } else {
                    originals.insert(id);
                }
            }
        }
        ensure(generated.is_disjoint(&originals), "候选 ID 与原节点碰撞")?;
    }
    Ok(())
}
