import { Context } from '@kit.AbilityKit'
import { CoreTask, CoreTaskModification, CoreRefileTarget } from './NativeCoreService'
import { TaskInlineService, TaskInlineMissingError } from './TaskInlineService'
import { MoveToTargetService } from './MoveToTargetService'
import { CoreDataChangeService, CoreDataChangeState } from './CoreDataChangeService'
import { DataSetManager } from './DataSetManager'

export { TaskInlineMissingError }
type TaskEditorDataState = CoreDataChangeState
export interface TaskEditorChange { task?: CoreTask; removed?: boolean; blocked?: boolean; error?: string; rejectedChanges?: CoreTaskModification[] }

// 一个编辑器只持有一个已经绑定的记录数据集，不选择查询范围或解释提交事件。
export class TaskEditorDataSet {
  readonly key: string
  recordKey: string
  task: CoreTask
  reading: Promise<void> = Promise.resolve()
  loading: boolean = false
  error: Error | undefined = undefined
  removed: boolean = false
  revision: number = -1
  request: number = 0
  listeners: Set<(change: TaskEditorChange) => void> = new Set()
  constructor(key: string, task: CoreTask) {
    this.key = key; this.task = task; this.recordKey = JSON.stringify([task.repoId, task.id])
  }
}

// 组合层绑定页面数据集或文件来源，数据读取、身份映射和监控集中在管理层。
export class TaskEditorDataManager {
  private context: Context | undefined = undefined
  private documentMode: boolean = false
  private manager: DataSetManager | undefined = undefined
  private name: string = ''
  private revision: number = 0
  private stopMonitor: (() => void) | undefined = undefined
  private dataSets: Map<string, TaskEditorDataSet> = new Map()
  constructor(context?: Context, documentMode: boolean = false) { this.context = context; this.documentMode = documentMode }
  static managed(manager: DataSetManager, name: string): TaskEditorDataManager {
    const result = new TaskEditorDataManager()
    result.manager = manager; result.name = name
    return result
  }
  dataSet(task: CoreTask): TaskEditorDataSet {
    const recordKey = JSON.stringify([task.repoId, task.id])
    const key = this.manager?.itemKey(this.name, recordKey) ?? recordKey
    let data = this.dataSets.get(key)
    if (!data) { data = new TaskEditorDataSet(key, task); this.dataSets.set(key, data) }
    if (!this.manager && data.listeners.size === 0) { data.task = task; data.error = undefined; data.removed = false }
    return data
  }
  dataSetForTaskId(taskId: string): TaskEditorDataSet | undefined {
    return Array.from(this.dataSets.values()).find(data => data.task.id === taskId || data.task.taskId === taskId)
  }
  snapshot(data: TaskEditorDataSet): CoreTask | undefined {
    return this.manager ? this.manager.findTask(this.name, data.recordKey) : data.removed ? undefined : data.task
  }
  async current(data: TaskEditorDataSet): Promise<CoreTask> {
    if (!this.manager) { await data.reading; if (data.error) throw data.error }
    const task = this.snapshot(data)
    if (!task) throw new TaskInlineMissingError()
    return task
  }
  async modify(data: TaskEditorDataSet, source: CoreTask, changes: CoreTaskModification[]): Promise<void> {
    if (!changes.length) return
    if (this.manager) this.manager.updateFields(this.name, data.recordKey, changes, source.fileVersion)
    else {
      await this.update(source, changes)
      if (!data.loading) this.readRecord(data, source, this.revision, true)
      await data.reading
    }
  }
  private readRecord(data: TaskEditorDataSet, source: CoreTask, revision: number, force: boolean = false): void {
    if (!force && data.revision === revision) return
    data.revision = revision; data.loading = true
    const request = ++data.request
    data.reading = Promise.resolve().then(async (): Promise<void> => {
      if (request !== data.request || data.listeners.size === 0) { if (request === data.request) data.loading = false; return }
      try {
        const task = await this.findChanged(source, revision)
        if (request !== data.request) return
        data.error = undefined; data.removed = !task
        if (task) data.task = task
        for (const listener of data.listeners) listener(task ? { task } : { removed: true })
      } catch (error) {
        if (request !== data.request) return
        data.error = error as Error
        for (const listener of data.listeners) listener({ error: data.error.message })
      } finally { if (request === data.request) data.loading = false }
    })
  }
  watchDataSet(data: TaskEditorDataSet, listener: (change: TaskEditorChange) => void): () => void {
    const manager = this.manager
    if (manager) {
      const stop = manager.subscribe(event => {
      if (event.name !== this.name) return
      const identity = event.identities?.find(item => item.before === data.recordKey && item.before !== item.after)
      if (identity) data.recordKey = identity.after
      if (event.type === 'error') {
        if (!event.targetKey || event.targetKey === data.recordKey) listener({ task: manager.findTask(this.name, data.recordKey), error: event.message ?? '修改失败', blocked: !!event.message && ['版本','失效','已变化'].some(value => event.message!.includes(value)), rejectedChanges: event.rejectedChanges })
        return
      }
      if (event.type === 'ready' || event.type === 'complete') return
      if (!identity && event.removed.includes(data.recordKey)) { listener({ removed: true }); return }
      if (identity || event.updated.includes(data.recordKey) || event.added.includes(data.recordKey)) {
        const task = manager.findTask(this.name, data.recordKey)
        if (task) { data.task = task; listener({ task }) }
      }
      })
      const task = manager.findTask(this.name, data.recordKey)
      if (task) { data.task = task; listener({ task }) }
      return stop
    }
    data.listeners.add(listener)
    if (!this.stopMonitor) this.stopMonitor = this.watch(state => {
      this.revision = state.revision
      for (const item of this.dataSets.values()) if (item.listeners.size) this.readRecord(item, item.task, state.revision)
    })
    return (): void => {
      data.listeners.delete(listener)
      if (Array.from(this.dataSets.values()).every(item => item.listeners.size === 0)) { this.stopMonitor?.(); this.stopMonitor = undefined }
    }
  }
  async targets(): Promise<CoreRefileTarget[]> { return this.manager ? await this.manager.moveTargets() : await this.moveTargets() }
  async moveDataSet(data: TaskEditorDataSet, source: CoreTask, target: CoreRefileTarget): Promise<void> {
    if (this.manager) await this.manager.move(this.name, data.recordKey, target)
    else await this.move(source, target)
  }
  async refresh(selected?: TaskEditorDataSet): Promise<void> {
    if (this.manager) { await this.manager.refresh(); return }
    const records = selected ? [selected] : Array.from(this.dataSets.values())
    for (const data of records) {
      const request = ++data.request; data.loading = true
      data.reading = this.reload(data.task).then((task: CoreTask): void => {
        if (request !== data.request) return
        data.task = task; data.error = undefined; data.removed = false
      }).catch((error: Error): void => { if (request === data.request) data.error = error })
        .finally((): void => { if (request === data.request) data.loading = false })
      await data.reading
    }
  }
  private watch(listener: (state: TaskEditorDataState) => void): () => void {
    CoreDataChangeService.watch(listener)
    return (): void => { CoreDataChangeService.unwatch(listener) }
  }
  private async reload(task: CoreTask): Promise<CoreTask> { return await TaskInlineService.reload(this.context!, task, this.documentMode) }
  private async findChanged(task: CoreTask, revision: number): Promise<CoreTask | undefined> { return await TaskInlineService.findChanged(this.context!, task, revision, this.documentMode) }
  private async update(task: CoreTask, changes: CoreTaskModification[]): Promise<void> { await TaskInlineService.modify(this.context!, task, changes, this.documentMode) }
  private async moveTargets(): Promise<CoreRefileTarget[]> { return await MoveToTargetService.targets(this.context!) }
  private async move(task: CoreTask, target: CoreRefileTarget): Promise<void> { await MoveToTargetService.move(this.context!, task, target) }
}
