import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { CoreTask } from './NativeCoreService'
import { DataSet, DataSetEvent } from './DataSet'
import { CalendarPermissionService, CalendarPermissionState } from './CalendarPermissionService'
import { CalendarSync, ReminderCheckResult, CalendarOperation } from './CalendarSync'
import { TaskReminderSettings, TaskReminderConfiguration } from './TaskReminderSettings'
import { calendarEventKey, DEFAULT_EVENT_DURATION_MINUTES } from './CalendarEventProjection'

export { TaskReminderConfiguration } from './TaskReminderSettings'
export { CalendarPermissionState } from './CalendarPermissionService'
export { ReminderCheckResult } from './CalendarSync'

export type ReminderOperationTrigger = '启动同步' | '任务修改' | '设置变更' | '恢复同步' | '过期清理'
export interface ReminderOperationLog extends CalendarOperation {
  readonly id: number
  readonly at: number
  readonly trigger: ReminderOperationTrigger
}

interface AppliedReminder { task: CoreTask; key: string }

const OPERATION_LOG_LIMIT = 500

// 由 AppDataManager 注册共享来源；集中管理本机提醒、授权、系统核实与确认快照的日历维护。
export class ReminderManager {
  private static context: Context | undefined = undefined
  private static source: DataSet | undefined = undefined
  private static calendar: CalendarSync | undefined = undefined
  private static unwatch: (() => void) | undefined = undefined
  private static listeners: Set<() => void> = new Set()
  private static applied: Map<string, AppliedReminder> = new Map()
  private static sourceStarted: boolean = false
  private static checks: Map<string, Promise<ReminderCheckResult>> = new Map()
  private static dirty: boolean = false
  private static generation: number = 0
  private static revision: number = 0
  private static running: Promise<void> | undefined = undefined
  private static enabled: boolean | undefined = undefined
  private static permission: CalendarPermissionState | undefined = undefined
  private static eventDurationMinutes: number = DEFAULT_EVENT_DURATION_MINUTES
  private static message: string = '正在读取提醒任务…'
  private static timer: number = -1
  private static operationHistory: ReminderOperationLog[] = []
  private static operationListeners: Set<() => void> = new Set()
  private static operationSequence: number = 0
  private static initialSyncCompleted: boolean = false
  private static pendingTrigger: ReminderOperationTrigger = '启动同步'

  static register(context: Context, source: DataSet): void {
    if (ReminderManager.source === source) return
    if (ReminderManager.source) throw new Error('提醒管理器已注册其他数据集')
    ReminderManager.context = context
    ReminderManager.source = source
    ReminderManager.calendar = new CalendarSync(context)
    ReminderManager.unwatch = source.subscribe((event: DataSetEvent): void => {
      // 失效与错误同样使旧批次停止；乐观修改只影响展示，不写入系统。
      if (!event.optimistic && ReminderManager.sourceStarted) ReminderManager.schedule()
    })
  }

  static dataSet(): DataSet {
    if (!ReminderManager.source) throw new Error('提醒管理器尚未注册')
    return ReminderManager.source
  }

  private static hostContext(): Context {
    if (!ReminderManager.context) throw new Error('提醒管理器尚未注册')
    return ReminderManager.context
  }

  static configuration(): Promise<TaskReminderConfiguration> {
    return TaskReminderSettings.load(ReminderManager.hostContext())
  }
  static permissionState(): Promise<CalendarPermissionState> { return CalendarPermissionService.state() }
  static async managePermission(): Promise<void> {
    await CalendarPermissionService.manage(ReminderManager.hostContext())
    await ReminderManager.refresh('设置变更')
  }
  static async setEnabled(enabled: boolean): Promise<void> {
    const context = ReminderManager.hostContext()
    if (enabled && !await CalendarPermissionService.request(context)) throw new Error('未获得日历读写权限，提醒未开启')
    await TaskReminderSettings.save(context, { enabled })
    ReminderManager.refresh('设置变更').catch((error: Error): void => { console.error(`刷新任务提醒失败：${error.message}`) })
  }

