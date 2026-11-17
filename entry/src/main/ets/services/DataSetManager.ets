import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreOrgFile, CoreQuerySubscriptionRequest, CoreQuerySubscriptionStart, CoreOrgFileMetadata, CoreSettingsObject, CoreWorkspace, NativeCoreService } from './NativeCoreService'
import { PageDataCache } from './PageDataCache'
import { cacheDataSet, restoreDataSet } from './PageDataSnapshot'
import { DataSet, DataSetDefinition, DataSetDefinitionFactory, UserOperationQueue, DataSetClock, DataSetQuery } from './DataSet'

export { DataSet, DataSetDefinition, DataSetDefinitionFactory, DataSetQuery, DataSetEvent, TaskDataChange, DataSetWriteError } from './DataSet'

export interface DataManagerOptions { cache?: boolean }
export interface DataLoadResult { name: string; fullFiles: CoreOrgFile[] }

interface DataSetCacheRepository { id: string; rootDirectory: string; excludedDirectories: string[] }
interface DataSetCacheScope { repositories: DataSetCacheRepository[]; todoDefaults: string; coreSettings: CoreSettingsObject; names: string[] }

interface PendingSubscription {
  name: string
  identity: string
  generation: number
  request: CoreQuerySubscriptionRequest
  activate: () => void
  resolve: (result: CoreQuerySubscriptionStart) => void
  reject: (error: Error) => void
}

