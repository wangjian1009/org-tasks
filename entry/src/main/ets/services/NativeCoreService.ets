import {
  Repo as NativeRepo,
  ConflictPreview as NativeConflictPreview,
  ConflictPreviewRequest as NativeConflictPreviewRequest,
  ConflictPreviewChanges as NativeConflictPreviewChanges,
  ConflictPreviewProjection as NativeConflictPreviewProjection,
  ConflictPreviewChange as NativeConflictPreviewChange,
  ConflictPreviewDiffLine as NativeConflictPreviewDiffLine,
  ConflictTarget as NativeConflictTarget,
  FileConflict as NativeFileConflict,
  TaskPath as NativeTaskPath,
  TaskFileVersion as NativeTaskFileVersion,
  TaskFileNew as NativeTaskFileNew,
  TaskFileDeletion as NativeTaskFileDeletion,
  TaskFileRename as NativeTaskFileRename,
  TaskFileInitialTask as NativeTaskFileInitialTask,
  TaskOperation as NativeTaskOperation,
  TaskMovement as NativeTaskMovement,
  TaskTrash as NativeTaskTrash,
  TaskRestore as NativeTaskRestore,
  TaskOperationGroup as NativeTaskOperationGroup,
  TaskMergeRequest as NativeTaskMergeRequest,
  TaskMergePlan as NativeTaskMergePlan,
  TaskStructureEdit as NativeTaskStructureEdit,
  TaskStructureRequest as NativeTaskStructureRequest,
  TaskConfilictSelection as NativeTaskConfilictSelection,
  TaskModification as NativeTaskModification,
  TaskModificationOperation as NativeTaskModificationOperation,
  TaskChecklistItem as NativeTaskChecklistItem,
  TaskChecklistChange as NativeTaskChecklistChange,
  TaskPlanningTime as NativeTaskPlanningTime,
  TaskPlanningEdit as NativeTaskPlanningEdit,
  TaskPlanningInfo as NativeTaskPlanningInfo,
  TaskRepeatRule as NativeTaskRepeatRule,
  TaskRepeatInfo as NativeTaskRepeatInfo,
  TaskRepeatMode as NativeTaskRepeatMode,
  TaskRepeatUnit as NativeTaskRepeatUnit,
  SupportTags as NativeSupportTags,
  TodoMetadata as NativeTodoMetadata,
  defaultTodoSettings,
  defaultTaskStates,
  CoreSettings,
  TaskState,
  TaskStateCount,
  TaskPriority,
  PeriodCategory,
  ConflictSync as NativeConflictSync,
  RefileTarget as NativeRefileTarget,
  RefileTargetQuery as NativeRefileTargetQuery,
  OrgFileRef as NativeOrgFileRef,
  CoreError as NativeCoreError,
  NotificationUpdateMonitor as NativeNotificationUpdateMonitor,
  NotificationScope as NativeNotificationScope,
  RepositoryRootStatus as NativeRepositoryRootStatus,
  RepositoryRootMissingNotification as NativeRepositoryRootMissingNotification,
  DataChangeEvent as NativeDataChangeEvent,
  ExternalFileChanged as NativeExternalFileChanged,
  TaskDataChange as NativeTaskDataChange,
  DataChangeMonitor as NativeDataChangeMonitor,
  QuerySubscriptionStart as NativeQuerySubscriptionStart,
  QuerySubscriptionRequest as NativeQuerySubscriptionRequest,
  QuerySubscriptionStatus as NativeQuerySubscriptionStatus,
  HttpServerInfo as NativeHttpServerInfo,
  HttpUiHandler, HttpUiRequest, HttpUiResponse,
  SyncRequiredNotification as NativeSyncRequiredNotification,
  CoreNotification as NativeCoreNotification,
  NotificationChange as NativeNotificationChange,
  NotificationUpdate as NativeNotificationUpdate,
  SyncBaselineUnavailableNotification as NativeSyncBaselineUnavailableNotification,
  SyncConflictNotification as NativeSyncConflictNotification,
  OrgFile as NativeOrgFile,
  FileHeaderEntry as NativeFileHeaderEntry,
  FileHeaderValueChange as NativeFileHeaderValueChange,
  FileHeaderValue as NativeFileHeaderValue,
  DocumentSection as NativeDocumentSection,
  DocumentLinkTarget as NativeDocumentLinkTarget,
  ContentBlock as NativeContentBlock,
  ContentBlockChange as NativeContentBlockChange,
  ContentNode as NativeContentNode,
  ContentInline as NativeContentInline,
  ContentInlineStyle as NativeContentInlineStyle,
  OrgFileMetadata as NativeOrgFileMetadata,
  SyncRecord as NativeSyncRecord,
  SyncTriggerReason,
  RepoRemoteChange as NativeRepoRemoteChange,
  RepoSyncResult as NativeRepoSyncResult,
  SyncRecordDetail as NativeSyncRecordDetail,
  SyncFileRecord as NativeSyncFileRecord,
  SyncHistoryError as NativeSyncHistoryError,
  Task as NativeTask,
  TaskLog as NativeTaskLog,
  TitlePart as NativeTitlePart,
  TextLink as NativeTextLink,
  LinkValue as NativeLinkValue,
  TaskLinkChange as NativeTaskLinkChange,
  AddressLink as NativeAddressLink,
  AppLink as NativeAppLink,
  TitleCount as NativeTitleCount,
  QueryRepositoryBinding as NativeQueryRepositoryBinding,
  CoreQuery as NativeCoreQuery,
  CoreQueryResult as NativeCoreQueryResult,
  FileQuery as NativeFileQuery,
  TaskQuery as NativeTaskQuery,
  TaskQueryResult as NativeTaskQueryResult,
  WebDavSyncEvent as NativeWebDavSyncEvent,
  WebDavSyncMonitor as NativeWebDavSyncMonitor,
  WebDavSyncPolicy as NativeWebDavSyncPolicy,
  Workspace as NativeWorkspace
} from 'liborg_tasks_harmony.so'
import { RepoConfig } from '../models/OrgTask'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'

