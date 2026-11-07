import { CoreTask } from '../services/NativeCoreService'

// 备忘专用展示规则；不依赖任务列表的日期、布局或状态计算。
function dateValue(value: string): number {
  const date = value.slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return NaN
  const time = new Date(`${date}T00:00:00Z`).getTime()
  return Number.isFinite(time) ? time : NaN
}

function memoDateValue(task: CoreTask): string {
  const scheduled = dateValue(task.scheduled)
  const deadline = dateValue(task.deadline)
  if (Number.isFinite(scheduled) && Number.isFinite(deadline)) {
    return (scheduled <= deadline ? task.scheduled : task.deadline).slice(0, 10)
  }
  if (Number.isFinite(scheduled)) return task.scheduled.slice(0, 10)
  return Number.isFinite(deadline) ? task.deadline.slice(0, 10) : ''
}

export function memoSummaryText(task: CoreTask): string {
  const date = memoDateValue(task)
  const body = task.body.trim()
  const dateText = date.length > 0
    ? `${Number(date.slice(5, 7))}月${Number(date.slice(8, 10))}日`
    : ''
  if (dateText.length === 0) return body
  return body.length > 0 ? `${dateText}  ${body}` : dateText
}
