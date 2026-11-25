import { localizedText } from '../ui/LocalizedText'
import { BusinessError } from '@kit.BasicServicesKit'
import { Context } from '@kit.AbilityKit'
import { calendarManager } from '@kit.CalendarKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { CoreTask } from './NativeCoreService'
import { calendarEventContent, calendarEventKey, DEFAULT_EVENT_DURATION_MINUTES, REMINDER_CLEANUP_DELAY } from './CalendarEventProjection'

export { REMINDER_CLEANUP_DELAY } from './CalendarEventProjection'

const OWNER = 'org-tasks'
const ACCOUNT = 'org-tasks.reminders'
const DISPLAY_NAME = '小清单提醒'

export interface ReminderCheckResult { registered: boolean; reason: string }
export interface CalendarOperation {
  readonly operation: '新增' | '修改' | '删除'
  readonly heading: string
  readonly reminderAt: number
  readonly eventStartTime: number
  readonly eventEndTime: number
  readonly previousReminderAt: number | null
  readonly eventId: number | null
  readonly succeeded: boolean
  readonly error: string
}
export type CalendarOperationRecorder = (operation: CalendarOperation) => void

interface EventMarker { owner: string; taskKey: string; contentHash: string }
interface MarkedEvent { event: calendarManager.Event; marker?: EventMarker }
interface DesiredEvent { task: CoreTask; marker: EventMarker; event: calendarManager.Event; notificationAt: number; cleanupAt: number }

async function sha256(value: string): Promise<string> {
  try {
    const digest = cryptoFramework.createMd('SHA256')
    await digest.update({ data: new util.TextEncoder().encodeInto(value) })
    const bytes = (await digest.digest()).data
    return Array.from(bytes).map((byte: number): string => byte.toString(16).padStart(2, '0')).join('')

  } catch (error) { throw error as Error }
}

function readMarker(event: calendarManager.Event): EventMarker | undefined {
  if (!event.identifier) return undefined
  let marker: EventMarker
  try { marker = JSON.parse(event.identifier) as EventMarker }
  catch (_) { return undefined }
  if (!marker || marker.owner !== OWNER) return undefined
  if (typeof marker.taskKey !== 'string' || typeof marker.contentHash !== 'string' || !/^[a-f0-9]{64}$/.test(marker.taskKey) || !/^[a-f0-9]{64}$/.test(marker.contentHash) || event.id === undefined) {
    throw new Error(localizedText($r('app.string.text_the_calendar_event_marker_is_invalid_existing')))
  }
  return marker
}

function notificationAt(event: calendarManager.Event): number {
  return event.startTime - (event.reminderTime?.[0] ?? 0) * 60000
}

function cleanupAt(event: calendarManager.Event): number {
  return Math.max(event.endTime, notificationAt(event) + REMINDER_CLEANUP_DELAY)
}

function sameEvent(actual: calendarManager.Event, expected: calendarManager.Event): boolean {
  const actualTimes = actual.reminderTime ?? [], expectedTimes = expected.reminderTime ?? []
  return actual.title === expected.title && actual.startTime === expected.startTime && actual.endTime === expected.endTime &&
    actual.isAllDay === false && actual.type === expected.type && actual.identifier === expected.identifier &&
    actualTimes.length === expectedTimes.length && actualTimes.every((value: number, index: number): boolean => value === expectedTimes[index])
}

// 独立的日历同步过程；只在启动或恢复时遍历系统事件，平时按任务增删改维护内存索引。
export class CalendarSync {
  private readonly context: Context
  private calendar: calendarManager.Calendar | undefined = undefined
  private events: Map<string, calendarManager.Event> = new Map()
  private initialized: boolean = false
  private inventoryLoaded: boolean = false
  private duplicates: calendarManager.Event[] = []

  constructor(context: Context) { this.context = context }
  isReady(): boolean { return this.initialized }
  cleanupTimes(): number[] { return Array.from(this.events.values()).map(event => cleanupAt(event)) }
  invalidate(): void { this.initialized = false; this.inventoryLoaded = false }

  private async open(create: boolean): Promise<calendarManager.Calendar | undefined> {
    try {
      const manager = calendarManager.getCalendarManager(this.context)
      const calendars = await manager.getAllCalendars()
      for (const calendar of calendars) {
        const account = calendar.getAccount()
        if (account.type === calendarManager.CalendarType.LOCAL && account.name === ACCOUNT) return calendar
      }
      if (!create) return undefined
      const calendar = await manager.createCalendar({ name: ACCOUNT, type: calendarManager.CalendarType.LOCAL, displayName: DISPLAY_NAME })
      await calendar.setConfig({ enableReminder: true, color: '#58C2B5' })
      return calendar

    } catch (error) { throw error as Error }
  }

