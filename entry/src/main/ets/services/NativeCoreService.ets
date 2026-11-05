import {
  Repo as NativeRepo,
  TodoMetadata as NativeTodoMetadata,
  defaultSyncOptions,
  defaultTodoSettings,
  ConflictSync as NativeConflictSync,
  MergeComparison as NativeMergeComparison,
  MergeChange as NativeMergeChange,
  MergeOutcome as NativeMergeOutcome,
  NewTask as NativeNewTask,
  CoreError as NativeCoreError,
  OrgFile as NativeOrgFile,
  OrgFileMetadata as NativeOrgFileMetadata,
  SyncRecord as NativeSyncRecord,
  Task as NativeTask,
  TitlePart as NativeTitlePart,
  TaskQuery as NativeTaskQuery,
  TaskCategory as NativeTaskCategory,
  TaskQueryResult as NativeTaskQueryResult,
  WebDavSyncEvent as NativeWebDavSyncEvent,
  WebDavSyncMonitor as NativeWebDavSyncMonitor,
  WebDavSyncPolicy as NativeWebDavSyncPolicy,
  Workspace as NativeWorkspace
} from 'liborg_tasks_harmony.so'
import { RepoConfig, SyncOptions } from '../models/OrgTask'

export type CoreOrgFile = NativeOrgFile
export type CoreOrgFileMetadata = NativeOrgFileMetadata

export type CoreTask = NativeTask
export type CoreTitlePart = NativeTitlePart
export type CoreTaskQuery = NativeTaskQuery
export type CoreTaskCategory = NativeTaskCategory
export type CoreTaskQueryResult = NativeTaskQueryResult

export interface CoreSyncSnapshot {
  id: string
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'
  started_at: number
  finished_at: number | null
  files: number
  conflicts: string[]
}

export interface CoreBridgeResponse {
  workspace: CoreWorkspace
  tasks: CoreTask[]
  sync: CoreSyncSnapshot | null
}

export type CoreTodoMetadata = NativeTodoMetadata

export type CoreMergeComparison = NativeMergeComparison
export type CoreMergeChange = NativeMergeChange
export type CoreMergeOutcome = NativeMergeOutcome
export enum CoreMergeMode {
  AcceptRemote = 'acceptRemote',
  MergeTasks = 'mergeTasks'
}
export enum CoreMergeResolution {
  Local = 'local',
  Remote = 'remote',
  Remove = 'remove'
}
export interface CoreConflict { repoId: string; syncId: string; paths: string[] }

export type CoreNewTask = NativeNewTask

export type CoreWebDavSyncEvent = NativeWebDavSyncEvent
export type CoreWebDavSyncMonitor = NativeWebDavSyncMonitor
export type CoreBridgeError = NativeCoreError

export function coreErrorMessage(error: CoreBridgeError): string {
  if (typeof error.message === 'string' && error.message.length > 0) {
    return error.message
  }
  return '操作未完成，请重试'
}

export class CoreWebDavSyncPolicy {
  private readonly native: NativeWebDavSyncPolicy

  constructor(webdavUrl: string, username: string, password: string) {
    this.native = new NativeWebDavSyncPolicy(webdavUrl, username, password)
  }

  nativePolicy(): NativeWebDavSyncPolicy {
    return this.native
  }

  async testConnection(): Promise<void> {
    await this.native.testConnection()
  }

  async compareMerge(repo: CoreRepo, syncId: string): Promise<CoreMergeComparison> {
    return await this.native.compareMerge(repo.nativeRepo(), syncId)
  }

  async applyMerge(repo: CoreRepo, comparison: CoreMergeComparison): Promise<CoreMergeOutcome> {
    return await this.native.applyMerge(repo.nativeRepo(), comparison)
  }
}

export class CoreRepo {
  private readonly native: NativeRepo

  constructor(native: NativeRepo) {
    this.native = native
  }

  get id(): string {
    return this.native.id
  }

  get rootDirectory(): string {
    return this.native.rootDirectory
  }

  nativeRepo(): NativeRepo { return this.native }

  async file(path: string): Promise<CoreOrgFile> { return await this.native.file(path) }

  async files(): Promise<CoreOrgFile[]> { return await this.native.files() }
  async fileMetadata(): Promise<CoreOrgFileMetadata[]> { return await this.native.fileMetadata() }

  async conflicts(): Promise<NativeConflictSync[]> { return await this.native.conflicts() }

  async load(): Promise<void> {
    await this.native.load()
  }

  async createTask(path: string, task: CoreNewTask, queueUpload: boolean): Promise<void> {
    await this.native.createTask(path, task, queueUpload)
  }

  async sync(policy: CoreWebDavSyncPolicy, monitor?: CoreWebDavSyncMonitor, options?: SyncOptions): Promise<CoreSyncSnapshot> {
    const effective = options ?? await defaultSyncOptions()
    return await this.native.sync(policy.nativePolicy(), monitor, effective) as NativeSyncRecord
  }
}

