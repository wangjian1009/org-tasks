import { CoreSyncRecord, CoreSyncFileRecord } from '../services/NativeCoreService'

export function syncLogTransferLabel(record: CoreSyncRecord): string {
  switch (record.transfer) {
    case 'download': return record.downloadedFiles > 0 ? `下载${record.downloadedFiles}个文件` : '有下载'
    case 'upload': return record.uploadedFiles > 0 ? `上传${record.uploadedFiles}个文件` : '有上传'
    case 'bidirectional': {
      const download = record.downloadedFiles > 0 ? `下载${record.downloadedFiles}` : '有下载'
      const upload = record.uploadedFiles > 0 ? `上传${record.uploadedFiles}` : '有上传'
      return `${download}/${upload}`
    }
    default: return record.files > 0 ? `${record.files}个文件无变化` : '无变化'
  }
}

export function syncLogResultLabel(record: CoreSyncRecord): string {
  switch (record.executionResult) {
    case 'succeeded': return '执行成功'
    case 'failed': return '执行失败'
    case 'cancelled': return '已取消'
    default: return '已中断'
  }
}

export function syncLogConflictLabel(record: CoreSyncRecord): string {
  if (record.pendingConflicts > 0) return `冲突 ${record.pendingConflicts}`
  if (record.resolvedConflicts > 0) return `已解决 ${record.resolvedConflicts}`
  return ''
}

export function syncLogErrorLabel(record: CoreSyncRecord): string {
  if (record.errorMessage && record.errorMessage.trim().length > 0) return record.errorMessage.trim()
  if (record.executionResult !== 'failed') return ''
  switch (record.errorCategory) {
    case 'Network': return '网络失败'
    case 'Authentication': return '认证失败'
    case 'Tls': return '安全连接失败'
    case 'Validation': return '协议或数据错误'
    case 'LocalStorage': return '本地存储失败'
    default: return '执行失败'
  }
}

export function syncLogTimeLabel(timestamp: number, compact: boolean = false): string {
  const date = new Date(timestamp)
  if (isNaN(date.getTime())) return '时间未知'
  const pad = (value: number): string => value.toString().padStart(2, '0')
  if (compact) return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export function visibleSyncLogs(records: CoreSyncRecord[], showUnchanged: boolean): CoreSyncRecord[] {
  return showUnchanged ? records : records.filter((record: CoreSyncRecord) =>
    record.transfer !== 'unchanged' || record.executionResult !== 'succeeded' || record.pendingConflicts > 0)
}

export function syncLogRenderKey(record: CoreSyncRecord): string {
  return JSON.stringify(record)
}

export function syncLogTitle(record: CoreSyncRecord): string {
  const error = syncLogErrorLabel(record).replace(/[\r\n]+/g, ' ')
  if (!error) return syncLogTransferLabel(record)
  return record.transfer !== 'unchanged'
    ? `${error} · ${syncLogTransferLabel(record)}` : error
}

export function syncLogFileOutcomeLabel(file: CoreSyncFileRecord): string {
  switch (file.outcome) {
    case 'downloaded': return '已下载'
    case 'uploaded': return '已上传'
    case 'created': return '已上传（新建）'
    case 'deleted': return '已采用远端删除'
    case 'conflict': return '冲突'
    case 'resolved': return '已解决'
    case 'failed': return '执行失败'
    case 'skipped': return '已跳过'
    default: return '无变化'
  }
}
