//! 按文件身份建立本轮比较组，使用不可变快照准备各组的传输和提交结果。
use super::synchronize::{missing_version, parse_snapshot, strong};
use super::*;
use crate::model::TASK_SCAN_RULES_PATH;
use std::path::Path;

type Sources = BTreeMap<String, Option<Vec<u8>>>;
const BASE: usize = 0;
const LOCAL: usize = 1;
const REMOTE: usize = 2;

pub(super) struct Snapshots {
    pub repo: OrgRepo,
    pub files: Vec<OrgFile>,
    pub base: Sources,
    pub local: Sources,
    pub remote: Sources,
    pub versions: BTreeMap<String, RemoteFileVersion>,
    pub detached: bool,
}

#[derive(Default)]
pub(super) struct Group {
    paths: [Option<String>; 3],
    additional_path: Option<String>,
}

impl Group {
    pub fn path(&self) -> &str {
        self.paths[REMOTE]
            .as_deref()
            .or(self.paths[LOCAL].as_deref())
            .or(self.paths[BASE].as_deref())
            .or(self.additional_path.as_deref())
            .expect("比较组至少有一个路径")
    }

    fn output_path(&self, detached: bool) -> Result<&str, CoreError> {
        match self.paths.each_ref().map(Option::as_deref) {
            [Some(base), Some(local), Some(remote)] if !detached => {
                if local == remote || remote == base {
                    Ok(local)
                } else if local == base {
                    Ok(remote)
                } else {
                    Err(CoreError::InvalidState("同一 Org 文件在两端改到不同路径"))
                }
            }
            _ => Ok(self.path()),
        }
    }
}

pub(super) struct Comparison {
    group: Group,
    output: String,
    operation: Operation,
    obsolete_paths: Vec<String>,
}

enum Operation {
    MergeWithBase,
    MergeNoBase,
    AdoptLocal,
    AdoptRemote,
    Remove,
    SyncRules,
}

impl Comparison {
    pub fn path(&self) -> &str {
        self.group.path()
    }

    fn new(group: Group, snapshots: &Snapshots) -> Result<Self, CoreError> {
        let output = group.output_path(snapshots.detached)?.to_owned();
        let [base, local, remote] = group.paths.each_ref().map(Option::as_deref);
        let base = base.filter(|_| !snapshots.detached);
        let operation = if output == TASK_SCAN_RULES_PATH {
            Operation::SyncRules
        } else {
            match (base, local, remote) {
                (Some(_), Some(_), Some(_)) => Operation::MergeWithBase,
                (None, Some(_), Some(_)) => Operation::MergeNoBase,
                (Some(base), None, Some(remote))
                    if base == remote && snapshots.base[base] == snapshots.remote[remote] =>
                {
                    Operation::Remove
                }
                (_, _, Some(_)) => Operation::AdoptRemote,
                (None, Some(_), None) => Operation::AdoptLocal,
                _ => Operation::Remove,
            }
        };
        Ok(Self {
            group,
            output,
            operation,
            obsolete_paths: Vec::new(),
        })
    }
}

pub(super) struct Prepared<T> {
    pub path: String,
    pub before: Option<Vec<u8>>,
    pub remote: Option<Vec<u8>>,
    pub result: Option<T>,
    pub version: RemoteFileVersion,
    pub action: OrgRepoSyncFileAction,
    pub conflicts: bool,
    pub deleted_source: Option<Vec<u8>>,
    pub outcome: OrgRepoSyncFileOutcome,
}

impl Prepared<LocalFileVersion> {
    pub async fn read(
        self,
        root: &Path,
        repo_id: &str,
        started_at: TimestampMs,
    ) -> Result<Prepared<Vec<u8>>, CoreError> {
        let Self {
            path,
            before,
            remote,
            result,
            version,
            action,
            conflicts,
            deleted_source,
            outcome,
        } = self;
        let result = if let Some(expected) = result {
            let bytes =
                super::session::read_staged(root, repo_id, started_at, "merged", &path).await?;
            if LocalFileVersion::from_bytes(&bytes) != expected {
                return Err(CoreError::InvalidState("暂存的合并正文已改变"));
            }
            Some(bytes)
        } else {
            None
        };
        Ok(Prepared {
            path,
            before,
            remote,
            result,
            version,
            action,
            conflicts,
            deleted_source,
            outcome,
        })
    }
}

type FileError = (String, CoreError);

struct FileIndex {
    remaining: BTreeSet<String>,
    by_id: BTreeMap<String, String>,
}

