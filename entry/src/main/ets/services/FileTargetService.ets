import { Context } from '@kit.AbilityKit'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreRepo, CoreTaskQueryResult, NativeCoreService } from './NativeCoreService'
import { inboxRecordQuery, memoRecordQuery } from './TaskViewQueries'

export type FileTargetKind = 'inbox' | 'someday' | 'memo'
export interface FileTarget { repoId: string; path: string }
export interface ResolvedFileTarget { repository: RepoConfig; repo: CoreRepo; path: string; tagOptions: string[]; tagGroups: string[][] }
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
    const repo = await NativeCoreService.repository([repository], repository, config.todoDefaults)
    const files = await repo.fileMetadata()
    const file = files.find(file => file.path === target.path && !file.isIgnore)
    if (!file) return undefined
    return { repository, repo, path: target.path, tagOptions: file.tagOptions ?? [], tagGroups: file.tagGroups ?? [] }
  }

  static async query(config: AppConfig, kind: FileTargetKind): Promise<FileTargetQueryResult | undefined> {
    const target = await FileTargetService.resolve(config, kind)
    if (!target) return undefined
    const query = kind === 'memo' ? memoRecordQuery(target.path) : inboxRecordQuery(target.path)
    query.includeDone = kind !== 'someday'
    const result = (await NativeCoreService.queryTasks([target.repository], [query], config.todoDefaults))[0]
    return { tasks: result.tasks, categories: result.categories, tagOptions: target.tagOptions, tagGroups: target.tagGroups }
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
