import { Context } from '@kit.AbilityKit'
import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget } from './FileTargetService'
import { CoreRefileTarget, CoreTask, CoreTaskDestination, CoreTaskQuery, NativeCoreService } from './NativeCoreService'

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
    let destination: CoreTaskDestination | null = null
    if (action === 'move') {
      if (!target) throw new Error('请选择任务目标')
      destination = { repoId: target.repoId, path: target.path, fileVersion: target.fileVersion,
        parent: target.position, clearTodo: false }
    } else if (action === 'memo') {
      const selected = configuredFileTarget(config, 'memo')
      const settings = config.repos.find((item: RepoConfig) => item.id === selected.repoId)
      const repo = repos.find(item => item.rootDirectory === settings?.rootDirectory)
      if (!repo || !selected.path) throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      const files = await repo.fileMetadata()
      if (!files.some(file => file.path === selected.path && !file.isIgnore)) {
        throw new Error('备忘文件未选择或已失效，请在设置中重新选择')
      }
      const file = await repo.file(selected.path)
      destination = { repoId: repo.id, path: selected.path, fileVersion: file.fileVersion,
        parent: null, clearTodo: true }
    }
    await workspace.editTask({ source: task.source, destination, queueRepoIds })
  }
}
