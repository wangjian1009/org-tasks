import { CoreTaskPlanningInfo } from '../services/NativeCoreService'
// 仅维护月历布局；任务时间戳的语法与写入由 Core 验证。
export interface TaskCalendarDay { key: string; label: string; date: string; inMonth: boolean; today: boolean; selected: boolean }

export function inlineDate(date: Date): string {
  return `${date.getFullYear().toString().padStart(4, '0')}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')}`
}
export function inlineDateLabel(value: string, now: Date = new Date()): string {
  if (!value) return ''
  if (value === inlineDate(now)) return '今天'
  const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 12)
  if (value === inlineDate(tomorrow)) return '明天'
  const date = new Date(`${value}T12:00:00`)
  return `${date.getFullYear() === now.getFullYear() ? '' : `${date.getFullYear()}年`}${date.getMonth() + 1}月${date.getDate()}日`
}
export function taskCalendarDays(year: number, month: number, selected: string, now: Date = new Date()): TaskCalendarDay[] {
  const first = new Date(year, month, 1, 12)
  const offset = (first.getDay() + 6) % 7
  const days: TaskCalendarDay[] = []
  for (let index = 0; index < 42; index++) {
    const day = new Date(year, month, 1 - offset + index, 12)
    const date = inlineDate(day)
    days.push({ key: date, label: `${day.getDate()}`, date, inMonth: day.getMonth() === month,
      today: date === inlineDate(now), selected: date === selected })
  }
  return days
}

export function inlinePlanningLabel(date: string, planning: CoreTaskPlanningInfo | null): string {
  const time = planning?.time
  return `${inlineDateLabel(date)}${time ? ` ${time.start}${time.end ? `–${time.end}` : ''}` : ''}`
}
