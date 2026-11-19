import { TaskModification } from 'liborg_tasks_harmony.so'
import { CoreTask } from './NativeCoreService'

export interface TaskDataChange {
  task?: CoreTask
  removed?: boolean
  blocked?: boolean
  error?: string
  rejectedChanges?: TaskModification[]
}

// 稳定行的数据入口；即使只有版本变化也替换快照，可见内容相同则不通知界面。
export class TaskDataSource {
  readonly rowId: string
  private current: CoreTask | undefined
  private readonly monitors: Set<(change: TaskDataChange) => void> = new Set()
  private closed: boolean = false

  constructor(rowId: string, task: CoreTask | undefined) { this.rowId = rowId; this.current = task }
  get task(): CoreTask | undefined { return this.current }

  monitor(callback: (change: TaskDataChange) => void): () => void {
    if (this.closed) { callback({ removed: true }); return (): void => {} }
    this.monitors.add(callback)
    callback(this.current ? { task: this.current } : { removed: true })
    return (): void => { this.monitors.delete(callback) }
  }

  // DataSet 先更新本批全部记录，随后统一通知，回调读取其他记录时不会取得半批状态。
  replace(task: CoreTask | undefined, visibleChanged: boolean = false): TaskDataChange | undefined {
    if (this.closed) return undefined
    const before = this.current
    this.current = task
    if (!task) return before ? { removed: true } : undefined
    return !before || visibleChanged ? { task } : undefined
  }

  notify(change: TaskDataChange): void {
    if (this.closed) return
    for (const callback of Array.from(this.monitors)) {
      if (!this.monitors.has(callback)) continue
      // 回调可以立即发起下一次编辑；嵌套更新后不再交付外层的旧快照。
      if (!change.error && (change.task !== this.current || change.removed && this.current !== undefined)) return
      try { callback(change) } catch (_) { console.error('任务记录监听处理失败') }
    }
  }

  close(): void { this.closed = true; this.current = undefined; this.monitors.clear() }
}
