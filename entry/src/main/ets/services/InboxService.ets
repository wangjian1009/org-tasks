import { Context } from '@kit.AbilityKit'
import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget } from './FileTargetService'
import { CoreRefileTarget, CoreTask, CoreTaskPath, CoreTaskOperation, CoreTaskFileVersion, CoreTaskQuery, NativeCoreService } from './NativeCoreService'

export type InboxAction = 'move' | 'memo' | 'delete'

// 只编排配置与 Core 请求，不解析 Org 或在宿主实现任务移动。
export class InboxService {
  static async targets(context: Context): Promise<CoreRefileTarget[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    return await workspace.refileTargets()
  }

  static async recent(context: Context): Promise<CoreTask[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const selected = configuredFileTarget(config, 'inbox')
    const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
    const repos = await workspace.repos()
    const inbox = repos.find(repo => repo.rootDirectory === settings?.rootDirectory)
    if (inbox) await inbox.load()
    const query: CoreTaskQuery = { expression: 'cr.ge.-2d cr.le.today .o.created', includeDone: true, includeComposeTasks: true,
      excludedFiles: inbox && selected.path ? [{ repoId: inbox.id, path: selected.path }] : [] }
    return (await workspace.query(query)).tasks
  }

  static async perform(context: Context, task: CoreTask, action: InboxAction,
    target?: CoreRefileTarget): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const repos = await workspace.repos()
    const queueRepoIds: string[] = []
    for (const repo of repos) {
      await repo.load()
      const settings = config.repos.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (settings?.webdavEnabled) queueRepoIds.push(repo.id)
    }
    let parent: CoreTaskPath | undefined = undefined
    const operations: CoreTaskOperation[] = []
    if (action === 'move') {
      if (!target) throw new Error('请选择任务目标')
      parent = target.fullPath
    } else if (action === 'memo') {
      const selected = configuredFileTarget(config, 'memo')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      const files = await repo.fileMetadata()
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      }
      parent = (await repo.file(selected.path)).fullPath
      operations.push({ type: 'Modification', data: { path: task.fullPath, modifications: [
        { field: 'TODO', value: null }, { field: 'PRIORITY', value: null },
        { field: 'SCHEDULE', value: null }, { field: 'DEADLINE', value: null }, { field: 'CLOSED', value: null }
      ] } })
    }
    operations.push(parent ? { type: 'Movement', data: { path: task.fullPath, position: { parent } } } :
      { type: 'Deletion', data: { path: task.fullPath } })
    const fileVersions: CoreTaskFileVersion[] = [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }]
    if (target && action === 'move') fileVersions.push({ repoId: target.repoId, file: target.path, version: target.fileVersion })
    await workspace.executeTaskOperations({ operations, queueRepoIds, fileVersions })
  }
}