export type CoreConflictPreview = NativeConflictPreview
export type CoreConflictPreviewRequest = NativeConflictPreviewRequest
export type CoreConflictPreviewChanges = NativeConflictPreviewChanges
export type CoreConflictPreviewProjection = NativeConflictPreviewProjection
export type CoreConflictPreviewChange = NativeConflictPreviewChange
export type CoreConflictPreviewDiffLine = NativeConflictPreviewDiffLine
export type CoreConflictTarget = NativeConflictTarget
// 候选内容与展示锚点由 Core 提供；展示锚点不等同于提交目标。
export type CoreFileConflict = NativeFileConflict
// project() 与 renderDocumentHtml() 均读取 Native OrgFile 的同版本 Core 快照。
export type CoreOrgFile = NativeOrgFile
export type CoreDocumentLinkTarget = NativeDocumentLinkTarget
export type CoreDocumentSection = NativeDocumentSection
// paragraph 与 blankLinesBefore 来自 Core 语法树投影，宿主仅选择阅读间距。
export type CoreContentBlock = NativeContentBlock
export type CoreContentBlockChange = NativeContentBlockChange
export type CoreContentNode = NativeContentNode
export type CoreContentInline = NativeContentInline
export type CoreContentInlineStyle = NativeContentInlineStyle
// 文件 category 与 projectName 来自同一 Core 快照，供导航展示分区。
export type CoreOrgFileMetadata = NativeOrgFileMetadata
export type CoreFileHeaderEntry = NativeFileHeaderEntry
export type CoreFileHeaderValueChange = NativeFileHeaderValueChange
export type CoreFileHeaderValue = NativeFileHeaderValue

