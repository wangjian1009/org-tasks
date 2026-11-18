import { UIContext } from '@kit.ArkUI'
import { DataSet } from '../services/DataSet'
import { CoreTask, coreErrorMessage, CoreBridgeError } from '../services/NativeCoreService'
import { TaskInlineSession } from '../services/TaskInlineService'
import { TaskRecordOperations, TaskRecordOperation } from '../services/TaskRecordOperations'
import { TaskOperation, TaskBatchAction } from './TaskActionPresentation'
import { TaskRecordActionController } from './TaskRecordActionController'

interface TaskSelectionEntry { key: string; task: CoreTask }

// 列表级选择快照独立于分组布局；外部刷新不替换已选记录的源版本。
@Observed
export class TaskSelectionController {
  selecting: boolean = false
  starting: boolean = false
  busy: boolean = false
  busyAction: string = ''
  selectedKeys: string[] = []
  message: string = ''
  private entries: TaskSelectionEntry[] = []
  private dataSet: DataSet | undefined = undefined
  private read: () => CoreTask[] = () => []
  private enabled: () => TaskBatchAction[] = () => []
  private ready: () => boolean = () => false
  private scroller: ListScroller | undefined = undefined
  private active: boolean = false
  private scope: string = ''
  private actions: TaskRecordActionController = new TaskRecordActionController()

  connect(dataSet: DataSet, read: () => CoreTask[], enabled: () => TaskBatchAction[], ready: () => boolean, scroller: ListScroller): void {
    this.dataSet = dataSet; this.read = read; this.enabled = enabled; this.ready = ready; this.scroller = scroller
    this.active = true
  }

  close(): void { this.active = false; this.actions.close() }
  blocked(): boolean { return this.busy || this.starting }

  async start(taskId: string): Promise<void> {
    if (!this.active || !this.ready() || this.selecting || this.blocked() || !this.dataSet) return
    this.starting = true
    const dataSet = this.dataSet, scope = dataSet.identity
    try {
      if (!await TaskInlineSession.end(true)) return
      await dataSet.settle()
      if (!this.active || !this.ready() || scope !== dataSet.identity) return
      const entries: TaskSelectionEntry[] = []
      for (const task of this.read()) {
        const key = dataSet.taskKey(task.id), current = dataSet.getTask(key)
        if (current) entries.push({ key, task: current })
      }
      const key = dataSet.taskKey(taskId)
      if (!entries.some(entry => entry.key === key)) return
      try { this.scroller?.closeAllSwipeActions() } catch (_) { /* 首次布局尚未绑定列表。 */ }
      this.scope = scope; this.entries = entries; this.selectedKeys = [key]; this.message = ''; this.selecting = true
    } catch (error) { if (this.active) this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { this.starting = false }
  }

  toggle(taskId: string): void {
    if (!this.selecting || this.blocked() || !this.dataSet) return
    const key = this.dataSet.taskKey(taskId)
    if (!this.entries.some(entry => entry.key === key)) return
    this.selectedKeys = this.selectedKeys.includes(key) ? this.selectedKeys.filter(value => value !== key) : this.selectedKeys.concat(key)
  }

  reset(): void {
    if (this.blocked()) return
    this.selecting = false; this.selectedKeys = []; this.entries = []; this.message = ''
  }

  async execute(context: UIContext, action: TaskBatchAction): Promise<void> {
    if (!this.active || !this.selecting || this.blocked() || !this.dataSet || !this.enabled().includes(action)) return
    let recordAction: TaskRecordOperation
    switch (action) {
      case TaskOperation.Delete: case TaskOperation.Reopen: case TaskOperation.Restore: case TaskOperation.Clear: recordAction = action; break
      default: throw new Error('此选择控件未启用该批量操作')
    }
    const tasks = this.entries.filter(entry => this.selectedKeys.includes(entry.key)).map(entry => entry.task)
    if (!tasks.length) return
    this.busy = true; this.busyAction = action; this.message = ''
    const dataSet = this.dataSet
    const allowed = (): boolean => this.active && this.selecting && this.ready() && this.scope === dataSet.identity && this.enabled().includes(action)
    try {
      if (!await TaskInlineSession.end(true) || !allowed()) return
      const result = await this.actions.execute(context, dataSet, tasks, recordAction, allowed)
      if (!allowed() || !result.committed) return
      if (result.retainedKeys.length) {
        this.selectedKeys = this.selectedKeys.filter(key => result.retainedKeys.includes(key))
        this.entries = this.entries.filter(entry => dataSet.getTask(entry.key) !== undefined).map((entry): TaskSelectionEntry =>
          ({ key: entry.key, task: dataSet.getTask(entry.key) ?? entry.task }))
        this.message = TaskRecordOperations.retainedMessage(this.selectedKeys.length)
        this.notify(context)
      } else {
        this.selecting = false; this.selectedKeys = []; this.entries = []
      }
    } catch (error) { if (this.active) { this.message = coreErrorMessage(error as CoreBridgeError); this.notify(context) } }
    finally { this.busy = false; this.busyAction = '' }
  }
  private notify(context: UIContext): void {
    try { context.getPromptAction().showToast({ message: this.message, duration: 3000 }) }
    catch (_) { /* 页面退出后提示可能不可用。 */ }
  }

}
