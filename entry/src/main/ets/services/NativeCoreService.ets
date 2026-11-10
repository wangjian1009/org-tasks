import {
  Repo as NativeRepo,
  ConflictPreview as NativeConflictPreview,
  ConflictPreviewRequest as NativeConflictPreviewRequest,
  ConflictPreviewChanges as NativeConflictPreviewChanges,
  ConflictPreviewChange as NativeConflictPreviewChange,
  ConflictPreviewDiffLine as NativeConflictPreviewDiffLine,
  ConflictTarget as NativeConflictTarget,
  FileConflict as NativeFileConflict,
  TaskPath as NativeTaskPath,
  TaskFileVersion as NativeTaskFileVersion,
  TaskOperation as NativeTaskOperation,
  TaskOperationGroup as NativeTaskOperationGroup,
  TaskMergeRequest as NativeTaskMergeRequest,
  TaskMergePlan as NativeTaskMergePlan,
  TaskConfilictSelection as NativeTaskConfilictSelection,
  TaskModification as NativeTaskModification,
  TaskChecklistItem as NativeTaskChecklistItem,
  TaskChecklistChange as NativeTaskChecklistChange,
  SupportTags as NativeSupportTags,
  TodoMetadata as NativeTodoMetadata,
  defaultSyncOptions,
  defaultTodoSettings,
  ConflictSync as NativeConflictSync,
  RefileTarget as NativeRefileTarget,
  RefileTargetQuery as NativeRefileTargetQuery,
  OrgFileRef as NativeOrgFileRef,
  CoreError as NativeCoreError,
  NotificationUpdateMonitor as NativeNotificationUpdateMonitor,
  DataChangeEvent as NativeDataChangeEvent,
  DataChangeMonitor as NativeDataChangeMonitor,
  SyncRequiredNotification as NativeSyncRequiredNotification,
  CoreNotification as NativeCoreNotification,
  SyncConflictNotification as NativeSyncConflictNotification,
  OrgFile as NativeOrgFile,
  OrgFileMetadata as NativeOrgFileMetadata,
  SyncRecord as NativeSyncRecord,
  SyncRecordDetail as NativeSyncRecordDetail,
  SyncFileRecord as NativeSyncFileRecord,
  SyncHistoryError as NativeSyncHistoryError,
  Task as NativeTask,
  TitlePart as NativeTitlePart,
  AddressLink as NativeAddressLink,
  TitleCount as NativeTitleCount,
  TaskQuery as NativeTaskQuery,
  TaskQueryResult as NativeTaskQueryResult,
  WebDavSyncEvent as NativeWebDavSyncEvent,
  WebDavSyncMonitor as NativeWebDavSyncMonitor,
  WebDavSyncPolicy as NativeWebDavSyncPolicy,
  Workspace as NativeWorkspace
} from 'liborg_tasks_harmony.so'
import { RepoConfig, SyncOptions } from '../models/OrgTask'

export type CoreConflictPreview = NativeConflictPreview
export type CoreConflictPreviewRequest = NativeConflictPreviewRequest
export type CoreConflictPreviewChanges = NativeConflictPreviewChanges
export type CoreConflictPreviewChange = NativeConflictPreviewChange
export type CoreConflictPreviewDiffLine = NativeConflictPreviewDiffLine
export type CoreConflictTarget = NativeConflictTarget
export type CoreFileConflict = NativeFileConflict
export type CoreOrgFile = NativeOrgFile
export type CoreOrgFileMetadata = NativeOrgFileMetadata

// 逻辑身份、category、hasList、hasText 与 isRepeating 均由 Core 投影，宿主不解析 Org 或重新计算。
export type CoreTaskChecklistItem = NativeTaskChecklistItem
// 包含 move / beforeId；与 siblingGroup 一起透传，排序规则由 Core 验证。
export type CoreTaskChecklistChange = NativeTaskChecklistChange
export type CoreSupportTags = NativeSupportTags
export type CoreTask = NativeTask
export type CoreTitlePart = NativeTitlePart
export type CoreAddressLink = NativeAddressLink
export type CoreTitleCount = NativeTitleCount
export type CoreTaskQuery = NativeTaskQuery
export type CoreTaskQueryResult = NativeTaskQueryResult

export interface CoreSyncSnapshot {
  id: string
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'
  started_at: number
  finished_at: number | null
  files: number
  conflicts: string[]
}

export type CoreSyncRecord = NativeSyncRecord
export type CoreSyncRecordDetail = NativeSyncRecordDetail
export type CoreNotificationUpdateMonitor = NativeNotificationUpdateMonitor
export type CoreSyncRequiredNotification = NativeSyncRequiredNotification
export type CoreSyncFileRecord = NativeSyncFileRecord
export type CoreSyncHistoryError = NativeSyncHistoryError

export type CoreTodoMetadata = NativeTodoMetadata

export interface CoreConflict { repoId: string; syncId: string; paths: string[] }

export type CoreOrgFileRef = NativeOrgFileRef
export type CoreRefileTargetQuery = NativeRefileTargetQuery
export type CoreRefileTarget = NativeRefileTarget
export type CoreTaskPath = NativeTaskPath
export type CoreTaskFileVersion = NativeTaskFileVersion
export type CoreTaskOperation = NativeTaskOperation
export type CoreTaskOperationGroup = NativeTaskOperationGroup
export type CoreTaskMergeRequest = NativeTaskMergeRequest
export type CoreTaskMergePlan = NativeTaskMergePlan
export type CoreTaskConfilictSelection = NativeTaskConfilictSelection
export type CoreDataChangeEvent = NativeDataChangeEvent
export type CoreDataChangeMonitor = NativeDataChangeMonitor
export type CoreTaskModification = NativeTaskModification