  static async setEventDurationMinutes(minutes: number): Promise<void> {
    await TaskReminderSettings.save(ReminderManager.hostContext(), { eventDurationMinutes: minutes })
    ReminderManager.refresh('设置变更').catch((error: Error): void => { console.error(`刷新任务提醒失败：${error.message}`) })
  }

  static contentKey(task: CoreTask): string { return calendarEventKey(task, ReminderManager.eventDurationMinutes) }

  static start(): void {
    if (ReminderManager.sourceStarted) return
    ReminderManager.refresh('启动同步').catch((error: Error): void => { console.error(`初始化提醒管理器失败：${error.message}`) })
  }

  static async refresh(trigger: ReminderOperationTrigger = '恢复同步'): Promise<void> {
    if (!ReminderManager.context) return
    ReminderManager.sourceStarted = true
    ReminderManager.schedule(trigger)
    while (ReminderManager.running) await ReminderManager.running
  }

  // 合并同一任务的在途核实；每次展开仍读取系统状态，不把上次同步成功当成当前登记事实。
  static checkRegistered(task: CoreTask): Promise<ReminderCheckResult> {
    if (task.reminderAt === null || task.reminderAt === undefined) return Promise.resolve<ReminderCheckResult>({ registered: false, reason: '任务未设置提醒时间' })
    if (task.reminderAt !== null && task.reminderAt !== undefined && task.reminderAt <= Date.now()) return Promise.resolve<ReminderCheckResult>({ registered: false, reason: '已过期' })
    const key = JSON.stringify([ReminderManager.generation, ReminderManager.revision, task.id, ReminderManager.contentKey(task), task.state])
    const pending = ReminderManager.checks.get(key)
    if (pending) return pending
    const generation = ReminderManager.generation, calendar = ReminderManager.calendar
    const work = (async (): Promise<ReminderCheckResult> => {
      while (ReminderManager.running) await ReminderManager.running
      const context = ReminderManager.hostContext()
      const config = await TaskReminderSettings.load(context)
      if (generation !== ReminderManager.generation || calendar !== ReminderManager.calendar) throw new Error('提醒管理器已停止，请重新展开任务')
      if (!config.enabled) return { registered: false, reason: '本机任务提醒已关闭' }
      const permission = await ReminderManager.permissionState()
      if (generation !== ReminderManager.generation || calendar !== ReminderManager.calendar || !calendar) throw new Error('提醒管理器已停止，请重新展开任务')
      if (permission !== 'enabled') return { registered: false, reason: '未获得日历读写权限' }
      if (task.reminderAt === null || task.reminderAt === undefined) return { registered: false, reason: '任务未设置提醒时间' }
      const result = await calendar.checkRegistered(task, config.eventDurationMinutes)
      if (generation !== ReminderManager.generation || calendar !== ReminderManager.calendar) throw new Error('提醒管理器已停止，请重新展开任务')
      return result
    })().catch((error: BusinessError): ReminderCheckResult => {
      const code = error.code === undefined ? '' : `（错误码 ${error.code}）`
      throw new Error(`${error.message || '系统提醒查询失败'}${code}`)
    }).finally((): void => { if (ReminderManager.checks.get(key) === work) ReminderManager.checks.delete(key) })
    ReminderManager.checks.set(key, work)
    return work
  }

  static async stop(): Promise<void> {
    const running = ReminderManager.running
    ReminderManager.generation++; ReminderManager.revision++
    ReminderManager.unwatch?.(); ReminderManager.unwatch = undefined
    ReminderManager.context = undefined; ReminderManager.source = undefined
    ReminderManager.calendar = undefined; ReminderManager.applied.clear(); ReminderManager.enabled = undefined
    ReminderManager.eventDurationMinutes = DEFAULT_EVENT_DURATION_MINUTES
    ReminderManager.permission = undefined; ReminderManager.sourceStarted = false; ReminderManager.dirty = false
    ReminderManager.checks.clear()
    ReminderManager.operationHistory = []; ReminderManager.operationSequence = 0
    ReminderManager.initialSyncCompleted = false; ReminderManager.pendingTrigger = '启动同步'
    ReminderManager.publishOperations()
    ReminderManager.message = '正在读取提醒任务…'
    if (ReminderManager.timer !== -1) clearTimeout(ReminderManager.timer)
    ReminderManager.timer = -1
    await running
  }

