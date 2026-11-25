import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreOrgFileMetadata, CoreQueryRepositoryBinding, CoreRepo, CoreQuery, CoreQueryResult, CoreOrgFileRef, CoreTaskQueryResult, NativeCoreService, taskResult, fileResult } from './NativeCoreService'
import { PageQueryService } from './PageQueryService'
import { inboxRecordQuery, memoRecordQuery, overviewTaskQuery } from './TaskViewQueries'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'

export type FileTargetKind = 'inbox' | 'someday' | 'memo'
export interface FileTarget { repoId: string; path: string }
export interface ResolvedFileTarget { repository: RepoConfig; repo: CoreRepo; path: string; metadata: CoreOrgFileMetadata; tagOptions: string[]; tagGroups: string[][] }
export interface PreparedFileTarget { task: CoreQuery; file: CoreQuery; reference: CoreOrgFileRef; repositoryBindings?: CoreQueryRepositoryBinding[] }
export interface FileTargetQueryResult extends CoreTaskQueryResult { tagOptions: string[]; tagGroups: string[][] }
export interface ConfiguredFileExclusions { files: CoreOrgFileRef[]; repositoryBindings: CoreQueryRepositoryBinding[] }

export function systemTrashExclusions(config: AppConfig): ConfiguredFileExclusions {
  const repository = config.repos.find(repo => repo.id === SYSTEM_REPOSITORY_ID)
  return repository ? { files: [{ repoId: repository.id, path: TRASH_FILE }],
    repositoryBindings: [{ id: repository.id, rootDirectory: repository.rootDirectory }] } : { files: [], repositoryBindings: [] }
}

// 特殊文件按配置仓库和相对路径定位，由工作线程解析宿主仓库 ID。
export function configuredSpecialFileExclusions(config: AppConfig): ConfiguredFileExclusions {
  const files: CoreOrgFileRef[] = []
  const repositoryBindings: CoreQueryRepositoryBinding[] = []
  for (const target of [configuredFileTarget(config, 'inbox'), configuredFileTarget(config, 'someday'), configuredFileTarget(config, 'memo'),
    { repoId: SYSTEM_REPOSITORY_ID, path: TRASH_FILE } as FileTarget]) {
    const repository = config.repos.find(repo => repo.id === target.repoId)
    if (!repository || !target.path) continue
    if (!files.some(file => file.repoId === repository.id && file.path === target.path)) files.push({ repoId: repository.id, path: target.path })
    if (!repositoryBindings.some(binding => binding.id === repository.id)) repositoryBindings.push({ id: repository.id, rootDirectory: repository.rootDirectory })
  }
  return { files, repositoryBindings }
}

export function configuredFileTarget(config: AppConfig, kind: FileTargetKind): FileTarget {
  if (kind === 'inbox') return { repoId: config.inboxRepoId, path: config.inboxFile }
  if (kind === 'someday') return { repoId: config.somedayRepoId, path: config.somedayFile }
  return { repoId: config.memoRepoId, path: config.memoFile }
}

export function fileTargetRepository(config: AppConfig, kind: FileTargetKind): RepoConfig | undefined {
  const target = configuredFileTarget(config, kind)
  if (!target.repoId || !target.path || target.repoId === SYSTEM_REPOSITORY_ID) return undefined
  return config.repos.find((repo: RepoConfig) => repo.id === target.repoId)
}

export function fileTargetName(kind: FileTargetKind): string {
  return kind === 'inbox' ? localizedText($r('app.string.text_inbox')) : kind === 'someday' ? localizedText($r('app.string.text_someday')) : localizedText($r('app.string.text_notes'))
}

