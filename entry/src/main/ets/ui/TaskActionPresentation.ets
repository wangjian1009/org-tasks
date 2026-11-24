import { TaskStateCategory } from 'liborg_tasks_harmony.so'

export type TaskActionPage = 'inbox' | 'today' | 'planned' | 'waiting' | 'anytime' | 'someday' | 'memo' | 'logbook' | 'recent'

export enum TaskOperation {
  ToggleState = 'toggleState',
  ToggleWait = 'toggleWait',
  Wait = 'wait',
  Cancel = 'cancel',
  Move = 'move',
  Refactor = 'refactor',
  Project = 'project',
  Schedule = 'schedule',
  Deadline = 'deadline',
  Someday = 'someday',
  Memo = 'memo',
  Delete = 'delete',
  Clear = 'clear',
  Restore = 'restore',
  Reopen = 'reopen',
  Merge = 'merge',
  Select = 'select'
}

type TaskCommonOperation = TaskOperation.Wait | TaskOperation.Cancel | TaskOperation.Move | TaskOperation.Schedule | TaskOperation.Deadline |
  TaskOperation.Someday | TaskOperation.Memo | TaskOperation.Delete | TaskOperation.Clear | TaskOperation.Restore | TaskOperation.Reopen
export type TaskSingleOperation = TaskCommonOperation | TaskOperation.ToggleState | TaskOperation.ToggleWait | TaskOperation.Project
export type TaskSwipeAction = TaskSingleOperation | TaskOperation.Select
export type TaskBatchAction = TaskCommonOperation | TaskOperation.Merge
type TaskMenuOperation = TaskSingleOperation | TaskBatchAction
type TaskToggleStateCategory = TaskStateCategory | null
export type TaskRightSwipeAction = TaskOperation.Schedule | TaskOperation.Move

export interface TaskActionOperations {
  singleOperations?: TaskSingleOperation[]
  bulkOperations?: TaskBatchAction[]
}

export interface TaskPageActionPolicy {
  singleOperations: TaskSingleOperation[]
  bulkOperations: TaskBatchAction[]
  rightSwipeAction: TaskRightSwipeAction | undefined
}

export interface TaskActionItem {
  id: string
  title: string
  label: string
  icon: Resource
  style?: 'normal' | 'danger' | 'selection'
  minimumSelection?: number
  busyTitle?: string
  action: () => void
}

// 两组操作列表独立控制功能与顺序；多选由左滑菜单固定追加。
export function taskActionPolicy(operations: TaskActionOperations = {}, rightSwipeAction: TaskRightSwipeAction | undefined = undefined): TaskPageActionPolicy {
  return { rightSwipeAction, singleOperations: [...(operations.singleOperations ?? [])],
    bulkOperations: [...(operations.bulkOperations ?? [])] }
}

// 右滑手势保持独立；只有接入共享控件的列表才展示左滑与多选。
export function taskPageActionPolicy(page: TaskActionPage): TaskPageActionPolicy {
  const activeTaskOperations: TaskSingleOperation[] = [TaskOperation.ToggleState, TaskOperation.ToggleWait, TaskOperation.Cancel,
    TaskOperation.Someday, TaskOperation.Delete]
  switch (page) {
    case 'today': case 'recent': case 'waiting':
      return taskActionPolicy({ singleOperations: activeTaskOperations }, TaskOperation.Schedule)
    case 'planned': return taskActionPolicy({ singleOperations: activeTaskOperations,
      bulkOperations: [TaskOperation.Schedule, TaskOperation.Deadline, TaskOperation.Someday, TaskOperation.Delete] }, TaskOperation.Schedule)
    case 'anytime': return taskActionPolicy({ singleOperations: activeTaskOperations,
      bulkOperations: [TaskOperation.Schedule, TaskOperation.Deadline, TaskOperation.Cancel, TaskOperation.Someday, TaskOperation.Delete] }, TaskOperation.Schedule)
    case 'someday': return taskActionPolicy({ singleOperations: [TaskOperation.Restore, TaskOperation.Delete],
      bulkOperations: [TaskOperation.Restore, TaskOperation.Delete] }, TaskOperation.Schedule)
    case 'inbox': return taskActionPolicy({}, TaskOperation.Schedule)
    default: return taskActionPolicy()
  }
}