  static operationLogs(): ReminderOperationLog[] { return ReminderManager.operationHistory.slice() }
  static subscribeOperations(listener: () => void): () => void {
    ReminderManager.operationListeners.add(listener)
    return (): void => { ReminderManager.operationListeners.delete(listener) }
  }
  private static publishOperations(): void {
    for (const listener of ReminderManager.operationListeners) {
      try { listener() } catch (_) { console.error('更新提醒操作日志展示失败') }
    }
  }
  private static recordOperation(operation: CalendarOperation, trigger: ReminderOperationTrigger): void {
    ReminderManager.operationHistory.unshift({ id: ++ReminderManager.operationSequence, at: Date.now(), trigger,
      operation: operation.operation, heading: operation.heading, reminderAt: operation.reminderAt,
      eventStartTime: operation.eventStartTime, eventEndTime: operation.eventEndTime,
      previousReminderAt: operation.previousReminderAt, eventId: operation.eventId,
      succeeded: operation.succeeded, error: operation.error })
    if (ReminderManager.operationHistory.length > OPERATION_LOG_LIMIT) ReminderManager.operationHistory.length = OPERATION_LOG_LIMIT
    ReminderManager.publishOperations()
  }

  static subscribe(listener: () => void): () => void {
    ReminderManager.listeners.add(listener)
    return (): void => { ReminderManager.listeners.delete(listener) }
  }
  static summary(): string { return ReminderManager.message }
  static status(task: CoreTask): string {
    if (task.reminderAt === null || task.reminderAt === undefined) return ''
    if (task.state === null) return '非任务记录不安排提醒'
    if (task.isDone()) return '任务已结束'
    if (task.reminderAt <= Date.now()) return '已过期'
    const applied = ReminderManager.applied.get(task.id)
    if (applied && applied.key === ReminderManager.contentKey(task) &&
      ReminderManager.enabled && ReminderManager.permission === 'enabled' && ReminderManager.calendar?.isReady()) return '日历提醒已设置'
    return ReminderManager.message
  }
  private static publish(): void { for (const listener of ReminderManager.listeners) listener() }

  private static schedule(trigger: ReminderOperationTrigger = '任务修改'): void {
    if (!ReminderManager.context) return
    ReminderManager.pendingTrigger = trigger
    ReminderManager.dirty = true; ReminderManager.revision++
    if (!ReminderManager.running) {
      ReminderManager.running = ReminderManager.drain().finally((): void => {
        ReminderManager.running = undefined
        if (ReminderManager.dirty && ReminderManager.context) ReminderManager.schedule(ReminderManager.pendingTrigger)
      })
    }
  }

  private static async drain(): Promise<void> {
    while (ReminderManager.dirty && ReminderManager.context) {
      ReminderManager.dirty = false
      const generation = ReminderManager.generation, revision = ReminderManager.revision
      const trigger = ReminderManager.initialSyncCompleted || ReminderManager.pendingTrigger === '设置变更' ? ReminderManager.pendingTrigger : '启动同步'
      const current = (): boolean => generation === ReminderManager.generation && revision === ReminderManager.revision && ReminderManager.context !== undefined
      try { await ReminderManager.maintain(ReminderManager.context, current, trigger) }
      catch (error) {
        if (!current()) continue
        ReminderManager.calendar?.invalidate()
        ReminderManager.message = (error as BusinessError).code === 201 ? '日历读写未授权，请在设置中授权' : `安排日历提醒失败：${(error as Error).message}`
        ReminderManager.publish()
      }
    }
  }

