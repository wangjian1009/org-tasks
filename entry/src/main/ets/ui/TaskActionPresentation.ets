export type TaskActionPage = 'inbox' | 'today' | 'planned' | 'anytime' | 'someday' | 'logbook' | 'recent'
export type TaskSwipeAction = 'move' | 'someday' | 'memo' | 'delete' | 'select'
export type TaskBatchAction = 'merge' | 'delete'
export type TaskRightSwipeAction = 'schedule' | 'doing' | 'move' | 'none'

export interface TaskPageActionPolicy {
  rightSwipeAction: TaskRightSwipeAction
  swipeActions: TaskSwipeAction[]
  batchEditing: boolean
  batchActions: TaskBatchAction[]
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

// 各页面独立声明开放范围；返回新数组，页面调整不能污染其他页面。
export function taskPageActionPolicy(page: TaskActionPage): TaskPageActionPolicy {
  switch (page) {
    case 'inbox': return { rightSwipeAction: 'move', swipeActions: ['someday', 'memo', 'delete', 'select'], batchEditing: true, batchActions: ['merge'] }
    case 'today': return { rightSwipeAction: 'doing', swipeActions: [], batchEditing: false, batchActions: [] }
    case 'planned': return { rightSwipeAction: 'schedule', swipeActions: [], batchEditing: false, batchActions: [] }
    case 'anytime': return { rightSwipeAction: 'schedule', swipeActions: [], batchEditing: false, batchActions: [] }
    case 'someday': return { rightSwipeAction: 'move', swipeActions: [], batchEditing: false, batchActions: [] }
    case 'logbook': return { rightSwipeAction: 'none', swipeActions: ['delete', 'select'], batchEditing: true, batchActions: ['delete'] }
    case 'recent': return { rightSwipeAction: 'schedule', swipeActions: [], batchEditing: false, batchActions: [] }
  }
}

export function taskSwipeMenu(policy: TaskPageActionPolicy, activate: (action: TaskSwipeAction) => void): TaskActionItem[] {
  const items: TaskActionItem[] = []
  for (const id of policy.swipeActions) {
    if (id === 'select' && !policy.batchEditing) continue
    switch (id) {
      case 'move': items.push({ id, title: '移动', label: '移动', icon: $r('app.media.ui_move_to'), action: () => activate(id) }); break
      case 'someday': items.push({ id, title: '将来', label: '将来，也许', icon: $r('app.media.nav_someday'), action: () => activate(id) }); break
      case 'memo': items.push({ id, title: '备忘', label: '转换为备忘', icon: $r('app.media.nav_memo'), action: () => activate(id) }); break
      case 'delete': items.push({ id, title: '删除', label: '删除', icon: $r('app.media.ui_delete'), style: 'danger', action: () => activate(id) }); break
      case 'select': items.push({ id, title: '多选', label: '进入批量编辑', icon: $r('app.media.ui_select_records'), style: 'selection', action: () => activate(id) }); break
    }
  }
  return items
}

export function taskBatchMenu(policy: TaskPageActionPolicy, activate: (action: TaskBatchAction) => void): TaskActionItem[] {
  if (!policy.batchEditing) return []
  return policy.batchActions.map((id: TaskBatchAction): TaskActionItem => id === 'delete'
    ? { id, title: '删除', label: '删除所选记录', icon: $r('app.media.ui_delete'), style: 'danger',
      busyTitle: '删除中…', action: () => activate(id) }
    : { id, title: '合并', label: '按选择顺序合并记录', icon: $r('app.media.ui_merge_records'),
      minimumSelection: 2, busyTitle: '合并中…', action: () => activate(id) })
}

export function taskBatchActionEnabled(item: TaskActionItem, count: number, busy: boolean, invalid: boolean): boolean {
  return !busy && !invalid && count >= (item.minimumSelection ?? 1)
}

export function taskSwipeMenuWidth(items: TaskActionItem[]): number {
  return items.length === 0 ? 0 : items.length * 48 + 16
}