// 逻辑身份、state、category、hasList、hasText、isRepeating、isHabit 与 properties 均由 Core 投影，宿主不解析 Org 或重新计算。
export type CoreTaskChecklistItem = NativeTaskChecklistItem
// editContent.noteRequiredStates 由 Core 计算；Modification.note 与独立 Note 通过统一批次原样透传。
// insertAfter 与 move 透传条目 ID，由 Core 按版本验证插入位置与同级排序。
export type CoreTaskChecklistChange = NativeTaskChecklistChange
export type CoreTaskPlanningTime = NativeTaskPlanningTime
export type CoreTaskPlanningEdit = NativeTaskPlanningEdit
export type CoreTaskPlanningInfo = NativeTaskPlanningInfo
export type CoreTaskRepeatRule = NativeTaskRepeatRule
export type CoreTaskRepeatInfo = NativeTaskRepeatInfo
export type CoreTaskRepeatMode = NativeTaskRepeatMode
export type CoreTaskRepeatUnit = NativeTaskRepeatUnit
export type CoreSupportTags = NativeSupportTags
// hasAttach 等只读标记由 Core 在过滤展示标签前计算，宿主不从 tags 反推。
export type CoreTask = NativeTask
export type CoreTaskLog = NativeTaskLog
// createdAt 与 closedAt 由 Core 按本地时区解析，日志簿不从正文推算事件时间。
export type CoreTitlePart = NativeTitlePart
export type CoreTextLink = NativeTextLink
export type CoreLinkValue = NativeLinkValue
export type CoreTaskLinkChange = NativeTaskLinkChange
export type CoreAddressLink = NativeAddressLink
export type CoreAppLink = NativeAppLink
export type CoreTitleCount = NativeTitleCount
export type CoreQueryRepositoryBinding = NativeQueryRepositoryBinding
export type CoreQuery = NativeCoreQuery
export type CoreQueryResult = NativeCoreQueryResult
export type CoreFileQuery = NativeFileQuery
export type CoreTaskQuery = NativeTaskQuery
// fullFiles 只随单次查询或订阅初始结果返回，由调用方消费。
export type CoreTaskQueryResult = NativeTaskQueryResult

// 历史可选字段和读取诊断原样传递，由展示层区分未知与零值。
export type CoreSyncRecord = NativeSyncRecord
export type CoreSyncRecordDetail = NativeSyncRecordDetail
export type CoreNotificationUpdateMonitor = NativeNotificationUpdateMonitor
export type CoreSyncRequiredNotification = NativeSyncRequiredNotification
export type CoreSyncFileRecord = NativeSyncFileRecord
export type CoreSyncHistoryError = NativeSyncHistoryError

export type CoreTaskState = TaskState
export type CoreTaskStateCount = TaskStateCount
export type CoreTaskPriority = TaskPriority
export type CorePeriodCategory = PeriodCategory
export type CoreSettingsObject = CoreSettings
export type CoreTodoMetadata = NativeTodoMetadata

export interface CoreConflict { repoId: string; syncId: string; paths: string[] }

export type CoreOrgFileRef = NativeOrgFileRef
export type CoreRefileTargetQuery = NativeRefileTargetQuery
// 目标元信息直接使用 Core 快照，包含用于平级项目分类的 projectName。
// 目标 titleParts 来自 Core，保持不含进度的展示投影与原始 fullPath 分离。
export type CoreRefileTarget = NativeRefileTarget
export type CoreTaskPath = NativeTaskPath
export type CoreTaskFileVersion = NativeTaskFileVersion
export type CoreTaskFileNew = NativeTaskFileNew
export type CoreTaskFileDeletion = NativeTaskFileDeletion
export type CoreTaskFileRename = NativeTaskFileRename
export type CoreTaskFileInitialTask = NativeTaskFileInitialTask
export type CoreTaskTrash = NativeTaskTrash
export type CoreTaskRestore = NativeTaskRestore
export type CoreTaskOperation = NativeTaskOperation
export type CoreTaskMovement = NativeTaskMovement
export type CoreTaskOperationGroup = NativeTaskOperationGroup
export type CoreTaskMergeRequest = NativeTaskMergeRequest
export type CoreTaskMergePlan = NativeTaskMergePlan
export type CoreTaskStructureEdit = NativeTaskStructureEdit
export type CoreTaskStructureRequest = NativeTaskStructureRequest
export type CoreTaskConfilictSelection = NativeTaskConfilictSelection
export type CoreTaskDataChange = NativeTaskDataChange
export type CoreExternalFileChanged = NativeExternalFileChanged
export type CoreDataChangeEvent = NativeDataChangeEvent
export type CoreDataChangeMonitor = NativeDataChangeMonitor
export type CoreQuerySubscriptionRequest = NativeQuerySubscriptionRequest
export type CoreQuerySubscriptionStart = NativeQuerySubscriptionStart
export type CoreQuerySubscriptionStatus = NativeQuerySubscriptionStatus
export type CoreHttpUiHandler = HttpUiHandler
export type CoreHttpUiRequest = HttpUiRequest
export type CoreHttpUiResponse = HttpUiResponse
export type CoreHttpServerInfo = NativeHttpServerInfo
export type CoreTaskModificationOperation = NativeTaskModificationOperation
export type CoreTaskModification = NativeTaskModification

