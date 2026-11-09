//! 同步历史的运行时摘要；不改写已提交记录或保存额外状态。
use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WebDavSyncTransfer {
    Unchanged,
    Download,
    Upload,
    Bidirectional,
}

#[derive(Clone, Debug)]
pub struct WebDavSyncRecordSummary {
    pub id: String,
    pub result: OrgRepoSyncResult,
    pub execution_result: OrgRepoSyncResult,
    pub started_at: TimestampMs,
    pub finished_at: Option<TimestampMs>,
    pub files: usize,
    pub downloaded_files: usize,
    pub uploaded_files: usize,
    pub transfer: WebDavSyncTransfer,
    pub conflicts: Vec<String>,
    pub pending_conflicts: usize,
    pub resolved_conflicts: usize,
    pub error_category: Option<OrgRepoSyncErrorCategory>,
    pub error_message: Option<String>,
}

pub(crate) fn is_conflict(file: &OrgRepoSyncFileRecord<WebDavSyncFileDetail>) -> bool {
    matches!(
        file.state,
        OrgRepoSyncFileState::Conflict | OrgRepoSyncFileState::RemoteDeleted
    ) || file
        .error
        .as_ref()
        .is_some_and(|error| error.category == OrgRepoSyncErrorCategory::Conflict)
}

impl WebDavSyncRecordSummary {
    pub fn from_record(
        record: &OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>,
    ) -> Result<Self, CoreError> {
        let result = record
            .result
            .ok_or(CoreError::InvalidState("同步记录尚未完成"))?;
        let mut downloaded_files = 0;
        let mut uploaded_files = 0;
        let mut conflicts = BTreeSet::new();
        let mut failed = false;
        let mut error_category = None;
        let mut error_message = None;
        for file in &record.files {
            if file.state == OrgRepoSyncFileState::Synchronized {
                // Created 表示远端创建；Deleted 表示采用远端删除并移除本地文件。
                downloaded_files += usize::from(matches!(
                    file.action,
                    OrgRepoSyncFileAction::Downloaded | OrgRepoSyncFileAction::Deleted
                ));
                uploaded_files += usize::from(matches!(
                    file.action,
                    OrgRepoSyncFileAction::Uploaded | OrgRepoSyncFileAction::Created
                ));
            }
            if is_conflict(file) {
                conflicts.insert(file.relative_path.clone());
            }
            let error = file
                .error
                .as_ref()
                .filter(|error| error.category != OrgRepoSyncErrorCategory::Conflict);
            if error.is_some() || (file.state == OrgRepoSyncFileState::Failed && !is_conflict(file))
            {
                failed = true;
                if error_category.is_none() {
                    error_category = error.map(|error| error.category.clone());
                }
                if error_message.is_none() {
                    error_message = error.map(|error| error.message.clone());
                }
            }
        }
        let execution_result =
            if result == OrgRepoSyncResult::Failed && !failed && !conflicts.is_empty() {
                OrgRepoSyncResult::Succeeded
            } else {
                result
            };
        Ok(Self {
            id: record.id.clone(),
            result,
            execution_result,
            started_at: record.started_at,
            finished_at: record.finished_at,
            files: record.files.len(),
            downloaded_files,
            uploaded_files,
            transfer: match (downloaded_files > 0, uploaded_files > 0) {
                (false, false) => WebDavSyncTransfer::Unchanged,
                (true, false) => WebDavSyncTransfer::Download,
                (false, true) => WebDavSyncTransfer::Upload,
                (true, true) => WebDavSyncTransfer::Bidirectional,
            },
            pending_conflicts: conflicts.len(),
            conflicts: conflicts.into_iter().collect(),
            resolved_conflicts: 0,
            error_category,
            error_message,
        })
    }
}