// 文件入口只接受显式选择的仓库和文件；旧配置、失效目标与忽略文件均不回退。
export class FileTargetService {
  static async resolve(config: AppConfig, kind: FileTargetKind): Promise<ResolvedFileTarget | undefined> {
    const repository = fileTargetRepository(config, kind)
    if (!repository) return undefined
    const target = configuredFileTarget(config, kind)
    const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
    const files = fileResult((await NativeCoreService.query(config.repos, [{ type: 'file',
      query: { includeFiles: [{ repoId: repo.id, path: target.path }] } }], config.todoDefaults, config.coreSettings))[0])
    const file = files.find(file => file.path === target.path && !file.isIgnore)
    if (!file) return undefined
    return { repository, repo, path: target.path, metadata: file, tagOptions: file.tagOptions ?? [], tagGroups: file.tagGroups ?? [] }
  }

  static prepare(config: AppConfig, repos: CoreRepo[], kind: FileTargetKind): PreparedFileTarget | undefined {
    const repository = fileTargetRepository(config, kind)
    if (!repository) return undefined
    const target = configuredFileTarget(config, kind)
    const repo = repos.find(item => item.rootDirectory === repository.rootDirectory)
    if (!repo) return undefined
    const reference: CoreOrgFileRef = { repoId: repo.id, path: target.path }
    const query = kind === 'someday' ? overviewTaskQuery('someday', reference) :
      kind === 'memo' ? memoRecordQuery(reference) : inboxRecordQuery(reference)
    return { task: { type: 'task', repoIds: [repo.id], query },
      file: { type: 'file', query: { includeFiles: [reference] } }, reference }
  }

  // 只组装本地查询；宿主 ID 在本次请求的工作线程内按根目录解析为 Core ID。
  static prepareConfigured(config: AppConfig, kind: FileTargetKind): PreparedFileTarget | undefined {
    const repository = fileTargetRepository(config, kind)
    if (!repository) return undefined
    const target = configuredFileTarget(config, kind)
    const reference: CoreOrgFileRef = { repoId: repository.id, path: target.path }
    const query = kind === 'someday' ? overviewTaskQuery('someday', reference) :
      kind === 'memo' ? memoRecordQuery(reference) : inboxRecordQuery(reference)
    return { task: { type: 'task', repoIds: [reference.repoId], query },
      file: { type: 'file', query: { includeFiles: [reference] } }, reference,
      repositoryBindings: [{ id: repository.id, rootDirectory: repository.rootDirectory }] }
  }

  static result(task: CoreQueryResult | undefined, metadata: CoreQueryResult | undefined): FileTargetQueryResult | undefined {
    if (!task || !metadata) return undefined
    const file = fileResult(metadata)[0]
    if (!file) return undefined
    const result = taskResult(task)
    return { tasks: result.tasks, categories: result.categories, fullFiles: [],
      tagOptions: file.tagOptions ?? [], tagGroups: file.tagGroups ?? [] }
  }

  static async query(config: AppConfig, kind: FileTargetKind): Promise<FileTargetQueryResult | undefined> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const prepared = FileTargetService.prepare(config, await workspace.repos(), kind)
    const results = await PageQueryService.query(config, prepared ? [prepared.task, prepared.file] : [])
    return prepared ? FileTargetService.result(results[0], results[1]) : undefined
  }

  static async select(context: Context, kind: FileTargetKind, repoId: string, path: string): Promise<void> {
    if (repoId === SYSTEM_REPOSITORY_ID) throw new Error(localizedText($r('app.string.text_the_system_repository_is_not_a_file')))
    // 选择列表只是展示快照；提交前重新读取配置和 Core 元信息，保留其他页面的更新。
    const config = await AppConfigService.load(context)
    if (kind === 'inbox') { config.inboxRepoId = repoId; config.inboxFile = path }
    else if (kind === 'someday') { config.somedayRepoId = repoId; config.somedayFile = path }
    else { config.memoRepoId = repoId; config.memoFile = path }
    if ((repoId || path) && !await FileTargetService.resolve(config, kind)) {
      throw new Error(localizedText($r('app.string.text_the_selected_file_is_invalid_please_re'), String(fileTargetName(kind))))
    }
    await AppConfigService.save(context, config)
  }
}
