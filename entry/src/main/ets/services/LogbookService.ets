import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskFileVersion, CoreTaskOperation, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { TaskStateCategory } from '../ui/TaskStatePresentation'

// 日志簿只编排删除与恢复请求；状态规则、版本校验、保真写入和同步队列由 Core 负责。
export class LogbookService {
  static async remove(context: Context, tasks: CoreTask[], operationId?: string): Promise<void> {
    await LogbookService.perform(context, tasks, 'delete', operationId)
  }

  static async restore(context: Context, tasks: CoreTask[], operationId?: string): Promise<void> {
    await LogbookService.perform(context, tasks, 'restore', operationId)
  }

  private static async perform(context: Context, tasks: CoreTask[], action: 'delete' | 'restore', operationId?: string): Promise<void> {
    if (tasks.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const versions = new Map<string, CoreTaskFileVersion>()
    const operations: CoreTaskOperation[] = []
    for (const task of tasks) {
      const key = `${task.repoId}\n${task.filePath}`
      if (!versions.has(key)) versions.set(key, { repoId: task.repoId, file: task.filePath, version: task.fileVersion })
      if (action === 'restore') {
        const state = task.taskStateOf(TaskStateCategory.Todo)
        if (!state) throw new Error(`“${task.heading}”所在文件没有可用的待办状态，请检查 TODO 流程`)
        operations.push({ type: 'Modification', data: { path: task.fullPath, modifications: [{ field: 'TODO', value: state.name }] } })
      } else {
        operations.push({ type: 'Deletion', data: { path: task.fullPath } })
      }
    }
    const group: CoreTaskOperationGroup = { operations, fileVersions: Array.from(versions.values()) }
    if (operationId) group.operationId = operationId
    await workspace.executeTaskOperations(group)
  }
}
