import { CoreTask } from '../services/NativeCoreService'
import { taskDisplayDate } from './TaskListPresentation'
import { localDate } from './Theme'

export interface PlannedTaskItem {
  task: CoreTask
}

export interface PlannedTaskGroup {
  key: string
  project: string | null
  items: PlannedTaskItem[]
}

export type PlannedGroupKind = 'day' | 'range' | 'month' | 'year' | 'unknown'

export interface PlannedGroup {
  key: string
  kind: PlannedGroupKind
  date: string
  title: string
  subtitle: string
  items: PlannedTaskItem[]
  groups: PlannedTaskGroup[]
}

const monthNames: string[] = ['一月', '二月', '三月', '四月', '五月', '六月',
  '七月', '八月', '九月', '十月', '十一月', '十二月']
const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']

function dateValue(value: string): number {
  const date = value.slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return NaN
  const time = new Date(`${date}T00:00:00Z`).getTime()
  return Number.isFinite(time) ? time / 86400000 : NaN
}

function dateFromValue(value: number): Date {
  return new Date(value * 86400000)
}

function dateString(value: number): string {
  return dateFromValue(value).toISOString().slice(0, 10)
}

function dayAfter(value: string, amount: number): string {
  const ordinal = dateValue(value) + amount
  return Number.isFinite(ordinal) ? dateString(ordinal) : value
}

function monthKey(value: string): string {
  return value.slice(0, 7)
}

function monthEnd(value: string): string {
  const date = dateFromValue(dateValue(`${value.slice(0, 7)}-01`))
  return dateString(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0) / 86400000)
}

function monthTitle(value: string): string {
  const date = dateFromValue(dateValue(value))
  return monthNames[date.getUTCMonth()]
}

function yearTitle(value: string): string {
  return `${dateFromValue(dateValue(value)).getUTCFullYear()}年`
}

function dateTitle(value: string): string {
  const date = dateFromValue(dateValue(value))
  return `${date.getUTCDate()}日`
}

function dateSubtitle(value: string, tomorrow: string): string {
  return value === tomorrow ? '明天' : weekdays[dateFromValue(dateValue(value)).getUTCDay()]
}

export function plannedTaskDate(task: CoreTask): string {
  return taskDisplayDate(task)
}

function groupFor(groups: PlannedGroup[], key: string, kind: PlannedGroupKind, date: string,
  title: string, subtitle: string = ''): PlannedGroup {
  let group = groups.find((item: PlannedGroup) => item.key === key)
  if (!group) {
    group = { key, kind, date, title, subtitle, items: [], groups: [] }
    groups.push(group)
  }
  return group
}

// Core 已经完成计划查询；这里仅按自然日组织已返回任务，并补齐设计要求的空日期分组。
export function plannedGroups(tasks: CoreTask[]): PlannedGroup[] {
  const today = localDate(new Date())
  const tomorrow = dayAfter(today, 1)
  const dailyEnd = dayAfter(today, 7)
  const recentEnd = dayAfter(today, 180)
  const groups: PlannedGroup[] = []

  for (let offset = 1; offset <= 7; offset++) {
    const date = dayAfter(today, offset)
    groupFor(groups, `day:${date}`, 'day', date, dateTitle(date), dateSubtitle(date, tomorrow))
  }

  const rangeStart = dayAfter(dailyEnd, 1)
  const rangeEnd = monthEnd(rangeStart)
  if (dateValue(rangeStart) <= dateValue(recentEnd)) {
    groupFor(groups, `range:${monthKey(rangeStart)}`, 'range', rangeStart,
      `${monthTitle(rangeStart)} ${dateFromValue(dateValue(rangeStart)).getUTCDate()}–${dateFromValue(dateValue(rangeEnd)).getUTCDate()}`)
  }

  let monthCursor = monthKey(rangeStart) === monthKey(rangeEnd) ? dayAfter(rangeEnd, 1) : rangeEnd
  while (dateValue(monthCursor) <= dateValue(recentEnd)) {
    const first = `${monthCursor.slice(0, 7)}-01`
    groupFor(groups, `month:${monthKey(first)}`, 'month', first, monthTitle(first))
    monthCursor = dayAfter(monthEnd(first), 1)
  }

  const byDate = tasks.slice().sort((left: CoreTask, right: CoreTask) => {
    const leftDate = plannedTaskDate(left)
    const rightDate = plannedTaskDate(right)
    return leftDate.localeCompare(rightDate) || left.filePath.localeCompare(right.filePath) || left.heading.localeCompare(right.heading)
  })
  for (const task of byDate) {
    const date = plannedTaskDate(task)
    const item: PlannedTaskItem = { task }
    if (date.length === 0) {
      groupFor(groups, 'unknown', 'unknown', '', '日期不可用').items.push(item)
    } else if (dateValue(date) <= dateValue(dailyEnd)) {
      groupFor(groups, `day:${date}`, 'day', date, dateTitle(date), dateSubtitle(date, tomorrow)).items.push(item)
    } else if (dateValue(date) <= dateValue(recentEnd)) {
      const key = monthKey(date) === monthKey(rangeStart) ? `range:${monthKey(rangeStart)}` : `month:${monthKey(date)}`
      const group = groups.find((candidate: PlannedGroup) => candidate.key === key)
      if (group) group.items.push(item)
      else groupFor(groups, key, 'month', `${date.slice(0, 7)}-01`, monthTitle(date)).items.push(item)
    } else {
      groupFor(groups, `year:${date.slice(0, 4)}`, 'year', `${date.slice(0, 4)}-01-01`, yearTitle(date)).items.push(item)
    }
  }
  for (const group of groups) {
    if (group.kind !== 'day') continue
    const projects = new Map<string, PlannedTaskGroup>()
    group.items.forEach((item: PlannedTaskItem, index: number) => {
      const project = typeof item.task.project === 'function' ? item.task.project() : null
      if (project !== null) {
        const key = JSON.stringify(['project', item.task.repoId, item.task.filePath, item.task.category || null, project])
        let projectGroup = projects.get(key)
        if (!projectGroup) {
          projectGroup = { key, project, items: [] }
          projects.set(key, projectGroup)
          group.groups.push(projectGroup)
        }
        projectGroup.items.push(item)
      } else {
        group.groups.push({ key: JSON.stringify(['task', index, item.task.id]), project: null, items: [item] })
      }
    })
  }
  return groups
}

export function plannedDateText(value: string): string {
  const ordinal = dateValue(value)
  if (!Number.isFinite(ordinal)) return ''
  const date = dateFromValue(ordinal)
  return `${date.getUTCMonth() + 1}月${date.getUTCDate()}日`
}
