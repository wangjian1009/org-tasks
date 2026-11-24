import { Context } from '@kit.AbilityKit'
import { RepoConfig } from '../models/OrgTask'
import { DEFAULT_TASK_FILE } from '../models/RepositoryDefaults'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget, FileTarget } from './FileTargetService'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { CoreOrgFileRef, CoreRefileTarget, CoreTask, NativeCoreService } from './NativeCoreService'

export interface MoveTargetSnapshot {
  targets: CoreRefileTarget[]
  repositoryNames: Map<string, string>
}

// 只编排移动入口的配置与快照；目标识别、移动与版本校验均由 Core 完成。
export class MoveToTargetService {
  static async targets(context: Context): Promise<MoveTargetSnapshot> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const repositoryNames = new Map<string, string>()
    for (const repo of repos) {
      const name = config.repos.find(item => item.rootDirectory === repo.rootDirectory)?.name?.trim()
      if (name) repositoryNames.set(repo.id, name)
    }
    const excludedFiles: CoreOrgFileRef[] = []
    const fileRoots: CoreOrgFileRef[] = []
    const inbox = configuredFileTarget(config, 'inbox')
    const files: FileTarget[] = [inbox, configuredFileTarget(config, 'someday'), { repoId: SYSTEM_REPOSITORY_ID, path: TRASH_FILE }]
    for (const file of files) {
      const configured = config.repos.find((item: RepoConfig) => item.id === file.repoId)
      const repo = repos.find(item => item.rootDirectory === configured?.rootDirectory)
      if (repo && file.path) {
        await repo.load()
        excludedFiles.push({ repoId: repo.id, path: file.path })
        if (file === inbox) fileRoots.push({ repoId: repo.id, path: DEFAULT_TASK_FILE })
      }
    }
    const targets = await workspace.refileTargets({ excludedFiles, includeProjectRoots: true, fileRoots })
    return { targets, repositoryNames }
  }

  static async move(context: Context, source: CoreTask, target: CoreRefileTarget): Promise<void> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await workspace.executeTaskOperations({
      operations: [{ type: 'Movement', data: { path: source.fullPath, position: { parent: target.fullPath } } }],

      fileVersions: [
        { repoId: source.repoId, file: source.filePath, version: source.fileVersion },
        { repoId: target.repoId, file: target.path, version: target.fileVersion }
      ]
    })
  }
}
