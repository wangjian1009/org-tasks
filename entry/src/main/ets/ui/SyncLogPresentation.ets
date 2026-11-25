import { localizedText } from './LocalizedText'
import { CoreSyncRecord, CoreSyncFileRecord } from '../services/NativeCoreService'

export function syncLogTransferLabel(record: CoreSyncRecord): string {
  switch (record.transfer) {
    case 'download': return (record.downloadedFiles ?? 0) > 0 ? localizedText($r('app.string.text_download_files'), String(record.downloadedFiles)) : localizedText($r('app.string.text_it_s_downloaded'))
    case 'upload': return (record.uploadedFiles ?? 0) > 0 ? localizedText($r('app.string.text_uploading_files'), String(record.uploadedFiles)) : localizedText($r('app.string.text_it_s_uploaded'))
    case 'bidirectional': {
      const download = (record.downloadedFiles ?? 0) > 0 ? localizedText($r('app.string.text_download'), String(record.downloadedFiles)) : localizedText($r('app.string.text_it_s_downloaded'))
      const upload = (record.uploadedFiles ?? 0) > 0 ? localizedText($r('app.string.text_upload'), String(record.uploadedFiles)) : localizedText($r('app.string.text_it_s_uploaded'))
      return `${download}/${upload}`
    }
    case 'unchanged': return record.files === null ? localizedText($r('app.string.text_unknown_number_of_files')) : record.files > 0 ? localizedText($r('app.string.text_file_unchanged'), String(record.files)) : localizedText($r('app.string.text_no_change'))
    default: return localizedText($r('app.string.text_transfer_information_is_unknown'))
  }
}

export function syncLogResultLabel(record: CoreSyncRecord): string {
  switch (record.executionResult) {
    case 'succeeded': return localizedText($r('app.string.text_implementation_success'))
    case 'failed': return localizedText($r('app.string.text_implementation_failed'))
    case 'cancelled': return localizedText($r('app.string.text_canceled'))
    case 'interrupted': return localizedText($r('app.string.text_interrupted'))
    default: return localizedText($r('app.string.text_the_execution_result_is_unknown'))
  }
}

export function syncLogConflictLabel(record: CoreSyncRecord): string {
  const count = record.conflictCount ?? record.conflicts.length
  if (count > 0) return localizedText($r('app.string.text_conflict_2'), String(count))
  return record.conflictCount === null ? localizedText($r('app.string.text_unknown_number_of_conflicts')) : ''
}

export function syncLogErrorLabel(record: CoreSyncRecord): string {
  if (record.errorMessage && record.errorMessage.trim().length > 0) return record.errorMessage.trim()
  if (record.incomplete) return localizedText($r('app.string.text_log_records_are_incomplete'))
  if (record.executionResult !== 'failed') return ''
  switch (record.errorCategory) {
    case 'Network': return localizedText($r('app.string.text_network_failure'))
    case 'Authentication': return localizedText($r('app.string.text_authentication_failed'))
    case 'Tls': return localizedText($r('app.string.text_secure_connection_failed'))
    case 'Validation': return localizedText($r('app.string.text_protocol_or_data_error'))
    case 'LocalStorage': return localizedText($r('app.string.text_local_storage_failed'))
    default: return localizedText($r('app.string.text_implementation_failed'))
  }
}

export function syncLogTimeLabel(timestamp: number | null, compact: boolean = false): string {
  if (timestamp === null || timestamp === undefined) return localizedText($r('app.string.text_time_unknown'))
  const date = new Date(timestamp)
  if (isNaN(date.getTime())) return localizedText($r('app.string.text_time_unknown'))
  const pad = (value: number): string => value.toString().padStart(2, '0')
  if (compact) return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export function visibleSyncLogs(records: CoreSyncRecord[], showUnchanged: boolean): CoreSyncRecord[] {
  return showUnchanged ? records : records.filter((record: CoreSyncRecord) =>
    record.triggerReason === 'repositoryCreated' || record.triggerReason === 'repositoryReset' ||
    record.transfer !== 'unchanged' || record.executionResult !== 'succeeded' || record.conflicts.length > 0 || record.incomplete || record.conflictCount === null)
}

export function syncLogRenderKey(record: CoreSyncRecord): string {
  return JSON.stringify(record)
}

export function syncLogTriggerLabel(record: CoreSyncRecord): string {
  switch (record.triggerReason) {
    case 'remoteChanged': return localizedText($r('app.string.text_remote_change'))
    case 'localChanged': return localizedText($r('app.string.text_local_changes'))
    case 'manual': return localizedText($r('app.string.text_synchronise_manually'))
    case 'repositoryCreated': return localizedText($r('app.string.text_new_repository'))
    case 'repositoryReset': return localizedText($r('app.string.text_reset_repository'))
    case 'appStartup': return localizedText($r('app.string.text_apply_startup'))
    case 'appBackground': return localizedText($r('app.string.text_backstage'))
    default: return record.triggerReason ? localizedText($r('app.string.text_unknown_trigger_cause')) : localizedText($r('app.string.text_no_cause_of_trigger_recorded'))
  }
}

export function syncLogTitle(record: CoreSyncRecord): string {
  const error = syncLogErrorLabel(record).replace(/[\r\n]+/g, ' ')
  const title = !error ? syncLogTransferLabel(record) : record.transfer !== 'unchanged'
    ? `${error} · ${syncLogTransferLabel(record)}` : error
  return record.triggerReason ? `${syncLogTriggerLabel(record)} · ${title}` : title
}

export function syncLogFileOutcomeLabel(file: CoreSyncFileRecord): string {
  switch (file.outcome) {
    case 'downloaded': return localizedText($r('app.string.text_update'))
    case 'uploaded': return localizedText($r('app.string.text_local_upload'))
    case 'created': return localizedText($r('app.string.text_add_3'))
    case 'deleted': return localizedText($r('app.string.text_delete'))
    case 'updated': return localizedText($r('app.string.text_update'))
    case 'merged': return localizedText($r('app.string.text_merge'))
    case 'conflict': return localizedText($r('app.string.text_conflict'))
    case 'failed': return localizedText($r('app.string.text_implementation_failed'))
    case 'skipped': return localizedText($r('app.string.text_skipped'))
    case 'unchanged': return localizedText($r('app.string.text_no_change'))
    default: return localizedText($r('app.string.text_status_unknown'))
  }
}
