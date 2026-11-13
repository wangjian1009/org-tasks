import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskFileVersion, CoreTaskOperation, NativeCoreService } from './NativeCoreService'
import { TaskStateCategory } from '../ui/TaskStatePresentation'

// 日志簿只编排删除与恢复请求；状态规则、版本校验、保真写入和同步队列由 Core 负责。
export class LogbookService {
  static async remove(context: Context, tasks: CoreTask[]): Promise<void> {
    await LogbookService.perform(context, tasks, 'delete')
  }

  static async restore(context: Context, tasks: CoreTask[]): Promise<void> {
    await LogbookService.perform(context, tasks, 'restore')
  }

  private static async perform(context: Context, tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> {
    if (tasks.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const queueRepoIds: string[] = []
    for (const repo of repos) {
      await repo.load()
      const settings = config.repos.find(item => item.rootDirectory === repo.rootDirectory)
      if (settings?.webdavEnabled) queueRepoIds.push(repo.id)
    }
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
    await workspace.executeTaskOperations({
      operations,
      queueRepoIds,
      fileVersions: Array.from(versions.values())
    })
  }
}
