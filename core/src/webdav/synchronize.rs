//! 先独立发布远端快照，再按旧共同祖先合并；工作文件与合并进度最后统一提交。
use super::remote_base::{Store, Update};
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
        let repo = context.repo.clone();
        let root_directory = repo.root_directory.clone();
        let root = Path::new(&root_directory);
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
        let download_guard = super::session::enter(root, &repo.id, context.started_at,
            super::session::Phase::Downloading).await?;
        let mut files = repo.load_files_unlocked(&[]).await?;
        let origin = LocalFileVersion::from_bytes(
            &serde_json::to_vec(&(
                &self.endpoint.base_url.trim_end_matches('/'),
                &self.username,
            ))
            .unwrap(),
        )
        .content_hash;
        let mut bases = Store::load(root, &origin).await?;
        bases.cleanup(root).await?;
        let mut paths = files.iter()
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
        for path in &paths {
            local_sources.insert(path.clone(), transaction::read(root, path).await?);
        }
        drop(download_guard);
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
            let before = local_sources[&path].clone();
            let baseline = bases.remote_state(&path).cloned();
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
                        Ok((bytes, version)) => {
                            remote_by_path.get_mut(&path).expect("已列举远端文件").version = version;
                            Some(bytes)
                        }
                        Err(error) => {
                            record.append_file(failed_record(
                                &repo,
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
            if let Some(bytes) = &remote {
                super::session::stage(root, &repo.id, context.started_at, "remote", &path, bytes).await?;
            }
            snapshots.insert(path.clone(), remote);
        }
        let remote_manifest = paths.iter().map(|path| serde_json::json!({
            "path": path, "present": snapshots[path].is_some(),
            "version": remote_by_path.get(path).map(|file| &file.version),
        })).collect::<Vec<_>>();
        super::session::stage(root, &repo.id, context.started_at, "metadata", "remote.json",
            &serde_json::to_vec(&remote_manifest).map_err(|_| CoreError::InvalidState("无法编码远端下载清单"))?).await?;
        if cancellation.is_cancelled() {
            return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
        }
        let remote = bases.prepare_remote(root, paths.iter().map(|path| Update {
            path: path.clone(), bytes: snapshots[path].clone(),
            version: remote_by_path.get(path).map_or_else(missing_version, |r| r.version.clone()),
            sync_id: record.id.clone(),
        }).collect()).await?;
        let publish_guard = super::session::enter(root, &repo.id, context.started_at,
            super::session::Phase::Publishing).await?;
        bases.publish(root, remote).await?;
        drop(publish_guard);
        let merge_guard = super::session::enter(root, &repo.id, context.started_at,
            super::session::Phase::Merging).await?;
        // 网络阶段允许普通编辑；合并必须重新取得当前磁盘内容。
        files = repo.load_files_unlocked(&[]).await?;
        for file in &files {
            if !context.options.excludes_path(&file.path) && !paths.contains(&file.path) {
                paths.push(file.path.clone());
                snapshots.insert(file.path.clone(), None);
            }
        }
        for path in &paths {
            local_sources.insert(path.clone(), transaction::read(root, path).await?);
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
                        &repo,
                        path,
                        LocalFileVersion::from_bytes(before.as_deref().unwrap_or_default()),
                        core_error(error),
                    ))?;
                    return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                }
                if before != remote && before.is_some() && baseline.as_ref() != Some(&before) {
                    record.append_file(failed_record(
                        &repo,
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
                        parse_snapshot(&repo, &path, bytes.clone(), &snapshots, &files)?;
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
                                &repo,
                                &path,
                                base.as_ref()
                                    .and_then(|b| b.as_ref())
                                    .cloned()
                                    .unwrap_or_default(),
                                &base_sources,
                                &files,
                            )?;
                            let local = parse_snapshot(&repo, &path, local.clone(), &local_sources, &files)?;
                            let remote = parse_snapshot(&repo, &path, remote.clone(), &snapshots, &files)?;
                            crate::merge::merge_files(&base, &local, &remote).map(Some)
                        }
                    }
                })();
                match decision {
                    Ok(result) => result,
                    Err(error) => {
                        record.append_file(failed_record(
                            &repo,
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
                        let file = parse_snapshot(&repo, &path, bytes, &snapshots, &files)?;
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
                        parse_snapshot(&repo, &path, bytes.clone(), &snapshots, &files)
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
                    &repo,
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
        for item in &prepared {
            plan.guards.push((item.path.clone(), item.before.clone()));
        }
        plan.verify(root).await?;
        let captured_intents = capture_intents(root).await?;
        for (path, bytes, _) in &captured_intents { plan.guards.push((path.clone(), Some(bytes.clone()))); }
        for item in &prepared {
            if let Some(bytes) = &item.result {
                super::session::stage(root, &repo.id, context.started_at, "merged", &item.path, bytes).await?;
            }
        }
        drop(merge_guard);
        // 上传与下载一样不占仓库锁；同步租约由外层操作一直持有。
        let upload_guard = super::session::enter(root, &repo.id, context.started_at,
            super::session::Phase::Uploading).await?;
        drop(upload_guard);
        let mut archives = Vec::new();
        for (index, item) in prepared.iter_mut().enumerate() {
            if cancellation.is_cancelled() {
                return self.abort_snapshot(record, OrgRepoSyncResult::Cancelled, progress);
            }
            progress.report("Synchronizing", index, total, Some(item.path.clone()));
            if item.path.ends_with(".org") && item.result != item.remote {
                super::session::stage(root, &repo.id, context.started_at, "requests", &format!("{index}.json"),
                    &serde_json::to_vec(&serde_json::json!({"path":item.path,"confirmed":false,
                        "deletion":item.result.is_none(),"expectedEtag":item.version.etag}))
                        .map_err(|_| CoreError::InvalidState("无法编码同步请求意图"))?).await?;
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
                    Ok(version) => {
                        let (confirmed, version) = if item.result.is_some() && strong(version.etag.as_deref()).is_none() {
                            // PUT 没有强版本时回读实际正文，不能给请求正文套用列举或旧基线的 ETag。
                            match runtime::get_remote(&self.client, &self.username, &self.password,
                                &self.endpoint, &item.path, None, progress, self.monitor.as_ref()).await {
                                Ok((bytes, version)) => (Some(bytes), version),
                                Err(error) => {
                                    record.append_file(failed_record(&repo, item.path.clone(),
                                        LocalFileVersion::from_bytes(item.before.as_deref().unwrap_or_default()),
                                        transfer_failure(error)))?;
                                    return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                                }
                            }
                        } else { (item.result.clone(), version) };
                        super::session::stage(root, &repo.id, context.started_at, "requests", &format!("{index}.json"),
                            &serde_json::to_vec(&serde_json::json!({"path":item.path,"confirmed":true,
                                "deletion":item.result.is_none(),"version":version}))
                                .map_err(|_| CoreError::InvalidState("无法编码同步请求结果"))?).await?;
                        item.version = version;
                        // 远端写入已确认，立即发布；后续文件或本地提交失败不能撤回这个事实。
                        let remote = bases.prepare_remote(root, vec![Update {
                            path: item.path.clone(), bytes: confirmed.clone(),
                            version: item.version.clone(), sync_id: record.id.clone(),
                        }]).await?;
                        let publish_guard = super::session::enter(root, &repo.id, context.started_at,
                            super::session::Phase::Publishing).await?;
                        bases.publish(root, remote).await?;
                        drop(publish_guard);
                        if confirmed != item.result {
                            record.append_file(failed_record(&repo, item.path.clone(),
                                LocalFileVersion::from_bytes(item.before.as_deref().unwrap_or_default()),
                                transfer_failure(WebDavError::Conflict("上传后远端内容已变化，请重新同步".into()))))?;
                            return self.abort_snapshot(record, OrgRepoSyncResult::Failed, progress);
                        }
                    }
                    Err(error) => {
                        record.append_file(failed_record(
                            &repo,
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
                archives.push((archive_path, bytes.clone()));
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
                archives.push((archive_path, bytes.clone()));
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
        let commit_guard = super::session::enter(root, &repo.id, context.started_at,
            super::session::Phase::Committing).await?;
        plan.verify(root).await?;
        for (path, bytes) in archives { plan.set(root, path, Some(bytes)).await?; }
        for item in &prepared {
            if item.before != item.result {
                plan.set(root, item.path.clone(), item.result.clone())
                    .await?;
            }
        }
        bases.stage_applied(root, &prepared.iter().map(|item| item.path.clone()).collect::<Vec<_>>(), &mut plan).await?;
        // outbox 确认与正式文件、基线及完成历史同属一个本地事务。
        for (relative, _, intent) in captured_intents {
            if prepared.iter().any(|item| item.path == intent.relative_path
                && item.before.as_deref().map(LocalFileVersion::from_bytes)
                    .is_some_and(|version| version.content_hash == intent.content_hash)) {
                plan.set(root, relative, None).await?;
            }
        }
        plan.verify(root).await?;
        transaction::stage(root, context.started_at, plan)?;
        drop(commit_guard);
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
                    "本轮同步未提交本地合并，已确认的远端基线保留".into(),
                )?);
            }
        }
        self.finish_snapshot(record, result, progress)
    }
    fn finish_snapshot(
        &self,
        mut record: OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
        result: OrgRepoSyncResult,
        _progress: &SyncProgressReporter,
    ) -> Result<OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>, CoreError> {
        record.finish(result, finished_at()?)?;
        Ok(record)
    }
}

// SETUPFILE 是只读的文件语义上下文；读取对应 B/L/R 快照，绝不为解析先写回仓库。
fn parse_snapshot(
    repo: &OrgRepo,
    path: &str,
    bytes: Vec<u8>,
    sources: &BTreeMap<String, Option<Vec<u8>>>,
    files: &[OrgFile],
) -> Result<OrgFile, CoreError> {
    let mut settings = Vec::new();
    let mut pending = vec![(path.to_string(), bytes.clone())];
    let mut seen = BTreeSet::new();
    while let Some((current, source)) = pending.pop() {
        for (key, value) in crate::model::service::file_keywords(&source)? {
            if matches!(key.as_str(), "TODO" | "SEQ_TODO" | "TYP_TODO") {
                settings.push(format!("#+{key}: {value}"));
                continue;
            }
            if key != "SETUPFILE" { continue; }
            let value = value.strip_prefix("file:").unwrap_or(&value);
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
        if let Some(previous) = files.iter().find(|f| f.path == path) {
            let references = |source: &[u8]| -> Result<Vec<String>, CoreError> {
                Ok(crate::model::service::file_keywords(source)?.into_iter()
                    .filter(|(key, _)| key == "SETUPFILE").map(|(_, value)| value).collect())
            };
            if references(previous.source_bytes())? == references(&bytes)? {
                settings.push(previous.todo_setup.clone());
            }
        }
    }
    repo.parse_file_with_setup(path.into(), bytes, settings.join("\n"))
}

// 只确认合并准备阶段已存在的意图，网络期间的新意图留待后续同步。
async fn capture_intents(root: &Path) -> Result<Vec<(String, Vec<u8>, crate::OrgRepoWriteIntent)>, CoreError> {
    let mut result = Vec::new();
    let mut entries = match tokio::fs::read_dir(root.join(".sync/outbox")).await {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(result),
        Err(error) => return Err(CoreError::Store(format!("无法读取待上传意图: {error}"))),
    };
    while let Some(entry) = entries.next_entry().await.map_err(|error| CoreError::Store(error.to_string()))? {
        if entry.path().extension().and_then(|v| v.to_str()) != Some("json") { continue; }
        let name = entry.file_name().into_string().map_err(|_| CoreError::InvalidState("意图文件名编码无效"))?;
        let path = format!(".sync/outbox/{name}");
        let bytes = transaction::read(root, &path).await?.ok_or(CoreError::InvalidState("意图文件已消失"))?;
        let intent = serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidState("待上传意图无效"))?;
        result.push((path, bytes, intent));
    }
    Ok(result)
}
