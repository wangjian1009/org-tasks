import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { DataSet } from './DataSet'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { TrashService } from './TrashService'
import { taskModificationGroup, mergeTaskOperationGroups } from './TaskOperationGroups'
import { TaskOperation } from '../ui/TaskActionPresentation'
import { TaskStateCategory } from '../ui/TaskStatePresentation'

export type TaskRecordOperation = TaskOperation.Wait | TaskOperation.Cancel | TaskOperation.Delete |
  TaskOperation.Reopen | TaskOperation.Restore | TaskOperation.Clear
export interface TaskRecordResult { committed: boolean; retainedKeys: string[] }

// 单条与批量共用操作组规划；状态变更、原位恢复和删除规则由 Core 执行。
export class TaskRecordOperations {
  static async group(context: Context, tasks: CoreTask[], action: TaskRecordOperation): Promise<CoreTaskOperationGroup> {
    if (!tasks.length) throw new Error(localizedText($r('app.string.text_please_select_the_record')))
    if (action === TaskOperation.Reopen || action === TaskOperation.Wait || action === TaskOperation.Cancel) {
      let category = TaskStateCategory.Todo
      let stateLabel = localizedText($r('app.string.text_to_do'))
      switch (action) {
        case TaskOperation.Wait: category = TaskStateCategory.Wait; stateLabel = localizedText($r('app.string.text_waiting')); break
        case TaskOperation.Cancel: category = TaskStateCategory.Cancel; stateLabel = localizedText($r('app.string.text_cancel')); break
      }
      const targets = action === TaskOperation.Cancel
        ? tasks.filter((task: CoreTask): boolean => task.state?.category !== TaskStateCategory.Cancel)
        : tasks
      return mergeTaskOperationGroups(targets.map((task: CoreTask): CoreTaskOperationGroup => {
        const state = task.taskStateOf(category)
        if (!state) throw new Error(localizedText($r('app.string.text_the_file_has_no_status_available_check'), String(task.heading), String(stateLabel)))
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
    if (!allowed()) throw new Error(localizedText($r('app.string.text_operation_cancelled')))
    const keys = tasks.map(task => dataSet.taskKey(task.id))
    if (group.operations.length > 0) await dataSet.submitOperationGroup(group, allowed)
    // DataSet 已在本地覆盖层立即合并；提交由后台队列串行完成。
    return { committed: true, retainedKeys: action === TaskOperation.Restore ? keys.filter(key => dataSet.getTask(key) !== undefined) : [] }
  }

  static retainedMessage(count: number): string { return localizedText($r('app.string.text_records_the_original_location_which_is_not'), String(count)) }
}
