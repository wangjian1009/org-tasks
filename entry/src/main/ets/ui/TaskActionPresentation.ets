export type TaskActionPage = 'inbox' | 'today' | 'planned' | 'anytime' | 'someday' | 'logbook' | 'recent'

export enum TaskOperation {
  Move = 'move',
  Schedule = 'schedule',
  Deadline = 'deadline',
  Someday = 'someday',
  Memo = 'memo',
  Delete = 'delete',
  Restore = 'restore',
  Merge = 'merge',
  Select = 'select'
}

export type TaskSingleOperation = TaskOperation.Move | TaskOperation.Schedule | TaskOperation.Deadline |
  TaskOperation.Someday | TaskOperation.Memo | TaskOperation.Delete
export type TaskSwipeAction = TaskSingleOperation | TaskOperation.Select
export type TaskBatchAction = TaskSingleOperation | TaskOperation.Restore | TaskOperation.Merge
export type TaskRightSwipeAction = 'schedule' | 'doing' | 'move' | 'none'

export interface TaskActionOperations {
  singleOperations?: TaskSingleOperation[]
  bulkOperations?: TaskBatchAction[]
}

export interface TaskPageActionPolicy {
  singleOperations: TaskSingleOperation[]
  bulkOperations: TaskBatchAction[]
  rightSwipeAction: TaskRightSwipeAction
}

export interface TaskActionItem {
  id: TaskOperation
  title: string
  label: string
  icon: Resource
  style?: 'normal' | 'danger' | 'selection'
  minimumSelection?: number
  busyTitle?: string
  action: () => void
}

// 两组操作列表独立控制功能与顺序；多选由左滑菜单固定追加。
export function taskActionPolicy(operations: TaskActionOperations = {}, rightSwipeAction: TaskRightSwipeAction = 'none'): TaskPageActionPolicy {
  return { rightSwipeAction, singleOperations: [...(operations.singleOperations ?? [])],
    bulkOperations: [...(operations.bulkOperations ?? [])] }
}

// 右滑手势保持独立；只有接入共享控件的列表才展示左滑与多选。
export function taskPageActionPolicy(page: TaskActionPage): TaskPageActionPolicy {
  switch (page) {
    case 'inbox': case 'someday': return taskActionPolicy({}, 'move')
    case 'today': return taskActionPolicy({}, 'doing')
    case 'planned': case 'anytime': case 'recent': return taskActionPolicy({}, 'schedule')
    default: return taskActionPolicy()
  }
}

function taskOperationMenu(operations: TaskBatchAction[], activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  const items: TaskActionItem[] = []
  for (const operation of operations) {
    switch (operation) {
      case TaskOperation.Move:
        items.push({ id: operation, title: '移动', label: '移动到目标', icon: $r('app.media.ui_move_to'), busyTitle: '移动中…', action: () => activate(operation) })
        break
      case TaskOperation.Schedule:
        items.push({ id: operation, title: '分配', label: '分配计划日期', icon: $r('app.media.ui_task_calendar'), busyTitle: '分配中…', action: () => activate(operation) })
        break
      case TaskOperation.Deadline:
        items.push({ id: operation, title: '截止', label: '设置截止日期', icon: $r('app.media.ui_task_deadline'), busyTitle: '设置中…', action: () => activate(operation) })
        break
      case TaskOperation.Someday:
        items.push({ id: operation, title: '将来', label: '将来，也许', icon: $r('app.media.nav_someday'), busyTitle: '整理中…', action: () => activate(operation) })
        break
      case TaskOperation.Memo:
        items.push({ id: operation, title: '备忘', label: '转换为备忘', icon: $r('app.media.nav_memo'), busyTitle: '转换中…', action: () => activate(operation) })
        break
      case TaskOperation.Delete:
        items.push({ id: operation, title: '删除', label: '删除', icon: $r('app.media.ui_delete'), style: 'danger', busyTitle: '删除中…', action: () => activate(operation) })
        break
      case TaskOperation.Restore:
        items.push({ id: operation, title: '恢复', label: '恢复为待办', icon: $r('app.media.ui_restore'), busyTitle: '恢复中…', action: () => activate(operation) })
        break
      case TaskOperation.Merge:
        items.push({ id: operation, title: '合并', label: '按选择顺序合并记录', icon: $r('app.media.ui_merge_records'),
          minimumSelection: 2, busyTitle: '合并中…', action: () => activate(operation) })
        break
    }
  }
  return items
}

export function taskSwipeMenu(policy: TaskPageActionPolicy, activate: (action: TaskSwipeAction) => void): TaskActionItem[] {
  const items = taskOperationMenu(policy.singleOperations, (action: TaskBatchAction): void => {
    if (action !== TaskOperation.Merge && action !== TaskOperation.Restore) activate(action)
  })
  items.push({ id: TaskOperation.Select, title: '多选', label: '进入批量编辑', icon: $r('app.media.ui_select_records'), style: 'selection', action: () => activate(TaskOperation.Select) })
  return items
}

export function taskBatchMenu(policy: TaskPageActionPolicy, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  return taskOperationMenu(policy.bulkOperations, activate)
}

export function taskBatchActionEnabled(item: TaskActionItem, count: number, busy: boolean, invalid: boolean): boolean {
  return !busy && !invalid && count >= (item.minimumSelection ?? 1)
}

export function taskSwipeMenuWidth(items: TaskActionItem[]): number {
  return items.length === 0 ? 0 : Math.min(items.length * 48 + 16, 304)
}
