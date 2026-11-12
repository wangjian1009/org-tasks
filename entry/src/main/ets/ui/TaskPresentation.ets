import { CoreTask } from '../services/NativeCoreService'

// Task 是只读且可枚举的查询快照；逻辑 ID 不变时，内容更新仍需重建列表行及点击参数。
export function taskRenderKey(task: CoreTask): string {
  return JSON.stringify([task, task.taskStateOf('Todo'), task.taskStateOf('Doing'),
    task.taskStateOf('Wait'), task.taskStateOf('Done'), task.taskStateOf('Cancle')])
}
