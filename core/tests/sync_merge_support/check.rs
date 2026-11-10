use super::fixture::{self, Inspect};
use super::{Result, ensure};
use org_tasks_core::OrgFile;
use orgize::{
    ast::{Headline, Keyword},
    rowan::ast::AstNode,
};
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
pub fn readable(bytes: &[u8]) -> Result<Vec<u8>> {
    let file = OrgFile::new("fixture".into(), "A.org".into(), bytes.into())?;
    let mut edits = Vec::new();
    let mut serial = 0;
    for headline in headings(&file) {
        if let Some(drawer) = headline.properties() {
            if let Some(id) = drawer.get("CONFILICT_ID") {
                serial += 1;
                edits.push((
                    usize::from(id.text_range().start())..usize::from(id.text_range().end()),
                    format!("<conflict-{serial}>"),
                ));
            }
        }
    }
    let mut result = String::from_utf8(bytes.to_vec())?;
    for (range, value) in edits.into_iter().rev() {
        result.replace_range(range, &value);
    }
    Ok(result.into_bytes())
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
    let mut ids = BTreeSet::new();
    for assertion in assertions {
        let Inspect::ConflictSubtree {
            candidate_alias,
            reason,
            source,
        } = assertion;
        let nodes = headings(file);
        let points = nodes
            .iter()
            .filter(|headline| {
                property(headline, "CONFILICT_ID").is_some()
                    && headline
                        .section()
                        .into_iter()
                        .flat_map(|section| {
                            section
                                .syntax()
                                .children()
                                .filter_map(Keyword::cast)
                                .collect::<Vec<_>>()
                        })
                        .any(|keyword| {
                            keyword.key().eq_ignore_ascii_case("CONFLICT_REASON")
                                && keyword.value().trim() == reason
                        })
            })
            .collect::<Vec<_>>();
        ensure(
            points.len() == 1,
            format!("{candidate_alias} 匹配数量不为 1"),
        )?;
        let point = points[0];
        ensure(
            ids.insert(property(point, "CONFILICT_ID").unwrap()),
            "冲突点 ID 重复",
        )?;
        ensure(point.level() == 2, "冲突点必须位于容器下")?;
        for key in [
            "CONFLICT_ID",
            "CONFLICT_ORIGIN",
            "CONFLICT_SOURCE",
            "CONFLICT_PARENT",
            "CONFLICT_PATH",
            "CONFLICT_OPERATION",
        ] {
            ensure(
                property(point, key).is_none(),
                format!("仍在生成旧冲突属性 {key}"),
            )?;
        }
        let original = fixture::read(case, source)?;
        let source_file = OrgFile::new("r".into(), "a.org".into(), original.clone())?;
        let first = source_file
            .syntax()
            .document()
            .first_headline()
            .ok_or("来源缺少标题")?;
        let child = point
            .headlines()
            .next()
            .ok_or("冲突点缺少可见的完整来源子树")?;
        let range = usize::from(child.start())..usize::from(child.end());
        let mut actual = String::from_utf8(file.source_bytes()[range].to_vec())?;
        for h in child
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
        {
            let start = usize::from(h.start()) - usize::from(child.start());
            actual.replace_range(
                start..start + h.level(),
                &"*".repeat(h.level() - child.level() + first.level()),
            );
        }
        ensure(
            actual.as_bytes() == original,
            format!("{candidate_alias} 可见来源子树不完整"),
        )?;
    }
    Ok(())
}
