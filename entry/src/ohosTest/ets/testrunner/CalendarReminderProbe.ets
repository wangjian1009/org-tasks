import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { calendarManager } from '@kit.CalendarKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { CalendarPermissionService } from '../../../main/ets/services/CalendarPermissionService'

interface CalendarProbeAccount { id: number; name: string; type: calendarManager.CalendarType; displayName?: string }
interface CalendarProbeFailure { stage: string; code: number; message: string }
interface CalendarProbeReport {
  accounts: CalendarProbeAccount[]; mode: string; permission: string; calendarId: number | null; scheduledAt: number | null
  identifierPreserved: boolean; updated: boolean; events: calendarManager.Event[]
}
const NAME = 'org-tasks.calendar-probe'
const MARKER = 'org-tasks-calendar-probe'

// 数据准备只用于专用模拟器；明确授权的真机诊断通过独立日历检查登记和实际投递。
export async function probeCalendarReminders(context: common.Context, mode: string): Promise<void> {
  let stage = 'permission'
  try {
    const creating = mode === 'create' || mode === 'create-long'
    if (await CalendarPermissionService.state() !== 'enabled') throw new Error('请先在应用设置中授予日历读写权限')
    stage = 'manager'
    const manager = calendarManager.getCalendarManager(context)
    stage = 'getAllCalendars'
    const calendars = await manager.getAllCalendars()
    const account = mode === 'events' ? 'org-tasks.reminders' : NAME
    stage = 'getCalendar'
    let calendar = mode === 'events' ? await manager.getCalendar({ name: account, type: calendarManager.CalendarType.LOCAL }) : calendars.find(value => value.getAccount().name === account)
    if (!calendar && creating) {
      stage = 'createCalendar'
      calendar = await manager.createCalendar({ name: NAME, displayName: '小清单日历验收', type: calendarManager.CalendarType.LOCAL })
      stage = 'setConfig'
      await calendar.setConfig({ enableReminder: true })
    }
    const report: CalendarProbeReport = { accounts: calendars.map((value: calendarManager.Calendar): CalendarProbeAccount => {
      const account = value.getAccount(); return { id: value.id, name: account.name, type: account.type, displayName: account.displayName }
    }), mode, permission: await CalendarPermissionService.state(), calendarId: calendar?.id ?? null,
      scheduledAt: null, identifierPreserved: false, updated: false, events: [] }
    if (calendar) {
      stage = 'getEvents'
      let events = await calendar.getEvents()
      if (mode === 'cleanup' || creating) {
        for (const event of events) if (event.identifier?.startsWith(MARKER)) await calendar.deleteEvent(event.id!)
      }
      if (creating) {
        const target = Math.ceil((Date.now() + (mode === 'create-long' ? 20000 : 60000)) / 60000) * 60000
        const identifier = `${MARKER}:${target}`
        const event: calendarManager.Event = { type: calendarManager.EventType.NORMAL, title: '日历提醒创建验收',
          startTime: target, endTime: target + (mode === 'create-long' ? 30 * 60000 : 60000), isAllDay: false, reminderTime: [0], identifier }
        stage = 'addEvent'
        const id = await calendar.addEvent(event)
        stage = 'readBack'
        const found = (await calendar.getEvents()).find(value => value.id === id)
        report.identifierPreserved = found?.identifier === identifier
        if (!report.identifierPreserved) throw new Error('系统日历未保留事件标记')
        event.id = id; event.title = '小清单日历提醒验收'
        stage = 'updateEvent'
        await calendar.updateEvent(event)
        events = await calendar.getEvents()
        report.updated = events.find(value => value.id === id)?.title === event.title
        if (!report.updated) throw new Error('系统日历事件更新未生效')
        report.scheduledAt = target
      }
      report.events = await calendar.getEvents()
      if (mode === 'cleanup' && report.events.length === 0) await manager.deleteCalendar(calendar)
    }
    const file = await fs.open(`${context.filesDir}/calendar-probe.json`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(file.fd, JSON.stringify(report)); await fs.fsync(file.fd) } finally { await fs.close(file) }
  } catch (error) {
    const failure: CalendarProbeFailure = { stage, code: (error as BusinessError).code ?? 0, message: (error as Error).message ?? String(error) }
    try {
    const file = await fs.open(`${context.filesDir}/calendar-probe-error.json`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(file.fd, JSON.stringify(failure)); await fs.fsync(file.fd) } finally { await fs.close(file) }
    } catch (_) { console.error('写入日历验收错误记录失败') }
    throw error as Error
  }
}
