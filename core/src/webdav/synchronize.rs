//! 获取完整远端快照后逐文件重放，最后由 OrgRepo 统一提交本地仓库和基线。
use super::remote_base::Store;
use super::transaction::{self, Plan};
use super::*;
use std::path::Path;

struct Prepared {
    path: String,
    before: Option<Vec<u8>>,
    remote: Option<Vec<u8>>,
    result: Option<Vec<u8>>,
    version: RemoteFileVersion,
    action: OrgRepoSyncFileAction,
    conflicts: bool,
    remote_deleted: bool,
    deleted_source: Option<Vec<u8>>,
    outcome: OrgRepoSyncFileOutcome,
}
fn missing_version() -> RemoteFileVersion {
    RemoteFileVersion {
        etag: None,
        modified_at: None,
        size: None,
    }
}
fn core_error(error: CoreError) -> OrgRepoSyncErrorSummary {
    OrgRepoSyncErrorSummary::new(
        if matches!(error, CoreError::Store(_)) {
            OrgRepoSyncErrorCategory::LocalStorage
        } else {
            OrgRepoSyncErrorCategory::Validation
        },
        false,
        error.to_string(),
    )
    .unwrap()
}
fn strong(etag: Option<&str>) -> Option<&str> {
    etag.filter(|s| !s.trim().is_empty() && !s.starts_with("W/"))
}

