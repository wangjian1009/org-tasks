import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { AppDataManager } from './AppDataManager'
import { CoreTask } from './NativeCoreService'
import { PreferencesStore } from './PreferencesStore'
import { TaskReminderSettings } from './TaskReminderSettings'

interface ReminderRecord {
  key: string; when: number; fingerprint: string; notificationId: number; reminderId: number | null
}
interface ReminderJournal { version: number; nextNotificationId: number; records: ReminderRecord[] }
interface DesiredReminder { key: string; when: number; fingerprint: string; task: CoreTask }

const KEY = 'orgTasksReminderKey'
const FINGERPRINT = 'orgTasksReminderFingerprint'
const LIMIT = 30

// 只消费已确认的 Core 快照；系统提醒及恢复日志均为本机状态，不参与文件同步。
export class TaskReminderService {
  private static context: Context | undefined = undefined
  private static unwatch: (() => void) | undefined = undefined
  private static listeners: Set<() => void> = new Set()
  private static statuses: Map<string, string> = new Map()
  private static message: string = '尚未读取任务提醒'
  private static dirty: boolean = false
  private static revision: number = 0
  private static running: Promise<void> | undefined = undefined
  private static timer: number = -1

  static subscribe(listener: () => void): () => void {
    TaskReminderService.listeners.add(listener)
    return (): void => { TaskReminderService.listeners.delete(listener) }
  }
  static summary(): string { return TaskReminderService.message }
  static status(task: CoreTask): string {
    if (task.reminderAt === null || task.reminderAt === undefined) return ''
    if (task.state === null) return '非任务记录不安排提醒'
    if (task.isDone()) return '任务已结束'
    return TaskReminderService.statuses.get(task.id) ?? TaskReminderService.message
  }
  private static publish(): void { for (const listener of TaskReminderService.listeners) listener() }

  static start(context: Context): void {
    TaskReminderService.context = context
    if (!TaskReminderService.unwatch) {
      TaskReminderService.unwatch = AppDataManager.shared(context).dataSet('reminderTasks').subscribe((event): void => {
        if (!event.optimistic) TaskReminderService.refresh(context)
      })
    }
    TaskReminderService.refresh(context)
  }
  static stop(): void {
    TaskReminderService.unwatch?.(); TaskReminderService.unwatch = undefined
    TaskReminderService.context = undefined; TaskReminderService.revision++
    if (TaskReminderService.timer !== -1) clearTimeout(TaskReminderService.timer)
    TaskReminderService.timer = -1
  }
  static refresh(context: Context): Promise<void> {
    TaskReminderService.context = context; TaskReminderService.dirty = true; TaskReminderService.revision++
    if (!TaskReminderService.running) {
      TaskReminderService.running = TaskReminderService.drain().finally((): void => { TaskReminderService.running = undefined })
    }
    return TaskReminderService.running
  }
  private static async drain(): Promise<void> {
    while (TaskReminderService.dirty && TaskReminderService.context) {
      TaskReminderService.dirty = false
      try { await TaskReminderService.reconcile(TaskReminderService.context, TaskReminderService.revision) }
      catch (error) {
        const code = (error as BusinessError).code
        TaskReminderService.message = code === 201 ? '代理提醒权限未开通' : code === 1700001 ? '系统通知未开启' :
          code === 1700002 ? '代理提醒暂不可用，请检查开放能力和系统提醒名额' : `安排提醒失败：${(error as Error).message}`
        TaskReminderService.statuses.clear()
      }
      TaskReminderService.publish()
    }
  }

