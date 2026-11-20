import { BusinessError } from '@kit.BasicServicesKit'
import { Context } from '@kit.AbilityKit'
import { calendarManager } from '@kit.CalendarKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { CoreTask } from './NativeCoreService'

const OWNER = 'org-tasks'
const ACCOUNT = 'org-tasks.reminders'
const DISPLAY_NAME = '小清单提醒'
const EVENT_DURATION = 60 * 1000
export const REMINDER_CLEANUP_DELAY = 30 * 60 * 1000

export interface ReminderCheckResult { registered: boolean; reason: string }
export interface CalendarOperation {
  readonly operation: '新增' | '修改' | '删除'
  readonly heading: string
  readonly reminderAt: number
  readonly previousReminderAt: number | null
  readonly eventId: number | null
  readonly succeeded: boolean
  readonly error: string
}
export type CalendarOperationRecorder = (operation: CalendarOperation) => void

interface EventMarker { owner: string; taskKey: string; contentHash: string }
interface MarkedEvent { event: calendarManager.Event; marker?: EventMarker }
interface DesiredEvent { task: CoreTask; marker: EventMarker; event: calendarManager.Event }

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
    throw new Error('应用日历事件标记无效，已保留现有事件')
  }
  return marker
}

function sameEvent(actual: calendarManager.Event, expected: calendarManager.Event): boolean {
  return actual.title === expected.title && actual.startTime === expected.startTime && actual.endTime === expected.endTime &&
    actual.isAllDay === false && actual.type === expected.type &&
    actual.reminderTime?.length === 1 && actual.reminderTime[0] === 0 && actual.identifier === expected.identifier
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

  private async desired(task: CoreTask): Promise<DesiredEvent> {
    const when = task.reminderAt
    if (when === null || when === undefined || !Number.isFinite(when)) throw new Error('任务提醒时间无效')
    const marker: EventMarker = { owner: OWNER, taskKey: await sha256(task.id), contentHash: await sha256(JSON.stringify([task.heading, when])) }
    const event: calendarManager.Event = { type: calendarManager.EventType.NORMAL, title: task.heading,
      description: '由小清单创建的任务提醒', startTime: when, endTime: when + EVENT_DURATION,
      isAllDay: false, reminderTime: [0], identifier: JSON.stringify(marker) }
    return { task, marker, event }
  }

  async checkRegistered(task: CoreTask): Promise<ReminderCheckResult> {
    try {
      if (task.reminderAt !== null && task.reminderAt !== undefined && task.reminderAt <= Date.now()) return { registered: false, reason: '已过期' }
      const expected = await this.desired(task)
      const calendar = this.calendar ?? await this.open(false)
      if (!calendar) return { registered: false, reason: '系统中不存在“小清单提醒”日历' }
      const known = this.events.get(expected.marker.taskKey)
      const filter = known?.id !== undefined ? calendarManager.EventFilter.filterById([known.id]) :
        calendarManager.EventFilter.filterByTime(expected.event.startTime, expected.event.endTime)
      const events = await calendar.getEvents(filter, ['id', 'type', 'title', 'startTime', 'endTime', 'isAllDay', 'reminderTime', 'identifier'])
      const actual = events.find((event: calendarManager.Event): boolean => readMarker(event)?.taskKey === expected.marker.taskKey)
      if (!actual) return { registered: false, reason: '系统日历中未找到对应提醒，可能已被删除' }
      if (!sameEvent(actual, expected.event)) return { registered: false, reason: '系统日历中的提醒时间或内容与任务不一致' }
      if (calendar.getConfig().enableReminder === false) return { registered: false, reason: '系统日历中“小清单提醒”的提醒开关已关闭' }
      return { registered: true, reason: '' }
    } catch (error) { throw error as Error }
  }

  async synchronize(tasks: CoreTask[], enabled: boolean, current: () => boolean, record: CalendarOperationRecorder): Promise<boolean> {
    try {
      this.initialized = false
      const desired: Map<string, DesiredEvent> = new Map()
      for (const task of enabled ? tasks : []) {
        const item = await this.desired(task)
        if (desired.has(item.marker.taskKey)) throw new Error('提醒任务身份重复')
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

  async apply(removed: CoreTask[], changed: CoreTask[], current: () => boolean, record: CalendarOperationRecorder): Promise<boolean> {
    try {
      if (!this.initialized) throw new Error('日历事件尚未完成初次同步')
      const prepared: DesiredEvent[] = []
      for (const task of changed) prepared.push(await this.desired(task))
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
        if (entry[1].startTime + REMINDER_CLEANUP_DELAY <= Date.now()) await this.delete(entry[0], record)
      }
      this.initialized = current()
      return this.initialized
    } catch (error) { this.invalidate(); throw error as Error }
  }

  private async upsertDesired(item: DesiredEvent, current: () => boolean, record: CalendarOperationRecorder): Promise<void> {
    try {
      const existing = this.events.get(item.marker.taskKey)
      if (item.event.startTime <= Date.now()) {
        // 已到点实例保留 30 分钟供系统交付，之后按内存索引清理；不补发过去的提醒。
        if (existing && (existing.startTime > Date.now() || existing.identifier !== item.event.identifier || existing.startTime + REMINDER_CLEANUP_DELAY <= Date.now())) await this.delete(item.marker.taskKey, record)
        return
      }
      if (!current()) return
      if (!this.calendar) throw new Error('应用提醒日历不可用')
      if (this.calendar.getConfig().enableReminder === false) throw new Error('请在系统日历中开启“小清单提醒”的提醒')
      if (existing && sameEvent(existing, item.event)) return
      if (existing) {
        item.event.id = existing.id
        await this.writeEvent('修改', item.event, existing.startTime, record, async (): Promise<void> => { await this.calendar!.updateEvent(item.event) })
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
      if (!this.calendar) throw new Error('应用提醒日历不可用')
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
      record({ operation, heading: event.title ?? '', reminderAt: event.startTime, previousReminderAt,
        eventId: event.id ?? null, succeeded: false,
        error: `${(error as Error).message || '系统日历写入失败'}${code === undefined ? '' : `（错误码 ${code}）`}` })
      throw error as Error
    }
    record({ operation, heading: event.title ?? '', reminderAt: event.startTime, previousReminderAt,
      eventId: event.id ?? null, succeeded: true, error: '' })
  }
}
