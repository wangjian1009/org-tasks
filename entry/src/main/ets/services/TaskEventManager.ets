import { Context } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AppConfig } from '../models/OrgTask'
import { CoreTask } from './NativeCoreService'
import { DataSet, DataSetDefinition, DataSetEvent, DataSetManager } from './DataSetManager'
import { systemTrashExclusions } from './FileTargetService'
import { CalendarPermissionService, CalendarPermissionState } from './CalendarPermissionService'
import { CalendarSync } from './CalendarSync'
import { TaskReminderSettings } from './TaskReminderSettings'

// 全局事件管理器拥有唯一来源 DataSet；设置列表与事件同步共用它，系统只消费已确认快照。
export class TaskEventManager {
  private static context: Context | undefined = undefined
  private static manager: DataSetManager | undefined = undefined
  private static source: DataSet | undefined = undefined
  private static calendar: CalendarSync | undefined = undefined
  private static unwatch: (() => void) | undefined = undefined
  private static listeners: Set<() => void> = new Set()
  private static applied: Map<string, CoreTask> = new Map()
  private static sourceStarted: boolean = false
  private static dirty: boolean = false
  private static generation: number = 0
  private static revision: number = 0
  private static running: Promise<void> | undefined = undefined
  private static enabled: boolean | undefined = undefined
  private static permission: CalendarPermissionState | undefined = undefined
  private static message: string = '正在读取提醒任务…'
  private static timer: number = -1

  static dataSet(context: Context): DataSet {
    if (!TaskEventManager.manager) {
      TaskEventManager.context = context
      TaskEventManager.calendar = new CalendarSync(context)
      TaskEventManager.manager = DataSetManager.create(context, 'events', (config: AppConfig): DataSetDefinition[] => {
        const trash = systemTrashExclusions(config)
        return [{ name: 'tasks', query: { type: 'task', query: {
          expression: 'it.todo has.reminder o.reminder', excludeFiles: trash.files,
        } }, repositoryBindings: trash.repositoryBindings }]
      }, { cache: false })
      TaskEventManager.source = TaskEventManager.manager.dataSet('tasks')
      TaskEventManager.unwatch = TaskEventManager.source.subscribe((event: DataSetEvent): void => {
        if (!event.optimistic && TaskEventManager.sourceStarted && TaskEventManager.source?.isReady()) TaskEventManager.schedule()
      })
    }
    return TaskEventManager.source!
  }

  static start(context: Context): void {
    TaskEventManager.refresh(context).catch((error: Error): void => { console.error(`初始化全局事件失败：${error.message}`) })
  }

  static async refresh(context: Context): Promise<void> {
    TaskEventManager.dataSet(context)
    const generation = TaskEventManager.generation
    try { await TaskEventManager.manager!.start() }
    catch (error) {
      if (generation === TaskEventManager.generation) {
        TaskEventManager.source?.reportError(error as Error)
        TaskEventManager.message = (error as Error).message; TaskEventManager.publish()
      }
      return
    }
    if (!TaskEventManager.context || generation !== TaskEventManager.generation) return
    TaskEventManager.sourceStarted = true
    TaskEventManager.schedule()
    while (TaskEventManager.running) await TaskEventManager.running
  }

  static stop(): void {
    TaskEventManager.generation++; TaskEventManager.revision++
    TaskEventManager.unwatch?.(); TaskEventManager.unwatch = undefined
    const manager = TaskEventManager.manager
    TaskEventManager.context = undefined; TaskEventManager.manager = undefined; TaskEventManager.source = undefined
    TaskEventManager.calendar = undefined; TaskEventManager.applied.clear(); TaskEventManager.enabled = undefined
    TaskEventManager.permission = undefined; TaskEventManager.sourceStarted = false; TaskEventManager.dirty = false
    if (TaskEventManager.timer !== -1) clearTimeout(TaskEventManager.timer)
    TaskEventManager.timer = -1
    manager?.close().catch((): void => { console.error('关闭全局事件数据集失败') })
  }

