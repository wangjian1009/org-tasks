import { CoreTask, CoreTaskModification, CoreTaskPlanningEdit, CoreTaskPlanningInfo } from '../services/NativeCoreService'
import { inlineDate } from './TaskInlinePresentation'

// 日期控件只交换结构化数据；属性名称和 Org 时间戳由 Core 封装。
export function reminderPlanning(task: CoreTask): CoreTaskPlanningInfo | null {
  if (task.reminderAt === null || task.reminderAt === undefined) return null
  const date = new Date(task.reminderAt)
  return { date: inlineDate(date), time: {
    start: `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`, end: null
  } }
}

export function reminderModification(task: CoreTask, edit: CoreTaskPlanningEdit | null): CoreTaskModification {
  if (!edit) return { field: 'SET_REMINDER', value: null }
  const time = edit.time === undefined ? reminderPlanning(task)?.time?.start ?? '00:00' : edit.time?.start ?? '00:00'
  const value = new Date(`${edit.date}T${time}:00`).getTime()
  if (!Number.isFinite(value) || edit.time?.end) throw new Error('请选择单个有效的提醒时间')
  return { field: 'SET_REMINDER', value }
}
