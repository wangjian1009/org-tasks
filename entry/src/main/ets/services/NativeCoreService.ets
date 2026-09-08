import { openWorkspace, Repo as NativeRepo, Workspace as NativeWorkspace } from 'liborg_tasks_harmony.so'

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

export class CoreRepo {
  private readonly native: NativeRepo

  constructor(native: NativeRepo) {
    this.native = native
  }

  id(): string {
    return this.native.id()
  }

  async snapshot(): Promise<CoreRepositorySnapshot> {
    return JSON.parse(await this.native.snapshot()) as CoreRepositorySnapshot
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

  async snapshot(): Promise<CoreWorkspaceSnapshot> {
    return JSON.parse(await this.native.snapshot()) as CoreWorkspaceSnapshot
  }

  async search(expression: string): Promise<CoreTask[]> {
    return JSON.parse(await this.native.search(expression)) as CoreTask[]
  }

  async syncWebDav(webdavUrl: string, username: string, password: string): Promise<CoreSyncSnapshot> {
    return JSON.parse(await this.native.syncWebDav(webdavUrl, username, password)) as CoreSyncSnapshot
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
    activeWorkspace = new CoreWorkspace(await openWorkspace(rootDirectory))
    activeRootDirectory = rootDirectory
    return activeWorkspace
  }

  static async loadWorkspace(rootDirectory: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    return {
      workspace: await workspace.snapshot(),
      tasks: await workspace.search(''),
      sync: null
    }
  }

  static async syncWorkspaceWebDav(rootDirectory: string, webdavUrl: string, username: string, password: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    const sync = await workspace.syncWebDav(webdavUrl, username, password)
    return {
      workspace: await workspace.snapshot(),
      tasks: await workspace.search(''),
      sync
    }
  }

  static async searchWorkspace(rootDirectory: string, expression: string): Promise<CoreBridgeResponse> {
    const workspace = await NativeCoreService.workspaceFor(rootDirectory)
    return {
      workspace: await workspace.snapshot(),
      tasks: await workspace.search(expression),
      sync: null
    }
  }
}
