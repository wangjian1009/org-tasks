import { localizedDate, localizedText } from './LocalizedText'
import { CoreTask, CoreTitlePart } from '../services/NativeCoreService'
import { localDate, UiColor } from './Theme'

export interface TaskRowLayout {
  tagWidth: number
  firstTagWidth: number
  showMoreTags: boolean
  indicatorWidth: number
  showAllIndicators: boolean
  durationWidth: number
}

export enum TaskDateDisplay {
  Creation = 'Creation',
  Schedule = 'Schedule',
  Deadline = 'Deadline',
  Closed = 'Closed',
  Deleted = 'Deleted',
  None = 'None'
}

export enum TaskTimeDisplay {
  Creation = 'Creation',
  Schedule = 'Schedule',
  Deadline = 'Deadline',
  Closed = 'Closed',
  Deleted = 'Deleted',
  None = 'None'
}

// 仅按所选来源读取时刻；规划只消费 Core 结构化字段，缺失时不借用其他来源。
export function taskTimeForDisplay(task: CoreTask, display: TaskTimeDisplay): string {
  if (display === TaskTimeDisplay.Schedule || display === TaskTimeDisplay.Deadline) {
    const planning = display === TaskTimeDisplay.Schedule ? task.editContent?.scheduledPlanning : task.editContent?.deadlinePlanning
    return planning?.time?.start ?? ''
  }
  const timestamp = display === TaskTimeDisplay.Creation ? task.createdAt : display === TaskTimeDisplay.Closed ? task.closedAt : display === TaskTimeDisplay.Deleted ? task.deletedAt : null
  if (timestamp === null || !Number.isFinite(timestamp)) return ''
  const date = new Date(timestamp)
  return Number.isFinite(date.getTime()) ? `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}` : ''
}

export enum RegionAreaPolicy {
  None = 'None',
  Category = 'Category',
  Project = 'Project',
  CategoryProject = 'CategoryProject'
}

export interface TaskRegionArea {
  category: string
  project: string | null
}

export function taskRegionArea(task: CoreTask, policy: RegionAreaPolicy): TaskRegionArea {
  return {
    category: policy === RegionAreaPolicy.Category || policy === RegionAreaPolicy.CategoryProject ? task.category || '' : '',
    project: policy === RegionAreaPolicy.Project || policy === RegionAreaPolicy.CategoryProject ? task.project() : null
  }
}

// 这里只计算展示日期，不参与任务筛选；自然日序号避免跨夏令时产生误差。
function dayNumber(value: string): number {
  const date = value.slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return NaN
  const time = new Date(`${date}T00:00:00Z`).getTime()
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === date ? time / 86400000 : NaN
}

export function taskDurationDays(task: CoreTask, today: Date = new Date()): number {
  const duration = dayNumber(localDate(today)) - dayNumber(task.scheduled)
  return Number.isFinite(duration) ? Math.max(0, duration) : 0
}

export function taskDateIsToday(value: string, today: Date = new Date()): boolean {
  return Number.isFinite(dayNumber(value)) && value.slice(0, 10) === localDate(today)
}

// 按调用方选择读取日期；缺失时隐藏，不借用其他类型的日期。
export function taskDateForDisplay(task: CoreTask, display: TaskDateDisplay): string {
  if (display === TaskDateDisplay.Creation || display === TaskDateDisplay.Deleted) {
    const timestamp = display === TaskDateDisplay.Deleted ? task.deletedAt : task.createdAt
    if (timestamp === null || !Number.isFinite(timestamp)) return ''
    const date = new Date(timestamp)
    return Number.isFinite(date.getTime()) ? localDate(date) : ''
  }
  const value = display === TaskDateDisplay.Schedule ? task.scheduled :
    display === TaskDateDisplay.Deadline ? task.deadline : display === TaskDateDisplay.Closed ?
      (task.closedAt === null || !Number.isFinite(task.closedAt) ? '' : localDate(new Date(task.closedAt))) : ''
  return Number.isFinite(dayNumber(value)) ? value.slice(0, 10) : ''
}