export type CoreWebDavSyncEvent = NativeWebDavSyncEvent
export type CoreWebDavSyncMonitor = NativeWebDavSyncMonitor
export type CoreRepoRemoteChange = NativeRepoRemoteChange
export type CoreRepoSyncResult = NativeRepoSyncResult
export type CoreBridgeError = NativeCoreError
export type CoreNotificationUpdate = NativeNotificationUpdate
export type CoreNotificationChange = NativeNotificationChange
export type CoreNotificationScope = NativeNotificationScope
export type CoreRepositoryRootStatus = NativeRepositoryRootStatus
export type CoreRepositoryRootMissingNotification = NativeRepositoryRootMissingNotification
export type CoreSyncBaselineUnavailableNotification = NativeSyncBaselineUnavailableNotification
export type CoreNotification = NativeCoreNotification
export type CoreSyncConflictNotification = NativeSyncConflictNotification

export function coreErrorMessage(error: CoreBridgeError): string {
  if (typeof error.message === 'string' && error.message.length > 0) {
    return error.message
  }
  return '操作未完成，请重试'
}

export type RepositorySyncSource = 'repositoryCreated' | 'repositoryReset'
export type SyncRequestSource = 'startup' | 'background' | 'manual' | RepositorySyncSource

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


}

export class CoreWorkspace {
  async setSyncPolicy(repoId: string, policy: CoreWebDavSyncPolicy, excludedDirectories: string[], monitor?: CoreWebDavSyncMonitor): Promise<void> {
    await this.native.setSyncPolicy(repoId, policy.nativePolicy(), excludedDirectories, monitor)
  }
  async removeSyncPolicy(repoId: string): Promise<void> { await this.native.removeSyncPolicy(repoId) }
  async checkRemoteChanges(): Promise<CoreRepoRemoteChange[]> { return await this.native.checkRemoteChanges() }
  async syncRepos(repoIds: string[], triggerReason: SyncTriggerReason, trashFile?: CoreOrgFileRef): Promise<CoreRepoSyncResult[]> {
    return await this.native.syncRepos(repoIds, triggerReason, trashFile)
  }

  private readonly native: NativeWorkspace

  constructor(native: NativeWorkspace) {
    this.native = native
  }

  async startHttpServer(port: number = 8787, handler?: CoreHttpUiHandler): Promise<CoreHttpServerInfo> { return await this.native.startHttpServer(port, handler) }
  async stopHttpServer(): Promise<void> { await this.native.stopHttpServer() }
  async httpServerStatus(): Promise<CoreHttpServerInfo | null> { return await this.native.httpServerStatus() }
  async setTodoDefaults(settings: string): Promise<void> { await this.native.setTodoDefaults(settings) }
  async getSettings(): Promise<CoreSettings> { return await this.native.getSettings() }
  async setSettings(settings: CoreSettings): Promise<void> { await this.native.setSettings(settings) }
  async setPreviewRoot(root: string): Promise<void> { await this.native.setPreviewRoot(root) }
  async createConflictPreview(request: CoreConflictPreviewRequest): Promise<CoreConflictPreview> { return await this.native.createConflictPreview(request) }
  async fileAt(path: CoreTaskPath): Promise<CoreOrgFile> { return await this.native.fileAt(path) }
  // 具名文件根节点与项目根节点使用同一个 Core 查询快照。
  async refileTargets(query: CoreRefileTargetQuery = {}): Promise<CoreRefileTarget[]> { return await this.native.refileTargets(query) }
  // 命令由 Core 统一调度；不同文件可并发，同文件在事件确认后衔接。
  async executeTaskOperations(group: CoreTaskOperationGroup): Promise<void> { await this.native.executeTaskOperations(group) }
  async taskMergeOperations(request: CoreTaskMergeRequest): Promise<CoreTaskMergePlan> { return await this.native.taskMergeOperations(request) }
  async taskStructureOperations(request: CoreTaskStructureRequest): Promise<CoreTaskOperationGroup> {
    return await this.native.taskStructureOperations(request)
  }
  async watchNotifications(monitor: CoreNotificationUpdateMonitor, scope?: string[] | CoreNotificationScope): Promise<void> {
    if (scope === undefined) await this.native.watchNotifications(monitor)
    else await this.native.watchNotifications(monitor, scope)
  }
  stopWatchingNotifications(): void { this.native.stopWatchingNotifications() }
  async watchExternalFileChanges(monitor: (event: CoreExternalFileChanged) => void): Promise<number> { return await this.native.watchExternalFileChanges(monitor) }
  stopWatchingExternalFileChanges(subscriptionId: number): void { this.native.stopWatchingExternalFileChanges(subscriptionId) }
  async watchDataChanges(monitor: CoreDataChangeMonitor): Promise<number> { return await this.native.watchDataChanges(monitor) }
  stopWatchingDataChanges(subscriptionId: number): void { this.native.stopWatchingDataChanges(subscriptionId) }
  async subscribeQuery(requests: CoreQuerySubscriptionRequest[]): Promise<CoreQuerySubscriptionStart[]> {
    return await this.native.subscribeQuery(requests)
  }
  async querySubscriptionStatus(id: number): Promise<CoreQuerySubscriptionStatus> { return await this.native.querySubscriptionStatus(id) }
  unsubscribeQuery(id: number): void { this.native.unsubscribeQuery(id) }

