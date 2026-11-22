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

pub(super) fn groups(
    snapshots: &Snapshots,
    paths: &[String],
    options: &crate::SyncOptions,
) -> Result<Vec<Comparison>, FileError> {
    let mut by_id = BTreeMap::<String, Group>::new();
    let mut by_path = BTreeMap::<String, String>::new();
    let mut unnamed = Vec::new();
    for (side, sources) in [&snapshots.base, &snapshots.local, &snapshots.remote]
        .into_iter()
        .enumerate()
    {
        for path in paths {
            let Some(bytes) = sources.get(path).and_then(Option::as_deref) else {
                continue;
            };
            let id = file_id(path, bytes).map_err(|error| (path.clone(), error))?;
            let Some(id) = id else {
                unnamed.push((side, path));
                continue;
            };
            if by_path.get(path).is_some_and(|previous| previous != &id) {
                return Err((
                    path.clone(),
                    CoreError::InvalidState("同一路径对应不同的 Org 文件 ID"),
                ));
            }
            by_path.insert(path.clone(), id.clone());
            let group = by_id.entry(id).or_default();
            if group.paths[side].replace(path.clone()).is_some() {
                return Err((
                    path.clone(),
                    CoreError::InvalidState("同一快照有重复的 Org 文件 ID"),
                ));
            }
        }
    }

    let mut path_groups = BTreeMap::<String, Group>::new();
    for (side, path) in unnamed {
        let group = match by_path.get(path) {
            Some(id) => by_id.get_mut(id).expect("路径关联到已有文件 ID"),
            None => path_groups.entry(path.clone()).or_default(),
        };
        if group.paths[side].replace(path.clone()).is_some() {
            return Err((
                path.clone(),
                CoreError::InvalidState("相对路径与 Org 文件 ID 的匹配有歧义"),
            ));
        }
    }
    for path in paths {
        if !by_path.contains_key(path) {
            path_groups.entry(path.clone()).or_default().additional_path = Some(path.clone());
        }
    }
    // 远端未列举的排除目录没有正文。可从本地和共同祖先识别的排除路径
    // 仍可保护对应文件，避免把跨过滤边界的移动解释为删除。
    let mut excluded = BTreeSet::new();
    for file in snapshots
        .files
        .iter()
        .filter(|file| options.excludes_path(&file.path))
    {
        if let Some(id) =
            file_id(&file.path, file.source_bytes()).map_err(|error| (file.path.clone(), error))?
        {
            excluded.insert(id);
        }
    }
    for (path, bytes) in snapshots
        .base
        .iter()
        .filter(|(path, _)| options.excludes_path(path))
    {
        if let Some(bytes) = bytes
            && let Some(id) = file_id(path, bytes).map_err(|error| (path.clone(), error))?
        {
            excluded.insert(id);
        }
    }
    let mut groups = by_id
        .into_iter()
        .filter_map(|(id, group)| (!excluded.contains(&id)).then_some(group))
        .chain(path_groups.into_values())
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| {
        (left.path() != TASK_SCAN_RULES_PATH, left.path())
            .cmp(&(right.path() != TASK_SCAN_RULES_PATH, right.path()))
    });
    groups
        .into_iter()
        .map(|group| {
            let path = group.path().to_owned();
            Comparison::new(group, snapshots).map_err(|error| (path, error))
        })
        .collect()
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
    let (result, conflicts) = if matches!(operation, Operation::SyncRules) {
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
    let mut paths = group
        .paths
        .iter()
        .flatten()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    paths.remove(path);
    // 先写目标，再清理改名前的路径。一个比较组完全拥有这些路径。
    let mut prepared = Vec::with_capacity(paths.len() + 1);
    for destination in std::iter::once(path).chain(paths) {
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
