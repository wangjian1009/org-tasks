export type TaskActionPage = 'inbox' | 'today' | 'planned' | 'anytime' | 'someday' | 'logbook' | 'recent'
export type TaskSwipeAction = 'move' | 'schedule' | 'deadline' | 'someday' | 'memo' | 'delete' | 'select'
export type TaskBatchAction = 'move' | 'schedule' | 'deadline' | 'someday' | 'memo' | 'delete' | 'merge'
export type TaskRightSwipeAction = 'schedule' | 'doing' | 'move' | 'none'

export interface TaskActionEnables {
  enableMove?: boolean
  enableSchedule?: boolean
  enableDeadline?: boolean
  enableSomeday?: boolean
  enableMemo?: boolean
  enableDelete?: boolean
  enableBulkMove?: boolean
  enableBulkSchedule?: boolean
  enableBulkDeadline?: boolean
  enableBulkSomeday?: boolean
  enableBulkMemo?: boolean
  enableBulkDelete?: boolean
  enableSelect?: boolean
  enableMerge?: boolean
}

export interface TaskPageActionPolicy extends TaskActionEnables {
  rightSwipeAction: TaskRightSwipeAction
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

// 默认没有菜单能力；具体页面显式传入所需开关。
export function taskActionPolicy(enables: TaskActionEnables = {}, rightSwipeAction: TaskRightSwipeAction = 'none'): TaskPageActionPolicy {
  return { rightSwipeAction, enableMove: enables.enableMove ?? false, enableSchedule: enables.enableSchedule ?? false,
    enableDeadline: enables.enableDeadline ?? false, enableSomeday: enables.enableSomeday ?? false,
    enableMemo: enables.enableMemo ?? false, enableDelete: enables.enableDelete ?? false,
    enableBulkMove: enables.enableBulkMove ?? false, enableBulkSchedule: enables.enableBulkSchedule ?? false,
    enableBulkDeadline: enables.enableBulkDeadline ?? false, enableBulkSomeday: enables.enableBulkSomeday ?? false,
    enableBulkMemo: enables.enableBulkMemo ?? false, enableBulkDelete: enables.enableBulkDelete ?? false,
    enableSelect: enables.enableSelect ?? false, enableMerge: enables.enableMerge ?? false }
}

// 右滑手势保持独立，不隐式开启左滑或批量菜单。
export function taskPageActionPolicy(page: TaskActionPage): TaskPageActionPolicy {
  switch (page) {
    case 'inbox': case 'someday': return taskActionPolicy({}, 'move')
    case 'today': return taskActionPolicy({}, 'doing')
    case 'planned': case 'anytime': case 'recent': return taskActionPolicy({}, 'schedule')
    default: return taskActionPolicy()
  }
}

function taskCommonMenu(policy: TaskActionEnables, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  const items: TaskActionItem[] = []
  if (policy.enableMove) items.push({ id: 'move', title: '移动', label: '移动到目标', icon: $r('app.media.ui_move_to'), busyTitle: '移动中…', action: () => activate('move') })
  if (policy.enableSchedule) items.push({ id: 'schedule', title: '分配', label: '分配计划日期', icon: $r('app.media.ui_task_calendar'), busyTitle: '分配中…', action: () => activate('schedule') })
  if (policy.enableDeadline) items.push({ id: 'deadline', title: '截止', label: '设置截止日期', icon: $r('app.media.ui_task_deadline'), busyTitle: '设置中…', action: () => activate('deadline') })
  if (policy.enableSomeday) items.push({ id: 'someday', title: '将来', label: '将来，也许', icon: $r('app.media.nav_someday'), busyTitle: '整理中…', action: () => activate('someday') })
  if (policy.enableMemo) items.push({ id: 'memo', title: '备忘', label: '转换为备忘', icon: $r('app.media.nav_memo'), busyTitle: '转换中…', action: () => activate('memo') })
  if (policy.enableDelete) items.push({ id: 'delete', title: '删除', label: '删除', icon: $r('app.media.ui_delete'), style: 'danger', busyTitle: '删除中…', action: () => activate('delete') })
  return items
}

export function taskSwipeMenu(policy: TaskActionEnables, activate: (action: TaskSwipeAction) => void): TaskActionItem[] {
  const items = taskCommonMenu(policy, (action: TaskBatchAction): void => { if (action !== 'merge') activate(action) })
  if (policy.enableSelect) items.push({ id: 'select', title: '多选', label: '进入批量编辑', icon: $r('app.media.ui_select_records'), style: 'selection', action: () => activate('select') })
  return items
}

export function taskBatchMenu(policy: TaskActionEnables, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  if (!policy.enableSelect) return []
  const items = taskCommonMenu({ enableMove: policy.enableBulkMove, enableSchedule: policy.enableBulkSchedule,
    enableDeadline: policy.enableBulkDeadline, enableSomeday: policy.enableBulkSomeday,
    enableMemo: policy.enableBulkMemo, enableDelete: policy.enableBulkDelete }, activate)
  if (policy.enableMerge) items.push({ id: 'merge', title: '合并', label: '按选择顺序合并记录', icon: $r('app.media.ui_merge_records'),
    minimumSelection: 2, busyTitle: '合并中…', action: () => activate('merge') })
  return items
}

export function taskHasSwipeActions(policy: TaskActionEnables): boolean {
  return !!(policy.enableMove || policy.enableSchedule || policy.enableDeadline || policy.enableSomeday ||
    policy.enableMemo || policy.enableDelete || policy.enableSelect)
}

export function taskBatchActionEnabled(item: TaskActionItem, count: number, busy: boolean, invalid: boolean): boolean {
  return !busy && !invalid && count >= (item.minimumSelection ?? 1)
}

export function taskSwipeMenuWidth(items: TaskActionItem[]): number {
  return items.length === 0 ? 0 : Math.min(items.length * 48 + 16, 304)
}
