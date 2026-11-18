import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { AppConfigService } from './AppConfigService'
import { configuredFileTarget } from './FileTargetService'
import { isSystemRepository } from '../models/SystemRepository'
import { CoreOrgFileRef, CoreRepo, CoreTask, CoreTaskFileNew, CoreTaskOperationGroup, NativeCoreService, fileResult } from './NativeCoreService'
import { ProjectRepositoryOption, ProjectLocation, projectFileName, projectInputError } from '../ui/ProjectCreatePresentation'

// 模板替换、SETUPFILE、文件创建与原记录移动全部交给 Core 的同一个操作组。
export class ProjectCreateService {
  static async repositories(context: Context): Promise<ProjectRepositoryOption[]> {
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repos = await workspace.repos()
    const excludeFiles: CoreOrgFileRef[] = []
    for (const target of [configuredFileTarget(config, 'inbox'), configuredFileTarget(config, 'someday'), configuredFileTarget(config, 'memo')]) {
      const configured = config.repos.find(item => item.id === target.repoId)
      const repo = repos.find(item => item.rootDirectory === configured?.rootDirectory)
      if (repo && target.path) excludeFiles.push({ repoId: repo.id, path: target.path })
    }
    const files = fileResult((await workspace.query([{ type: 'file', query: { excludeFiles } }]))[0])
    return repos.filter(repo => !config.repos.some(item => item.rootDirectory === repo.rootDirectory && isSystemRepository(item))).map((repo: CoreRepo): ProjectRepositoryOption => ({ repoId: repo.id,
      name: config.repos.find(item => item.rootDirectory === repo.rootDirectory)?.name || '未命名存储库',
      regions: Array.from(new Set(files.filter(file => file.repoId === repo.id && !file.isIgnore && !!file.category)
        .map(file => file.category!))).sort() }))
  }

  static async operationGroup(context: Context, source: CoreTask, location: ProjectLocation, name: string,
    fileName: string): Promise<CoreTaskOperationGroup> {
    const error = projectInputError(location.repoId, name, fileName, location.region)
    if (error) throw new Error(error)
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const system = config.repos.find(item => isSystemRepository(item))
    if ((await workspace.repos()).some(repo => repo.id === location.repoId && repo.rootDirectory === system?.rootDirectory)) throw new Error('系统仓库不能创建项目')
    if (!(await workspace.repos()).some(repo => repo.id === location.repoId)) throw new Error('目标存储库已失效，请重新选择')
    let template: Uint8Array
    try { template = await context.resourceManager.getRawFileContent('templates/project.org') }
    catch (_) { throw new Error('项目模板读取失败，请重试') }
    const file: CoreTaskFileNew = {
      path: { repoId: location.repoId, file: projectFileName(fileName), titles: [] },
      templatePath: '', templateContent: util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(template),
      arguments: { 'project_name': name.trim(), 'category': location.region.trim() }, initTasks: []
    }
    // 随包模板仅含文件头，已有记录以首层子树移入，保留原始正文、属性和日志。
    return {
      operations: [{ type: 'FileNew', data: file },
        { type: 'Movement', data: { path: source.fullPath, position: { parent: file.path } } }],
      fileVersions: [{ repoId: source.repoId, file: source.filePath, version: source.fileVersion }]
    }
  }
}