function taskOperationMenu(operations: TaskMenuOperation[], activate: (action: TaskMenuOperation) => void,
  toggleStateCategory: TaskToggleStateCategory = null,
  toggleWaitCategory: TaskToggleStateCategory = null): TaskActionItem[] {
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
      case TaskOperation.ToggleWait:
        if (toggleWaitCategory === 'Wait' || toggleWaitCategory === 'Todo') {
          const waiting = toggleWaitCategory === 'Wait'
          items.push({ id: operation, title: waiting ? '等待' : '待办', label: waiting ? '设为等待' : '恢复为待办',
            icon: waiting ? $r('app.media.ui_task_waiting') : $r('app.media.ui_action_restore'),
            busyTitle: waiting ? '设置中…' : '处理中…', action: () => activate(operation) })
        }
        break
      case TaskOperation.Wait:
        items.push({ id: operation, title: '等待', label: '设为等待', icon: $r('app.media.ui_task_waiting'), busyTitle: '设置中…', action: () => activate(operation) })
        break
      case TaskOperation.Cancel:
        items.push({ id: operation, title: '取消', label: '取消任务', icon: $r('app.media.ui_action_cancel'),
          busyTitle: '处理中…', action: () => activate(operation) })
        break
      case TaskOperation.Project:
        items.push({ id: operation, title: '项目', label: '转换为项目', icon: $r('app.media.ui_action_project'), busyTitle: '创建中…', action: () => activate(operation) })
        break
      case TaskOperation.Move:
        items.push({ id: operation, title: '移动', label: '移动到目标', icon: $r('app.media.ui_move_to'), busyTitle: '移动中…', action: () => activate(operation) })
        break
      case TaskOperation.Schedule:
        items.push({ id: operation, title: '分配', label: '分配计划日期', icon: $r('app.media.ui_action_schedule'), busyTitle: '分配中…', action: () => activate(operation) })
        break
      case TaskOperation.Deadline:
        items.push({ id: operation, title: '截止', label: '设置截止日期', icon: $r('app.media.ui_action_deadline'), busyTitle: '设置中…', action: () => activate(operation) })
        break
      case TaskOperation.Someday:
        items.push({ id: operation, title: '某天', label: '移入某天', icon: $r('app.media.ui_action_someday'), busyTitle: '整理中…', action: () => activate(operation) })
        break
      case TaskOperation.Memo:
        items.push({ id: operation, title: '备忘', label: '转换为备忘', icon: $r('app.media.ui_action_memo'), busyTitle: '转换中…', action: () => activate(operation) })
        break
      case TaskOperation.Delete:
        items.push({ id: operation, title: '删除', label: '删除', icon: $r('app.media.ui_delete'), style: 'danger', busyTitle: '删除中…', action: () => activate(operation) })
        break
      case TaskOperation.Clear:
        items.push({ id: operation, title: '清除', label: '永久清除', icon: $r('app.media.ui_delete'), style: 'danger', busyTitle: '清除中…', action: () => activate(operation) })
        break
      case TaskOperation.Reopen:
        items.push({ id: operation, title: '待办', label: '恢复为待办', icon: $r('app.media.ui_action_restore'), busyTitle: '处理中…', action: () => activate(operation) })
        break
      case TaskOperation.Restore:
        items.push({ id: operation, title: '归位', label: '恢复到原位置', icon: $r('app.media.ui_action_restore'), busyTitle: '归位中…', action: () => activate(operation) })
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
  toggleStateCategory: TaskToggleStateCategory = null,
  toggleWaitCategory: TaskToggleStateCategory = null): TaskActionItem[] {
  // 只有等待切换时，第三个参数也可直接传入其状态，兼容单一状态操作的调用点。
  const waitCategory = toggleWaitCategory ??
    (operations.includes(TaskOperation.ToggleWait) && !operations.includes(TaskOperation.ToggleState) ? toggleStateCategory : null)
  return taskOperationMenu(operations, (action: TaskMenuOperation): void => {
    if (action !== TaskOperation.Merge) activate(action)
  }, toggleStateCategory, waitCategory)
}

export function taskSwipeMenu(policy: TaskPageActionPolicy, activate: (action: TaskSwipeAction) => void,
  toggleStateCategory: TaskToggleStateCategory = null,
  toggleWaitCategory: TaskToggleStateCategory = null): TaskActionItem[] {
  const items = taskSingleMenu(policy.singleOperations, activate, toggleStateCategory, toggleWaitCategory)
  items.push(taskSelectItem(() => activate(TaskOperation.Select)))
  return items
}

function taskSelectItem(action: () => void): TaskActionItem {
  return { id: TaskOperation.Select, title: '多选', label: '进入批量编辑', icon: $r('app.media.ui_select_records'), style: 'selection', action }
}

export function taskBatchMenu(policy: TaskPageActionPolicy, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  return taskOperationMenu(policy.bulkOperations, (action: TaskMenuOperation): void => {
    if (action !== TaskOperation.ToggleState && action !== TaskOperation.ToggleWait && action !== TaskOperation.Project) activate(action)
  })
}

export function taskBatchActionEnabled(item: TaskActionItem, count: number, busy: boolean, invalid: boolean): boolean {
  return !busy && !invalid && count >= (item.minimumSelection ?? 1)
}

export function taskSwipeMenuWidth(items: TaskActionItem[]): number {
  return items.length === 0 ? 0 : Math.min(items.length * 48 + 16, 304)
}