// 计划分组使用有效计划／截止日期中较早的一天，仅计算展示，不参与筛选。
export function taskDisplayDate(task: CoreTask): string {
  const scheduled = dayNumber(task.scheduled)
  const deadline = dayNumber(task.deadline)
  if (Number.isFinite(scheduled) && Number.isFinite(deadline)) {
    return (scheduled <= deadline ? task.scheduled : task.deadline).slice(0, 10)
  }
  if (Number.isFinite(scheduled)) return task.scheduled.slice(0, 10)
  return Number.isFinite(deadline) ? task.deadline.slice(0, 10) : ''
}

export function taskDeadlineColor(task: CoreTask, today: Date = new Date()): string {
  const remaining = dayNumber(task.deadline) - dayNumber(localDate(today))
  return !task.isDone() && Number.isFinite(remaining) && remaining <= 0
    ? UiColor.deadline : UiColor.secondary
}

export function taskDeadlineText(task: CoreTask, today: Date = new Date()): string {
  const remaining = dayNumber(task.deadline) - dayNumber(localDate(today))
  if (!Number.isFinite(remaining)) return localizedText($r('app.string.text_date_not_available'))
  if (task.isDone()) return taskDateText(task.deadline, true, today)
  if (remaining > 0) return localizedText($r('app.string.text_days_left'), String(remaining))
  return remaining === 0 ? localizedText($r('app.string.text_it_s_closed_today')) : localizedText($r('app.string.text_overdue_days'), String(-remaining))
}

export function taskDateText(value: string, compact: boolean = false, today: Date = new Date()): string {
  if (!Number.isFinite(dayNumber(value))) return localizedText($r('app.string.text_date_not_available'))
  if (compact && taskDateIsToday(value, today)) return localizedText($r('app.string.text_today'))
  const date = new Date(dayNumber(value) * 86400000)
  if (compact) return localizedDate(date, { month: 'numeric', day: 'numeric', timeZone: 'UTC' })
  const label = localizedDate(date, { month: 'long', day: 'numeric', timeZone: 'UTC',
    year: date.getUTCFullYear() === today.getFullYear() ? undefined : 'numeric' })
  return localizedText($r('app.string.date_with_weekday'), label, localizedDate(date, { weekday: 'short', timeZone: 'UTC' }))
}

export function taskTitleText(task: CoreTask): string {
  return task.headingParts.length > 0 ? task.headingParts.map((part: CoreTitlePart): string => part.text).join('') : task.heading
}

export function taskIndicators(task: CoreTask): string[] {
  const result: string[] = []
  if (task.hasList) result.push('list')
  if (task.hasText) result.push('body')
  return result
}

// 标签名决定色相；固定深色亮度保证浅色文字可读，配色不随排序或展开状态变化。
export function taskTagColor(tag: string): string {
  let hash = 0
  for (let index = 0; index < tag.length; index++) hash = (hash * 31 + tag.charCodeAt(index)) >>> 0
  const hue = (hash % 360) / 30
  const channels: number[] = [0, 8, 4]
  return '#' + channels.map((offset: number): string => {
    const position = (offset + hue) % 12
    const value = 0.30 - 0.126 * Math.max(-1, Math.min(position - 3, 9 - position, 1))
    return Math.round(value * 255).toString(16).padStart(2, '0')
  }).join('')
}

// 按截止日期实际测量宽度预留右侧空间，再分配标签、标志与持续天数；剩余空间全部交给标题。
export function taskRowLayout(width: number, tagCount: number, indicatorCount: number,
  duration: number, deadlineWidth: number, countWidth: number = 0): TaskRowLayout {
  const available = Math.max(0, width - 26 - (countWidth > 0 ? countWidth + 6 : 0) - (deadlineWidth > 0 ? deadlineWidth + 8 : 0))
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
    durationWidth }
}

// 仅组合 Core 已提供的来源名称，不判断文件标签或项目属性。
export function taskSourceText(task: CoreTask, fallbackFile: boolean = false,
  policy: RegionAreaPolicy = RegionAreaPolicy.CategoryProject): string {
  const area = taskRegionArea(task, policy)
  const category = area.category
  const project = area.project
  if (project !== null) {
    const name = project || localizedText($r('app.string.text_untitled_project'))
    return category ? `${category} · ${name}` : name
  }
  return category || (fallbackFile && policy === RegionAreaPolicy.CategoryProject ? task.fileName : '')
}
