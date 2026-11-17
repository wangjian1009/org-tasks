import { TaskStateCategory } from 'liborg_tasks_harmony.so'

export type TaskActionPage = 'inbox' | 'today' | 'planned' | 'anytime' | 'someday' | 'memo' | 'logbook' | 'recent'

export enum TaskOperation {
  ToggleState = 'toggleState',
  Move = 'move',
  Project = 'project',
  Schedule = 'schedule',
  Deadline = 'deadline',
  Someday = 'someday',
  Memo = 'memo',
  Delete = 'delete',
  Restore = 'restore',
  Merge = 'merge',
  Select = 'select'
}

type TaskCommonOperation = TaskOperation.Move | TaskOperation.Schedule | TaskOperation.Deadline |
  TaskOperation.Someday | TaskOperation.Memo | TaskOperation.Delete
export type TaskSingleOperation = TaskCommonOperation | TaskOperation.ToggleState
export type TaskSwipeAction = TaskSingleOperation | TaskOperation.Select
export type TaskBatchAction = TaskCommonOperation | TaskOperation.Restore | TaskOperation.Merge
type TaskMenuOperation = TaskSingleOperation | TaskBatchAction
type TaskToggleStateCategory = TaskStateCategory | null
export type TaskRightSwipeAction = 'schedule' | 'move' | 'none'

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
    case 'today': return taskActionPolicy({ singleOperations: [TaskOperation.ToggleState, TaskOperation.Delete] }, 'schedule')
    case 'planned': case 'anytime': case 'someday': case 'recent': return taskActionPolicy({ singleOperations: [TaskOperation.Delete] }, 'schedule')
    case 'inbox': return taskActionPolicy({}, 'schedule')
    default: return taskActionPolicy()
  }
}

function taskOperationMenu(operations: TaskMenuOperation[], activate: (action: TaskMenuOperation) => void,
  toggleStateCategory: TaskToggleStateCategory = null): TaskActionItem[] {
  const items: TaskActionItem[] = []
  for (const operation of operations) {
    switch (operation) {
      case TaskOperation.ToggleState:
        if (toggleStateCategory === 'Doing' || toggleStateCategory === 'Todo') {
          const start = toggleStateCategory === 'Doing'
          items.push({ id: operation, title: start ? '开始' : '暂停', label: start ? '开始任务' : '暂停任务',
            icon: start ? $r('app.media.ui_task_start') : $r('app.media.ui_task_pause'), action: () => activate(operation) })
        }
        break
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

export function taskSingleMenu(operations: TaskSingleOperation[], activate: (action: TaskSingleOperation) => void,
  toggleStateCategory: TaskToggleStateCategory = null): TaskActionItem[] {
  return taskOperationMenu(operations, (action: TaskMenuOperation): void => {
    if (action !== TaskOperation.Merge && action !== TaskOperation.Restore) activate(action)
  }, toggleStateCategory)
}

export function taskSwipeMenu(policy: TaskPageActionPolicy, activate: (action: TaskSwipeAction) => void,
  toggleStateCategory: TaskToggleStateCategory = null): TaskActionItem[] {
  const items = taskSingleMenu(policy.singleOperations, activate, toggleStateCategory)
  items.push({ id: TaskOperation.Select, title: '多选', label: '进入批量编辑', icon: $r('app.media.ui_select_records'), style: 'selection', action: () => activate(TaskOperation.Select) })
  return items
}

export function taskBatchMenu(policy: TaskPageActionPolicy, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  return taskOperationMenu(policy.bulkOperations, (action: TaskMenuOperation): void => {
    if (action !== TaskOperation.ToggleState) activate(action)
  })
}

export function taskBatchActionEnabled(item: TaskActionItem, count: number, busy: boolean, invalid: boolean): boolean {
  return !busy && !invalid && count >= (item.minimumSelection ?? 1)
}

export function taskSwipeMenuWidth(items: TaskActionItem[]): number {
  return items.length === 0 ? 0 : Math.min(items.length * 48 + 16, 304)
}
