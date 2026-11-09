import { CoreTask } from '../services/NativeCoreService'

// 只格式化 Core 的日期、标签和首行正文快照，不解析 Org 或重新排序。
export function memoSummaryText(task: CoreTask): string {
  const timestamp = task.modifiedAt ?? task.createdAt
  const parts: string[] = []
  if (timestamp !== null && timestamp !== undefined) {
    const date = new Date(timestamp)
    if (Number.isFinite(date.getTime())) parts.push(`${date.getMonth() + 1}月${date.getDate()}日`)
  }
  if (task.tags.length > 0) parts.push(task.tags.map(tag => `#${tag}`).join(' '))
  if (task.bodyFirstLine) parts.push(task.bodyFirstLine)
  return parts.join('  ')
}