export type CoreWebDavSyncEvent = NativeWebDavSyncEvent
export type CoreWebDavSyncMonitor = NativeWebDavSyncMonitor
export type CoreBridgeError = NativeCoreError
export type CoreNotification = NativeCoreNotification
export type CoreSyncConflictNotification = NativeSyncConflictNotification

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

  get id(): string {
    return this.native.id
  }

  get fullPath(): CoreTaskPath { return this.native.fullPath }

  get rootDirectory(): string {
    return this.native.rootDirectory
  }

  nativeRepo(): NativeRepo { return this.native }

  async file(path: string): Promise<CoreOrgFile> { return await this.native.file(path) }

  async loadFiles(ignoreFiles: string[] = []): Promise<CoreOrgFile[]> { return await this.native.loadFiles(ignoreFiles) }
  async fileMetadata(): Promise<CoreOrgFileMetadata[]> { return await this.native.fileMetadata() }

  async conflicts(): Promise<NativeConflictSync[]> { return await this.native.conflicts() }

  async load(): Promise<void> {
    await this.native.load()
  }

  async reset(): Promise<void> { await this.native.reset() }

  async history(): Promise<CoreSyncRecord[]> {
    // Core 提供执行结果、传输方向与冲突解决摘要，宿主不重算历史。
    return await this.native.history()
  }

  async lastEffectSync(): Promise<CoreSyncRecord | null> { return await this.native.lastEffectSync() }

  async historyFile(syncId: string, path: string, resolved: boolean): Promise<CoreOrgFile> {
    return await this.native.historyFile({ syncId, path, resolved })
  }

  async historyDetail(syncId: string): Promise<CoreSyncRecordDetail> {
    return await this.native.historyDetail(syncId)
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
  async setPreviewRoot(root: string): Promise<void> { await this.native.setPreviewRoot(root) }
  async createConflictPreview(request: CoreConflictPreviewRequest): Promise<CoreConflictPreview> { return await this.native.createConflictPreview(request) }
  async fileAt(path: CoreTaskPath): Promise<CoreOrgFile> { return await this.native.fileAt(path) }
  async refileTargets(query: CoreRefileTargetQuery = {}): Promise<CoreRefileTarget[]> { return await this.native.refileTargets(query) }
  async executeTaskOperations(group: CoreTaskOperationGroup): Promise<void> { await this.native.executeTaskOperations(group) }
  async taskMergeOperations(request: CoreTaskMergeRequest): Promise<CoreTaskMergePlan> { return await this.native.taskMergeOperations(request) }
  async notifications(): Promise<CoreNotification[]> { return await this.native.notifications() }
  async watchNotifications(monitor: CoreNotificationUpdateMonitor): Promise<void> { await this.native.watchNotifications(monitor) }
  stopWatchingNotifications(): void { this.native.stopWatchingNotifications() }
  async watchDataChanges(monitor: CoreDataChangeMonitor): Promise<number> { return await this.native.watchDataChanges(monitor) }
  stopWatchingDataChanges(subscriptionId: number): void { this.native.stopWatchingDataChanges(subscriptionId) }
  async reload(): Promise<void> { await this.native.reload() }

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

  async query(query: CoreTaskQuery): Promise<CoreTaskQueryResult> {
    return await this.native.query(query)
  }

}

let activeWorkspace: CoreWorkspace | undefined = undefined
let activeWorkspaceKey: string = ''
let activeTodoDefaults: string | undefined = undefined
let workspaceQueue: Promise<void> = Promise.resolve()

// 页面通过同一 workspace session 调用 core，不解释 org 内容或同步规则。
export class NativeCoreService {
  static async notifications(repositories: RepoConfig[], todoDefaults?: string): Promise<CoreNotification[]> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    return await workspace.notifications()
  }

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

  static async repositoryHistory(repositories: RepoConfig[], repository: RepoConfig, todoDefaults?: string): Promise<CoreSyncRecord[]> {
    const repo = await NativeCoreService.repository(repositories, repository, todoDefaults)
    return await repo.history()
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
    const request = workspaceQueue.then(async (): Promise<CoreWorkspace> => {
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
    })
    workspaceQueue = request.then((): void => {}, (): void => {})
    return await request
  }

  static async executeTaskOperations(repositories: RepoConfig[], group: CoreTaskOperationGroup, todoDefaults?: string): Promise<void> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    await workspace.executeTaskOperations(group)
  }

  static async loadWorkspace(repositories: RepoConfig[], todoDefaults?: string): Promise<CoreTask[]> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    await workspace.reload()
    return (await workspace.query({})).tasks
  }

  static async syncWorkspaceWebDav(
    repositories: RepoConfig[],
    monitor?: CoreWebDavSyncMonitor,
    todoDefaults?: string
  ): Promise<CoreTask[]> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults)
    const repos = await workspace.repos()
    for (const repo of repos) {
      const config = repositories.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (config?.webdavEnabled) {
        const policy = new CoreWebDavSyncPolicy(config.webdavUrl, config.webdavUsername, config.webdavPassword)
        const sync = await repo.sync(policy, monitor, { excludedDirectories: config.excludedDirectories })
        if (sync.result !== 'succeeded') {
          throw new Error('WebDAV 同步未完成，请重试')
        }
      } else {
        await repo.load()
      }
    }
    return (await workspace.query({})).tasks
  }

}
