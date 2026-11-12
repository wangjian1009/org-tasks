import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreTaskFileVersion, CoreTaskOperation, NativeCoreService } from './NativeCoreService'

// 日志簿只编排删除操作；任务定位、版本校验、保真写入和同步队列由 Core 负责。
export class LogbookService {
  static async remove(context: Context, tasks: CoreTask[]): Promise<void> {
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
      operations.push({ type: 'Deletion', data: { path: task.fullPath } })
    }
    await workspace.executeTaskOperations({
      operations,
      queueRepoIds,
      fileVersions: Array.from(versions.values())
    })
  }
}