impl FileIndex {
    fn new(sources: &Sources, paths: &[String]) -> Result<Self, FileError> {
        let mut index = Self {
            remaining: BTreeSet::new(),
            by_id: BTreeMap::new(),
        };
        for path in paths {
            let Some(bytes) = sources.get(path).and_then(Option::as_deref) else {
                continue;
            };
            index.remaining.insert(path.clone());
            let id = file_id(path, bytes).map_err(|error| (path.clone(), error))?;
            if let Some(id) = id
                && index.by_id.insert(id, path.clone()).is_some()
            {
                return Err((
                    path.clone(),
                    CoreError::InvalidState("同一快照有重复的 Org 文件 ID"),
                ));
            }
        }
        Ok(index)
    }

    fn take_id(&mut self, id: &str) -> Option<String> {
        let path = self.by_id.get(id)?;
        self.remaining.take(path)
    }
}

pub(super) fn groups(
    snapshots: &Snapshots,
    paths: &[String],
    options: &crate::SyncOptions,
) -> Result<Vec<Comparison>, FileError> {
    let mut base = FileIndex::new(&snapshots.base, paths)?;
    let mut local = FileIndex::new(&snapshots.local, paths)?;
    let remote = FileIndex::new(&snapshots.remote, paths)?;
    let protected = excluded_paths(snapshots, options, [&base, &local, &remote])?;
    let mut groups = remote
        .remaining
        .iter()
        .map(|path| {
            (
                path.clone(),
                Group {
                    paths: [None, None, Some(path.clone())],
                    additional_path: None,
                },
            )
        })
        .collect::<BTreeMap<_, _>>();

    // 全部远端 ID 优先认领基线与本地版本，同路径补配只能取得各侧余下的文件。
    for (id, path) in &remote.by_id {
        let group = groups.get_mut(path).expect("远端文件已建立比较组");
        group.paths[BASE] = base.take_id(id);
        group.paths[LOCAL] = local.take_id(id);
    }
    for (path, group) in &mut groups {
        if group.paths[BASE].is_none() {
            group.paths[BASE] = base.remaining.take(path);
        }
        if group.paths[LOCAL].is_none() {
            group.paths[LOCAL] = local.remaining.take(path);
        }
    }

    // 远端已删除的文件仍按 ID 找回旧基线，以识别本地改名。
    let mut remaining_local = BTreeMap::<String, String>::new();
    for (id, path) in local.by_id {
        if local.remaining.contains(&path)
            && let Some(base_path) = base.take_id(&id)
        {
            remaining_local.insert(path, base_path);
        }
    }
    let mut groups = groups.into_values().collect::<Vec<_>>();
    groups.extend(local.remaining.into_iter().map(|path| {
        let baseline = remaining_local
            .remove(&path)
            .or_else(|| base.remaining.take(&path));
        Group {
            paths: [baseline, Some(path), None],
            additional_path: None,
        }
    }));
    groups.extend(base.remaining.into_iter().map(|path| Group {
        paths: [Some(path), None, None],
        additional_path: None,
    }));
    for path in paths {
        let exists = [&snapshots.base, &snapshots.local, &snapshots.remote]
            .iter()
            .any(|sources| sources.get(path).is_some_and(Option::is_some));
        if !exists {
            groups.push(Group {
                paths: [None, None, None],
                additional_path: Some(path.clone()),
            });
        }
    }

    groups.retain(|group| {
        !group
            .paths
            .iter()
            .flatten()
            .any(|path| protected.contains(path))
    });
    groups.sort_by(|left, right| {
        (left.path() != TASK_SCAN_RULES_PATH, left.path())
            .cmp(&(right.path() != TASK_SCAN_RULES_PATH, right.path()))
    });
    let mut comparisons = groups
        .into_iter()
        .map(|group| {
            let path = group.path().to_owned();
            Comparison::new(group, snapshots).map_err(|error| (path, error))
        })
        .collect::<Result<Vec<_>, _>>()?;
    assign_paths(&mut comparisons, snapshots)?;
    Ok(comparisons)
}

fn excluded_paths(
    snapshots: &Snapshots,
    options: &crate::SyncOptions,
    indexes: [&FileIndex; 3],
) -> Result<BTreeSet<String>, FileError> {
    // 远端过滤目录没有正文。用已知本地和祖先的排除路径保护对应文件身份。
    let excluded = snapshots
        .files
        .iter()
        .map(|file| (&file.path, file.source_bytes()))
        .chain(
            snapshots
                .base
                .iter()
                .filter_map(|(path, bytes)| Some((path, bytes.as_deref()?))),
        )
        .filter(|(path, _)| options.excludes_path(path))
        .map(|(path, bytes)| file_id(path, bytes).map_err(|error| (path.clone(), error)))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(excluded
        .into_iter()
        .flatten()
        .flat_map(|id| {
            indexes
                .iter()
                .filter_map(move |index| index.by_id.get(&id).cloned())
        })
        .collect())
}