  async repos(): Promise<CoreRepo[]> {
    const repos = await this.native.repos()
    return repos.map((repo: NativeRepo) => new CoreRepo(repo))
  }

  async addRepo(rootDirectory: string): Promise<CoreRepo> {
    return new CoreRepo(await this.native.addRepo(rootDirectory))
  }

  async configureRepositoryRoots(roots: string[]): Promise<CoreRepositoryRootStatus[]> {
    return await this.native.configureRepositoryRoots(roots)
  }

  async validateRepository(rootDirectory: string): Promise<void> {
    await this.native.validateRepository(rootDirectory)
  }

  async removeRepo(rootDirectory: string): Promise<void> {
    await this.native.removeRepo(rootDirectory)
  }

  async query(queries: CoreQuery[], repositoryBindings: CoreQueryRepositoryBinding[] = []): Promise<CoreQueryResult[]> {
    // 透传任务与文件查询的仓库范围。
    return await this.native.query(queries, repositoryBindings)
  }

}

let activeWorkspace: CoreWorkspace | undefined = undefined
let activeRepositoryRoots: string[] = []
let pendingRepositoryRoots: boolean = false
let activeTodoDefaults: string | undefined = undefined
let activeCoreSettings: string = ''
let workspaceQueue: Promise<void> = Promise.resolve()

// 页面通过同一 workspace session 调用 core，不解释 org 内容或同步规则。
export class NativeCoreService {
  static start(): CoreWorkspace {
    if (!activeWorkspace) activeWorkspace = new CoreWorkspace(new NativeWorkspace())
    return activeWorkspace
  }

  static defaultTaskStates(): Promise<CoreTaskState[]> { return defaultTaskStates() }