/// 历史按开始时间升序传入；resolved 由仓库按该次日志的结果文件填入。
pub fn sync_history_summaries(
    history: &[OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>],
) -> Result<Vec<WebDavSyncRecordSummary>, CoreError> {
    let mut summaries = Vec::with_capacity(history.len());
    for record in history.iter().rev() {
        let mut summary = WebDavSyncRecordSummary::from_record(record)?;
        summary.resolved_conflicts = summary
            .conflicts
            .iter()
            .filter(|path| record.files.iter().any(|f| &f.relative_path == *path && f.detail.resolved))
            .count();
        summary.pending_conflicts -= summary.resolved_conflicts;
        summaries.push(summary);

    }
    summaries.reverse();
    Ok(summaries)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WebDavSyncFileOutcome {
    Unchanged,
    Downloaded,
    Uploaded,
    Created,
    Deleted,
    Conflict,
    Resolved,
    Failed,
    Skipped,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavSyncFileSummary {
    pub path: String,
    pub outcome: WebDavSyncFileOutcome,
    pub section: Option<String>,
    pub backup: Option<crate::OrgFileMetadata>,
}

#[derive(Clone, Debug, Serialize)]
pub struct WebDavSyncHistoryError {
    pub path: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct WebDavSyncRecordDetail {
    pub summary: WebDavSyncRecordSummary,
    pub files: Vec<WebDavSyncFileSummary>,
    pub errors: Vec<WebDavSyncHistoryError>,
}

/// 详情只按当前仓库的历史 ID 定位，不返回正文快照、版本哈希或远端地址。
pub fn sync_history_detail(
    history: &[OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail>],
    sync_id: &str,
) -> Result<WebDavSyncRecordDetail, CoreError> {
    let index = history
        .iter()
        .position(|record| record.id == sync_id)
        .ok_or(CoreError::InvalidInput(
            "此同步记录已不存在，请返回日志列表",
        ))?;
    let summary = sync_history_summaries(history)?.swap_remove(index);
    let record = &history[index];
    let files = record
        .files
        .iter()
        .map(|file| {
            let outcome = if is_conflict(file) {
                if file.detail.resolved {
                    WebDavSyncFileOutcome::Resolved
                } else {
                    WebDavSyncFileOutcome::Conflict
                }
            } else if file.state == OrgRepoSyncFileState::Failed {
                WebDavSyncFileOutcome::Failed
            } else {
                match file.action {
                    OrgRepoSyncFileAction::Unchanged => WebDavSyncFileOutcome::Unchanged,
                    OrgRepoSyncFileAction::Downloaded => WebDavSyncFileOutcome::Downloaded,
                    OrgRepoSyncFileAction::Uploaded => WebDavSyncFileOutcome::Uploaded,
                    OrgRepoSyncFileAction::Created => WebDavSyncFileOutcome::Created,
                    OrgRepoSyncFileAction::Deleted => WebDavSyncFileOutcome::Deleted,
                    OrgRepoSyncFileAction::Conflicted => WebDavSyncFileOutcome::Conflict,
                    OrgRepoSyncFileAction::Skipped => WebDavSyncFileOutcome::Skipped,
                }
            };
            WebDavSyncFileSummary {
                path: file.relative_path.clone(),
                outcome,
                section: None,
                backup: None,
            }
        })
        .collect();
    let mut errors = Vec::new();
    for file in &record.files {
        if let Some(error) = file
            .error
            .as_ref()
            .filter(|error| error.category != OrgRepoSyncErrorCategory::Conflict)
        {
            errors.push(WebDavSyncHistoryError {
                path: Some(file.relative_path.clone()),
                message: error.message.clone(),
            });
        }
    }
    Ok(WebDavSyncRecordDetail {
        summary,
        files,
        errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_record(
        id: &str,
        result: OrgRepoSyncResult,
        files: Vec<OrgRepoSyncFileRecord<WebDavSyncFileDetail>>,
    ) -> OrgRepoSyncRecord<WebDavSyncContextDetail, WebDavSyncFileDetail> {
        let mut record = OrgRepoSyncRecord::new(id.into(), 1).unwrap();
        record.files = files;
        record.finish(result, 2).unwrap();
        record
    }

    fn file(
        path: &str,
        action: OrgRepoSyncFileAction,
        state: OrgRepoSyncFileState,
    ) -> OrgRepoSyncFileRecord<WebDavSyncFileDetail> {
        OrgRepoSyncFileRecord::new(path.into(), action, state).unwrap()
    }

    #[test]
    fn transfer_counts_successful_directions_including_remote_creation_and_local_deletion() {
        use OrgRepoSyncFileAction::*;
        use OrgRepoSyncFileState::*;
        for (actions, expected) in [
            (vec![], WebDavSyncTransfer::Unchanged),
            (vec![Unchanged, Skipped], WebDavSyncTransfer::Unchanged),
            (vec![Downloaded, Deleted], WebDavSyncTransfer::Download),
            (vec![Uploaded, Created], WebDavSyncTransfer::Upload),
            (vec![Downloaded, Created], WebDavSyncTransfer::Bidirectional),
        ] {
            let record = make_record(
                "sync",
                OrgRepoSyncResult::Succeeded,
                actions
                    .into_iter()
                    .map(|action| file("a.org", action, Synchronized))
                    .collect(),
            );
            assert_eq!(
                WebDavSyncRecordSummary::from_record(&record)
                    .unwrap()
                    .transfer,
                expected
            );
        }
        let record = make_record(
            "partial",
            OrgRepoSyncResult::Failed,
            vec![
                file("a.org", Uploaded, Failed),
                file("b.org", Downloaded, Synchronized),
            ],
        );
        assert_eq!(
            WebDavSyncRecordSummary::from_record(&record)
                .unwrap()
                .transfer,
            WebDavSyncTransfer::Download
        );
    }

    #[test]
    fn conflicts_are_independent_of_execution_errors_and_original_records_are_preserved() {
        let conflict = file(
            "a.org",
            OrgRepoSyncFileAction::Conflicted,
            OrgRepoSyncFileState::Conflict,
        );
        let mut network = file(
            "b.org",
            OrgRepoSyncFileAction::Skipped,
            OrgRepoSyncFileState::Failed,
        );
        network.error = Some(
            OrgRepoSyncErrorSummary::new(
                OrgRepoSyncErrorCategory::Network,
                true,
                "网络异常".into(),
            )
            .unwrap(),
        );
        let record = make_record("old", OrgRepoSyncResult::Failed, vec![conflict.clone()]);
        let summary = WebDavSyncRecordSummary::from_record(&record).unwrap();
        assert_eq!(record.result, Some(OrgRepoSyncResult::Failed));
        assert_eq!(summary.execution_result, OrgRepoSyncResult::Succeeded);
        assert_eq!(summary.pending_conflicts, 1);
        let mixed = make_record("mixed", OrgRepoSyncResult::Failed, vec![conflict, network]);
        let summary = WebDavSyncRecordSummary::from_record(&mixed).unwrap();
        assert_eq!(summary.execution_result, OrgRepoSyncResult::Failed);
        assert_eq!(
            summary.error_category,
            Some(OrgRepoSyncErrorCategory::Network)
        );
        assert_eq!(summary.pending_conflicts, 1);
        let empty = make_record("listing", OrgRepoSyncResult::Failed, vec![]);
        assert_eq!(
            WebDavSyncRecordSummary::from_record(&empty)
                .unwrap()
                .execution_result,
            OrgRepoSyncResult::Failed
        );
    }

    #[test]
    fn partial_resolution_and_later_recurrence_do_not_rewrite_previous_resolution() {
        use OrgRepoSyncFileAction::*;
        use OrgRepoSyncFileState::*;
        let history = vec![
            make_record(
                "before",
                OrgRepoSyncResult::Succeeded,
                vec![file("a.org", Uploaded, Synchronized)],
            ),
            make_record(
                "conflict",
                OrgRepoSyncResult::Failed,
                vec![
                    file("a.org", Conflicted, Conflict),
                    file("b.org", Skipped, RemoteDeleted),
                ],
            ),
            make_record(
                "retry",
                OrgRepoSyncResult::Failed,
                vec![file("b.org", Skipped, Failed)],
            ),
            make_record(
                "partial",
                OrgRepoSyncResult::Failed,
                vec![
                    file("a.org", Downloaded, Synchronized),
                    file("b.org", Skipped, Failed),
                ],
            ),
            make_record(
                "again",
                OrgRepoSyncResult::Failed,
                vec![file("a.org", Conflicted, Conflict)],
            ),
        ];
        let summaries = sync_history_summaries(&history).unwrap();
        assert_eq!(summaries[1].pending_conflicts, 2);
        assert_eq!(summaries[1].resolved_conflicts, 0);
        assert_eq!(summaries[4].pending_conflicts, 1);
        assert_eq!(summaries[4].resolved_conflicts, 0);
        assert_eq!(
            sync_history_summaries(&history[..3]).unwrap()[1].resolved_conflicts,
            0
        );
    }

    #[test]
    fn conditional_write_conflicts_are_not_execution_errors_and_terminal_states_are_preserved() {
        let mut conditional = file(
            "a.org",
            OrgRepoSyncFileAction::Skipped,
            OrgRepoSyncFileState::Failed,
        );
        conditional.error = Some(
            OrgRepoSyncErrorSummary::new(
                OrgRepoSyncErrorCategory::Conflict,
                false,
                "条件写入冲突".into(),
            )
            .unwrap(),
        );
        let conflict = make_record(
            "conditional",
            OrgRepoSyncResult::Failed,
            vec![conditional.clone()],
        );
        let summary = WebDavSyncRecordSummary::from_record(&conflict).unwrap();
        assert_eq!(summary.execution_result, OrgRepoSyncResult::Succeeded);
        assert_eq!(summary.pending_conflicts, 1);
        assert_eq!(summary.transfer, WebDavSyncTransfer::Unchanged);
        assert!(summary.error_category.is_none());
        for result in [OrgRepoSyncResult::Cancelled, OrgRepoSyncResult::Interrupted] {
            let stopped = make_record("stopped", result, vec![conditional.clone()]);
            assert_eq!(
                WebDavSyncRecordSummary::from_record(&stopped)
                    .unwrap()
                    .execution_result,
                result
            );
        }
        let resolved = make_record(
            "resolved",
            OrgRepoSyncResult::Succeeded,
            vec![file(
                "a.org",
                OrgRepoSyncFileAction::Uploaded,
                OrgRepoSyncFileState::Synchronized,
            )],
        );
        let summaries = sync_history_summaries(&[conflict, resolved]).unwrap();
        assert_eq!(summaries[0].pending_conflicts, 1);
        assert_eq!(summaries[0].resolved_conflicts, 0);
    }

    #[test]
    fn counts_and_details_preserve_partial_transfers_and_exclude_source_snapshots() {
        use OrgRepoSyncFileAction::*;
        use OrgRepoSyncFileState::*;
        let mut downloaded = file("a.org", Downloaded, Synchronized);
        downloaded.detail.synced_source = Some("private source".into());
        let mut failed = file("d.org", Skipped, Failed);
        failed.error = Some(
            OrgRepoSyncErrorSummary::new(
                OrgRepoSyncErrorCategory::Network,
                true,
                "连接被重置".into(),
            )
            .unwrap(),
        );
        let history = vec![make_record(
            "partial",
            OrgRepoSyncResult::Failed,
            vec![
                downloaded,
                file("b.org", Created, Synchronized),
                file("c.org", Uploaded, Synchronized),
                failed,
            ],
        )];
        let detail = sync_history_detail(&history, "partial").unwrap();
        assert_eq!(detail.summary.downloaded_files, 1);
        assert_eq!(detail.summary.uploaded_files, 2);
        assert_eq!(detail.summary.error_message.as_deref(), Some("连接被重置"));
        assert_eq!(detail.errors[0].path.as_deref(), Some("d.org"));
        assert_eq!(detail.files[3].outcome, WebDavSyncFileOutcome::Failed);
        assert!(
            !serde_json::to_string(&detail.files)
                .unwrap()
                .contains("private source")
        );
        assert!(sync_history_detail(&history, "missing").is_err());
    }

    #[test]
    fn legacy_null_context_and_empty_failures_remain_readable() {
        let record = make_record("listing", OrgRepoSyncResult::Failed, vec![]);
        let encoded = serde_json::to_string(&record).unwrap();
        assert!(encoded.contains("\"context_detail\":null"));
        let decoded = serde_json::from_str(&encoded).unwrap();
        let detail = sync_history_detail(&[decoded], "listing").unwrap();
        assert!(detail.files.is_empty());
        assert!(detail.errors.is_empty());
        assert_eq!(detail.summary.execution_result, OrgRepoSyncResult::Failed);
        assert!(detail.summary.error_message.is_none());
    }
}