fn assign_paths(comparisons: &mut [Comparison], snapshots: &Snapshots) -> Result<(), FileError> {
    let mut targets = BTreeSet::new();
    for comparison in comparisons
        .iter()
        .filter(|item| !matches!(item.operation, Operation::Remove))
    {
        let path = &comparison.output;
        if !targets.insert(path.clone())
            || (snapshots.remote.get(path).is_some_and(Option::is_some)
                && comparison.group.paths[REMOTE].as_ref() != Some(path))
        {
            return Err((
                path.clone(),
                CoreError::InvalidState("同步目标路径已被另一文件占用"),
            ));
        }
    }

    // 交换路径时两个目标都保留。未被任何结果占用的路径由持有远端、本地或基线版本的组清理。
    let mut obsolete = BTreeMap::new();
    for side in [BASE, LOCAL, REMOTE] {
        for (index, comparison) in comparisons.iter().enumerate() {
            if let Some(path) = &comparison.group.paths[side]
                && !targets.contains(path)
            {
                obsolete.insert(path.clone(), index);
            }
        }
    }
    for (index, comparison) in comparisons.iter().enumerate() {
        if let Some(path) = &comparison.group.additional_path
            && !targets.contains(path)
        {
            obsolete.insert(path.clone(), index);
        }
    }
    for (path, index) in obsolete {
        comparisons[index].obsolete_paths.push(path);
    }
    Ok(())
}

fn file_id(path: &str, bytes: &[u8]) -> Result<Option<String>, CoreError> {
    if !path.ends_with(".org") {
        return Ok(None);
    }
    let source =
        std::str::from_utf8(bytes).map_err(|_| CoreError::InvalidInput("Org 文件必须是 UTF-8"))?;
    let org = orgize::Org::parse(source);
    let Some(drawer) = org.document().properties() else {
        return Ok(None);
    };
    let mut ids = crate::model::properties::entries(&drawer)
        .filter(|entry| entry.name == "ID" && !entry.append && !entry.value.is_empty())
        .map(|entry| entry.value);
    let id = ids.next();
    if ids.next().is_some() {
        return Err(CoreError::InvalidState("Org 文件顶部声明了多个 ID"));
    }
    Ok(id)
}

pub(super) async fn execute(
    snapshots: &Snapshots,
    comparison: Comparison,
    started_at: TimestampMs,
) -> Result<Vec<Prepared<LocalFileVersion>>, CoreError> {
    let Comparison {
        group,
        output,
        operation,
        obsolete_paths,
    } = comparison;
    let path = output.as_str();
    let get = |side: usize, sources: &Sources| -> Option<Vec<u8>> {
        group.paths[side]
            .as_ref()
            .and_then(|path| sources.get(path))
            .cloned()
            .flatten()
    };
    let before = get(LOCAL, &snapshots.local);
    let remote = get(REMOTE, &snapshots.remote);
    let base = get(BASE, &snapshots.base);
    let sync_rules = matches!(operation, Operation::SyncRules);
    let (result, conflicts) = if sync_rules {
        let baseline = snapshots.base.get(path);
        if remote.is_none() && baseline.is_none() {
            return Ok(Vec::new());
        }
        let rules = remote
            .as_deref()
            .map(std::str::from_utf8)
            .transpose()
            .map_err(|_| CoreError::InvalidInput("远端 .orgzlyignore 必须是 UTF-8"))?;
        crate::TaskScanRules::parse(rules.unwrap_or_default())?;
        if before != remote && before.is_some() && baseline != Some(&before) {
            return Err(CoreError::InvalidState(
                "本地 .orgzlyignore 有独立修改，请先统一规则",
            ));
        }
        (remote.clone(), false)
    } else {
        merge(
            snapshots,
            &group,
            path,
            operation,
            before.as_ref(),
            remote.as_ref(),
            base.as_ref(),
        )
        .await?
    };

    let remote_deleted = !snapshots.detached && base.is_some() && remote.is_none();
    let archive_path = group.paths[LOCAL].as_deref().unwrap_or(path);
    let result_path = (result.is_some() || sync_rules).then_some(path);
    let mut prepared =
        Vec::with_capacity(obsolete_paths.len() + usize::from(result_path.is_some()));
    for destination in result_path
        .into_iter()
        .chain(obsolete_paths.iter().map(String::as_str))
    {
        let physical_local = snapshots.local.get(destination).cloned().flatten();
        let physical_remote = snapshots.remote.get(destination).cloned().flatten();
        let result = if destination == path {
            result.clone()
        } else {
            None
        };
        let mut version = snapshots
            .versions
            .get(destination)
            .cloned()
            .unwrap_or_else(missing_version);
        if physical_remote.is_none() {
            version = missing_version();
        } else if destination.ends_with(".org")
            && result != physical_remote
            && strong(version.etag.as_deref()).is_none()
        {
            return Err(CoreError::InvalidState(
                "远端未提供强 ETag，无法安全更新或删除",
            ));
        }
        let deleted_source = if remote_deleted && destination == archive_path {
            before.clone().or_else(|| base.clone())
        } else {
            None
        };
        let has_conflicts = destination == path && conflicts;
        let action = action(destination, &physical_local, &physical_remote, &result);
        let outcome = if has_conflicts {
            OrgRepoSyncFileOutcome::Conflict
        } else if result.is_none() {
            if physical_local.is_some() || physical_remote.is_some() || deleted_source.is_some() {
                OrgRepoSyncFileOutcome::Deleted
            } else {
                OrgRepoSyncFileOutcome::Unchanged
            }
        } else if base.is_none() && (before.is_none() || remote.is_none()) {
            OrgRepoSyncFileOutcome::Created
        } else if base.is_none() || snapshots.detached {
            if result == physical_local {
                OrgRepoSyncFileOutcome::Unchanged
            } else {
                OrgRepoSyncFileOutcome::Updated
            }
        } else {
            let local_changed = before != base || group.paths[LOCAL] != group.paths[BASE];
            let remote_changed = remote != base || group.paths[REMOTE] != group.paths[BASE];
            match (local_changed, remote_changed) {
                (true, true) => OrgRepoSyncFileOutcome::Merged,
                (false, true) => OrgRepoSyncFileOutcome::Updated,
                (true, false) => OrgRepoSyncFileOutcome::Uploaded,
                (false, false) => OrgRepoSyncFileOutcome::Unchanged,
            }
        };
        if let Some(bytes) = &result {
            super::session::stage(
                Path::new(&snapshots.repo.root_directory),
                &snapshots.repo.id,
                started_at,
                "merged",
                destination,
                bytes,
            )
            .await?;
        }
        prepared.push(Prepared {
            path: destination.into(),
            before: physical_local,
            remote: physical_remote,
            result: result.as_deref().map(LocalFileVersion::from_bytes),
            version,
            action,
            conflicts: has_conflicts,
            deleted_source,
            outcome,
        });
    }
    Ok(prepared)
}