  static subscribe(listener: () => void): () => void {
    TaskEventManager.listeners.add(listener)
    return (): void => { TaskEventManager.listeners.delete(listener) }
  }
  static summary(): string { return TaskEventManager.message }
  static status(task: CoreTask): string {
    if (task.reminderAt === null || task.reminderAt === undefined) return ''
    if (task.state === null) return '非任务记录不安排提醒'
    if (task.isDone()) return '任务已结束'
    if (task.reminderAt <= Date.now()) return '提醒时间已过'
    const applied = TaskEventManager.applied.get(task.id)
    if (applied && applied.heading === task.heading && applied.reminderAt === task.reminderAt &&
      TaskEventManager.enabled && TaskEventManager.permission === 'enabled' && TaskEventManager.calendar?.isReady()) return '日历提醒已设置'
    return TaskEventManager.message
  }
  private static publish(): void { for (const listener of TaskEventManager.listeners) listener() }

  private static schedule(): void {
    if (!TaskEventManager.context) return
    TaskEventManager.dirty = true; TaskEventManager.revision++
    if (!TaskEventManager.running) {
      TaskEventManager.running = TaskEventManager.drain().finally((): void => {
        TaskEventManager.running = undefined
        if (TaskEventManager.dirty && TaskEventManager.context) TaskEventManager.schedule()
      })
    }
  }

  private static async drain(): Promise<void> {
    while (TaskEventManager.dirty && TaskEventManager.context) {
      TaskEventManager.dirty = false
      const generation = TaskEventManager.generation, revision = TaskEventManager.revision
      const current = (): boolean => generation === TaskEventManager.generation && revision === TaskEventManager.revision && TaskEventManager.context !== undefined
      try { await TaskEventManager.maintain(TaskEventManager.context, current) }
      catch (error) {
        if (!current()) continue
        TaskEventManager.calendar?.invalidate()
        TaskEventManager.message = (error as BusinessError).code === 201 ? '日历读写未授权，请在设置中授权' : `安排日历提醒失败：${(error as Error).message}`
        TaskEventManager.publish()
      }
    }
  }

  private static async maintain(context: Context, current: () => boolean): Promise<void> {
    const config = await TaskReminderSettings.load(context)
    const permission = await CalendarPermissionService.state()
    if (!current()) return
    if (TaskEventManager.enabled !== config.enabled || TaskEventManager.permission !== permission) TaskEventManager.calendar!.invalidate()
    TaskEventManager.enabled = config.enabled; TaskEventManager.permission = permission
    if (permission !== 'enabled') {
      TaskEventManager.message = config.enabled ? '日历读写未授权，请在设置中授权' : '本机任务提醒已关闭'
      TaskEventManager.publish(); return
    }
    const source = TaskEventManager.source!
    const confirmed = source.getConfirmed()
    if (config.enabled && (!source.isReady() || source.error || !confirmed || confirmed.version === 0 || confirmed.data.type !== 'task')) {
      TaskEventManager.message = source.error || '正在读取提醒任务…'
      TaskEventManager.publish(); return
    }
    const tasks = config.enabled && confirmed?.data.type === 'task' ? confirmed.data.result.tasks : []
    const desired: Map<string, CoreTask> = new Map()
    for (const task of tasks) {
      if (desired.has(task.id)) throw new Error('提醒任务身份重复')
      desired.set(task.id, task)
    }
    const calendar = TaskEventManager.calendar!
    let completed: boolean
    if (!calendar.isReady()) completed = await calendar.synchronize(tasks, config.enabled, current)
    else {
      const removed = Array.from(TaskEventManager.applied.values()).filter(task => !desired.has(task.id))
      const changed = tasks.filter(task => {
        const before = TaskEventManager.applied.get(task.id)
        return !before || before.heading !== task.heading || before.reminderAt !== task.reminderAt
      })
      completed = await calendar.apply(removed, changed, current)
    }
    if (!completed || calendar !== TaskEventManager.calendar) return
    TaskEventManager.applied = desired
    if (!current()) return
    TaskEventManager.message = config.enabled ? `已设置 ${tasks.filter(task => task.reminderAt! > Date.now()).length} 项日历提醒` : '本机任务提醒已关闭'
    TaskEventManager.updateTimer(tasks)
    TaskEventManager.publish()
  }

  private static updateTimer(tasks: CoreTask[]): void {
    if (TaskEventManager.timer !== -1) clearTimeout(TaskEventManager.timer)
    TaskEventManager.timer = -1
    const future = tasks.map(task => task.reminderAt!).filter(when => when > Date.now())
    if (!future.length) return
    TaskEventManager.timer = setTimeout((): void => {
      TaskEventManager.timer = -1; TaskEventManager.publish(); TaskEventManager.updateTimer(tasks)
    }, Math.min(2147483647, Math.max(1, Math.min(...future) - Date.now() + 500)))
  }
}
