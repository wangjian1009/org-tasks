import { localizedDate, localizedText } from './LocalizedText'
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

// 任务范围由 Core 的 it.done 决定；每个已完成或已取消任务仅按 closedAt 编排一次。
export function logbookGroups(tasks: CoreTask[], now: Date = new Date(), timestampOf: (task: CoreTask) => number | null = task => task.closedAt,
  keyOf: (task: CoreTask) => string = task => task.id): LogbookGroup[] {
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
      const title = !valid ? localizedText($r('app.string.logbook_time_not_recorded')) :
        kind === 'day' ? localizedDate(date!, { day: 'numeric' }) :
        kind === 'month' ? localizedDate(date!, { month: 'long', year: date!.getFullYear() === now.getFullYear() ? undefined : 'numeric' }) :
        localizedDate(date!, { year: 'numeric' })
      const subtitle = kind !== 'day' ? '' : day === today ? localizedText($r('app.string.text_today')) : day === yesterday ? localizedText($r('app.string.text_yesterday')) : localizedDate(date!, { weekday: 'long' })
      group = { key, kind, date: day, title, subtitle, items: [], groups: [] }
      groups.push(group)
    }
    group.items.push(item)
  }
  for (const task of tasks) {
    add({ key: keyOf(task), timestamp: timestampOf(task), task })
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
