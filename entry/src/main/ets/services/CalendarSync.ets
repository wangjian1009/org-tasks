// 日历同步服务
// 将 org 任务同步到 HarmonyOS 系统日历

import { Context } from '@kit.AbilityKit'
import { calendarManager } from '@kit.CalendarKit'
import { OrgTask, SyncResult } from '../models/OrgTask'

export class CalendarSync {
  private calendar: calendarManager.Calendar | undefined = undefined
  private readonly calendarName: string
  private readonly context: Context

  constructor(context: Context, calendarName: string) {
    this.context = context
    this.calendarName = calendarName
  }

  /** 初始化或创建应用专用的本地日历。 */
  async init(): Promise<boolean> {
    try {
      const manager = calendarManager.getCalendarManager(this.context)
      const account: calendarManager.CalendarAccount = {
        name: this.calendarName,
        type: calendarManager.CalendarType.LOCAL,
        displayName: this.calendarName
      }

      try {
        this.calendar = await manager.getCalendar(account)
      } catch {
        this.calendar = await manager.createCalendar(account)
        await this.calendar.setConfig({ color: '#4CAF50', enableReminder: true })
      }
      return true
    } catch (error) {
      console.error('初始化日历失败:', JSON.stringify(error))
      return false
    }
  }

  async syncTasks(tasks: OrgTask[], existingIds: Set<string>): Promise<SyncResult> {
    const result: SyncResult = {
      total: tasks.length,
      synced: 0,
      errors: [],
      timestamp: Date.now()
    }

    if (!this.calendar && !await this.init()) {
      result.errors.push('无法初始化日历')
      return result
    }

    const calendar = this.calendar
    if (!calendar) {
      result.errors.push('无法获取日历')
      return result
    }

    for (const task of tasks) {
      if (!task.scheduled && !task.deadline) {
        continue
      }

      try {
        // Event 标识符用于后续增量同步时检索和更新。
        if (!existingIds.has(task.id)) {
          await calendar.addEvent(this.taskToEvent(task))
        }
        result.synced++
      } catch (error) {
        result.errors.push(`${task.heading}: ${JSON.stringify(error)}`)
      }
    }

    return result
  }

  private taskToEvent(task: OrgTask): calendarManager.Event {
    const dateStr = task.scheduled || task.deadline || ''
    const isAllDay = !dateStr.includes('T')
    const parsedDate = new Date(dateStr)
    const startTime = isAllDay
      ? new Date(parsedDate.getFullYear(), parsedDate.getMonth(), parsedDate.getDate()).getTime()
      : parsedDate.getTime()
    const endTime = startTime + (isAllDay ? 24 : 1) * 60 * 60 * 1000
    const title = task.priority ? `[#${task.priority}] ${task.heading}` : task.heading
    const description = this.taskDescription(task)
    const reminderTime = task.deadline
      ? [startTime - 24 * 60 * 60 * 1000, startTime - 60 * 60 * 1000]
      : undefined

    return {
      type: calendarManager.EventType.NORMAL,
      title,
      description,
      startTime,
      endTime,
      isAllDay,
      identifier: task.id,
      reminderTime
    }
  }

  private taskDescription(task: OrgTask): string {
    let description = `来源: ${task.fileName}\n状态: ${task.todoState}\n`
    if (task.tags.length > 0) {
      description += `标签: ${task.tags.join(', ')}\n`
    }
    if (task.progress >= 0) {
      description += `进度: ${task.progress}%\n`
    }
    if (task.body) {
      description += `\n${task.body}`
    }
    return description
  }

  async removeEvent(eventId: number): Promise<boolean> {
    if (!this.calendar) {
      return false
    }
    try {
      await this.calendar.deleteEvent(eventId)
      return true
    } catch (error) {
      console.error('删除事件失败:', JSON.stringify(error))
      return false
    }
  }

  async clearAll(eventIds: number[]): Promise<number> {
    let count = 0
    for (const eventId of eventIds) {
      if (await this.removeEvent(eventId)) {
        count++
      }
    }
    return count
  }
}