  private async desired(task: CoreTask, durationMinutes: number): Promise<DesiredEvent> {
    const content = calendarEventContent(task, durationMinutes)
    const marker: EventMarker = { owner: OWNER, taskKey: await sha256(task.id), contentHash: await sha256(calendarEventKey(task, durationMinutes)) }
    const event: calendarManager.Event = { type: calendarManager.EventType.NORMAL, title: content.title,
      description: localizedText($r('app.string.calendar_event_description')), startTime: content.startTime, endTime: content.endTime,
      isAllDay: false, reminderTime: content.reminderTime, identifier: JSON.stringify(marker) }
    return { task, marker, event, notificationAt: content.notificationAt, cleanupAt: content.cleanupAt }
  }

  async checkRegistered(task: CoreTask, durationMinutes: number = DEFAULT_EVENT_DURATION_MINUTES): Promise<ReminderCheckResult> {
    try {
      if (task.reminderAt !== null && task.reminderAt !== undefined && task.reminderAt <= Date.now()) return { registered: false, reason: localizedText($r('app.string.text_expired')) }
      const expected = await this.desired(task, durationMinutes)
      const calendar = this.calendar ?? await this.open(false)
      if (!calendar) return { registered: false, reason: localizedText($r('app.string.text_there_is_no_org_tasks_alarm_calendar')) }
      const known = this.events.get(expected.marker.taskKey)
      const filter = known?.id !== undefined ? calendarManager.EventFilter.filterById([known.id]) :
        calendarManager.EventFilter.filterByTime(expected.event.startTime, expected.event.endTime)
      const events = await calendar.getEvents(filter, ['id', 'type', 'title', 'startTime', 'endTime', 'isAllDay', 'reminderTime', 'identifier'])
      const actual = events.find((event: calendarManager.Event): boolean => readMarker(event)?.taskKey === expected.marker.taskKey)
      if (!actual) return { registered: false, reason: localizedText($r('app.string.text_no_corresponding_alarm_was_found_in_the')) }
      if (!sameEvent(actual, expected.event)) return { registered: false, reason: localizedText($r('app.string.text_the_alarm_time_or_content_in_the')) }
      if (calendar.getConfig().enableReminder === false) return { registered: false, reason: localizedText($r('app.string.text_reminders_are_turned_off_for_the_org')) }
      return { registered: true, reason: '' }
    } catch (error) { throw error as Error }
  }

  async synchronize(tasks: CoreTask[], enabled: boolean, current: () => boolean, record: CalendarOperationRecorder, durationMinutes: number = DEFAULT_EVENT_DURATION_MINUTES): Promise<boolean> {
    try {
      this.initialized = false
      const desired: Map<string, DesiredEvent> = new Map()
      for (const task of enabled ? tasks : []) {
        const item = await this.desired(task, durationMinutes)
        if (desired.has(item.marker.taskKey)) throw new Error(localizedText($r('app.string.calendar_duplicate_task_id')))
        desired.set(item.marker.taskKey, item)
      }
      if (!current()) return false
      if (!this.inventoryLoaded) {
        this.calendar = await this.open(enabled)
        if (!current()) return false
        if (this.calendar) {
          const inventory = await this.calendar.getEvents()
          const marked = inventory.map((event: calendarManager.Event): MarkedEvent => ({ event, marker: readMarker(event) }))
          const recovered: Map<string, calendarManager.Event> = new Map()
          const duplicates: calendarManager.Event[] = []
          for (const item of marked) {
            if (!item.marker) continue
            if (recovered.has(item.marker.taskKey)) duplicates.push(item.event)
            else recovered.set(item.marker.taskKey, item.event)
          }
          // 库存独立于来源版本；来源换代时保留已读取库存，继续用内存索引收尾。
          this.events = recovered; this.duplicates = duplicates
        } else { this.events.clear(); this.duplicates = [] }
        this.inventoryLoaded = true
      }
      if (!current()) return false
      for (const item of desired.values()) {
        if (!current()) return false
        await this.upsertDesired(item, current, record)
      }
      for (const entry of Array.from(this.events.entries())) {
        if (!current()) return false
        if (!desired.has(entry[0])) await this.delete(entry[0], record)
      }
      while (this.duplicates.length) {
        if (!current()) return false
        await this.removeEvent(this.duplicates[0], record)
        this.duplicates.shift()
      }
      this.initialized = current()
      return this.initialized
    } catch (error) { this.invalidate(); throw error as Error }
  }

