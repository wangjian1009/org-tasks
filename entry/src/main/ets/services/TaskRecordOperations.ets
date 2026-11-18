import { Context } from '@kit.AbilityKit'
import { DataSet } from './DataSet'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { TrashService } from './TrashService'
import { taskModificationGroup, mergeTaskOperationGroups } from './TaskOperationGroups'
import { TaskOperation } from '../ui/TaskActionPresentation'
import { TaskStateCategory } from '../ui/TaskStatePresentation'

export type TaskRecordOperation = TaskOperation.Wait | TaskOperation.Delete | TaskOperation.Reopen | TaskOperation.Restore | TaskOperation.Clear
export interface TaskRecordResult { committed: boolean; retainedKeys: string[] }

// 单条与批量共用操作组规划；状态变更、原位恢复和删除规则由 Core 执行。
export class TaskRecordOperations {
  static async group(context: Context, tasks: CoreTask[], action: TaskRecordOperation): Promise<CoreTaskOperationGroup> {
    if (!tasks.length) throw new Error('请选择记录')
    if (action === TaskOperation.Reopen || action === TaskOperation.Wait) {
      return mergeTaskOperationGroups(tasks.map((task: CoreTask): CoreTaskOperationGroup => {
        const waiting = action === TaskOperation.Wait
        const state = task.taskStateOf(waiting ? TaskStateCategory.Wait : TaskStateCategory.Todo)
        if (!state) throw new Error(`“${task.heading}”所在文件没有可用的${waiting ? '等待' : '待办'}状态，请检查 TODO 流程`)
        return taskModificationGroup(task, [{ field: 'TODO', value: state.name }])
      }))
    }
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    return await TrashService.group(config, workspace, tasks,
      action === TaskOperation.Delete ? 'trash' : action === TaskOperation.Restore ? 'restore' : 'clear')
  }

  static async submit(dataSet: DataSet, tasks: CoreTask[], action: TaskRecordOperation,
    group: CoreTaskOperationGroup, allowed: () => boolean): Promise<TaskRecordResult> {
    if (!allowed()) throw new Error('操作已取消')
    const keys = tasks.map(task => dataSet.taskKey(task.id))
    await dataSet.submitOperationGroup(group, allowed)
    await dataSet.settle()
    return { committed: true, retainedKeys: action === TaskOperation.Restore ? keys.filter(key => dataSet.getTask(key) !== undefined) : [] }
  }

  static retainedMessage(count: number): string { return `${count} 条记录原位置不可用，已保留在废纸篓` }
}