  private static async maintain(context: Context, current: () => boolean, trigger: ReminderOperationTrigger): Promise<void> {
    const config = await TaskReminderSettings.load(context)
    const permission = await CalendarPermissionService.state()
    if (!current()) return
    const settingsChanged = ReminderManager.enabled !== undefined &&
      (ReminderManager.enabled !== config.enabled || ReminderManager.permission !== permission || ReminderManager.eventDurationMinutes !== config.eventDurationMinutes)
    if (settingsChanged) trigger = '设置变更'
    if (ReminderManager.enabled !== config.enabled || ReminderManager.permission !== permission) ReminderManager.calendar!.invalidate()
    ReminderManager.enabled = config.enabled; ReminderManager.permission = permission
    ReminderManager.eventDurationMinutes = config.eventDurationMinutes
    if (permission !== 'enabled') {
      ReminderManager.message = config.enabled ? '日历读写未授权，请在设置中授权' : '本机任务提醒已关闭'
      ReminderManager.publish(); return
    }
    const source = ReminderManager.source!
    const confirmed = source.getConfirmed()
    if (config.enabled && (!source.hasValidScope() || !source.isReady() || source.error || !confirmed || confirmed.version === 0 || confirmed.data.type !== 'task')) {
      ReminderManager.message = source.error || '正在读取提醒任务…'
      ReminderManager.publish(); return
    }
    const tasks = config.enabled && confirmed?.data.type === 'task' ? confirmed.data.result.tasks : []
    const desired: Map<string, AppliedReminder> = new Map()
    for (const task of tasks) {
      if (desired.has(task.id)) throw new Error('提醒任务身份重复')
      desired.set(task.id, { task, key: calendarEventKey(task, config.eventDurationMinutes) })
    }
    const calendar = ReminderManager.calendar!
    const generation = ReminderManager.generation
    const record = (operation: CalendarOperation): void => {
      // 停止后的迟到写入不进入下一次管理器会话的日志。
      if (generation === ReminderManager.generation && context === ReminderManager.context) ReminderManager.recordOperation(operation, trigger)
    }
    let completed: boolean
    if (!calendar.isReady()) completed = await calendar.synchronize(tasks, config.enabled, current, record, config.eventDurationMinutes)
    else {
      const removed = Array.from(ReminderManager.applied.values()).map(item => item.task).filter(task => !desired.has(task.id))
      const changed = tasks.filter(task => {
        const before = ReminderManager.applied.get(task.id)
        return !before || before.key !== desired.get(task.id)!.key
      })
      completed = await calendar.apply(removed, changed, current, record, config.eventDurationMinutes)
    }
    if (!completed || calendar !== ReminderManager.calendar) return
    ReminderManager.applied = desired
    ReminderManager.initialSyncCompleted = true
    if (!current()) return
    ReminderManager.message = config.enabled ? `已设置 ${tasks.filter(task => task.reminderAt! > Date.now()).length} 项日历提醒` : '本机任务提醒已关闭'
    ReminderManager.updateTimer(tasks)
    ReminderManager.publish()
  }

  private static updateTimer(tasks: CoreTask[]): void {
    if (ReminderManager.timer !== -1) clearTimeout(ReminderManager.timer)
    ReminderManager.timer = -1
    const scheduledAt = Date.now()
    const cleanupTimes = ReminderManager.calendar?.cleanupTimes() ?? []
    const times = tasks.map(task => task.reminderAt!).concat(cleanupTimes).filter(when => when > scheduledAt)
    if (!times.length) return
    ReminderManager.timer = setTimeout((): void => {
      ReminderManager.timer = -1
      const cleanupDue = cleanupTimes.some(when => when > scheduledAt && when <= Date.now())
      if (cleanupDue) ReminderManager.schedule('过期清理')
      else { ReminderManager.publish(); ReminderManager.updateTimer(tasks) }
    }, Math.min(2147483647, Math.max(1, Math.min(...times) - scheduledAt + 500)))
  }
}
