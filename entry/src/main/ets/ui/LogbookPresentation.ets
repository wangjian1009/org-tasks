import { CoreTask } from '../services/NativeCoreService'
import { localDate } from './Theme'
import { TaskRegionGroup, taskRegionGroups } from './TaskRegionPresentation'

export interface LogbookTaskItem {
  key: string
  timestamp: number | null
  task: CoreTask
}

export type LogbookTaskGroup = TaskRegionGroup<LogbookTaskItem>

export interface LogbookGroup {
  key: string
  kind: 'day' | 'month' | 'year' | 'unknown'
  date: string
  title: string
  subtitle: string
  items: LogbookTaskItem[]
  groups: LogbookTaskGroup[]
}

const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']

// 任务范围由 Core 的 it.done 决定；每个已完成或已取消任务仅按 closedAt 编排一次。
export function logbookGroups(tasks: CoreTask[], now: Date = new Date()): LogbookGroup[] {
  const groups: LogbookGroup[] = []
  const dailyStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6)
  const monthlyStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 180)
  const today = localDate(now)
  const yesterday = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))
  const add = (item: LogbookTaskItem): void => {
    const time = item.timestamp
    const date = time === null ? undefined : new Date(time)
    const valid = date !== undefined && Number.isFinite(date.getTime())
    const day = valid ? localDate(date!) : ''
    const kind: 'day' | 'month' | 'year' | 'unknown' = !valid ? 'unknown' : date! >= dailyStart ? 'day' :
      date! >= monthlyStart ? 'month' : 'year'
    const key = kind === 'day' ? day : kind === 'month' ? day.slice(0, 7) : kind === 'year' ? day.slice(0, 4) : 'unknown'
    let group = groups.find((item: LogbookGroup) => item.key === key)
    if (!group) {
      const title = !valid ? '时间未记录' : kind === 'day' ? `${date!.getDate()}日` : kind === 'month' ?
        `${date!.getFullYear() === now.getFullYear() ? '' : `${date!.getFullYear()}年`}${date!.getMonth() + 1}月` : `${date!.getFullYear()}年`
      const subtitle = kind !== 'day' ? '' : day === today ? '今天' : day === yesterday ? '昨天' : weekdays[date!.getDay()]
      group = { key, kind, date: day, title, subtitle, items: [], groups: [] }
      groups.push(group)
    }
    group.items.push(item)
  }
  for (const task of tasks) {
    add({ key: task.id, timestamp: task.closedAt, task })
  }
  for (const group of groups) {
    group.items.sort((left: LogbookTaskItem, right: LogbookTaskItem) => {
      return (right.timestamp ?? -Infinity) - (left.timestamp ?? -Infinity) || left.key.localeCompare(right.key)
    })
    if (group.kind === 'day') {
      group.groups = taskRegionGroups(group.items, (item: LogbookTaskItem): CoreTask => item.task)
    }
  }

  groups.sort((left: LogbookGroup, right: LogbookGroup) => {
    if (left.kind === 'unknown') return 1
    if (right.kind === 'unknown') return -1
    return right.key.localeCompare(left.key)
  })
  return groups
}