// 管理命名数据集、批量订阅句柄及页面缓存；各 DataSet 独立处理自己的结果与变化事件。
export class DataSetManager {
  private static active: Set<DataSetManager> = new Set()
  private readonly context: Context
  private readonly pageName: string
  private readonly source: DataSetDefinition[] | DataSetDefinitionFactory
  private readonly sets: Map<string, DataSet> = new Map()
  private readonly queryRequests: Map<string, number> = new Map()
  private readonly overrides: Map<string, DataSetQuery> = new Map()
  private readonly stops: Map<string, () => void> = new Map()
  private readonly subscriptions: Map<string, number> = new Map()
  private readonly subscriptionRequests: Map<string, CoreQuerySubscriptionRequest> = new Map()
  private pendingSubscriptions: PendingSubscription[] = []
  private subscribeTimer: number = -1
  private cache: PageDataCache | undefined = undefined
  private running: Promise<DataLoadResult[]> | undefined = undefined
  private readonly cacheEnabled: boolean
  private initialFilesDelivered: boolean = false
  private captureFiles: ((result: DataLoadResult) => void) | undefined = undefined
  private initialized: boolean = false
  private closed: boolean = false
  private closing: boolean = false
  private generation: number = 0
  private saveTimer: number = -1
  private savedRevision: string = ''
  private scope: string = ''
  private config: AppConfig | undefined = undefined
  private workspace: CoreWorkspace | undefined = undefined
  private definitions: DataSetDefinition[] = []
  private phase: number = 1
  private clock: DataSetClock = {
    subscribe: (name: string, request: CoreQuerySubscriptionRequest, activate: () => void): Promise<CoreQuerySubscriptionStart> => this.queueSubscription(name, request, activate),
    unsubscribe: (name: string): void => this.stopSubscription(name),
    status: async (name: string) => {
      const id = this.subscriptions.get(name)
      return id === undefined ? 'closed' : await this.workspace!.querySubscriptionStatus(id)
    },
    owner: util.generateRandomUUID(), next: (): number => ++this.phase, metadata: (repoId: string, path: string): CoreOrgFileMetadata | undefined => {
    for (const dataSet of this.sets.values()) if (dataSet.data?.type === 'file') {
      const metadata = dataSet.data.result.find(file => file.repoId === repoId && file.path === path)
      if (metadata) return metadata
    }
    return undefined
  } }
  private stopIdle: () => void
  private configChanged = (): void => {
    if (this.closed || this.closing) return
    this.generation++; this.initialized = false; this.running = undefined
    for (const name of this.sets.keys()) this.queryRequests.set(name, (this.queryRequests.get(name) ?? 0) + 1)
    for (const dataSet of this.sets.values()) dataSet.invalidate()
    this.start().catch((error: Error): void => { for (const dataSet of this.sets.values()) dataSet.reportError(error) })
  }
  static create(context: Context, pageName: string, definitions: DataSetDefinition[] | DataSetDefinitionFactory, options: DataManagerOptions = {}): DataSetManager {
    return new DataSetManager(context, pageName, definitions, options)
  }
  private constructor(context: Context, pageName: string, source: DataSetDefinition[] | DataSetDefinitionFactory, options: DataManagerOptions) {
    this.cacheEnabled = options.cache !== false
    this.context = context; this.pageName = pageName; this.source = typeof source === 'function' ? source : JSON.parse(JSON.stringify(source)) as DataSetDefinition[]
    if (typeof source !== 'function') {
      this.validate(source)
      for (const definition of source) this.dataSet(definition.name)
    }
    this.stopIdle = UserOperationQueue.watchIdle((): void => this.scheduleSave())
    AppConfigService.watchChanges(this.configChanged)
    DataSetManager.active.add(this)
  }
  private validate(definitions: DataSetDefinition[]): void {
    if ((!definitions.length && !this.sets.size) || new Set(definitions.map(item => item.name)).size !== definitions.length ||
      definitions.some(item => !item.name || !item.query || (item.query.type !== 'task' && item.query.type !== 'file'))) throw new Error('页面数据集定义无效')
  }
  dataSet(name: string): DataSet {
    let dataSet = this.sets.get(name)
    if (!dataSet) {
      if (this.initialized) throw new Error(`未定义数据集：${name}`)
      dataSet = new DataSet(this.context, name, this.clock)
      dataSet.bindQueryChange(async (query: DataSetQuery): Promise<void> => {
        await this.start()
        if (this.closed || this.closing) return
        const request = (this.queryRequests.get(name) ?? 0) + 1
        this.queryRequests.set(name, request)
        this.overrides.set(name, query)
        const definition: DataSetDefinition = { name, query, repositoryBindings: dataSet!.repositoryBindings }
        this.definitions = this.definitions.filter(item => item.name !== name).concat(definition)
        this.resetCache()
        await dataSet!.configure(this.config!, this.workspace!, definition)
        if (request !== this.queryRequests.get(name) || this.closed || this.closing) return
        const cache = this.cache
        const cached = await cache?.read().catch((): undefined => undefined)
        if (request !== this.queryRequests.get(name) || this.closed || this.closing) return
        const restored = cached?.find(item => item.name === name)
        if (restored?.queryKey === this.queryKey(dataSet!)) dataSet!.restore(restoreDataSet(restored))
        try { await dataSet!.start() }
        catch (error) { if (request === this.queryRequests.get(name) && !this.closed && !this.closing) throw error as Error }
        this.scheduleSave()
      })
      this.sets.set(name, dataSet)
      this.stops.set(name, dataSet.subscribe((): void => {
        if (this.workspace && !this.closed && Array.from(this.sets.values()).every(item => item.isReady())) this.initialized = true
        this.scheduleSave()
      }))
    }
    return dataSet
  }
  start(): Promise<DataLoadResult[]> {
    if (this.closed || this.closing) return Promise.reject(new Error('数据集管理器已关闭'))
    if (this.initialized) return Promise.resolve([])
    if (this.running) return this.running
    const generation = this.generation
    const running = this.initialize(generation).finally((): void => { if (this.running === running) this.running = undefined })
    this.running = running
    return running
  }
  private async initialize(generation: number): Promise<DataLoadResult[]> {
    const config = await AppConfigService.load(this.context, false)
    const workspace = NativeCoreService.start()
    const definitions = typeof this.source === 'function' ? this.source(config) : this.source
    this.validate(definitions)
    if (this.closed || this.closing || generation !== this.generation) return []
    const resolved = definitions.map((definition): DataSetDefinition => this.overrides.has(definition.name)
      ? { name: definition.name, query: this.overrides.get(definition.name)!, repositoryBindings: definition.repositoryBindings } : definition)
    for (const definition of resolved) this.dataSet(definition.name)
    this.config = config; this.workspace = workspace; this.definitions = resolved
    this.resetCache()
    const names = Array.from(this.sets.keys())
    const scope = this.scope
    for (const entry of this.sets.entries()) {
      const name = entry[0], dataSet = entry[1]
      await dataSet.configure(config, workspace, resolved.find(definition => definition.name === name))
      if (this.closed || generation !== this.generation) return []
    }
    try {
      const cached = await this.cache?.read()
      if (this.closed || this.closing || generation !== this.generation) return []
      if (cached && cached.length === names.length && cached.every(item => names.includes(item.name))) {
        for (const item of cached) {
          const dataSet = this.sets.get(item.name)!
          if (item.queryKey === this.queryKey(dataSet)) dataSet.restore(restoreDataSet(item))
        }
      }
    } catch (_) { /* 缓存不可用时仍由每个数据集执行首次查询。 */ }
    if (this.closed || generation !== this.generation) return []
    await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    if (this.closed || generation !== this.generation) return []
    const loaded: DataLoadResult[] = []
    const capture = !this.initialFilesDelivered ? (result: DataLoadResult): void => { loaded.push(result) } : undefined
    this.captureFiles = capture
    try {
      await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.start()))
      if (this.closed || generation !== this.generation || scope !== this.scope) return []
      this.initialFilesDelivered = true
      this.initialized = true; this.savedRevision = ''; this.scheduleSave()
      return loaded
    } finally {
      if (this.captureFiles === capture) this.captureFiles = undefined
    }
  }
  private stopSubscription(name: string): void {
    const id = this.subscriptions.get(name)
    this.subscriptions.delete(name); this.subscriptionRequests.delete(name)
    if (id !== undefined) this.workspace?.unsubscribeQuery(id)
  }
  private queueSubscription(name: string, request: CoreQuerySubscriptionRequest, activate: () => void): Promise<CoreQuerySubscriptionStart> {
    this.subscriptionRequests.set(name, request)
    const work = new Promise<CoreQuerySubscriptionStart>((resolve, reject): void => {
      this.pendingSubscriptions.push({ name, identity: this.sets.get(name)!.identity, generation: this.generation, request, activate, resolve, reject })
    })
    if (this.subscribeTimer < 0) this.subscribeTimer = setTimeout((): void => {
      this.subscribeTimer = -1
      this.submitSubscriptions()
    }, 0)
    return work
  }
  private currentSubscription(entry: PendingSubscription): boolean {
    return !this.closed && entry.generation === this.generation && this.sets.get(entry.name)?.identity === entry.identity &&
      this.subscriptionRequests.get(entry.name) === entry.request
  }
  private submitSubscriptions(): void {
    const entries = this.pendingSubscriptions
    this.pendingSubscriptions = []
    const workspace = this.workspace!
    const keys = entries.flatMap(entry => [...(this.sets.get(entry.name)?.scopeFiles() ?? []), JSON.stringify(['$dataset', entry.identity, entry.name])])
    const execute = async (): Promise<void> => {
      const active = entries.filter(entry => this.currentSubscription(entry))
      for (const entry of entries) if (!active.includes(entry)) entry.reject(new Error('数据集查询已变化'))
      if (!active.length) return
      try {
        for (const entry of active) {
          this.stopSubscription(entry.name)
          this.subscriptionRequests.set(entry.name, entry.request)
          entry.activate()
        }
        const capture = this.captureFiles
        const results = await workspace.subscribeQuery(active.map(entry => {
          const request = JSON.parse(JSON.stringify({ query: entry.request.query, operationId: entry.request.operationId,
            repositoryBindings: entry.request.repositoryBindings })) as CoreQuerySubscriptionRequest
          request.callback = entry.request.callback
          if (request.query.type === 'task') request.query.query.fullFiles = capture ? request.query.query.fullFiles : []
          return request
        }))
        if (results.length !== active.length) {
          for (const result of results) workspace.unsubscribeQuery(result.subscriptionId)
          throw new Error('批量订阅结果数量不一致')
        }
        for (let index = 0; index < active.length; index++) {
          const entry = active[index], result = results[index]
          if (!this.currentSubscription(entry)) {
            workspace.unsubscribeQuery(result.subscriptionId)
            entry.reject(new Error('数据集查询已变化'))
          } else {
            this.subscriptions.set(entry.name, result.subscriptionId)
            if (result.data.type === 'task') {
              const files = result.data.result.fullFiles ?? []
              if (capture && files.length) capture({ name: entry.name, fullFiles: files })
              result.data.result.fullFiles = []
            }
            entry.resolve(result)
          }
        }
      } catch (error) { for (const entry of active) entry.reject(error as Error) }
    }
    const work = entries.some(entry => this.sets.get(entry.name)?.isReady()) ? UserOperationQueue.submit(execute, keys) : execute()
    work.catch((error: Error): void => { for (const entry of entries) entry.reject(error) })
  }
  private resetCache(): void {
    const config = this.config!, names = Array.from(this.sets.keys())
    const identity: DataSetCacheScope = { repositories: config.repos.map((repo): DataSetCacheRepository =>
      ({ id: repo.id, rootDirectory: repo.rootDirectory, excludedDirectories: repo.excludedDirectories ?? [] })),
      todoDefaults: config.todoDefaults, coreSettings: config.coreSettings, names }
    this.scope = JSON.stringify(identity)
    this.cache = this.cacheEnabled ? new PageDataCache(this.context, this.pageName, this.scope) : undefined
    this.savedRevision = ''
  }
  private queryKey(dataSet: DataSet): string {
    return dataSet.repositoryBindings.length > 0
      ? JSON.stringify({ query: dataSet.query, repositoryBindings: dataSet.repositoryBindings })
      : JSON.stringify(dataSet.query) ?? ''
  }
  hasValidScope(): boolean { return !this.closed && !this.closing }
  isReady(): boolean { return this.initialized && Array.from(this.sets.values()).every(dataSet => dataSet.isReady()) }
  async refresh(): Promise<void> { await this.start(); await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.refresh())) }
  private revision(): string { return JSON.stringify(Array.from(this.sets.values()).map(dataSet => [dataSet.version, dataSet.revision])) }
  private scheduleSave(): void {
    if (!this.cache || !this.initialized || this.closed || this.closing || this.saveTimer >= 0 || !UserOperationQueue.isIdle() || this.revision() === this.savedRevision) return
    this.saveTimer = setTimeout((): void => { this.saveTimer = -1; this.flush().catch((error: Error): void => { for (const dataSet of this.sets.values()) dataSet.reportError(error) }) }, 250)
  }
  async flush(): Promise<void> {
    clearTimeout(this.saveTimer); this.saveTimer = -1
    const generation = this.generation, cache = this.cache
    await UserOperationQueue.whenIdle()
    await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.settle()))
    if (!cache || !this.initialized || generation !== this.generation || cache !== this.cache || Array.from(this.sets.values()).some(dataSet => !dataSet.getConfirmed(dataSet.name))) return
    const revision = this.revision()
    const data = Array.from(this.sets.entries()).map(entry => {
      const name = entry[0], dataSet = entry[1]
      const cached = cacheDataSet(name, dataSet.getConfirmed(name)!.data); cached.version = dataSet.version; cached.queryKey = this.queryKey(dataSet); return cached
    })
    const result = await this.cache.write(data, (): boolean => UserOperationQueue.isIdle() && generation === this.generation && revision === this.revision())
    if (result === 'deferred') return await this.flush()
    this.savedRevision = revision
  }
  static async flushAll(): Promise<void> { await Promise.all(Array.from(DataSetManager.active).map(manager => manager.flush())) }
  async close(): Promise<void> {
    if (this.closed) return
    this.closing = true
    try {
      if (this.running) await this.running.catch((): void => {})
      await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.settle()))
      await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.close()))
      await this.flush()
    } finally {
      this.closed = true; this.captureFiles = undefined; clearTimeout(this.saveTimer)
      for (const name of Array.from(this.subscriptions.keys())) this.stopSubscription(name)
      for (const stop of this.stops.values()) stop()
      this.stopIdle(); AppConfigService.stopWatchingChanges(this.configChanged); DataSetManager.active.delete(this)
    }
  }
}
