//! 基于 orgize 来源区间的任务比较；该投影不是另一套 Org AST。
use std::collections::{BTreeMap, BTreeSet};

use orgize::{ast::Headline, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};

use super::{LocalFileVersion, OrgFile};
use crate::CoreError;

/// 同步变更检测元数据，不保存任务标题或正文。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgTaskFingerprint {
    pub key: String,
    pub hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgMergeVersion {
    pub title: String,
    pub source: String,
    pub parent: Option<String>,
    pub level: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OrgMergeChange {
    Unchanged,
    Modified,
    Added,
    Deleted,
    Unmatched,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgMergeItem {
    pub key: String,
    pub change: OrgMergeChange,
    pub local_change: OrgMergeChange,
    pub remote_change: OrgMergeChange,
    pub local: Option<OrgMergeVersion>,
    pub remote: Option<OrgMergeVersion>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgMergePlan {
    pub todo_defaults: super::TodoConfig,
    pub local_hash: String,
    pub remote_hash: String,
    pub has_baseline: bool,
    pub items: Vec<OrgMergeItem>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OrgMergeSide {
    Local,
    Remote,
    Remove,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrgMergeChoice {
    pub key: String,
    pub side: OrgMergeSide,
}

fn content_hash(source: &[u8]) -> String {
    LocalFileVersion::from_bytes(source).content_hash
}

fn version_hash(version: &OrgMergeVersion) -> String {
    content_hash(&serde_json::to_vec(&(version.parent.as_deref(), &version.source)).unwrap())
}

/// 每个标题只拥有自身标题与 section，不包含子标题；前言独立比较。
fn units(file: &OrgFile) -> Vec<(String, OrgMergeVersion)> {
    let headlines = file
        .syntax()
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .collect::<Vec<_>>();
    let prefix_end = headlines
        .first()
        .map(|h| u32::from(h.start()) as usize)
        .unwrap_or(file.source_bytes().len());
    let mut result = vec![(
        "preamble".into(),
        OrgMergeVersion {
            title: "文件前言".into(),
            source: String::from_utf8(file.source_bytes()[..prefix_end].to_vec()).unwrap(),
            parent: None,
            level: 0,
        },
    )];
    let mut ancestors: Vec<(usize, String)> = Vec::new();
    let mut occurrences = BTreeMap::<String, usize>::new();
    for headline in headlines {
        let level = headline.level();
        while ancestors
            .last()
            .is_some_and(|(ancestor, _)| *ancestor >= level)
        {
            ancestors.pop();
        }
        let parent = ancestors.last().map(|(_, key)| key.clone());
        let outline = serde_json::to_string(&(
            ancestors
                .iter()
                .map(|(_, key)| key.as_str())
                .collect::<Vec<_>>(),
            headline.title_raw().trim_end(),
        ))
        .unwrap();
        let explicit = headline.properties().and_then(|p| {
            p.iter()
                .find(|(key, _)| key.eq_ignore_ascii_case("ID"))
                .map(|(_, value)| value.to_string())
        });
        // 无 ID 的标题改名无法可靠配对；重复身份通过出现序号区分，始终要求人工检查差异。
        let identity = explicit
            .filter(|id| !id.trim().is_empty())
            .map(|id| format!("id:{}", content_hash(id.as_bytes())))
            .unwrap_or_else(|| format!("outline:{}", content_hash(outline.as_bytes())));
        let occurrence = occurrences.entry(identity.clone()).or_default();
        let key = format!("{identity}:{}", *occurrence);
        *occurrence += 1;
        let start = u32::from(headline.start()) as usize;
        let end = headline
            .headlines()
            .next()
            .map(|h| u32::from(h.start()) as usize)
            .unwrap_or(u32::from(headline.end()) as usize);
        let version = OrgMergeVersion {
            title: headline.title_raw().trim_end().into(),
            source: String::from_utf8(file.source_bytes()[start..end].to_vec()).unwrap(),
            parent,
            level,
        };
        ancestors.push((level, key.clone()));
        result.push((key, version));
    }
    result
}

pub fn task_fingerprints(file: &OrgFile) -> Vec<OrgTaskFingerprint> {
    units(file)
        .into_iter()
        .map(|(key, version)| OrgTaskFingerprint {
            key,
            hash: version_hash(&version),
        })
        .collect()
}

pub fn compare_org_tasks(
    local: &OrgFile,
    remote: &OrgFile,
    baseline: Option<&[OrgTaskFingerprint]>,
) -> OrgMergePlan {
    let local_units = units(local);
    let remote_units = units(remote);
    let local_by_key = local_units.iter().cloned().collect::<BTreeMap<_, _>>();
    let remote_by_key = remote_units.iter().cloned().collect::<BTreeMap<_, _>>();
    let base = baseline
        .unwrap_or_default()
        .iter()
        .map(|v| (v.key.as_str(), v.hash.as_str()))
        .collect::<BTreeMap<_, _>>();
    let side_change = |key: &str, version: Option<&OrgMergeVersion>| {
        if baseline.is_none() {
            return OrgMergeChange::Unmatched;
        }
        match (base.get(key), version) {
            (Some(hash), Some(version)) if **hash == version_hash(version) => {
                OrgMergeChange::Unchanged
            }
            (Some(_), Some(_)) => OrgMergeChange::Modified,
            (Some(_), None) => OrgMergeChange::Deleted,
            (None, Some(_)) => OrgMergeChange::Added,
            (None, None) => OrgMergeChange::Unchanged,
        }
    };
    // 本地变更依赖的已删除祖先也必须可供选择，不能静默丢弃子任务。
    let mut required_parents = BTreeSet::new();
    for (key, version) in &local_units {
        if side_change(key, Some(version)) == OrgMergeChange::Unchanged
            || remote_by_key.get(key) == Some(version)
        {
            continue;
        }
        let mut parent = version.parent.as_deref();
        let mut child_level = version.level;
        while let Some(key) = parent {
            if remote_by_key
                .get(key)
                .is_none_or(|version| version.level >= child_level)
            {
                required_parents.insert(key.to_string());
            }
            let local_parent = &local_by_key[key];
            child_level = local_parent.level;
            parent = local_parent.parent.as_deref();
        }
    }
    let mut seen = BTreeSet::new();
    let items = remote_units
        .iter()
        .chain(local_units.iter())
        .filter_map(|(key, _)| {
            if !seen.insert(key.clone()) {
                return None;
            }
            let local = local_by_key.get(key).cloned();
            let remote = remote_by_key.get(key).cloned();
            let local_change = side_change(key, local.as_ref());
            let remote_change = side_change(key, remote.as_ref());
            let change = match (&local, &remote) {
                (Some(a), Some(b)) if a == b => OrgMergeChange::Unchanged,
                _ if local_change == OrgMergeChange::Unchanged
                    && !required_parents.contains(key) =>
                {
                    OrgMergeChange::Unchanged
                }
                (Some(_), Some(_)) => OrgMergeChange::Modified,
                _ if baseline.is_none() => OrgMergeChange::Unmatched,
                (Some(_), None) => OrgMergeChange::Added,
                _ => OrgMergeChange::Deleted,
            };
            Some(OrgMergeItem {
                key: key.clone(),
                change,
                local_change,
                remote_change,
                local,
                remote,
            })
        })
        .collect();
    OrgMergePlan {
        todo_defaults: local.todo_defaults.clone(),
        local_hash: content_hash(local.source_bytes()),
        remote_hash: content_hash(remote.source_bytes()),
        has_baseline: baseline.is_some(),
        items,
    }
}

/// 未变化项隐式保留；所有差异必须显式选择，拒绝缺项、重复、未知键与不完整层级。
pub fn merge_org_tasks(
    plan: &OrgMergePlan,
    choices: &[OrgMergeChoice],
) -> Result<Vec<u8>, CoreError> {
    let mut decisions = BTreeMap::new();
    for choice in choices {
        if decisions.insert(choice.key.as_str(), choice.side).is_some() {
            return Err(CoreError::InvalidInput("合并选择包含重复任务"));
        }
    }
    let mut selected = BTreeMap::new();
    let mut ordered = Vec::new();
    for item in &plan.items {
        let side = if item.change == OrgMergeChange::Unchanged {
            if decisions.contains_key(item.key.as_str()) {
                return Err(CoreError::InvalidInput("未变化任务不能删除或替换"));
            }
            OrgMergeSide::Remote
        } else {
            decisions
                .remove(item.key.as_str())
                .ok_or(CoreError::InvalidInput("请确认每个新增、修改或删除项"))?
        };
        let version = match side {
            OrgMergeSide::Local => &item.local,
            OrgMergeSide::Remote => &item.remote,
            OrgMergeSide::Remove => &None,
        };
        if let Some(version) = version {
            selected.insert(item.key.as_str(), version);
            ordered.push(item.key.as_str());
        }
    }
    if !decisions.is_empty() {
        return Err(CoreError::InvalidInput("合并选择包含未知任务"));
    }
    for version in selected.values() {
        if let Some(parent) = &version.parent {
            let Some(parent_version) = selected.get(parent.as_str()) else {
                return Err(CoreError::InvalidInput(
                    "子任务的父标题未保留，请调整父标题或子任务的选择",
                ));
            };
            if parent_version.level >= version.level {
                return Err(CoreError::InvalidInput(
                    "所选任务的父子层级不一致，请重新选择",
                ));
            }
        }
    }
    fn append<'a>(
        key: &'a str,
        selected: &BTreeMap<&'a str, &'a OrgMergeVersion>,
        ordered: &[&'a str],
        visited: &mut BTreeSet<&'a str>,
        output: &mut Vec<u8>,
        rendered: &mut Vec<&'a str>,
    ) -> Result<(), CoreError> {
        if !visited.insert(key) {
            return Err(CoreError::InvalidInput("合并后的任务层级形成循环"));
        }
        rendered.push(key);
        let version = selected[key];
        if !output.is_empty() && !output.ends_with(b"\n") && !version.source.is_empty() {
            output.push(b'\n');
        }
        output.extend_from_slice(version.source.as_bytes());
        for child in ordered
            .iter()
            .copied()
            .filter(|child| selected[child].parent.as_deref() == Some(key))
        {
            append(child, selected, ordered, visited, output, rendered)?;
        }
        Ok(())
    }
    let mut output = Vec::new();
    let mut visited = BTreeSet::new();
    let mut rendered = Vec::new();
    for key in ordered
        .iter()
        .copied()
        .filter(|key| selected[key].parent.is_none())
    {
        append(
            key,
            &selected,
            &ordered,
            &mut visited,
            &mut output,
            &mut rendered,
        )?;
    }
    if visited.len() != selected.len() {
        return Err(CoreError::InvalidInput("合并后的任务层级不完整"));
    }
    let parsed = OrgFile::with_todo_defaults(
        "merge-validation".into(),
        "merge.org".into(),
        output.clone(),
        plan.todo_defaults.clone(),
    )?;
    let actual = units(&parsed);
    // 祖先改名会改变无 ID 子标题的匹配键，验证来源与层级而非重新生成的身份键。
    let nodes = rendered
        .iter()
        .copied()
        .filter(|key| *key != "preamble")
        .collect::<Vec<_>>();
    let expected_positions = nodes
        .iter()
        .copied()
        .enumerate()
        .map(|(i, key)| (key, i))
        .collect::<BTreeMap<_, _>>();
    let actual_nodes = actual
        .iter()
        .filter(|(key, _)| key != "preamble")
        .collect::<Vec<_>>();
    let actual_positions = actual_nodes
        .iter()
        .enumerate()
        .map(|(i, (key, _))| (key.as_str(), i))
        .collect::<BTreeMap<_, _>>();
    let same_bytes =
        |actual: &str, expected: &str| actual == expected || actual == format!("{expected}\n");
    let prefix = selected
        .get("preamble")
        .map(|v| v.source.as_str())
        .unwrap_or("");
    if !same_bytes(&actual[0].1.source, prefix) || nodes.len() != actual_nodes.len() {
        return Err(CoreError::InvalidInput(
            "所选内容无法组成完整 Org 任务，请调整选择",
        ));
    }
    for (key, (_, version)) in nodes.iter().zip(actual_nodes) {
        let expected = selected[key];
        if expected.level != version.level
            || !same_bytes(&version.source, &expected.source)
            || expected
                .parent
                .as_deref()
                .and_then(|p| expected_positions.get(p))
                != version
                    .parent
                    .as_deref()
                    .and_then(|p| actual_positions.get(p))
        {
            return Err(CoreError::InvalidInput(
                "所选内容改变了未确认的任务或父子层级，请调整选择",
            ));
        }
    }
    Ok(output)
}

impl super::OrgRepo {
    /// 同次同步的冲突备份集中在 .sync/backups/<started_at>/，不参与文件扫描或传输。
    pub async fn backup_sync_conflict(
        &self,
        path: &str,
        expected_hash: &str,
        timestamp: crate::TimestampMs,
    ) -> Result<String, CoreError> {
        use super::creation::{read_optional, task_target, write_new};
        use tokio::fs;
        super::validate_relative_path(path)?;
        if path.split('/').next() == Some(".sync") || !path.ends_with(".org") {
            return Err(CoreError::InvalidInput(
                "冲突目标必须是控制目录外的 .org 文件",
            ));
        }
        let target = task_target(std::path::Path::new(&self.root_directory), path).await?;
        let original = read_optional(&target)
            .await?
            .ok_or(CoreError::InvalidState("本地文件已删除，请重新比较"))?;
        if content_hash(&original) != expected_hash {
            return Err(CoreError::InvalidState("本地文件已改变，请重新比较"));
        }
        let root = fs::canonicalize(&self.root_directory)
            .await
            .map_err(merge_io)?;
        let relative = std::path::Path::new(path);
        let group = format!(".sync/backups/{timestamp}");
        let mut parent = root.clone();
        for part in std::path::Path::new(&group)
            .components()
            .chain(relative.parent().unwrap().components())
        {
            parent.push(part);
            match fs::symlink_metadata(&parent).await {
                Ok(info) if info.file_type().is_symlink() || !info.is_dir() => {
                    return Err(CoreError::InvalidInput(
                        "同步备份路径不能包含符号链接或非目录",
                    ));
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    fs::create_dir(&parent).await.map_err(merge_io)?;
                }
                Err(error) => return Err(merge_io(error)),
            }
        }
        let date = chrono::DateTime::from_timestamp_millis(timestamp)
            .ok_or(CoreError::InvalidInput("备份时间无效"))?
            .with_timezone(&chrono::Local)
            .format("%Y-%m-%d_%H-%M-%S")
            .to_string();
        let nonce = super::service::generate_repo_id()?;
        let backup = parent.join(format!(
            "{}-{date}-{}.org",
            relative.file_stem().unwrap().to_string_lossy(),
            &nonce[..8]
        ));
        write_new(&backup, &original).await?;
        Ok(backup.strip_prefix(root).unwrap().to_string_lossy().into())
    }

    /// 从预览版本提交已确认内容；不格式化未修改字节。
    pub async fn replace_conflict_file(
        &mut self,
        path: &str,
        expected_hash: Option<&str>,
        content: Option<Vec<u8>>,
    ) -> Result<(), CoreError> {
        use super::creation::{read_optional, task_target, write_new};
        use tokio::fs;
        super::validate_relative_path(path)?;
        if path.split('/').next() == Some(".sync") || !path.ends_with(".org") {
            return Err(CoreError::InvalidInput(
                "冲突目标必须是控制目录外的 .org 文件",
            ));
        }
        let target = task_target(std::path::Path::new(&self.root_directory), path).await?;
        let original = read_optional(&target).await?;
        if original.as_deref().map(content_hash).as_deref() != expected_hash {
            return Err(CoreError::InvalidState("本地文件已改变，请重新比较"));
        }
        let file = content
            .map(|bytes| self.parse_file(path.into(), bytes))
            .transpose()?;
        let temporary =
            target.with_file_name(format!(".{}.tmp", super::service::generate_repo_id()?));
        if let Some(file) = &file {
            write_new(&temporary, file.source_bytes()).await?;
        }
        if read_optional(&target).await? != original {
            let _ = fs::remove_file(&temporary).await;
            return Err(CoreError::InvalidState("本地文件已改变，请重新比较"));
        }
        let result = if file.is_some() {
            fs::rename(&temporary, &target).await
        } else if original.is_some() {
            fs::remove_file(&target).await
        } else {
            Ok(())
        };
        if let Err(error) = result {
            let _ = fs::remove_file(&temporary).await;
            return Err(merge_io(error));
        }
        self.files.retain(|f| f.path != path);
        if let Some(file) = file {
            self.files.push(file);
        }
        Ok(())
    }
}

fn merge_io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法保存冲突备份或合并文件: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "inbox.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }
    fn choices(plan: &OrgMergePlan, side: OrgMergeSide) -> Vec<OrgMergeChoice> {
        plan.items
            .iter()
            .filter(|item| item.change != OrgMergeChange::Unchanged)
            .map(|item| OrgMergeChoice {
                key: item.key.clone(),
                side,
            })
            .collect()
    }

    #[test]
    fn unchanged_nested_tasks_and_crlf_are_byte_identical() {
        let source = "#+TITLE: Tasks\r\n* TODO Parent\r\n  body  \r\n** DONE Child\r\n:PROPERTIES:\r\n:ID: child\r\n:END:\r\n";
        let plan = compare_org_tasks(&file(source), &file(source), None);
        assert!(
            plan.items
                .iter()
                .all(|item| item.change == OrgMergeChange::Unchanged)
        );
        assert_eq!(merge_org_tasks(&plan, &[]).unwrap(), source.as_bytes());
    }

    #[test]
    fn stable_id_matches_a_renamed_task_and_keeps_unchanged_children() {
        let local = file(
            "* TODO Local title\n:PROPERTIES:\n:ID: p\n:END:\n** TODO Child\n:PROPERTIES:\n:ID: c\n:END:\n",
        );
        let remote = file(
            "* DONE Remote title\n:PROPERTIES:\n:ID: p\n:END:\n** TODO Child\n:PROPERTIES:\n:ID: c\n:END:\n",
        );
        let plan = compare_org_tasks(&local, &remote, None);
        assert_eq!(
            plan.items
                .iter()
                .filter(|item| item.change == OrgMergeChange::Modified)
                .count(),
            1
        );
        let merged = merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Local)).unwrap();
        assert_eq!(merged, local.source_bytes());
    }

    #[test]
    fn parent_rename_preserves_child_without_id_and_rejects_accidental_reparenting() {
        let local = file("* TODO Local\n:PROPERTIES:\n:ID: p\n:END:\n** TODO Child\n");
        let remote = file("* TODO Remote\n:PROPERTIES:\n:ID: p\n:END:\n** TODO Child\n");
        let plan = compare_org_tasks(&local, &remote, None);
        assert!(
            plan.items
                .iter()
                .any(|item| item.change == OrgMergeChange::Unchanged
                    && item.local.as_ref().is_some_and(|v| v.title == "Child"))
        );
        let selected = plan
            .items
            .iter()
            .filter(|item| item.change != OrgMergeChange::Unchanged)
            .map(|item| OrgMergeChoice {
                key: item.key.clone(),
                side: OrgMergeSide::Local,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            merge_org_tasks(&plan, &selected).unwrap(),
            local.source_bytes()
        );
        let local = file("* Parent\n*** Local child\n");
        let remote = file("* Parent\n** Remote child\n");
        let plan = compare_org_tasks(&local, &remote, None);
        let selected = plan
            .items
            .iter()
            .filter(|item| item.change != OrgMergeChange::Unchanged)
            .map(|item| OrgMergeChoice {
                key: item.key.clone(),
                side: if item.local.is_some() {
                    OrgMergeSide::Local
                } else {
                    OrgMergeSide::Remote
                },
            })
            .collect::<Vec<_>>();
        assert!(merge_org_tasks(&plan, &selected).is_err());
    }

    #[test]
    fn remote_only_changes_are_kept_and_legacy_fingerprints_still_work() {
        let base = file("* TODO A\n* TODO Deleted\n");
        let local = base.clone();
        let remote = file("* TODO A\n* TODO Added\n");
        let versions = task_fingerprints(&base);
        let plan = compare_org_tasks(&local, &remote, Some(&versions));
        assert_eq!(
            plan.items
                .iter()
                .find(|item| item.local.as_ref().is_some_and(|v| v.title == "Deleted"))
                .unwrap()
                .change,
            OrgMergeChange::Unchanged
        );
        assert_eq!(
            plan.items
                .iter()
                .find(|item| item.remote.as_ref().is_some_and(|v| v.title == "Added"))
                .unwrap()
                .change,
            OrgMergeChange::Unchanged
        );
        assert_eq!(
            merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Remote)).unwrap(),
            remote.source_bytes()
        );
        let stored = serde_json::to_string(&versions).unwrap();
        assert!(!stored.contains("Deleted") && !stored.contains("TODO"));
        let unknown = compare_org_tasks(&local, &remote, None);
        assert_eq!(
            unknown
                .items
                .iter()
                .filter(|item| item.change == OrgMergeChange::Unmatched)
                .count(),
            2
        );
    }

    #[test]
    fn local_changes_are_reviewed_against_remote_with_both_delete_modify_conflicts() {
        fn task(body: Option<&str>) -> String {
            body.map(|body| format!("* TODO Task\n:PROPERTIES:\n:ID: stable\n:END:\n{body}\n"))
                .unwrap_or_default()
        }
        use OrgMergeChange::{Added, Deleted, Modified, Unchanged};
        let cases = [
            (
                Some("base"),
                Some("local"),
                None,
                Modified,
                Deleted,
                Some(Added),
            ),
            (
                Some("base"),
                None,
                Some("remote"),
                Deleted,
                Modified,
                Some(Deleted),
            ),
            (
                Some("base"),
                Some("local"),
                Some("remote"),
                Modified,
                Modified,
                Some(Modified),
            ),
            (
                Some("base"),
                None,
                Some("base"),
                Deleted,
                Unchanged,
                Some(Deleted),
            ),
            (
                Some("base"),
                Some("local"),
                Some("base"),
                Modified,
                Unchanged,
                Some(Modified),
            ),
            (None, Some("local"), None, Added, Unchanged, Some(Added)),
            (None, None, Some("remote"), Unchanged, Added, None),
            (
                Some("base"),
                Some("base"),
                Some("remote"),
                Unchanged,
                Modified,
                None,
            ),
            (Some("base"), Some("base"), None, Unchanged, Deleted, None),
            (
                Some("base"),
                Some("same"),
                Some("same"),
                Modified,
                Modified,
                None,
            ),
        ];
        for (base, local, remote, local_change, remote_change, expected) in cases {
            let base = file(&task(base));
            let local = file(&task(local));
            let remote = file(&task(remote));
            let baseline = task_fingerprints(&base);
            let plan = compare_org_tasks(&local, &remote, Some(&baseline));
            let reviewed = plan
                .items
                .iter()
                .filter(|item| item.change != Unchanged)
                .collect::<Vec<_>>();
            assert_eq!(reviewed.len(), usize::from(expected.is_some()));
            if let Some(kind) = expected {
                assert_eq!(reviewed[0].change, kind);
                assert_eq!(reviewed[0].local_change, local_change);
                assert_eq!(reviewed[0].remote_change, remote_change);
            }
            assert_eq!(
                merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Remote)).unwrap(),
                remote.source_bytes()
            );
            let accepted = merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Local)).unwrap();
            assert_eq!(
                accepted,
                if expected.is_some() {
                    local.source_bytes()
                } else {
                    remote.source_bytes()
                }
            );
        }
    }

    #[test]
    fn deleted_parent_remains_reviewable_when_a_local_child_was_modified() {
        let base = file("* Parent\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nbase\n");
        let local = file("* Parent\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nlocal\n");
        let baseline = task_fingerprints(&base);
        let plan = compare_org_tasks(&local, &file(""), Some(&baseline));
        assert_eq!(
            plan.items
                .iter()
                .filter(|item| item.change != OrgMergeChange::Unchanged)
                .count(),
            2
        );
        assert_eq!(
            merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Local)).unwrap(),
            local.source_bytes()
        );
    }

    #[test]
    fn remote_parent_level_changes_can_be_rejected_to_keep_a_local_child() {
        let base = file(
            "* Parent\n:PROPERTIES:\n:ID: parent\n:END:\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nbase\n",
        );
        let local = file(
            "* Parent\n:PROPERTIES:\n:ID: parent\n:END:\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nlocal\n",
        );
        let remote = file(
            "** Parent\n:PROPERTIES:\n:ID: parent\n:END:\n*** Child\n:PROPERTIES:\n:ID: child\n:END:\nbase\n",
        );
        let baseline = task_fingerprints(&base);
        let plan = compare_org_tasks(&local, &remote, Some(&baseline));
        assert_eq!(
            plan.items
                .iter()
                .filter(|item| item.change != OrgMergeChange::Unchanged)
                .count(),
            2
        );
        assert_eq!(
            merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Local)).unwrap(),
            local.source_bytes()
        );
        assert_eq!(
            merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Remote)).unwrap(),
            remote.source_bytes()
        );
    }

    #[test]
    fn requires_complete_choices_and_never_silently_drops_a_child() {
        let local = file("* TODO Parent\n** TODO Child\n");
        let remote = file("* DONE Parent\n** TODO Child\n");
        let plan = compare_org_tasks(&local, &remote, None);
        assert!(merge_org_tasks(&plan, &[]).is_err());
        assert!(merge_org_tasks(&plan, &choices(&plan, OrgMergeSide::Remove)).is_err());
        let mut selected = choices(&plan, OrgMergeSide::Remote);
        selected.push(selected[0].clone());
        assert!(merge_org_tasks(&plan, &selected).is_err());
    }

    #[test]
    fn preserves_blocks_and_new_local_tasks_without_reformatting_remote() {
        let local = file(
            "* TODO Keep\n#+begin_src text\nnot a heading\n#+end_src\n* TODO Local only\n  body  \n",
        );
        let remote =
            file("* TODO Keep\n#+begin_src text\nnot a heading\n#+end_src\n* TODO Remote only\n");
        let plan = compare_org_tasks(&local, &remote, None);
        let selected = plan
            .items
            .iter()
            .filter(|i| i.change != OrgMergeChange::Unchanged)
            .map(|i| OrgMergeChoice {
                key: i.key.clone(),
                side: if i.local.is_some() {
                    OrgMergeSide::Local
                } else {
                    OrgMergeSide::Remote
                },
            })
            .collect::<Vec<_>>();
        let merged = merge_org_tasks(&plan, &selected).unwrap();
        assert!(merged.starts_with(remote.source_bytes()));
        assert!(merged.ends_with(b"* TODO Local only\n  body  \n"));
    }

    #[tokio::test]
    async fn backup_is_grouped_under_sync_and_stale_local_edits_are_rejected() {
        use crate::webdav::WebDavSyncPolicy;
        let base = std::env::temp_dir().join(format!(
            "org-tasks-merge-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        let root = base.join("repo");
        tokio::fs::create_dir_all(&root).await.unwrap();
        tokio::fs::write(root.join("inbox.org"), b"* TODO Original\r\n")
            .await
            .unwrap();
        let mut repo = super::super::OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let hash = content_hash(b"* TODO Original\r\n");
        let backup = repo
            .backup_sync_conflict("inbox.org", &hash, 1792296000000)
            .await
            .unwrap();
        assert_eq!(
            tokio::fs::read(root.join(&backup)).await.unwrap(),
            b"* TODO Original\r\n"
        );
        assert!(
            std::path::Path::new(&backup)
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("inbox-2026-10-18_")
        );
        assert!(
            repo.backup_sync_conflict("../outside.org", &hash, 1)
                .await
                .is_err()
        );
        #[cfg(unix)]
        {
            tokio::fs::remove_dir_all(root.join(".sync/backups"))
                .await
                .unwrap();
            let outside = base.join("outside");
            tokio::fs::create_dir(&outside).await.unwrap();
            std::os::unix::fs::symlink(&outside, root.join(".sync/backups")).unwrap();
            assert!(
                repo.backup_sync_conflict("inbox.org", &hash, 200)
                    .await
                    .is_err()
            );
            assert!(
                tokio::fs::read_dir(outside)
                    .await
                    .unwrap()
                    .next_entry()
                    .await
                    .unwrap()
                    .is_none()
            );
        }
        tokio::fs::write(root.join("inbox.org"), b"* TODO Newer\n")
            .await
            .unwrap();
        assert!(
            repo.replace_conflict_file("inbox.org", Some(&hash), Some(b"* TODO Remote\n".to_vec()))
                .await
                .is_err()
        );
        assert_eq!(
            tokio::fs::read(root.join("inbox.org")).await.unwrap(),
            b"* TODO Newer\n"
        );
        tokio::fs::remove_dir_all(base).await.unwrap();
    }
}
