import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { CoreOrgFileMetadata, CoreSettingsObject, CoreWorkspace, NativeCoreService } from './NativeCoreService'
import { PageDataCache } from './PageDataCache'
import { cacheDataSet, restoreDataSet } from './PageDataSnapshot'
import { DataSet, DataSetDefinition, DataSetDefinitionFactory, UserOperationQueue, DataSetClock, DataSetQuery } from './DataSet'

export { DataSet, DataSetDefinition, DataSetDefinitionFactory, DataSetQuery, DataSetEvent, TaskDataChange, DataSetWriteError } from './DataSet'

interface DataSetCacheRepository { id: string; rootDirectory: string; excludedDirectories: string[] }
interface DataSetCacheScope { repositories: DataSetCacheRepository[]; todoDefaults: string; coreSettings: CoreSettingsObject; names: string[] }

// 管理命名数据集及页面缓存；查询、原始订阅和变化事件均归各个 DataSet。
export class DataSetManager {
  private static active: Set<DataSetManager> = new Set()
  private readonly context: Context
  private readonly pageName: string
  private readonly source: DataSetDefinition[] | DataSetDefinitionFactory
  private readonly sets: Map<string, DataSet> = new Map()
  private readonly queryRequests: Map<string, number> = new Map()
  private readonly overrides: Map<string, DataSetQuery> = new Map()
  private readonly stops: Map<string, () => void> = new Map()
  private cache: PageDataCache | undefined = undefined
  private running: Promise<void> | undefined = undefined
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
  private clock: DataSetClock = { owner: util.generateRandomUUID(), next: (): number => ++this.phase, metadata: (repoId: string, path: string): CoreOrgFileMetadata | undefined => {
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
  static create(context: Context, pageName: string, definitions: DataSetDefinition[] | DataSetDefinitionFactory): DataSetManager {
    return new DataSetManager(context, pageName, definitions)
  }
  private constructor(context: Context, pageName: string, source: DataSetDefinition[] | DataSetDefinitionFactory) {
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
      definitions.some(item => !item.name || !item.query || item.query.type === 'notification')) throw new Error('页面数据集定义无效')
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
        const definition: DataSetDefinition = { name, query }
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
  start(): Promise<void> {
    if (this.closed || this.closing) return Promise.reject(new Error('数据集管理器已关闭'))
    if (this.initialized) return Promise.resolve()
    if (this.running) return this.running
    const generation = this.generation
    const running = this.initialize(generation).finally((): void => { if (this.running === running) this.running = undefined })
    this.running = running
    return running
  }
  private async initialize(generation: number): Promise<void> {
    const config = await AppConfigService.load(this.context, false)
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    const definitions = typeof this.source === 'function' ? this.source(config, await workspace.repos()) : this.source
    this.validate(definitions)
    if (this.closed || this.closing || generation !== this.generation) return
    const resolved = definitions.map((definition): DataSetDefinition => this.overrides.has(definition.name)
      ? { name: definition.name, query: this.overrides.get(definition.name)! } : definition)
    for (const definition of resolved) this.dataSet(definition.name)
    this.config = config; this.workspace = workspace; this.definitions = resolved
    this.resetCache()
    const names = Array.from(this.sets.keys())
    const scope = this.scope
    for (const entry of this.sets.entries()) {
      const name = entry[0], dataSet = entry[1]
      await dataSet.configure(config, workspace, resolved.find(definition => definition.name === name))
      if (this.closed || generation !== this.generation) return
    }
    try {
      const cached = await this.cache?.read()
      if (cached && cached.length === names.length && cached.every(item => names.includes(item.name))) {
        for (const item of cached) {
          const dataSet = this.sets.get(item.name)!
          if (item.queryKey === this.queryKey(dataSet)) dataSet.restore(restoreDataSet(item))
        }
      }
    } catch (_) { /* 缓存不可用时仍由每个数据集执行首次查询。 */ }
    if (this.closed || generation !== this.generation) return
    await Promise.all(Array.from(this.sets.values()).map(dataSet => dataSet.start()))
    if (this.closed || generation !== this.generation || scope !== this.scope) return
    this.initialized = true; this.savedRevision = ''; this.scheduleSave()
  }
  private resetCache(): void {
    const config = this.config!, resolved = this.definitions, names = Array.from(this.sets.keys())
    const identity: DataSetCacheScope = { repositories: config.repos.map((repo): DataSetCacheRepository =>
      ({ id: repo.id, rootDirectory: repo.rootDirectory, excludedDirectories: repo.excludedDirectories ?? [] })),
      todoDefaults: config.todoDefaults, coreSettings: config.coreSettings, names }
    this.scope = JSON.stringify(identity)
    this.cache = resolved.some(definition => definition.query.type === 'document') ? undefined : new PageDataCache(this.context, this.pageName, this.scope)
    this.savedRevision = ''
  }
  private queryKey(dataSet: DataSet): string { return JSON.stringify(dataSet.query) ?? '' }
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
      this.closed = true; clearTimeout(this.saveTimer)
      for (const stop of this.stops.values()) stop()
      this.stopIdle(); AppConfigService.stopWatchingChanges(this.configChanged); DataSetManager.active.delete(this)
    }
  }
}
