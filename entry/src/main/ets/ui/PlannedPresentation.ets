import { localizedDate, localizedText } from './LocalizedText'
import { CoreTask } from '../services/NativeCoreService'
import { TaskTimeDisplay, taskDisplayDate } from './TaskListPresentation'
import { localDate } from './Theme'
import { TaskRegionData, TaskRegionGroup, taskRegion, taskRegionGroups } from './TaskRegionPresentation'

// 候选来自未筛选的计划快照；只汇总来源，不在展示层筛选任务。
export function plannedRegionOptions(tasks: CoreTask[]): TaskRegionData[] {
  const categories = new Map<string, TaskRegionData>()
  const projects = new Map<string, TaskRegionData>()
  for (const task of tasks) {
    const source = taskRegion(task)
    const key = JSON.stringify(['category', source.category])
    if (!categories.has(key)) {
      categories.set(key, { key, kind: 'category', title: source.category || localizedText($r('app.string.text_uncategorized')),
        category: source.category, repoId: '', filePath: '' })
    }
    if (source.kind === 'project' && !projects.has(source.key)) projects.set(source.key, source)
  }
  const options: TaskRegionData[] = []
  categories.forEach((region: TaskRegionData) => { options.push(region) })
  projects.forEach((region: TaskRegionData) => { options.push(region) })
  return options
}

export interface PlannedTaskItem {
  task: CoreTask
}

export interface PlannedScheduleItem extends PlannedTaskItem {
  time: string
  timeDisplay: TaskTimeDisplay
}

export type PlannedTaskGroup = TaskRegionGroup<PlannedTaskItem>

export type PlannedGroupKind = 'day' | 'range' | 'month' | 'year' | 'unknown'

export interface PlannedGroup {
  key: string
  kind: PlannedGroupKind
  date: string
  title: string
  subtitle: string
  items: PlannedTaskItem[]
  scheduleItems: PlannedScheduleItem[]
  groups: PlannedTaskGroup[]
}

// 字段内容由 TaskEditor 自己订阅；布局未变化时保留日期、区域与任务行容器。
export function samePlannedGroups(left: PlannedGroup[], right: PlannedGroup[], keyOf: (task: CoreTask) => string): boolean {
  return left.length === right.length && left.every((group: PlannedGroup, index: number): boolean => {
    const next = right[index]
    return group.key === next.key && group.kind === next.kind && group.date === next.date &&
      group.title === next.title && group.subtitle === next.subtitle && group.items.length === next.items.length &&
      group.items.every((item: PlannedTaskItem, itemIndex: number): boolean => {
        const other = next.items[itemIndex]
        return keyOf(item.task) === keyOf(other.task) && plannedTaskDate(item.task) === plannedTaskDate(other.task) &&
          (plannedTaskDate(item.task) === item.task.scheduled) === (plannedTaskDate(other.task) === other.task.scheduled) &&
          (item.task.project() === null) === (other.task.project() === null)
      }) && group.scheduleItems.length === next.scheduleItems.length &&
      group.scheduleItems.every((item: PlannedScheduleItem, itemIndex: number): boolean => {
        const other = next.scheduleItems[itemIndex]
        return keyOf(item.task) === keyOf(other.task) && item.time === other.time && item.timeDisplay === other.timeDisplay
      }) && group.groups.length === next.groups.length &&
      group.groups.every((region: PlannedTaskGroup, regionIndex: number): boolean => {
        const other = next.groups[regionIndex]
        return region.key === other.key && region.title === other.title && region.category === other.category &&
          region.items.length === other.items.length && region.items.every((item: PlannedTaskItem, itemIndex: number): boolean =>
            keyOf(item.task) === keyOf(other.items[itemIndex].task))
      })
  })
}

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
  return localizedDate(date, { month: 'long', timeZone: 'UTC' })
}

function yearTitle(value: string): string {
  return localizedDate(dateFromValue(dateValue(value)), { year: 'numeric', timeZone: 'UTC' })
}

function dateTitle(value: string): string {
  const date = dateFromValue(dateValue(value))
  return localizedDate(date, { day: 'numeric', timeZone: 'UTC' })
}

function dateSubtitle(value: string, tomorrow: string): string {
  return value === tomorrow ? localizedText($r('app.string.text_tomorrow')) : localizedDate(dateFromValue(dateValue(value)), { weekday: 'long', timeZone: 'UTC' })
}

export function plannedTaskDate(task: CoreTask): string {
  return taskDisplayDate(task)
}

function groupFor(groups: PlannedGroup[], key: string, kind: PlannedGroupKind, date: string,
  title: string, subtitle: string = ''): PlannedGroup {
  let group = groups.find((item: PlannedGroup) => item.key === key)
  if (!group) {
    group = { key, kind, date, title, subtitle, items: [], scheduleItems: [], groups: [] }
    groups.push(group)
  }
  return group
}

// 仅在任务被分到该自然日时读取对应规划字段；计划优先于截止，避免一条任务进入两个日程位置。
function plannedScheduleItem(task: CoreTask, date: string): PlannedScheduleItem | null {
  const scheduled = task.editContent?.scheduledPlanning
  if (scheduled?.date === date && scheduled.time?.start) {
    return { task, time: scheduled.time.start, timeDisplay: TaskTimeDisplay.Schedule }
  }
  const deadline = task.editContent?.deadlinePlanning
  if (deadline?.date === date && deadline.time?.start) {
    return { task, time: deadline.time.start, timeDisplay: TaskTimeDisplay.Deadline }
  }
  return null
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
      groupFor(groups, 'unknown', 'unknown', '', localizedText($r('app.string.text_date_not_available'))).items.push(item)
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
    if (group.kind === 'day') {
      const scheduleItems: PlannedScheduleItem[] = []
      for (const item of group.items) {
        const scheduleItem = plannedScheduleItem(item.task, group.date)
        if (scheduleItem !== null) scheduleItems.push(scheduleItem)
      }
      group.scheduleItems = scheduleItems
      group.scheduleItems.sort((left: PlannedScheduleItem, right: PlannedScheduleItem): number =>
        left.time.localeCompare(right.time))
      const scheduledIds = new Set<string>(group.scheduleItems.map((item: PlannedScheduleItem): string => item.task.id))
      group.groups = taskRegionGroups(group.items.filter((item: PlannedTaskItem): boolean => !scheduledIds.has(item.task.id)),
        (item: PlannedTaskItem): CoreTask => item.task)
    }
  }
  return groups
}

export function plannedDateText(value: string): string {
  const ordinal = dateValue(value)
  if (!Number.isFinite(ordinal)) return ''
  const date = dateFromValue(ordinal)
  return localizedDate(date, { month: 'long', day: 'numeric', timeZone: 'UTC' })
}