impl WebDavSyncPolicy {
    pub(super) async fn synchronize_snapshot(
        &self,
        context: &mut SyncContext<'_>,
        cancellation: &SyncCancellation,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>, CoreError> {
        let repo = &*context.repo;
        let root = Path::new(&repo.root_directory);
        let mut record = OrgRepoSyncRecord::new(
            format!("webdav-{}-{}", repo.id, context.started_at),
            context.started_at,
        )?
        .with_kind(Self::KIND)
        .with_context_detail(WebDavSyncContextDetail { format_version: 4 });
        self.report(WebDavSyncEvent::Started {
            repo_id: repo.id.clone(),
        });
        if cancellation.is_cancelled() {
            return self.finish_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
        }
        progress.report("Listing", 0, 0, None);
        self.report(WebDavSyncEvent::ListingStarted);
        let remotes = match runtime::list_remote_tree(
            &self.client,
            &self.username,
            &self.password,
            &self.endpoint,
            &context.options,
            progress,
            self.monitor.as_ref(),
        )
        .await
        {
            Ok(files) => files,
            Err(_) => return self.finish_snapshot(record, OrgRepoSyncResult::Failed, progress),
        };
        let mut remote_by_path = BTreeMap::new();
        for remote in remotes {
            if !context.options.excludes_path(&remote.path)
                && remote_by_path.insert(remote.path.clone(), remote).is_some()
            {
                return Err(CoreError::InvalidState("WebDAV 列举返回重复文件"));
            }
        }
        self.report(WebDavSyncEvent::Listed {
            files: remote_by_path.len(),
        });
        let origin = LocalFileVersion::from_bytes(
            &serde_json::to_vec(&(
                &self.endpoint.base_url.trim_end_matches('/'),
                &self.username,
            ))
            .unwrap(),
        )
        .content_hash;
        let mut bases = Store::load(root, &origin).await?;
        let history = repo.sync_history::<Self>().await?;
        // 旧基线只从可信完整原文恢复；失败／未上传解决结果不伪装成已确认远端。
        for previous in history.iter().rev() {
            if previous.context_detail.format_version >= 4
                && previous.result != Some(OrgRepoSyncResult::Succeeded)
            {
                continue;
            }
            for file in &previous.files {
                if file.state != OrgRepoSyncFileState::Synchronized
                    && !(previous.context_detail.format_version >= 4
                        && file.detail.synced_source.is_some())
                {
                    continue;
                }
                if bases.state(&file.relative_path).is_some() {
                    continue;
                }
                let source = file
                    .detail
                    .synced_source
                    .as_ref()
                    .map(|s| s.as_bytes().to_vec());
                if let Some(bytes) = &source {
                    if file.local_version.as_ref() != Some(&LocalFileVersion::from_bytes(bytes)) {
                        return Err(CoreError::InvalidState("历史远端快照与文件版本不一致"));
                    }
                } else if file.local_version.is_some() {
                    continue;
                }
                bases.migrate(
                    file.relative_path.clone(),
                    source,
                    file.detail.clone().into(),
                );
            }
        }
        let mut paths = repo
            .files
            .iter()
            .map(|f| f.path.clone())
            .collect::<BTreeSet<_>>();
        paths.extend(remote_by_path.keys().cloned());
        paths.extend(bases.paths().cloned());
        paths.extend(
            repo.pending_writes()
                .await?
                .into_iter()
                .map(|i| i.relative_path),
        );
        paths.retain(|p| !context.options.excludes_path(p) && !p.starts_with(".sync/"));
        let mut paths = paths.into_iter().collect::<Vec<_>>();
        if let Some(index) = paths
            .iter()
            .position(|p| p == crate::model::TASK_SCAN_RULES_PATH)
        {
            paths.swap(0, index);
        }
        let total = paths.len();
        let mut prepared = Vec::new();
        // 下载和解析全部远端文件后才发送修改远端的请求，减少准备失败的远端副作用。
        let mut snapshots = BTreeMap::<String, Option<Vec<u8>>>::new();
        let mut local_sources = BTreeMap::<String, Option<Vec<u8>>>::new();
        for (index, path) in paths.iter().cloned().enumerate() {
            if cancellation.is_cancelled() {
                return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
            }
            progress.report("Downloading", index, total, Some(path.clone()));
            self.report(WebDavSyncEvent::FileStarted {
                path: path.clone(),
                index,
                total,
            });
            let before = transaction::read(root, &path).await?;
            if path.ends_with(".org")
                && repo
                    .files
                    .iter()
                    .find(|f| f.path == path)
                    .map(|f| f.source_bytes())
                    != before.as_deref()
            {
                return Err(CoreError::InvalidState(
                    "同步准备期间本地文件已变化，请重试",
                ));
            }
            let baseline = bases.state(&path).cloned();
            let listed = remote_by_path.get(&path);
            let remote = if let Some(remote) = listed {
                let cached = bases
                    .version(&path)
                    .and_then(|v| strong(v.etag.as_deref()))
                    .is_some_and(|etag| Some(etag) == strong(remote.version.etag.as_deref()))
                    && baseline.as_ref().and_then(|b| b.as_ref()).is_some_and(|b| {
                        remote
                            .version
                            .size
                            .is_none_or(|size| size == b.len() as i64)
                    });
                if cached {
                    baseline.clone().flatten()
                } else {
                    match runtime::get_remote(
                        &self.client,
                        &self.username,
                        &self.password,
                        &self.endpoint,
                        &path,
                        remote.version.etag.as_deref(),
                        progress,
                        self.monitor.as_ref(),
                    )
                    .await
                    {
                        Ok(bytes) => Some(bytes),
                        Err(error) => {
                            record.append_file(failed_record(
                                repo,
                                path,
                                LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                                transfer_failure(error),
                            ))?;
                            return self.abort_snapshot(
                                record,
                                OrgRepoSyncResult::Failed,
                                progress,
                            );
                        }
                    }
                }
            } else {
                None
            };
            snapshots.insert(path.clone(), remote);
            local_sources.insert(path, before);
        }
        let base_sources = bases.sources();
        for (index, path) in paths.into_iter().enumerate() {
            if cancellation.is_cancelled() {
                return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
            }
            progress.report("Merging", index, total, Some(path.clone()));
            let before = local_sources[&path].clone();
            let baseline = bases.state(&path).cloned();
            let remote = snapshots[&path].clone();
            let mut version = remote_by_path
                .get(&path)
                .map_or_else(missing_version, |r| r.version.clone());
            let result = if path == crate::model::TASK_SCAN_RULES_PATH {
                // 根目录从未存在远端规则时保留用户本地规则，不制造远端删除。
                if remote.is_none() && baseline.is_none() {
                    continue;
                }
                let valid = remote
                    .as_deref()
                    .map(std::str::from_utf8)
                    .transpose()
                    .map_err(|_| CoreError::InvalidInput("远端 .orgzlyignore 必须是 UTF-8"))
                    .and_then(|source| {
                        crate::TaskScanRules::parse(source.unwrap_or_default()).map(|_| ())
                    });
                if let Err(error) = valid {
                    record.append_file(failed_record(
                        repo,
                        path,
                        LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                        core_error(error),
                    ))?;
                    return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                }
                if before != remote && before.is_some() && baseline.as_ref() != Some(&before) {
                    record.append_file(failed_record(
                        repo,
                        path,
                        LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                        core_error(CoreError::InvalidState(
                            "本地 .orgzlyignore 有独立修改，请先统一规则",
                        )),
                    ))?;
                    return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                }
                remote.clone()
            } else {
                let decision = (|| -> Result<Option<Vec<u8>>, CoreError> {
                    if let Some(bytes) = &remote {
                        parse_snapshot(repo, &path, bytes.clone(), &snapshots)?;
                    }
                    match (&baseline, &before, &remote) {
                        // 已跟踪远端删除：无论本地是否修改都采用删除。
                        (Some(Some(_)), _, None) => Ok(None),
                        (Some(Some(base)), None, Some(remote)) if remote == base => Ok(None),
                        (_, None, Some(remote)) => Ok(Some(remote.clone())),
                        (_, Some(local), None) => Ok(Some(local.clone())),
                        (_, None, None) => Ok(None),
                        (base, Some(local), Some(remote)) => {
                            let base = parse_snapshot(
                                repo,
                                &path,
                                base.as_ref()
                                    .and_then(|b| b.as_ref())
                                    .cloned()
                                    .unwrap_or_default(),
                                &base_sources,
                            )?;
                            let local = parse_snapshot(repo, &path, local.clone(), &local_sources)?;
                            let remote = parse_snapshot(repo, &path, remote.clone(), &snapshots)?;
                            crate::merge::merge_files(&base, &local, &remote).map(Some)
                        }
                    }
                })();
                match decision {
                    Ok(result) => result,
                    Err(error) => {
                        record.append_file(failed_record(
                            repo,
                            path,
                            LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                            core_error(error),
                        ))?;
                        return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                    }
                }
            };
            let result = if path.ends_with(".org") {
                result
                    .map(|bytes| {
                        let file = parse_snapshot(repo, &path, bytes, &snapshots)?;
                        crate::merge::with_conflict_header(&file)
                    })
                    .transpose()?
            } else {
                result
            };
            let conflicts = if path.ends_with(".org") {
                result
                    .as_ref()
                    .map(|bytes| {
                        parse_snapshot(repo, &path, bytes.clone(), &snapshots)
                            .map(|f| crate::merge::has_conflicts(&f))
                    })
                    .transpose()?
                    .unwrap_or(false)
            } else {
                false
            };
            let local_changed = match &baseline {
                Some(Some(base)) => before.as_ref() != Some(base),
                Some(None) => before.is_some(),
                None => before.is_some(),
            };
            let remote_changed = match &baseline {
                Some(Some(base)) => remote.as_ref() != Some(base),
                Some(None) => remote.is_some(),
                None => remote.is_some(),
            };
            let remote_deleted =
                remote.is_none() && baseline.as_ref().is_some_and(|base| base.is_some());
            let deleted_source = if remote_deleted {
                before.clone().or_else(|| baseline.clone().flatten())
            } else {
                None
            };
            let action = if result.is_none() {
                if before.is_none() && remote.is_none() {
                    OrgRepoSyncFileAction::Unchanged
                } else {
                    OrgRepoSyncFileAction::Deleted
                }
            } else if path == crate::model::TASK_SCAN_RULES_PATH {
                if before == result {
                    OrgRepoSyncFileAction::Unchanged
                } else {
                    OrgRepoSyncFileAction::Downloaded
                }
            } else if result != remote {
                if remote.is_some() {
                    OrgRepoSyncFileAction::Uploaded
                } else {
                    OrgRepoSyncFileAction::Created
                }
            } else if result != before {
                OrgRepoSyncFileAction::Downloaded
            } else {
                OrgRepoSyncFileAction::Unchanged
            };
            let outcome = if conflicts {
                OrgRepoSyncFileOutcome::Conflict
            } else if result.is_none() && (before.is_some() || remote.is_some() || remote_deleted) {
                OrgRepoSyncFileOutcome::Deleted
            } else if result.is_none() {
                OrgRepoSyncFileOutcome::Unchanged
            } else if baseline.as_ref().is_none_or(|base| base.is_none())
                && (before.is_none() || remote.is_none())
            {
                OrgRepoSyncFileOutcome::Created
            } else if before.is_none() && remote.is_some() && !local_changed {
                OrgRepoSyncFileOutcome::Updated
            } else if remote_changed && local_changed {
                OrgRepoSyncFileOutcome::Merged
            } else if remote_changed {
                OrgRepoSyncFileOutcome::Updated
            } else if local_changed {
                OrgRepoSyncFileOutcome::Uploaded
            } else {
                OrgRepoSyncFileOutcome::Unchanged
            };
            // 任何需要更新／删除已有远端的计划都先验证条件能力，不能在上传了一半后才发现缺少版本。
            if path.ends_with(".org")
                && result != remote
                && remote.is_some()
                && strong(version.etag.as_deref()).is_none()
            {
                record.append_file(failed_record(
                    repo,
                    path,
                    LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                    core_error(CoreError::InvalidState(
                        "远端未提供强 ETag，无法安全更新或删除",
                    )),
                ))?;
                return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
            }
            if remote.is_none() {
                version = missing_version();
            }
            prepared.push(Prepared {
                path,
                before,
                remote,
                result,
                version,
                action,
                conflicts,
                remote_deleted,
                deleted_source,
                outcome,
            });
        }
        let mut plan = Plan::default();
        bases.guard(&mut plan);
        for item in &prepared {
            plan.guards.push((item.path.clone(), item.before.clone()));
        }
        plan.verify(root).await?;
        for (index, item) in prepared.iter_mut().enumerate() {
            if cancellation.is_cancelled() {
                return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
            }
            progress.report("Synchronizing", index, total, Some(item.path.clone()));
            if item.path.ends_with(".org") && item.result != item.remote {
                let transfer = if let Some(bytes) = &item.result {
                    let condition = if item.remote.is_some() {
                        WebDavPutCondition::Match(item.version.etag.clone().unwrap())
                    } else {
                        WebDavPutCondition::CreateOnly
                    };
                    runtime::put_remote(
                        &self.client,
                        &self.username,
                        &self.password,
                        &self.endpoint,
                        &item.path,
                        bytes,
                        condition,
                        progress,
                        self.monitor.as_ref(),
                    )
                    .await
                } else {
                    runtime::delete_remote(
                        &self.client,
                        &self.username,
                        &self.password,
                        &self.endpoint,
                        &item.path,
                        item.version.etag.as_deref().unwrap(),
                        progress,
                        self.monitor.as_ref(),
                    )
                    .await
                    .map(|()| missing_version())
                };
                match transfer {
                    Ok(version) => item.version = version,
                    Err(error) => {
                        record.append_file(failed_record(
                            repo,
                            item.path.clone(),
                            LocalFileVersion::from_bytes(
                                item.before.as_deref().unwrap_or_default(),
                            ),
                            transfer_failure(error),
                        ))?;
                        return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                    }
                }
            }
            let mut detail = WebDavSyncFileDetail::from(item.version.clone());
            detail.synced_source = item
                .result
                .as_deref()
                .map(|b| String::from_utf8(b.to_vec()).expect("已校验 UTF-8"));
            if item.conflicts {
                let bytes = item
                    .result
                    .as_ref()
                    .ok_or(CoreError::InvalidState("任务冲突必须包含合并后的文件内容"))?;
                let archive_path = format!(
                    ".sync/history/{}/conflicts/{}/{}",
                    record.started_at,
                    item.path,
                    super::archive::archive_name(&item.path, false)?
                );
                plan.set(root, archive_path, Some(bytes.clone())).await?;
                detail.archive = Some(super::WebDavFileArchive {
                    content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
                });
            }
            if item.remote_deleted {
                let bytes = item
                    .deleted_source
                    .as_ref()
                    .ok_or(CoreError::InvalidState("远端删除缺少可备份原文"))?;
                let archive_path = format!(
                    ".sync/history/{}/deleted/{}/{}",
                    record.started_at,
                    item.path,
                    super::archive::archive_name(&item.path, false)?
                );
                plan.set(root, archive_path, Some(bytes.clone())).await?;
                detail.deleted_archive = Some(super::WebDavFileArchive {
                    content_hash: LocalFileVersion::from_bytes(bytes).content_hash,
                });
            }
            let file = OrgRepoSyncFileRecord::new(
                item.path.clone(),
                item.action,
                if item.conflicts {
                    OrgRepoSyncFileState::Conflict
                } else {
                    OrgRepoSyncFileState::Synchronized
                },
            )?
            .with_local_version(item.result.as_deref().map(LocalFileVersion::from_bytes))
            .with_detail(detail)
            .with_outcome(item.outcome);
            record.append_file(file.clone())?;
            let mut event = file;
            event.detail.synced_source = None;
            self.report(WebDavSyncEvent::FileProcessed { record: event });
        }
        if cancellation.is_cancelled() {
            return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
        }
        for item in &prepared {
            if item.before != item.result {
                plan.set(root, item.path.clone(), item.result.clone())
                    .await?;
            }
            bases
                .stage(
                    root,
                    &item.path,
                    item.result.clone(),
                    item.version.clone(),
                    &record.id,
                    &mut plan,
                )
                .await?;
        }
        bases.finish(root, &mut plan).await?;
        // outbox 确认与正式文件、基线及完成历史同属一个本地事务。
        let intents = root.join(".sync/outbox");
        if let Ok(mut entries) = tokio::fs::read_dir(&intents).await {
            while let Some(entry) = entries
                .next_entry()
                .await
                .map_err(|e| CoreError::Store(format!("无法读取待上传意图: {e}")))?
            {
                if !entry
                    .file_type()
                    .await
                    .map_err(|e| CoreError::Store(e.to_string()))?
                    .is_file()
                    || entry.path().extension().and_then(|e| e.to_str()) != Some("json")
                {
                    continue;
                }
                let relative = format!(".sync/outbox/{}", entry.file_name().to_string_lossy());
                let source = transaction::read(root, &relative)
                    .await?
                    .ok_or(CoreError::InvalidState("写入意图在同步期间消失"))?;
                let intent: crate::OrgRepoWriteIntent = serde_json::from_slice(&source)
                    .map_err(|_| CoreError::Store("写入意图无效".into()))?;
                if prepared.iter().any(|p| p.path == intent.relative_path) {
                    plan.set(root, relative, None).await?;
                }
            }
        }
        let mut snapshot = repo.clone();
        let mut final_sources = local_sources.clone();
        for item in &prepared {
            final_sources.insert(item.path.clone(), item.result.clone());
        }
        for item in &prepared {
            if item.path == crate::model::TASK_SCAN_RULES_PATH {
                snapshot.task_scan_rules = crate::TaskScanRules::parse(
                    item.result
                        .as_deref()
                        .map(std::str::from_utf8)
                        .transpose()
                        .map_err(|_| CoreError::InvalidInput("忽略规则编码无效"))?
                        .unwrap_or_default(),
                )?;
            } else {
                snapshot.files.retain(|f| f.path != item.path);
                if let Some(bytes) = &item.result {
                    snapshot.files.push(parse_snapshot(
                        repo,
                        &item.path,
                        bytes.clone(),
                        &final_sources,
                    )?);
                }
            }
        }
        plan.snapshot = Some(snapshot);
        plan.verify(root).await?;
        transaction::stage(root, context.started_at, plan)?;
        self.finish_snapshot(record, OrgRepoSyncResult::Succeeded, progress)
    }
    fn abort_snapshot(
        &self,
        mut record: OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
        result: OrgRepoSyncResult,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>, CoreError> {
        for file in &mut record.files {
            if file.state != OrgRepoSyncFileState::Failed {
                file.state = OrgRepoSyncFileState::Failed;
                file.detail.synced_source = None;
                file.error = Some(OrgRepoSyncErrorSummary::new(
                    OrgRepoSyncErrorCategory::LocalStorage,
                    true,
                    "本轮同步未提交本地仓库和远端基线".into(),
                )?);
            }
        }
        self.finish_snapshot(record, result, progress)
    }
    fn finish_snapshot(
        &self,
        mut record: OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
        result: OrgRepoSyncResult,
        progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>, CoreError> {
        record.finish(result, finished_at()?)?;
        progress.report("Finished", record.files.len(), record.files.len(), None);
        self.report(WebDavSyncEvent::Finished {
            result,
            files: record.files.len(),
        });
        Ok(record)
    }
}

// SETUPFILE 是只读的文件语义上下文；读取对应 B/L/R 快照，绝不为解析先写回仓库。
fn parse_snapshot(
    repo: &OrgRepo,
    path: &str,
    bytes: Vec<u8>,
    sources: &BTreeMap<String, Option<Vec<u8>>>,
) -> Result<OrgFile, CoreError> {
    let mut settings = Vec::new();
    let mut pending = vec![(path.to_string(), bytes.clone())];
    let mut seen = BTreeSet::new();
    while let Some((current, source)) = pending.pop() {
        for line in String::from_utf8_lossy(&source).lines() {
            let trimmed = line.trim();
            let lower = trimmed.to_ascii_lowercase();
            if lower.starts_with("#+todo:")
                || lower.starts_with("#+seq_todo:")
                || lower.starts_with("#+typ_todo:")
            {
                settings.push(trimmed.to_string());
                continue;
            }
            if !lower.starts_with("#+setupfile:") {
                continue;
            }
            let value = trimmed.get(12..).unwrap_or_default().trim();
            let value = value.strip_prefix("file:").unwrap_or(value);
            let setup = std::path::Path::new(value);
            if setup.is_absolute()
                || setup
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                continue;
            }
            let joined = std::path::Path::new(&current)
                .parent()
                .unwrap_or_else(|| std::path::Path::new(""))
                .join(setup);
            let normalized = joined
                .components()
                .filter(|c| !matches!(c, std::path::Component::CurDir))
                .collect::<std::path::PathBuf>()
                .to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/");
            if normalized.split('/').any(|p| p == ".sync") || !seen.insert(normalized.clone()) {
                continue;
            }
            if let Some(Some(source)) = sources.get(&normalized) {
                pending.push((normalized, source.clone()));
            }
        }
    }
    if settings.is_empty() {
        if let Some(previous) = repo.files.iter().find(|f| f.path == path) {
            let references = |source: &[u8]| {
                String::from_utf8_lossy(source)
                    .lines()
                    .filter(|line| line.trim().to_ascii_lowercase().starts_with("#+setupfile:"))
                    .map(|line| line.trim().to_string())
                    .collect::<Vec<_>>()
            };
            if references(previous.source_bytes()) == references(&bytes) {
                settings.push(previous.todo_setup.clone());
            }
        }
    }
    repo.parse_file_with_setup(path.into(), bytes, settings.join("\n"))
}
