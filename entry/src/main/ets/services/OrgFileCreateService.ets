import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { AppConfigService } from './AppConfigService'
import { AppDataManager } from './AppDataManager'
import { isSystemRepository } from '../models/SystemRepository'
import { CoreRepo, CoreTask, CoreTaskFileNew, CoreTaskOperationGroup, NativeCoreService } from './NativeCoreService'
import { OrgFileRepositoryOption, OrgFileCreateInput, orgFileName, orgFileInputError } from '../ui/OrgFileCreatePresentation'

// 模板替换、SETUPFILE、文件创建与原记录移动全部交给 Core 的同一个操作组。
export class OrgFileCreateService {
  static async repositories(context: Context): Promise<OrgFileRepositoryOption[]> {
    const app = AppDataManager.shared(context)
    await app.start()
    const categories = app.dataSet('categories')
    if (categories.error) throw new Error(categories.error)
    if (!categories.isReady() || categories.data?.type !== 'file') throw new Error(localizedText($r('app.string.text_categories_are_still_loading_try_again_shortly')))
    const config = app.configuration!
    const repos = app.manager.repositoryInfo
    const files = categories.data.result
    return repos.filter(repo => !config.repos.some(item => item.rootDirectory === repo.rootDirectory && isSystemRepository(item))).map((repo: CoreRepo): OrgFileRepositoryOption => ({ repoId: repo.id,
      name: config.repos.find(item => item.rootDirectory === repo.rootDirectory)?.name || localizedText($r('app.string.text_unnamed_repository')),
      regions: Array.from(new Set(files.filter(file => file.repoId === repo.id && !file.isIgnore && !!file.category)
        .map(file => file.category!))).sort() }))
  }

  static async operationGroup(context: Context, source: CoreTask | undefined, input: OrgFileCreateInput): Promise<CoreTaskOperationGroup> {
    const error = orgFileInputError(input)
    if (error) throw new Error(error)
    const config = await AppConfigService.load(context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const system = config.repos.find(item => isSystemRepository(item))
    const target = (await workspace.repos()).find(repo => repo.id === input.repoId)
    if (!target) throw new Error(localizedText($r('app.string.text_target_repository_is_dead_please_re_select')))
    if (target.rootDirectory === system?.rootDirectory) throw new Error(localizedText($r('app.string.text_system_repository_cannot_add_files')))
    const title = input.title.trim()
    const projectName = input.projectName.trim()
    let template: Uint8Array
    try { template = await context.resourceManager.getRawFileContent(projectName ? 'templates/project.org' : 'templates/tasks.org') }
    catch (_) { throw new Error(localizedText($r('app.string.text_file_template_reading_failed_please_try_again'))) }
    const file: CoreTaskFileNew = {
      path: { repoId: input.repoId, file: orgFileName(input.fileName.trim() || title), titles: [] },
      templatePath: '', templateContent: util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(template),
      arguments: { 'title': title, 'project_name': projectName, 'category': input.region.trim() }, initTasks: []
    }
    const group: CoreTaskOperationGroup = { operations: [{ type: 'FileNew', data: file }] }
    if (source) {
      // 转换时将已有记录以首层子树移入，保留原始正文、属性和日志。
      group.operations.push({ type: 'Movement', data: { path: source.fullPath, position: { parent: file.path } } })
      group.fileVersions = [{ repoId: source.repoId, file: source.filePath, version: source.fileVersion }]
    }
    return group
  }
}