fn action(
    path: &str,
    before: &Option<Vec<u8>>,
    remote: &Option<Vec<u8>>,
    result: &Option<Vec<u8>>,
) -> OrgRepoSyncFileAction {
    use OrgRepoSyncFileAction::*;
    if result.is_none() {
        if before.is_none() && remote.is_none() {
            Unchanged
        } else {
            Deleted
        }
    } else if path == TASK_SCAN_RULES_PATH {
        if before == result {
            Unchanged
        } else {
            Downloaded
        }
    } else if result != remote {
        if remote.is_some() { Uploaded } else { Created }
    } else if result != before {
        Downloaded
    } else {
        Unchanged
    }
}

async fn merge(
    snapshots: &Snapshots,
    group: &Group,
    path: &str,
    operation: Operation,
    local: Option<&Vec<u8>>,
    remote: Option<&Vec<u8>>,
    base: Option<&Vec<u8>>,
) -> Result<(Option<Vec<u8>>, bool), CoreError> {
    let parse = |side: usize, bytes: &Vec<u8>, sources| {
        parse_snapshot(
            &snapshots.repo,
            group.paths[side].as_deref().unwrap_or(path),
            bytes.clone(),
            sources,
            &snapshots.files,
        )
    };
    let remote_file = remote
        .map(|bytes| parse(REMOTE, bytes, &snapshots.remote))
        .transpose()?;
    match operation {
        Operation::MergeWithBase | Operation::MergeNoBase => {
            let local_file = parse(LOCAL, local.expect("计划包含本地正文"), &snapshots.local)?;
            let mut remote_file = remote_file.expect("计划包含远端正文");
            if matches!(operation, Operation::MergeWithBase) {
                let base_file = parse(BASE, base.expect("计划包含基线正文"), &snapshots.base)?;
                // 保留各侧解析上下文，同时用最终路径生成稳定的冲突身份。
                remote_file.path = path.to_owned();
                let merged =
                    crate::merge::merge_file_with_base(local_file, remote_file, base_file).await?;
                return Ok((Some(merged.content), merged.has_conflicts));
            }
            let conflicts = crate::merge::has_conflicts(&remote_file);
            crate::merge::merge_file_no_base(local_file, remote_file, None).await?;
            Ok((remote.cloned(), conflicts))
        }
        Operation::AdoptRemote => {
            let file = remote_file.expect("计划包含远端正文");
            Ok((remote.cloned(), crate::merge::has_conflicts(&file)))
        }
        Operation::AdoptLocal => {
            let local = local.expect("计划包含本地正文");
            let file = parse(LOCAL, local, &snapshots.remote)?;
            Ok((Some(local.clone()), crate::merge::has_conflicts(&file)))
        }
        Operation::Remove => Ok((None, false)),
        Operation::SyncRules => unreachable!("扫描规则单独准备"),
    }
}
