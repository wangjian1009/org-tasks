// 日历同步服务
// 将 org 任务同步到 HarmonyOS 系统日历

import { Context } from '@kit.AbilityKit'
import { calendarManager } from '@kit.CalendarKit'
import { PreferencesStore } from './PreferencesStore'
import { OrgTask, SyncResult } from '../models/OrgTask'

const PREF_NAME = 'org_tasks_config'
const SYNC_STATE_KEY = 'calendar_sync_state'

interface SyncEventRecord {
  taskId: string
  eventId: number
  fingerprint: string
}

interface StoredSyncState {
  calendarName: string
  records: SyncEventRecord[]
}

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

  async syncTasks(tasks: OrgTask[]): Promise<SyncResult> {
    const result: SyncResult = {
      total: tasks.length,
      synced: 0,
      created: 0,
      updated: 0,
      deleted: 0,
      unchanged: 0,
      skipped: 0,
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

    const records = await this.loadSyncRecords()
    const recordByTaskId = new Map<string, SyncEventRecord>()
    for (const record of records) {
      recordByTaskId.set(record.taskId, record)
    }

    const calendarEvents = await this.getExistingEvents(calendar)
    const activeTaskIds = new Set<string>()

    for (const task of tasks) {
      if (!task.scheduled && !task.deadline) {
        result.skipped++
        continue
      }

      activeTaskIds.add(task.id)
      try {
        const fingerprint = this.taskFingerprint(task)
        let record = recordByTaskId.get(task.id)

        // 日历被手动清空或重新创建后，丢弃失效的事件记录。
        if (record && calendarEvents && !calendarEvents.has(record.eventId)) {
          recordByTaskId.delete(task.id)
          record = undefined
        }

        if (!record && calendarEvents) {
          const existingEventId = this.findEventByIdentifier(calendarEvents, task.id)
          if (existingEventId !== undefined) {
            record = { taskId: task.id, eventId: existingEventId, fingerprint: '' }
            recordByTaskId.set(task.id, record)
          }
        }

        if (!record) {
          const eventId = await calendar.addEvent(this.taskToEvent(task))
          recordByTaskId.set(task.id, { taskId: task.id, eventId, fingerprint })
          result.created++
        } else if (record.fingerprint !== fingerprint) {
          const event = this.taskToEvent(task)
          event.id = record.eventId
          await calendar.updateEvent(event)
          record.fingerprint = fingerprint
          result.updated++
        } else {
          result.unchanged++
        }
        result.synced++
      } catch (error) {
        result.errors.push(`${task.heading}: ${JSON.stringify(error)}`)
      }
    }

    for (const record of records) {
      if (activeTaskIds.has(record.taskId)) {
        continue
      }

      try {
        // 如果用户已手动删除日历事件，只清除本地记录。
        if (!calendarEvents || calendarEvents.has(record.eventId)) {
          await calendar.deleteEvent(record.eventId)
          result.deleted++
        }
        recordByTaskId.delete(record.taskId)
      } catch (error) {
        result.errors.push(`删除日历事件失败: ${JSON.stringify(error)}`)
      }
    }

    await this.saveSyncRecords(Array.from(recordByTaskId.values()))

    return result
  }

  private async getExistingEvents(calendar: calendarManager.Calendar): Promise<Map<number, calendarManager.Event> | undefined> {
    try {
      const events = await calendar.getEvents()
      const eventMap = new Map<number, calendarManager.Event>()
      for (const event of events) {
        if (event.id !== undefined) {
          eventMap.set(event.id, event)
        }
      }
      return eventMap
    } catch (error) {
      console.warn('读取现有日历事件失败，将仅使用本地同步记录:', JSON.stringify(error))
      return undefined
    }
  }

  private findEventByIdentifier(events: Map<number, calendarManager.Event>, taskId: string): number | undefined {
    for (const entry of events.entries()) {
      const eventId = entry[0]
      const event = entry[1]
      if (event.identifier === taskId) {
        return eventId
      }
    }
    return undefined
  }

  private taskFingerprint(task: OrgTask): string {
    return JSON.stringify([
      task.heading,
      (task.state?.name || ''),
      task.priority,
      task.scheduled,
      task.deadline,
      task.tags,
      task.fileName,
      task.body,
      task.progress
    ])
  }

  private async loadSyncRecords(): Promise<SyncEventRecord[]> {
    try {
      const store = await PreferencesStore.open(this.context, PREF_NAME)
      const rawState = await store.get(SYNC_STATE_KEY, '') as string
      if (!rawState) {
        return []
      }

      const state = JSON.parse(rawState) as StoredSyncState
      if (state.calendarName !== this.calendarName || !Array.isArray(state.records)) {
        return []
      }
      return state.records.filter((record) => record.taskId && record.eventId > 0)
    } catch (error) {
      console.warn('读取同步状态失败:', JSON.stringify(error))
      return []
    }
  }

  private async saveSyncRecords(records: SyncEventRecord[]): Promise<void> {
    const store = await PreferencesStore.open(this.context, PREF_NAME)
    const state: StoredSyncState = { calendarName: this.calendarName, records }
    await store.put(SYNC_STATE_KEY, JSON.stringify(state))
    await store.flush()
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
    let description = `来源: ${task.fileName}\n状态: ${(task.state?.name || '')}\n`
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
