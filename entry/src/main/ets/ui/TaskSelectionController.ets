import { UIContext } from '@kit.ArkUI'
import { DataSet } from '../services/DataSet'
import { CoreTask, CoreTaskPath, CoreRefileTarget, CoreTaskPlanningEdit, coreErrorMessage, CoreBridgeError } from '../services/NativeCoreService'
import { TaskInlineSession } from '../services/TaskInlineService'
import { TaskRecordOperations } from '../services/TaskRecordOperations'
import { TaskBatchOperations } from '../services/TaskBatchOperations'
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
  invalid: boolean = false
  pendingAction: string = ''
  mergedPath: string = ''
  private entries: TaskSelectionEntry[] = []
  private dataSet: DataSet | undefined = undefined
  private read: () => CoreTask[] = () => []
  private enabled: () => TaskBatchAction[] = () => []
  private ready: () => boolean = () => false
  private scroller: ListScroller | undefined = undefined
  private active: boolean = false
  private scope: string = ''
  private generation: number = 0
  private changed: () => void = () => {}
  private merged: (path: CoreTaskPath) => void = () => {}
  private actions: TaskRecordActionController = new TaskRecordActionController()

  connect(dataSet: DataSet, read: () => CoreTask[], enabled: () => TaskBatchAction[], ready: () => boolean, scroller: ListScroller,
    changed: () => void = () => {}, merged: (path: CoreTaskPath) => void = () => {}): void {
    this.dataSet = dataSet; this.read = read; this.enabled = enabled; this.ready = ready; this.scroller = scroller
    this.changed = changed; this.merged = merged; this.active = true
  }

  close(): void {
    this.active = false; ++this.generation; this.pendingAction = ''; this.actions.close()
    this.selecting = false; this.selectedKeys = []; this.entries = []
  }
  blocked(): boolean { return this.busy || this.starting || this.pendingAction !== '' }
  available(action: TaskBatchAction): boolean {
    return this.active && this.selecting && this.ready() && !!this.dataSet && this.scope === this.dataSet.identity &&
      !this.invalid && this.enabled().includes(action)
  }
  tasks(): CoreTask[] {
    const tasks: CoreTask[] = []
    for (const key of this.selectedKeys) {
      const entry = this.entries.find(item => item.key === key)
      if (entry) tasks.push(entry.task)
    }
    return tasks
  }
  popupToken(): number { return this.generation }
  popupAvailable(action: TaskBatchAction, token: number): boolean {
    return token === this.generation && this.pendingAction === action && this.available(action)
  }
  async moveTargets(): Promise<CoreRefileTarget[]> { return await this.dataSet!.moveTargets() }

  async start(taskId: string): Promise<void> {
    if (!this.active || !this.ready() || this.selecting || this.blocked() || !this.dataSet) return
    this.starting = true
    const dataSet = this.dataSet, scope = dataSet.identity, generation = this.generation
    try {
      if (!await TaskInlineSession.end(true)) return
      await dataSet.settle()
      if (!this.active || !this.ready() || scope !== dataSet.identity || generation !== this.generation) return
      const entries: TaskSelectionEntry[] = []
      for (const task of this.read()) {
        const key = dataSet.taskKey(task.id), current = dataSet.getTask(key)
        if (current) entries.push({ key, task: current })
      }
      const key = dataSet.taskKey(taskId)
      if (!entries.some(entry => entry.key === key)) return
      try { this.scroller?.closeAllSwipeActions() } catch (_) { /* 首次布局尚未绑定列表。 */ }
      this.scope = scope; this.entries = entries; this.selectedKeys = [key]; this.message = ''; this.invalid = false
      this.mergedPath = ''; this.selecting = true
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
    if (this.busy || this.starting) return
    ++this.generation; this.pendingAction = ''; this.actions.close()
    this.selecting = false; this.selectedKeys = []; this.entries = []; this.message = ''; this.invalid = false
    this.changed()
  }

  cancelPopup(): void { ++this.generation; this.pendingAction = '' }

  request(context: UIContext, action: TaskBatchAction): void {
    if (this.blocked() || !this.available(action) || !this.selectedKeys.length) return
    if (action === TaskOperation.Move || action === TaskOperation.Schedule || action === TaskOperation.Deadline) {
      ++this.generation; this.pendingAction = action
    } else this.execute(context, action)
  }

  async execute(context: UIContext, action: TaskBatchAction, target?: CoreRefileTarget, date?: CoreTaskPlanningEdit | null): Promise<void> {
    if (this.busy || this.starting || !this.available(action) || !this.dataSet || this.pendingAction && this.pendingAction !== action) return
    const tasks = this.tasks()
    if (!tasks.length || action === TaskOperation.Merge && tasks.length < 2) return
    this.busy = true; this.busyAction = action; this.message = ''
    const dataSet = this.dataSet, generation = this.generation
    const allowed = (): boolean => this.available(action) && generation === this.generation
    try {
      if (!await TaskInlineSession.end(true) || !allowed()) return
      let retainedKeys: string[] = [], mainPath: CoreTaskPath | undefined = undefined
      switch (action) {
        case TaskOperation.Delete: case TaskOperation.Reopen: case TaskOperation.Restore: case TaskOperation.Clear: {
          const result = await this.actions.execute(context, dataSet, tasks, action, allowed)
          if (!result.committed) return
          retainedKeys = result.retainedKeys
          break
        }
        default: {
          const plan = await TaskBatchOperations.plan(context.getHostContext()!, tasks, this.entries.map(entry => entry.task), action, target, date)
          if (!allowed()) return
          await dataSet.submitOperationGroup(plan.group, allowed)
          mainPath = plan.mainPath
        }
      }
      // 成功提交后立即释放源选择；后续刷新失败不能使旧操作再次执行。
      if (!this.active || generation !== this.generation) return
      this.pendingAction = ''
      if (retainedKeys.length) {
        this.selectedKeys = this.selectedKeys.filter(key => retainedKeys.includes(key))
        this.entries = this.entries.filter(entry => dataSet.getTask(entry.key) !== undefined).map((entry): TaskSelectionEntry =>
          ({ key: entry.key, task: dataSet.getTask(entry.key) ?? entry.task }))
        this.message = TaskRecordOperations.retainedMessage(this.selectedKeys.length)
        this.notify(context)
      } else {
        this.selecting = false; this.selectedKeys = []; this.entries = []
      }
      if (mainPath) {
        this.mergedPath = JSON.stringify(mainPath)
        this.merged(mainPath)
        try { context.getPromptAction().showToast({ message: `已合并 ${tasks.length} 条记录` }) }
        catch (_) { /* 页面退出后提示可能不可用。 */ }
      }
    } catch (error) {
      if (this.active && generation === this.generation) {
        this.message = coreErrorMessage(error as CoreBridgeError)
        this.invalid = (error as CoreBridgeError).code === 'invalidState'
        this.notify(context)
      }
    } finally {
      this.busy = false; this.busyAction = ''
      if (this.active) this.changed()
    }
  }

  private notify(context: UIContext): void {
    try { context.getPromptAction().showToast({ message: this.message, duration: 3000 }) }
    catch (_) { /* 页面退出后提示可能不可用。 */ }
  }
}
