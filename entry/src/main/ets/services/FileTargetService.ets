import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreRepo, CoreQuery, CoreQueryResult, CoreOrgFileRef, CoreTaskQueryResult, NativeCoreService, taskResult, fileResult } from './NativeCoreService'
import { PageQueryService } from './PageQueryService'
import { inboxRecordQuery, memoRecordQuery } from './TaskViewQueries'

export type FileTargetKind = 'inbox' | 'someday' | 'memo'
export interface FileTarget { repoId: string; path: string }
export interface ResolvedFileTarget { repository: RepoConfig; repo: CoreRepo; path: string; tagOptions: string[]; tagGroups: string[][] }
export interface PreparedFileTarget { task: CoreQuery; file: CoreQuery; reference: CoreOrgFileRef }
export interface FileTargetQueryResult extends CoreTaskQueryResult { tagOptions: string[]; tagGroups: string[][] }

export function configuredFileTarget(config: AppConfig, kind: FileTargetKind): FileTarget {
  if (kind === 'inbox') return { repoId: config.inboxRepoId, path: config.inboxFile }
  if (kind === 'someday') return { repoId: config.somedayRepoId, path: config.somedayFile }
  return { repoId: config.memoRepoId, path: config.memoFile }
}

export function fileTargetRepository(config: AppConfig, kind: FileTargetKind): RepoConfig | undefined {
  const target = configuredFileTarget(config, kind)
  if (!target.repoId || !target.path) return undefined
  return config.repos.find((repo: RepoConfig) => repo.id === target.repoId)
}

export function fileTargetName(kind: FileTargetKind): string {
  return kind === 'inbox' ? '收件箱' : kind === 'someday' ? '某天' : '备忘'
}

// 文件入口只接受显式选择的仓库和文件；旧配置、失效目标与忽略文件均不回退。
export class FileTargetService {
  static async resolve(config: AppConfig, kind: FileTargetKind): Promise<ResolvedFileTarget | undefined> {
    const repository = fileTargetRepository(config, kind)
    if (!repository) return undefined
    const target = configuredFileTarget(config, kind)
    const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
    const files = fileResult((await NativeCoreService.query(config.repos, [{ type: 'file',
      query: { includeFiles: [{ repoId: repo.id, path: target.path }] } }], config.todoDefaults))[0])
    const file = files.find(file => file.path === target.path && !file.isIgnore)
    if (!file) return undefined
    return { repository, repo, path: target.path, tagOptions: file.tagOptions ?? [], tagGroups: file.tagGroups ?? [] }
  }

  static prepare(config: AppConfig, repos: CoreRepo[], kind: FileTargetKind): PreparedFileTarget | undefined {
    const repository = fileTargetRepository(config, kind)
    if (!repository) return undefined
    const target = configuredFileTarget(config, kind)
    const repo = repos.find(item => item.rootDirectory === repository.rootDirectory)
    if (!repo) return undefined
    const query = kind === 'memo' ? memoRecordQuery(target.path) : inboxRecordQuery(target.path)
    query.includeDone = kind !== 'someday'
    const reference: CoreOrgFileRef = { repoId: repo.id, path: target.path }
    return { task: { type: 'task', repoIds: [repo.id], query },
      file: { type: 'file', query: { includeFiles: [reference] } }, reference }
  }

  static result(task: CoreQueryResult | undefined, metadata: CoreQueryResult | undefined): FileTargetQueryResult | undefined {
    if (!task || !metadata) return undefined
    const file = fileResult(metadata)[0]
    if (!file) return undefined
    const result = taskResult(task)
    return { tasks: result.tasks, categories: result.categories,
      tagOptions: file.tagOptions ?? [], tagGroups: file.tagGroups ?? [] }
  }

  static async query(config: AppConfig, kind: FileTargetKind): Promise<FileTargetQueryResult | undefined> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    const prepared = FileTargetService.prepare(config, await workspace.repos(), kind)
    const results = await PageQueryService.query(config, prepared ? [prepared.task, prepared.file] : [])
    return prepared ? FileTargetService.result(results[0], results[1]) : undefined
  }

  static async select(context: Context, kind: FileTargetKind, repoId: string, path: string): Promise<void> {
    // 选择列表只是展示快照；提交前重新读取配置和 Core 元信息，保留其他页面的更新。
    const config = await AppConfigService.load(context)
    if (kind === 'inbox') { config.inboxRepoId = repoId; config.inboxFile = path }
    else if (kind === 'someday') { config.somedayRepoId = repoId; config.somedayFile = path }
    else { config.memoRepoId = repoId; config.memoFile = path }
    if ((repoId || path) && !await FileTargetService.resolve(config, kind)) {
      throw new Error(`所选${fileTargetName(kind)}文件已失效，请重新选择`)
    }
    await AppConfigService.save(context, config)
  }
}
