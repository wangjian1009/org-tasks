import { Context } from '@kit.AbilityKit'
import { RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget } from './FileTargetService'
import { CoreOrgFileRef, CoreRefileTarget, CoreTask, NativeCoreService } from './NativeCoreService'

// 只编排移动入口的配置与快照；目标识别、移动与版本校验均由 Core 完成。
export class MoveToTargetService {
  static async targets(context: Context): Promise<CoreRefileTarget[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const excludedFiles: CoreOrgFileRef[] = []
    for (const file of [configuredFileTarget(config, 'inbox'), configuredFileTarget(config, 'someday')]) {
      const configured = config.repos.find((item: RepoConfig) => item.id === file.repoId)
      const repo = repos.find(item => item.rootDirectory === configured?.rootDirectory)
      if (repo && file.path) {
        await repo.load()
        excludedFiles.push({ repoId: repo.id, path: file.path })
      }
    }
    return await workspace.refileTargets({ excludedFiles, includeProjectRoots: true })
  }

  static async move(context: Context, source: CoreTask, target: CoreRefileTarget): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const queueRepoIds: string[] = []
    for (const repo of await workspace.repos()) {
      await repo.load()
      const settings = config.repos.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (settings?.webdavEnabled) queueRepoIds.push(repo.id)
    }
    await workspace.executeTaskOperations({
      operations: [{ type: 'Movement', data: { path: source.fullPath, position: { parent: target.fullPath } } }],
      queueRepoIds,
      fileVersions: [
        { repoId: source.repoId, file: source.filePath, version: source.fileVersion },
        { repoId: target.repoId, file: target.path, version: target.fileVersion }
      ]
    })
  }
}
