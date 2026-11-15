import { Context } from '@kit.AbilityKit'
import { CoreTask, CoreTaskModification, CoreRefileTarget } from './NativeCoreService'
import { TaskInlineMissingError } from './TaskInlineService'
import { MoveToTargetService } from './MoveToTargetService'
import { DataSetManager } from './DataSetManager'

export { TaskInlineMissingError }
export class TaskEditorWriteError extends Error {
  readonly committed: boolean
  constructor(message: string, committed: boolean) { super(message); this.committed = committed }
}
export interface TaskEditorChange { task?: CoreTask; removed?: boolean; blocked?: boolean; error?: string; rejectedChanges?: CoreTaskModification[] }

// 一个编辑器只持有一个已经绑定的记录数据集，不选择查询范围或解释提交事件。
export class TaskEditorDataSet {
  readonly key: string
  recordKey: string
  task: CoreTask
  reading: Promise<void> = Promise.resolve()
  loading: boolean = false
  error: TaskEditorWriteError | undefined = undefined
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
  private manager: DataSetManager | undefined = undefined
  private name: string = ''
  private dataSets: Map<string, TaskEditorDataSet> = new Map()
  constructor(context?: Context) { this.context = context }
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
    return data
  }
  dataSetForTaskId(taskId: string): TaskEditorDataSet | undefined {
    return Array.from(this.dataSets.values()).find(data => data.task.id === taskId || data.task.taskId === taskId)
  }
  snapshot(data: TaskEditorDataSet): CoreTask | undefined {
    return this.manager ? this.manager.findTask(this.name, data.recordKey) : data.removed ? undefined : data.task
  }
  async current(data: TaskEditorDataSet): Promise<CoreTask> {
    const task = this.snapshot(data)
    if (!task) throw new TaskInlineMissingError()
    return task
  }
  async modify(data: TaskEditorDataSet, source: CoreTask, changes: CoreTaskModification[]): Promise<void> {
    if (!changes.length) return
    if (this.manager) this.manager.updateFields(this.name, data.recordKey, changes, source.fileVersion)
    else throw new Error('未绑定页面数据集')
  }
  async modifyConfirmed(data: TaskEditorDataSet, source: CoreTask, changes: CoreTaskModification[]): Promise<CoreTask> {
    if (!this.manager) throw new Error('未绑定页面数据集')
    await this.manager.update(this.name, data.recordKey, changes, source.fileVersion)
    return await this.current(data)
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
    throw new Error('未绑定页面数据集')
  }
  async targets(): Promise<CoreRefileTarget[]> { return this.manager ? await this.manager.moveTargets() : await this.moveTargets() }
  async moveDataSet(data: TaskEditorDataSet, source: CoreTask, target: CoreRefileTarget): Promise<void> {
    if (this.manager) await this.manager.move(this.name, data.recordKey, target)
    else await this.move(source, target)
  }
  async refresh(_selected?: TaskEditorDataSet): Promise<void> {
    if (!this.manager) throw new Error('未绑定页面数据集')
    await this.manager.refresh()
  }
  private async moveTargets(): Promise<CoreRefileTarget[]> { return await MoveToTargetService.targets(this.context!) }
  private async move(task: CoreTask, target: CoreRefileTarget): Promise<void> { await MoveToTargetService.move(this.context!, task, target) }
}
