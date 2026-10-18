import {
  Repo as NativeRepo,
  ConflictSync as NativeConflictSync,
  MergeComparison as NativeMergeComparison,
  MergeChange as NativeMergeChange,
  MergeOutcome as NativeMergeOutcome,
  NewTask as NativeNewTask,
  CoreError as NativeCoreError,
  RepositorySnapshot as NativeRepositorySnapshot,
  SyncRecord as NativeSyncRecord,
  Task as NativeTask,
  WebDavSyncEvent as NativeWebDavSyncEvent,
  WebDavSyncMonitor as NativeWebDavSyncMonitor,
  WebDavSyncPolicy as NativeWebDavSyncPolicy,
  Workspace as NativeWorkspace
} from 'liborg_tasks_harmony.so'
import { RepoConfig } from '../models/OrgTask'

export interface CoreRepositoryFile {
  path: string
  source: string
  byte_length: number
}

export interface CoreWorkspaceSnapshot {
  repos: CoreRepositorySnapshot[]
}

export interface CoreRepositorySnapshot {
  id: string
  rootDirectory: string
  files: CoreRepositoryFile[]
}

export interface CoreTask {
  id: string
  repoId: string
  heading: string
  todoState: string
  priority: string
  scheduled: string
  deadline: string
  tags: string[]
  filePath: string
  fileName: string
  level: number
  body: string
  progress: number
}

export interface CoreSyncSnapshot {
  id: string
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'
  started_at: number
  finished_at: number | null
  files: number
  conflicts: string[]
}

export interface CoreBridgeResponse {
  workspace: CoreWorkspaceSnapshot
  tasks: CoreTask[]
  sync: CoreSyncSnapshot | null
}

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
}

export class CoreRepo {
  private readonly native: NativeRepo

  constructor(native: NativeRepo) {
    this.native = native
  }

  id(): string {
    return this.native.id()
  }

  rootDirectory(): string {
    return this.native.rootDirectory()
  }

  async conflicts(): Promise<NativeConflictSync[]> { return await this.native.conflicts() }

  async compareMerge(policy: CoreWebDavSyncPolicy, syncId: string): Promise<CoreMergeComparison> {
    return await this.native.compareMerge(policy.nativePolicy(), syncId)
  }

  async apply(policy: CoreWebDavSyncPolicy, comparison: CoreMergeComparison): Promise<CoreMergeOutcome> {
    return await this.native.apply(policy.nativePolicy(), comparison)
  }

  async load(): Promise<void> {
    await this.native.load()
  }

  async createTask(path: string, task: CoreNewTask, queueUpload: boolean): Promise<void> {
    await this.native.createTask(path, task, queueUpload)
  }

  async snapshot(): Promise<CoreRepositorySnapshot> {
    const snapshot = await this.native.snapshot() as NativeRepositorySnapshot
    return { id: snapshot.id, rootDirectory: this.rootDirectory(), files: snapshot.files }
  }

  async sync(policy: CoreWebDavSyncPolicy, monitor?: CoreWebDavSyncMonitor): Promise<CoreSyncSnapshot> {
    return await this.native.sync(policy.nativePolicy(), monitor) as NativeSyncRecord
  }
}

export class CoreWorkspace {
  private readonly native: NativeWorkspace

  constructor(native: NativeWorkspace) {
    this.native = native
  }

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

}

let activeWorkspace: CoreWorkspace | undefined = undefined
let activeWorkspaceKey: string = ''

// 页面通过同一 workspace session 调用 core，不解释 org 内容或同步规则。
export class NativeCoreService {
  static async repository(repositories: RepoConfig[], repository: RepoConfig): Promise<CoreRepo> {
    const workspace = await NativeCoreService.workspaceFor(repositories)
    const repos = await workspace.repos()
    const repo = repos.find((item: CoreRepo) => item.rootDirectory() === repository.rootDirectory)
    if (!repo) throw new Error('目标仓库不可用')
    return repo
  }

  static async conflicts(repositories: RepoConfig[]): Promise<CoreConflict[]> {
    const result: CoreConflict[] = []
    for (const repository of repositories) {
      if (!repository.webdavEnabled) continue
      const repo = await NativeCoreService.repository(repositories, repository)
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

  static async workspaceFor(repositories: RepoConfig[]): Promise<CoreWorkspace> {
    const workspaceKey = repositories.map((repository: RepoConfig) => repository.rootDirectory).join('\n')
    if (activeWorkspace && activeWorkspaceKey === workspaceKey) {
      return activeWorkspace
    }
    const workspace = new CoreWorkspace(new NativeWorkspace())
    for (const repository of repositories) {
      await workspace.addRepo(repository.rootDirectory)
    }
    activeWorkspace = workspace
    activeWorkspaceKey = workspaceKey
    return activeWorkspace
  }

  static async createTask(repositories: RepoConfig[], repository: RepoConfig, path: string, task: CoreNewTask): Promise<void> {
    const workspace = await NativeCoreService.workspaceFor(repositories)
    const repos = await workspace.repos()
    const repo = repos.find((item: CoreRepo) => item.rootDirectory() === repository.rootDirectory)
    if (!repo) throw new Error('目标仓库不可用')
    await repo.createTask(path, task, repository.webdavEnabled)
  }

  static async loadWorkspace(repositories: RepoConfig[]): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories)
    const repos = await workspace.repos()
    for (const repo of repos) {
      await repo.load()
    }
    return {
      workspace: await NativeCoreService.workspaceSnapshot(workspace),
      tasks: await workspace.search(''),
      sync: null
    }
  }

  static async syncWorkspaceWebDav(
    repositories: RepoConfig[],
    monitor?: CoreWebDavSyncMonitor
  ): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories)
    const repos = await workspace.repos()
    let sync: CoreSyncSnapshot | null = null
    for (const repo of repos) {
      await repo.load()
      const config = repositories.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory())
      if (config?.webdavEnabled) {
        const policy = new CoreWebDavSyncPolicy(config.webdavUrl, config.webdavUsername, config.webdavPassword)
        sync = await repo.sync(policy, monitor)
        if (sync.result !== 'succeeded') {
          throw new Error('WebDAV 同步未完成，请查看同步记录；待上传任务已保留')
        }
      }
    }
    return {
      workspace: await NativeCoreService.workspaceSnapshot(workspace),
      tasks: await workspace.search(''),
      sync
    }
  }

  static async searchWorkspace(repositories: RepoConfig[], expression: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(repositories)
    const repos = await workspace.repos()
    for (const repo of repos) {
      await repo.load()
    }
    return {
      workspace: await NativeCoreService.workspaceSnapshot(workspace),
      tasks: await workspace.search(expression),
      sync: null
    }
  }

  private static async workspaceSnapshot(workspace: CoreWorkspace): Promise<CoreWorkspaceSnapshot> {
    const repos = await workspace.repos()
    return { repos: await Promise.all(repos.map((repo: CoreRepo) => repo.snapshot())) }
  }
}
