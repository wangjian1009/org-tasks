import { CoreTaskLog } from '../services/NativeCoreService'

function escapeLogText(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

// 分区仅选择既有条目，不复制或修改 Core 日志对象。
export function taskNoteEntries(logs: CoreTaskLog[]): CoreTaskLog[] {
  return logs.filter((log: CoreTaskLog): boolean =>
    log.type !== 'other' && log.type !== 'taskClock' &&
      log.noteHtml.replace(/<\/?(?:main|section|p)\b[^>]*>|<br\s*\/?>/gi, '').trim().length > 0)
}

export function taskEventLogs(logs: CoreTaskLog[]): CoreTaskLog[] {
  return logs.filter((log: CoreTaskLog): boolean => log.type !== 'taskNote' && log.type !== 'taskClosingNote')
}

export function taskNoteTime(log: CoreTaskLog, year: number = new Date().getFullYear()): string {
  if (log.type === 'other' || log.type === 'taskClock') return ''
  return log.timestamp.startsWith(`${year}-`) ? log.timestamp.slice(5) : log.timestamp
}

export function taskNoteHtml(log: CoreTaskLog): string {
  if (log.type === 'other' || log.type === 'taskClock') return ''
  return `<article class="task-log task-note">${log.noteHtml}</article>`
}

// 只按 Core 类型组织排版；时间与 Org 富文本均已在 Core 解析。
export function taskLogHtml(log: CoreTaskLog): string {
  if (log.type === 'taskNote' || log.type === 'taskClosingNote') return ''
  if (log.type === 'other') return `<article class="task-log other">${log.html}</article>`
  if (log.type === 'taskClock') {
    const range = `${log.start}${log.end ? ` – ${log.end}` : ' · 计时中'}`
    return `<article class="task-log clock"><div class="task-log-heading"><span>计时${log.duration ? ` · ${escapeLogText(log.duration)}` : ''}</span><span class="task-log-time">${escapeLogText(range)}</span></div></article>`
  }
  let label = ''
  let detail = ''
  switch (log.type) {
    case 'taskStateChange': label = `${log.from || '无状态'} → ${log.to || '无状态'}`; break
    case 'taskReschedule': label = '调整计划'; detail = `原计划 ${log.previous}`; break
    case 'taskScheduleRemoval': label = '移除计划'; detail = `原计划 ${log.previous}`; break
    case 'taskDeadlineChange': label = '调整截止日期'; detail = `原截止 ${log.previous}`; break
    case 'taskDeadlineRemoval': label = '移除截止日期'; detail = `原截止 ${log.previous}`; break
    case 'taskRefile': label = '移动任务'; break
  }
  return `<article class="task-log ${log.type}"><div class="task-log-heading"><span>${escapeLogText(label)}</span><span class="task-log-time">${escapeLogText(log.timestamp)}</span></div>${detail ? `<div class="task-log-detail">${escapeLogText(detail)}</div>` : ''}</article>`
}

export enum LogShowPolicy {
  LogShowBySwitch = 'LogShowBySwitch',
  LogShowAlways = 'LogShowAlways'
}

export function taskLogVisible(policy: LogShowPolicy, switched: boolean): boolean {
  return policy === LogShowPolicy.LogShowAlways || switched
}
