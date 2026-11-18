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

export function taskStateCategoryLabel(category: NativeTaskStateCategory | null | undefined): string {
  switch (category) {
    case TaskStateCategory.Todo: return '待办'
    case TaskStateCategory.Doing: return '进行中'
    case TaskStateCategory.Wait: return '等待'
    case TaskStateCategory.Done: return '已完成'
    case TaskStateCategory.Cancel: return '已取消'
    default: return '未分类'
  }
}
