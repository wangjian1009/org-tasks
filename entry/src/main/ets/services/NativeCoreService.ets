import {
  Repo as NativeRepo,
  RepositorySnapshot as NativeRepositorySnapshot,
  SyncRecord as NativeSyncRecord,
  Task as NativeTask,
  WebDavSyncEvent as NativeWebDavSyncEvent,
  WebDavSyncMonitor as NativeWebDavSyncMonitor,
  WebDavSyncPolicy as NativeWebDavSyncPolicy,
  Workspace as NativeWorkspace
} from 'liborg_tasks_harmony.so'

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
  files: CoreRepositoryFile[]
}

export interface CoreTask {
  id: string
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
}

export interface CoreBridgeResponse {
  workspace: CoreWorkspaceSnapshot
  tasks: CoreTask[]
  sync: CoreSyncSnapshot | null
}

export type CoreWebDavSyncEvent = NativeWebDavSyncEvent
export type CoreWebDavSyncMonitor = NativeWebDavSyncMonitor

export class CoreWebDavSyncPolicy {
  private readonly native: NativeWebDavSyncPolicy

  constructor(webdavUrl: string, username: string, password: string) {
    this.native = new NativeWebDavSyncPolicy(webdavUrl, username, password)
  }

  nativePolicy(): NativeWebDavSyncPolicy {
    return this.native
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

  async snapshot(): Promise<CoreRepositorySnapshot> {
    return await this.native.snapshot() as NativeRepositorySnapshot
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

  async addRepo(rootDirectory: string): Promise<void> {
    await this.native.addRepo(rootDirectory)
  }

  async load(): Promise<void> {
    await this.native.load()
  }

  async search(expression: string): Promise<CoreTask[]> {
    return await this.native.search(expression) as NativeTask[]
  }

}

let activeWorkspace: CoreWorkspace | undefined = undefined
let activeRootDirectory: string = ''

// 页面通过同一 workspace session 调用 core，不解释 org 内容或同步规则。
export class NativeCoreService {
  static async workspaceFor(rootDirectory: string): Promise<CoreWorkspace> {
    if (activeWorkspace && activeRootDirectory === rootDirectory) {
      return activeWorkspace
    }
    activeWorkspace = new CoreWorkspace(new NativeWorkspace())
    await activeWorkspace.addRepo(rootDirectory)
    activeRootDirectory = rootDirectory
    return activeWorkspace
  }

  static async loadWorkspace(rootDirectory: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    await workspace.load()
    return {
      workspace: await NativeCoreService.workspaceSnapshot(workspace),
      tasks: await workspace.search(''),
      sync: null
    }
  }

  static async syncWorkspaceWebDav(
    rootDirectory: string,
    webdavUrl: string,
    username: string,
    password: string,
    monitor?: CoreWebDavSyncMonitor
  ): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    await workspace.load()
    const repos = await workspace.repos()
    if (repos.length !== 1) {
      throw new Error('当前 Harmony workspace 必须包含一个仓库')
    }
    const policy = new CoreWebDavSyncPolicy(webdavUrl, username, password)
    const sync = await repos[0].sync(policy, monitor)
    return {
      workspace: await NativeCoreService.workspaceSnapshot(workspace),
      tasks: await workspace.search(''),
      sync
    }
  }

  static async searchWorkspace(rootDirectory: string, expression: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    await workspace.load()
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
