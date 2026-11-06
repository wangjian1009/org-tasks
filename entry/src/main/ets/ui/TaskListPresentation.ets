import { CoreTask, CoreTitlePart } from '../services/NativeCoreService'
import { localDate } from './Theme'

export interface TaskRowLayout {
  tagWidth: number
  firstTagWidth: number
  showMoreTags: boolean
  indicatorWidth: number
  showAllIndicators: boolean
  durationWidth: number
  deadlineWidth: number
}

// 这里只计算展示日期，不参与任务筛选；自然日序号避免跨夏令时产生误差。
function dayNumber(value: string): number {
  const date = value.slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return NaN
  const time = new Date(`${date}T00:00:00Z`).getTime()
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === date ? time / 86400000 : NaN
}

export function taskDurationDays(task: CoreTask, today: Date = new Date()): number {
  const start: string = Number.isFinite(dayNumber(task.scheduled)) ? task.scheduled : task.deadline
  const duration = dayNumber(localDate(today)) - dayNumber(start)
  return Number.isFinite(duration) ? Math.max(0, duration) : 0
}

export function taskDateIsToday(value: string, today: Date = new Date()): boolean {
  return Number.isFinite(dayNumber(value)) && value.slice(0, 10) === localDate(today)
}

export function taskDateText(value: string, compact: boolean = false, today: Date = new Date()): string {
  if (!Number.isFinite(dayNumber(value))) return '日期不可用'
  if (compact && taskDateIsToday(value, today)) return '今天'
  const date = new Date(dayNumber(value) * 86400000)
  const month = date.getUTCMonth() + 1
  const day = date.getUTCDate()
  if (compact) return `${month}/${day}`
  const weekdays: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
  const year = date.getUTCFullYear() === today.getFullYear() ? '' : `${date.getUTCFullYear()}年`
  return `${year}${month}月${day}日 ${weekdays[date.getUTCDay()]}`
}

export function taskTitleText(task: CoreTask): string {
  return task.headingParts.length > 0 ? task.headingParts.map((part: CoreTitlePart): string => part.text).join('') : task.heading
}

export function taskIndicators(task: CoreTask): string[] {
  const result: string[] = []
  if (task.bodyHtml.trim().length > 0) result.push('body')
  if (task.hasList) result.push('list')
  if (task.isRepeating) result.push('repeat')
  return result
}

// 为截止日期预留右侧宽度，再分配标签、标志与持续天数；剩余空间全部交给标题。
export function taskRowLayout(width: number, tagCount: number, indicatorCount: number,
  duration: number, hasDeadline: boolean): TaskRowLayout {
  const deadlineWidth = hasDeadline ? 70 : 0
  const available = Math.max(0, width - 26 - (hasDeadline ? deadlineWidth + 8 : 0))
  let remaining = Math.max(0, available * 0.45)
  const durationWidth = duration > 0 && remaining >= 26 ? Math.min(44, `${duration}`.length * 7 + 12, remaining - 6) : 0
  remaining = Math.max(0, remaining - (durationWidth > 0 ? durationWidth + 6 : 0))
  const fullIndicators = indicatorCount * 14 + Math.max(0, indicatorCount - 1) * 4
  const indicatorWidth = indicatorCount === 0 || remaining < 20 ? 0 : fullIndicators <= remaining * 0.45 ? fullIndicators : 14
  remaining = Math.max(0, remaining - (indicatorWidth > 0 ? indicatorWidth + 6 : 0))
  const tagWidth = tagCount > 0 && remaining >= 28 ? Math.min(84, remaining - 6) : 0
  const showMoreTags = tagCount > 1 && tagWidth >= 50
  return { tagWidth, firstTagWidth: tagWidth - (showMoreTags ? 26 : 0), showMoreTags,
    indicatorWidth, showAllIndicators: indicatorWidth >= fullIndicators,
    durationWidth, deadlineWidth }
}