  async apply(removed: CoreTask[], changed: CoreTask[], current: () => boolean, record: CalendarOperationRecorder, durationMinutes: number = DEFAULT_EVENT_DURATION_MINUTES): Promise<boolean> {
    try {
      if (!this.initialized) throw new Error(localizedText($r('app.string.text_calendar_event_not_completed_initial_sync')))
      const prepared: DesiredEvent[] = []
      for (const task of changed) prepared.push(await this.desired(task, durationMinutes))
      const removedKeys: string[] = []
      for (const task of removed) removedKeys.push(await sha256(task.id))
      for (const item of prepared) {
        if (!current()) { this.initialized = false; return false }
        await this.upsertDesired(item, current, record)
      }
      for (const taskKey of removedKeys) {
        if (!current()) { this.initialized = false; return false }
        await this.delete(taskKey, record)
      }
      for (const entry of Array.from(this.events.entries())) {
        if (!current()) { this.initialized = false; return false }
        if (cleanupAt(entry[1]) <= Date.now()) await this.delete(entry[0], record)
      }
      this.initialized = current()
      return this.initialized
    } catch (error) { this.invalidate(); throw error as Error }
  }

  private async upsertDesired(item: DesiredEvent, current: () => boolean, record: CalendarOperationRecorder): Promise<void> {
    try {
      const existing = this.events.get(item.marker.taskKey)
      if (item.notificationAt <= Date.now()) {
        // 已触发实例保留原参数至清理，不因改标题、规划或默认时长重发已过期提醒。
        if (existing && (notificationAt(existing) !== item.notificationAt || cleanupAt(existing) <= Date.now())) await this.delete(item.marker.taskKey, record)
        return
      }
      if (!current()) return
      if (!this.calendar) throw new Error(localizedText($r('app.string.text_the_alarm_calendar_is_not_available')))
      if (this.calendar.getConfig().enableReminder === false) throw new Error(localizedText($r('app.string.text_turn_on_reminders_for_the_org_tasks')))
      if (existing && sameEvent(existing, item.event)) return
      if (existing) {
        item.event.id = existing.id
        await this.writeEvent('修改', item.event, notificationAt(existing), record, async (): Promise<void> => { await this.calendar!.updateEvent(item.event) })
      } else {
        await this.writeEvent('新增', item.event, null, record, async (): Promise<void> => { item.event.id = await this.calendar!.addEvent(item.event) })
      }
      // 即使等待系统写入期间来源换代，也记录已成功的实际 ID，供下一批增量继续处理。
      this.events.set(item.marker.taskKey, item.event)

    } catch (error) { throw error as Error }
  }

  private async delete(taskKey: string, record: CalendarOperationRecorder): Promise<void> {
    try {
      const existing = this.events.get(taskKey)
      if (!existing) return
      if (!this.calendar) throw new Error(localizedText($r('app.string.text_the_alarm_calendar_is_not_available')))
      await this.removeEvent(existing, record)
      this.events.delete(taskKey)

    } catch (error) { throw error as Error }
  }

  private async removeEvent(event: calendarManager.Event, record: CalendarOperationRecorder): Promise<void> {
    await this.writeEvent('删除', event, null, record, async (): Promise<void> => { await this.calendar!.deleteEvent(event.id!) })
  }

  private async writeEvent(operation: '新增' | '修改' | '删除', event: calendarManager.Event,
    previousReminderAt: number | null, record: CalendarOperationRecorder, write: () => Promise<void>): Promise<void> {
    try { await write() }
    catch (error) {
      const code = (error as BusinessError).code
      record({ operation, heading: event.title ?? '', reminderAt: notificationAt(event), eventStartTime: event.startTime, eventEndTime: event.endTime, previousReminderAt,
        eventId: event.id ?? null, succeeded: false,
        error: `${(error as Error).message || localizedText($r('app.string.text_system_calendar_writing_failed'))}${code === undefined ? '' : localizedText($r('app.string.text_error_code'), String(code))}` })
      throw error as Error
    }
    record({ operation, heading: event.title ?? '', reminderAt: notificationAt(event), eventStartTime: event.startTime, eventEndTime: event.endTime, previousReminderAt,
      eventId: event.id ?? null, succeeded: true, error: '' })
  }
}