  static async query(repositories: RepoConfig[], queries: CoreQuery[], todoDefaults?: string, coreSettings?: CoreSettings): Promise<CoreQueryResult[]> {
    if (queries.length === 0) return []
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults, coreSettings)
    return await workspace.query(queries)
  }
  static async repository(repositories: RepoConfig[], repository: RepoConfig, todoDefaults?: string, coreSettings?: CoreSettings): Promise<CoreRepo> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults, coreSettings)
    const repos = await workspace.repos()
    const repo = repos.find((item: CoreRepo) => item.rootDirectory === repository.rootDirectory)
    if (!repo) throw new Error('目标仓库不可用')
    return repo
  }

  static async repositoryHistory(repositories: RepoConfig[], repository: RepoConfig, todoDefaults?: string, coreSettings?: CoreSettings): Promise<CoreSyncRecord[]> {
    const repo = await NativeCoreService.repository(repositories, repository, todoDefaults, coreSettings)
    return await repo.history()
  }

  static async conflicts(repositories: RepoConfig[], todoDefaults?: string, coreSettings?: CoreSettings): Promise<CoreConflict[]> {
    const result: CoreConflict[] = []
    for (const repository of repositories) {
      if (!repository.webdavEnabled) continue
      const repo = await NativeCoreService.repository(repositories, repository, todoDefaults, coreSettings)
      const conflicts = await repo.conflicts()
      for (const conflict of conflicts) result.push({ repoId: repository.id, syncId: conflict.syncId, paths: conflict.paths })
    }
    return result
  }

  static async validateRepository(rootDirectory: string): Promise<void> {
    await NativeCoreService.start().validateRepository(rootDirectory)
  }

  static async workspaceFor(repositories: RepoConfig[], todoDefaults?: string, coreSettings?: CoreSettings): Promise<CoreWorkspace> {
    const request = workspaceQueue.then(async (): Promise<CoreWorkspace> => {
      const settings = todoDefaults ?? await defaultTodoSettings()
      const encodedCoreSettings = JSON.stringify(coreSettings ?? { additionStates: [] } as CoreSettings)
      const workspace = NativeCoreService.start()
      if (activeTodoDefaults !== settings) {
        await workspace.setTodoDefaults(settings)
        activeTodoDefaults = settings
      }
      if (activeCoreSettings !== encodedCoreSettings) {
        await workspace.setSettings(coreSettings ?? { additionStates: [] })
        activeCoreSettings = encodedCoreSettings
      }
      const requestedRoots = repositories.map((repository: RepoConfig) => repository.rootDirectory)
      if (pendingRepositoryRoots || requestedRoots.length !== activeRepositoryRoots.length ||
        requestedRoots.some((root: string, index: number): boolean => root !== activeRepositoryRoots[index])) {
        const statuses = await workspace.configureRepositoryRoots(requestedRoots)
        activeRepositoryRoots = requestedRoots
        pendingRepositoryRoots = statuses.some(status => status.repoId === null)
      }
      return workspace
    })
    workspaceQueue = request.then((): void => {}, (): void => {})
    return await request
  }

  static async executeTaskOperations(repositories: RepoConfig[], group: CoreTaskOperationGroup, todoDefaults?: string, coreSettings?: CoreSettings): Promise<void> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults, coreSettings)
    await workspace.executeTaskOperations(group)
  }

  static async syncWorkspaceWebDav(
    repositories: RepoConfig[],
    monitor?: CoreWebDavSyncMonitor,
    todoDefaults?: string,
    coreSettings?: CoreSettings,
    source: SyncRequestSource = 'manual',
    repositoryId?: string
  ): Promise<void> {
    const workspace = await NativeCoreService.workspaceFor(repositories, todoDefaults, coreSettings)
    const repos = await workspace.repos()
    const enabledIds: string[] = []
    for (const repo of repos) {
      const config = repositories.find((item: RepoConfig) => item.rootDirectory === repo.rootDirectory)
      if (repositoryId && config?.id !== repositoryId) continue
      if (config?.webdavEnabled) {
        const policy = new CoreWebDavSyncPolicy(config.webdavUrl, config.webdavUsername, config.webdavPassword)
        await workspace.setSyncPolicy(repo.id, policy, config.excludedDirectories, monitor)
        enabledIds.push(repo.id)
      }
    }
    if (repositoryId && enabledIds.length === 0) throw new Error('目标仓库不存在或未启用 WebDAV')
    let selectedIds: string[] = enabledIds
    let failure = ''
    if (source === 'startup') {
      const checks = await workspace.checkRemoteChanges()
      selectedIds = []
      for (const id of enabledIds) {
        const check = checks.find((item: CoreRepoRemoteChange) => item.repoId === id)
        if (!check) { failure = failure || '仓库远端检查结果缺失'; continue }
        if (check.error) { failure = failure || coreErrorMessage(check.error); continue }
        if (check.state !== 'unchanged') selectedIds.push(id)
      }
    }
    if (selectedIds.length > 0) {
      const reason: SyncTriggerReason = source === 'startup' ? 'remoteChanged'
        : source === 'background' ? 'localChanged' : source
      const system = repositories.find((item: RepoConfig): boolean => item.id === SYSTEM_REPOSITORY_ID)
      const trashRepo = repos.find(repo => repo.rootDirectory === system?.rootDirectory)
      if (system && !trashRepo) throw new Error('系统仓库不可用，无法保护首次同步的本地任务')
      const trashFile: CoreOrgFileRef | undefined = trashRepo ? { repoId: trashRepo.id, path: TRASH_FILE } : undefined
      const results = await workspace.syncRepos(selectedIds, reason, trashFile)
      for (const result of results) {
        if (result.error) failure = failure || coreErrorMessage(result.error)
        else if (!result.record || result.record.result !== 'succeeded') {
          failure = failure || result.record?.errorMessage || 'WebDAV 同步未完成，请重试'
        }
      }
    }
    if (failure.length > 0) throw new Error(failure)
  }

}

export function taskResult(result: CoreQueryResult): CoreTaskQueryResult {
  if (result.type !== 'task') throw new Error('查询结果不是任务结果')
  return result.result
}
export function fileResult(result: CoreQueryResult): CoreOrgFileMetadata[] {
  if (result.type !== 'file') throw new Error('查询结果不是文件结果')
  return result.result
}