  private static async reconcile(context: Context, revision: number): Promise<void> {
    if (TaskReminderService.timer !== -1) clearTimeout(TaskReminderService.timer)
    TaskReminderService.timer = -1
    const config = await TaskReminderSettings.load(context)
    const app = AppDataManager.shared(context)
    // 总开关关闭时不依赖查询成功；开启时必须取得完整、已确认、非缓存的快照。
    if (config.enabled) await app.start()
    const dataSet = app.dataSet('reminderTasks')
    const confirmed = dataSet.getConfirmed()
    if (config.enabled && (!dataSet.isReady() || dataSet.error || !confirmed || confirmed.version === 0 || confirmed.data.type !== 'task')) {
      throw new Error(dataSet.error || '任务提醒尚未读取完成')
    }
    const tasks = config.enabled && confirmed?.data.type === 'task' ? confirmed.data.result.tasks : []
    const now = Date.now()
    const desired: DesiredReminder[] = []
    TaskReminderService.statuses.clear()
    for (const task of tasks) {
      const when = task.reminderAt
      if (when === null || when === undefined) continue
      if (when <= now) { TaskReminderService.statuses.set(task.id, '提醒时间已过'); continue }
      const key = JSON.stringify([task.id, when])
      desired.push({ key, when, task, fingerprint: JSON.stringify([key, task.heading, config.ringDuration]) })
    }
    desired.sort((a: DesiredReminder, b: DesiredReminder): number => a.when - b.when || a.key.localeCompare(b.key))
    const store = await PreferencesStore.open(context, 'org_tasks_reminder_state')
    const raw = await store.get('journal', '') as string
    const journal: ReminderJournal = raw ? JSON.parse(raw) as ReminderJournal : { version: 1, nextNotificationId: 100000, records: [] }
    if (journal.version !== 1 || !Array.isArray(journal.records) || !Number.isInteger(journal.nextNotificationId)) throw new Error('提醒恢复记录无效')
    // 每次查询系统实际记录，覆盖发布成功但本地记录未落盘的崩溃窗口。
    let inventory: reminderAgentManager.ReminderInfo[]
    try { inventory = await reminderAgentManager.getAllValidReminders() }
    catch (error) { throw error as Error }
    if (revision !== TaskReminderService.revision) return
    const managed = inventory.filter((info: reminderAgentManager.ReminderInfo): boolean =>
      typeof info.reminderReq.wantAgent?.parameters?.[KEY] === 'string')
    const ringing = new Set<string>()
    for (const info of managed) {
      const key = info.reminderReq.wantAgent!.parameters![KEY] as string
      const record = journal.records.find(record => record.key === key)
      if (config.enabled && record && record.when <= now && now < record.when + config.ringDuration * 1000 &&
        tasks.some(task => task.reminderAt === record.when && JSON.stringify([task.id, record.when]) === key)) ringing.add(key)
    }
    const available = Math.max(0, LIMIT - (inventory.length - managed.length) - ringing.size)
    const chosen = desired.slice(0, available)
    const wanted = new Map<string, DesiredReminder>()
    for (const item of chosen) wanted.set(item.key, item)
    const actual = new Map<string, reminderAgentManager.ReminderInfo>()
    for (const info of managed) {
      const key = info.reminderReq.wantAgent!.parameters![KEY] as string
      const target = wanted.get(key)
      const fingerprint = info.reminderReq.wantAgent!.parameters![FINGERPRINT] as string
      // 已触发且仍响铃的本次提醒占用名额，保留至响铃结束。
      if ((!target || target.fingerprint !== fingerprint || actual.has(key)) && !ringing.has(key)) {
        if (revision !== TaskReminderService.revision) return
        try { await reminderAgentManager.cancelReminder(info.reminderId) }
        catch (error) { if ((error as BusinessError).code !== 1700003) throw error as Error }
      } else actual.set(key, info)
    }
    journal.records = journal.records.filter(record => wanted.has(record.key) || actual.has(record.key))
    for (const item of chosen) {
      if (revision !== TaskReminderService.revision) return
      const existing = actual.get(item.key)
      let record = journal.records.find(record => record.key === item.key)
      if (!record) {
        if (journal.nextNotificationId >= 2147483647) journal.nextNotificationId = 100000
        record = { key: item.key, when: item.when, fingerprint: item.fingerprint,
          notificationId: existing?.reminderReq.notificationId ?? journal.nextNotificationId++, reminderId: existing?.reminderId ?? null }
        journal.records.push(record)
      }
      if (existing) { record.reminderId = existing.reminderId; record.fingerprint = item.fingerprint; continue }
      try { if (!await notificationManager.isNotificationEnabled()) throw new Error('系统通知未开启，请在通知与角标中开启') }
      catch (error) { throw error as Error }
      // 发布前先记录意图，失败或退出后通过系统记录中的 key 恢复，不重复登记。
      record.fingerprint = item.fingerprint; record.reminderId = null
      await TaskReminderService.saveJournal(store, journal)
      const date = new Date(item.when)
      const request: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(),
          hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds() },
        title: '任务提醒', content: item.task.heading, ringDuration: config.ringDuration,
        notificationId: record.notificationId, slotType: notificationManager.SlotType.CONTENT_INFORMATION,
        actionButton: [{ title: '关闭', type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE }],
        wantAgent: { pkgName: 'com.example.orgtasks', abilityName: 'EntryAbility',
          parameters: { orgTasksReminderKey: item.key, orgTasksReminderFingerprint: item.fingerprint } }
      }
      try { record.reminderId = await reminderAgentManager.publishReminder(request) }
      catch (error) { throw error as Error }
      await TaskReminderService.saveJournal(store, journal)
    }
    await TaskReminderService.saveJournal(store, journal)
    for (const item of desired) {
      TaskReminderService.statuses.set(item.task.id, wanted.has(item.key) ? '提醒已安排' : '等待系统提醒名额')
    }
    TaskReminderService.message = config.enabled ? `已安排 ${chosen.length} 次提醒${desired.length > chosen.length ? `，${desired.length - chosen.length} 次等待名额` : ''}` : '本机任务提醒已关闭'
    // 进程存活时清理已触发提醒并补位；进程退出后已登记的提醒仍由系统执行。
    if (config.enabled && (desired.length || ringing.size)) {
      const targets = desired.length ? [desired[0].when] : []
      for (const record of journal.records) if (ringing.has(record.key)) targets.push(record.when)
      const delay = Math.min(60000, Math.max(1000, Math.min(...targets) + config.ringDuration * 1000 + 1000 - Date.now()))
      TaskReminderService.timer = setTimeout((): void => {
        TaskReminderService.timer = -1
        if (TaskReminderService.context) TaskReminderService.refresh(TaskReminderService.context)
      }, delay)
    }
  }
  private static async saveJournal(store: PreferencesStore, journal: ReminderJournal): Promise<void> {
    await store.put('journal', JSON.stringify(journal)); await store.flush()
  }
}
