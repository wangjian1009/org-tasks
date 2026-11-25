import { localizedText } from './LocalizedText'
import { TaskStateCategory as NativeTaskStateCategory } from 'liborg_tasks_harmony.so'
import { CoreTask } from '../services/NativeCoreService'

export enum TaskStateCategory {
  Todo = 'Todo',
  Doing = 'Doing',
  Wait = 'Wait',
  Done = 'Done',
  Cancel = 'Cancel'
}

export function taskStateToggleCategory(task: CoreTask | undefined): TaskStateCategory | null {
  const category = task?.state?.category
  const target = (category === TaskStateCategory.Todo || category === TaskStateCategory.Wait) ? TaskStateCategory.Doing :
    category === TaskStateCategory.Doing ? TaskStateCategory.Todo : null
  return target && task?.taskStateOf(target) ? target : null
}

// 等待操作按当前状态在 Wait 与 Todo 之间切换；仅在目标状态存在时提供入口。
export function taskStateToggleWaitCategory(task: CoreTask | undefined): TaskStateCategory | null {
  const category = task?.state?.category
  const target = category === TaskStateCategory.Wait ? TaskStateCategory.Todo :
    (category === TaskStateCategory.Todo || category === TaskStateCategory.Doing) ? TaskStateCategory.Wait : null
  return target && task?.taskStateOf(target) ? target : null
}

export function taskStateCategoryLabel(category: NativeTaskStateCategory | null | undefined): string {
  switch (category) {
    case TaskStateCategory.Todo: return localizedText($r('app.string.text_to_do'))
    case TaskStateCategory.Doing: return localizedText($r('app.string.text_ongoing'))
    case TaskStateCategory.Wait: return localizedText($r('app.string.text_waiting'))
    case TaskStateCategory.Done: return localizedText($r('app.string.text_completed'))
    case TaskStateCategory.Cancel: return localizedText($r('app.string.text_canceled'))
    default: return localizedText($r('app.string.text_uncategorized'))
  }
}
