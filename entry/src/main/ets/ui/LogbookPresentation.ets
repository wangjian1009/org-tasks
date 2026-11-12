import { CoreTask } from '../services/NativeCoreService'
import { TaskStateCategory } from './TaskStatePresentation'
import { localDate } from './Theme'

export interface LogbookEvent {
  key: string
  kind: 'created' | 'closed'
  label: string
  timestamp: number | null
  task: CoreTask
}

export interface LogbookGroup {
  key: string
  kind: 'day' | 'month' | 'year' | 'unknown'
  date: string
  title: string
  subtitle: string
  events: LogbookEvent[]
}

const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']

// 任务范围由 Core 的 it.done 决定；这里只把返回快照排成事件时间线。
export function logbookGroups(tasks: CoreTask[], now: Date = new Date()): LogbookGroup[] {
  const groups: LogbookGroup[] = []
  const dailyStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6)
  const monthlyStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 180)
  const today = localDate(now)
  const yesterday = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))
  const add = (event: LogbookEvent): void => {
    const time = event.timestamp
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
      group = { key, kind, date: day, title, subtitle, events: [] }
      groups.push(group)
    }
    group.events.push(event)
  }
  for (const task of tasks) {
    if (task.createdAt !== null) {
      add({ key: `${task.id}\ncreated`, kind: 'created', label: '创建', timestamp: task.createdAt, task })
    }
    add({ key: `${task.id}\nclosed`, kind: 'closed',
      label: task.state?.category === TaskStateCategory.Cancel ? '取消' : '完成', timestamp: task.closedAt, task })
  }
  for (const group of groups) {
    group.events.sort((left: LogbookEvent, right: LogbookEvent) => {
      return (right.timestamp ?? -Infinity) - (left.timestamp ?? -Infinity) || left.key.localeCompare(right.key)
    })
  }
  groups.sort((left: LogbookGroup, right: LogbookGroup) => {
    if (left.kind === 'unknown') return 1
    if (right.kind === 'unknown') return -1
    return right.key.localeCompare(left.key)
  })
  return groups
}

export function logbookEventTime(event: LogbookEvent, group: LogbookGroup): string {
  if (event.timestamp === null) return '时间未记录'
  const date = new Date(event.timestamp)
  if (!Number.isFinite(date.getTime())) return '时间未记录'
  const clock = `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`
  return group.kind === 'day' ? clock : `${date.getMonth() + 1}月${date.getDate()}日 ${clock}`
}
