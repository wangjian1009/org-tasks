import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { TrashService } from './TrashService'
import { CoreTask, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { TaskStateCategory } from '../ui/TaskStatePresentation'
import { taskModificationGroup, mergeTaskOperationGroups } from './TaskOperationGroups'

// 日志簿只编排删除与恢复请求；状态规则、版本校验、保真写入和同步队列由 Core 负责。
export class LogbookService {
  static async remove(context: Context, tasks: CoreTask[], operationId?: string): Promise<void> {
    await TrashService.perform(context, tasks, 'trash', operationId)
  }

  static async restore(context: Context, tasks: CoreTask[], operationId?: string): Promise<void> {
    await LogbookService.perform(context, tasks, 'restore', operationId)
  }

  static async operationGroups(context: Context, tasks: CoreTask[], action: 'delete' | 'restore'): Promise<CoreTaskOperationGroup[]> {
    if (tasks.length === 0) return []
    if (action === 'delete') {
      const config = await AppConfigService.load(context, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      return [await TrashService.group(config, workspace, tasks, 'trash')]
    }
    return tasks.map((task: CoreTask): CoreTaskOperationGroup => {
      const state = task.taskStateOf(TaskStateCategory.Todo)
      if (!state) throw new Error(`“${task.heading}”所在文件没有可用的待办状态，请检查 TODO 流程`)
      return taskModificationGroup(task, [{ field: 'TODO', value: state.name }])
    })
  }

  private static async perform(context: Context, tasks: CoreTask[], action: 'delete' | 'restore', operationId?: string): Promise<void> {
    const group = mergeTaskOperationGroups(await LogbookService.operationGroups(context, tasks, action))
    if (!group.operations.length) return
    if (operationId) group.operationId = operationId
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await workspace.executeTaskOperations(group)
  }
}
