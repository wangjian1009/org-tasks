import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { AppConfigService } from './AppConfigService'
import { CoreTask, CoreWorkspace, CoreOrgFileRef, CoreTaskOperationGroup, CoreTaskOperation, CoreTaskFileVersion, NativeCoreService } from './NativeCoreService'

export type TrashAction = 'trash' | 'restore' | 'clear'

// 宿主只组装原有批量入口，复制、叶节点校验、位置恢复与原子提交均由 Core 执行。
export class TrashService {
  static async target(config: AppConfig, workspace: CoreWorkspace): Promise<CoreOrgFileRef> {
    const system = config.repos.find(repo => repo.id === SYSTEM_REPOSITORY_ID)
    if (!system) throw new Error('系统仓库尚未初始化')
    const repo = (await workspace.repos()).find(repo => repo.rootDirectory === system.rootDirectory)
    if (!repo) throw new Error('系统仓库不可用，请重启应用后重试')
    return { repoId: repo.id, path: TRASH_FILE }
  }

  static async group(config: AppConfig, workspace: CoreWorkspace, tasks: CoreTask[], action: TrashAction,
    operationId?: string): Promise<CoreTaskOperationGroup> {
    if (tasks.length === 0) throw new Error('请选择记录')
    const target = action === 'trash' ? await TrashService.target(config, workspace) : undefined
    const versions = new Map<string, CoreTaskFileVersion>()
    const unique: CoreTask[] = []
    for (const task of tasks) {
      if (unique.some(value => value.repoId === task.repoId && value.id === task.id)) continue
      const key = JSON.stringify([task.repoId, task.filePath])
      const previous = versions.get(key)
      if (previous && previous.version !== task.fileVersion) throw new Error('文件版本已变化，请刷新后重新选择')
      versions.set(key, { repoId: task.repoId, file: task.filePath, version: task.fileVersion })
      unique.push(task)
    }
    // 永久删除沿源位置逆序处理重名项，避免删除前一条使后续 occurrence 失效。
    if (action === 'clear') unique.sort((left, right): number =>
      right.fullPath.titles.length - left.fullPath.titles.length ||
      (right.fullPath.occurrence ?? 1) - (left.fullPath.occurrence ?? 1))
    const operations = unique.map((task: CoreTask): CoreTaskOperation => {
      if (action === 'trash') return { type: 'Trash', data: { path: task.fullPath, target: target! } }
      return action === 'restore' ? { type: 'Restore', data: { path: task.fullPath } } : { type: 'Deletion', data: { path: task.fullPath } }
    })
    return { operationId, operations, fileVersions: Array.from(versions.values()) }
  }

  static async perform(context: Context, tasks: CoreTask[], action: TrashAction, operationId?: string): Promise<void> {
    if (tasks.length === 0) return
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await workspace.executeTaskOperations(await TrashService.group(config, workspace, tasks, action, operationId))
  }
}