export class CoreWorkspace {
  private readonly native: NativeWorkspace

  constructor(native: NativeWorkspace) {
    this.native = native
  }

  async setTodoDefaults(settings: string): Promise<void> { await this.native.setTodoDefaults(settings) }

  async repos(): Promise<CoreRepo[]> {
    const repos = await this.native.repos()
    return repos.map((repo: NativeRepo) => new CoreRepo(repo))
  }

  async addRepo(rootDirectory: string): Promise<CoreRepo> {
    return new CoreRepo(await this.native.addRepo(rootDirectory))
  }

  async removeRepo(rootDirectory: string): Promise<void> {
    await this.native.removeRepo(rootDirectory)
  }

  async search(expression: string): Promise<CoreTask[]> {
    return await this.native.search(expression) as NativeTask[]
  }

  async query(query: CoreTaskQuery): Promise<CoreTaskQueryResult> {
    return await this.native.query(query)
  }

}

let activeWorkspace: CoreWorkspace | undefined = undefined
let activeWorkspaceKey: string = ''
let activeTodoDefaults: string | undefined = undefined

// 页面通过同一 workspace session 调用 core，不解释 org 内容或同步规则。
export class NativeCoreService {
  static async queryTasks(repositories: RepoConfig[], query: CoreTaskQuery, todoDefaults?: string): Promise<CoreTaskQueryResult> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    return await workspace.query(query)
  }
  static async repository(repositories: RepoConfig[], repository: RepoConfig, todoDefaults?: string): Promise<CoreRepo> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    const repo = repos.find((item: CoreRepo) => item.rootDirectory === repository.rootDirectory)
    if (!repo) throw new Error('目标仓库不可用')
    return repo
  }

  static async conflicts(repositories: RepoConfig[], todoDefaults?: string): Promise<CoreConflict[]> {
    const result: CoreConflict[] = []
    for (const repository of repositories) {
      if (!repository.webdavEnabled) continue
      const repo = await NativeCoreService.repository(repositories, repository, todoDefaults)
      const conflicts = await repo.conflicts()
      for (const conflict of conflicts) result.push({ repoId: repository.id, syncId: conflict.syncId, paths: conflict.paths })
    }
    return result
  }

  static async validateRepository(rootDirectory: string): Promise<void> {
    const workspace = new CoreWorkspace(new NativeWorkspace())
    const repo = await workspace.addRepo(rootDirectory)
    await repo.load()
  }

  static async workspaceFor(repositories: RepoConfig[], todoDefaults?: string): Promise<CoreWorkspace> {
    const settings = todoDefaults ?? await defaultTodoSettings()
    const workspaceKey = repositories.map((repository: RepoConfig) => repository.rootDirectory).join('\n')
    if (activeWorkspace && activeWorkspaceKey === workspaceKey) {
      if (activeTodoDefaults !== settings) {
        await activeWorkspace.setTodoDefaults(settings)
        activeTodoDefaults = settings
      }
      return activeWorkspace
    }
    const workspace = new CoreWorkspace(new NativeWorkspace())
    await workspace.setTodoDefaults(settings)
    for (const repository of repositories) {
      await workspace.addRepo(repository.rootDirectory)
    }
    activeWorkspace = workspace
    activeWorkspaceKey = workspaceKey
    activeTodoDefaults = settings
    return activeWorkspace
  }

  static async createTask(repositories: RepoConfig[], repository: RepoConfig, path: string, task: CoreNewTask, todoDefaults?: string): Promise<void> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    const repo = repos.find((item: CoreRepo) => item.rootDirectory === repository.rootDirectory)
    if (!repo) throw new Error('目标仓库不可用')
    await repo.createTask(path, task, repository.webdavEnabled)
  }

  static async loadWorkspace(repositories: RepoConfig[], todoDefaults?: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    for (const repo of repos) {
      await repo.load()
    }
    return {
      workspace,
      tasks: await workspace.search(''),
      sync: null
    }
  }

  static async syncWorkspaceWebDav(
    repositories: RepoConfig[],
    monitor?: CoreWebDavSyncMonitor,
    todoDefaults?: string
  ): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    let sync: CoreSyncSnapshot | null = null
    for (const repo of repos) {
      const config = repositories.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (config?.webdavEnabled) {
        const policy = new CoreWebDavSyncPolicy(config.webdavUrl, config.webdavUsername, config.webdavPassword)
        sync = await repo.sync(policy, monitor, { excludedDirectories: config.excludedDirectories })
        if (sync.result !== 'succeeded') {
          throw new Error('WebDAV 同步未完成，请重试')
        }
      } else {
        await repo.load()
      }
    }
    return {
      workspace,
      tasks: await workspace.search(''),
      sync
    }
  }

  static async searchWorkspace(repositories: RepoConfig[], expression: string, todoDefaults?: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    for (const repo of repos) {
      await repo.load()
    }
    return {
      workspace,
      tasks: await workspace.search(expression),
      sync: null
    }
  }

}
