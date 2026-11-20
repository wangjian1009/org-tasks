import { CoreTask } from './NativeCoreService'

export const DEFAULT_EVENT_DURATION_MINUTES = 5
export const REMINDER_CLEANUP_DELAY = 30 * 60 * 1000

export interface CalendarEventContent {
  readonly title: string
  readonly startTime: number
  readonly endTime: number
  readonly reminderTime: number[]
  readonly notificationAt: number
  readonly cleanupAt: number
}

// 只转换 Core 已解析的规划快照；日历标记不写回任务或修改 Org 优先级。
export function calendarEventContent(task: CoreTask, durationMinutes: number): CalendarEventContent {
  const notificationAt = task.reminderAt
  if (notificationAt === null || notificationAt === undefined || !Number.isFinite(notificationAt)) throw new Error('任务提醒时间无效')
  const planning = task.editContent.scheduledPlanning ?? task.editContent.deadlinePlanning
  const startTime = planning ? new Date(`${planning.date}T${planning.time?.start ?? '00:00'}:00`).getTime() : notificationAt
  if (!Number.isFinite(startTime)) throw new Error('任务规划时间无效')
  if (!Number.isInteger(durationMinutes) || durationMinutes < 1 || durationMinutes > 1440) throw new Error('事件持续时长须为 1 至 1440 分钟的整数')
  const endTime = Math.max(startTime, notificationAt) + durationMinutes * 60000
  const highest = task.taskPriorityOf('Hight')
  const important = task.priority !== null && highest !== null && task.priority.name === highest.name
  return { title: `${important ? '【重要】' : ''}${task.heading}`, startTime, endTime,
    reminderTime: [Math.round((startTime - notificationAt) / 60000)], notificationAt,
    cleanupAt: Math.max(endTime, notificationAt + REMINDER_CLEANUP_DELAY) }
}

export function calendarEventKey(task: CoreTask, durationMinutes: number): string {
  const content = calendarEventContent(task, durationMinutes)
  return JSON.stringify([content.title, content.startTime, content.endTime, content.reminderTime, content.notificationAt])
}
