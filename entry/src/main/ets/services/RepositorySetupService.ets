import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { DEFAULT_TASK_CATEGORY, DEFAULT_TASK_FILE } from '../models/RepositoryDefaults'
import { configuredFileTarget, FileTargetKind, fileTargetName } from './FileTargetService'
import { CoreOrgFileMetadata, CoreTaskFileNew, CoreTaskOperation, CoreWorkspace, NativeCoreService, fileResult } from './NativeCoreService'

type RepositoryTemplateKind = FileTargetKind | 'task'

interface RepositoryTemplate {
  kind: RepositoryTemplateKind
  name: string
  content: string
}

interface EntryFile {
  path: string
  title: string | null
  isIgnore: boolean
}

const ENTRY_KINDS: FileTargetKind[] = ['inbox', 'someday', 'memo']
const TEMPLATE_KINDS: RepositoryTemplateKind[] = [...ENTRY_KINDS, 'task']

function templateName(kind: RepositoryTemplateKind): string {
  return kind === 'memo' ? 'note' : kind
}

// 识别随包 Org 模板的原始标题，语言切换不影响已有文件的匹配。
function entryTemplateTitle(kind: FileTargetKind): string {
  return kind === 'inbox' ? '收件箱' : kind === 'someday' ? '某天' : '备忘'
}

function entryFile(files: EntryFile[], kind: FileTargetKind): EntryFile | undefined {
  const name = templateName(kind)
  const matches = files.filter((file: EntryFile): boolean => {
    const title = file.title?.trim() || ''
    return !file.isIgnore && (title === entryTemplateTitle(kind) || title.toLowerCase() === name)
  })
  return matches.find(file => file.path === `${name}.org`) ?? (matches.length === 1 ? matches[0] : undefined)
}

export class RepositorySetupService {
  static async initialize(context: Context, config: AppConfig, repository: RepoConfig, reset: boolean = false):
    Promise<EntryFile[]> {
    const templates: RepositoryTemplate[] = []
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
    for (const kind of TEMPLATE_KINDS) {
      const name = templateName(kind)
      try {
        const resource = await context.resourceManager.getRawFileContent(`templates/${name}.org`)
        templates.push({ kind, name, content: decoder.decodeToString(resource) })
      } catch (_) { throw new Error(localizedText($r('app.string.text_could_not_read_the_template_please_try'), String(kind === 'task' ? localizedText($r('app.string.text_tasks_2')) : fileTargetName(kind)))) }
    }
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repo = (await workspace.repos()).find(item => item.rootDirectory === repository.rootDirectory)
    if (!repo) throw new Error(localizedText($r('app.string.text_target_repository_not_available')))
    if (reset) await repo.reset()
    const files = reset ? [] : await RepositorySetupService.files(workspace, repo.id)
    const operations: CoreTaskOperation[] = []
    for (const template of templates) {
      const file = template.kind === 'task' ? DEFAULT_TASK_FILE : `${template.name}.org`
      if (files.some(item => item.path === file) || (template.kind !== 'task' && entryFile(files, template.kind))) continue
      const argumentsByName: Record<string, string> = {}
      if (template.kind === 'task') {
        argumentsByName['title'] = DEFAULT_TASK_CATEGORY
        argumentsByName['category'] = DEFAULT_TASK_CATEGORY
      }
      const data: CoreTaskFileNew = {
        path: { repoId: repo.id, file, titles: [] },
        templatePath: '', templateContent: template.content, arguments: argumentsByName, initTasks: []
      }
      operations.push({ type: 'FileNew', data })
    }
    if (operations.length === 0) return files
    await workspace.executeTaskOperations({ operations })
    if (reset) return templates.map((template: RepositoryTemplate): EntryFile => ({
      path: `${template.name}.org`, title: template.kind === 'task' ? DEFAULT_TASK_CATEGORY : entryTemplateTitle(template.kind), isIgnore: false
    }))
    return await RepositorySetupService.files(workspace, repo.id)
  }

  static bindEntries(config: AppConfig, repository: RepoConfig, files: EntryFile[], afterReset: boolean = false): boolean {
    let changed = false
    for (const kind of ENTRY_KINDS) {
      const target = configuredFileTarget(config, kind)
      if (target.repoId && config.repos.some(item => item.id === target.repoId)) {
        if (!afterReset || target.repoId !== repository.id || files.some(file => file.path === target.path && !file.isIgnore)) continue
      }
      const file = entryFile(files, kind)
      if (!file) continue
      if (kind === 'inbox') { config.inboxRepoId = repository.id; config.inboxFile = file.path }
      else if (kind === 'someday') { config.somedayRepoId = repository.id; config.somedayFile = file.path }
      else { config.memoRepoId = repository.id; config.memoFile = file.path }
      changed = true
    }
    return changed
  }

  static async listEntries(config: AppConfig, repository: RepoConfig): Promise<CoreOrgFileMetadata[]> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const repo = (await workspace.repos()).find(item => item.rootDirectory === repository.rootDirectory)
    if (!repo) throw new Error(localizedText($r('app.string.text_target_repository_not_available')))
    return await RepositorySetupService.files(workspace, repo.id)
  }

  private static async files(workspace: CoreWorkspace, repoId: string): Promise<CoreOrgFileMetadata[]> {
    const results = await workspace.query([{ type: 'file', query: { includeIgnored: true } }])
    return fileResult(results[0]).filter(file => file.repoId === repoId)
  }
}
