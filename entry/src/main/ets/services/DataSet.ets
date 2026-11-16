import { compareRecords } from '../ui/QueryOrderPresentation'
import { samePageTask, samePageMetadata, samePageValue } from './PageDataEquality'
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { TaskCreation, TaskModification } from 'liborg_tasks_harmony.so'
import { AppConfig } from '../models/OrgTask'
import { CoreDataChangeEvent, CoreQuerySubscriptionRequest, CoreQuerySubscriptionStart, CoreQuerySubscriptionStatus, CoreQuery, CoreQueryResult, CoreTask, CoreQueryRepositoryBinding, CoreOrgFile, CoreOrgFileRef, CoreOrgFileMetadata, CoreTaskOperationGroup, CoreTaskDataChange, CoreWorkspace, CoreRefileTarget, CoreSettingsObject } from './NativeCoreService'
import { PageTaskSnapshot, PageMetadataSnapshot, cacheDataSet, restoreDataSet, taskRecord, metadataRecord } from './PageDataSnapshot'
import { createPageTask, projectTaskFields } from './PageDataProjection'
import { MoveToTargetService } from './MoveToTargetService'

export interface DocumentDataSetQuery { type: 'document'; query: CoreOrgFileRef }
export type DataSetQuery = CoreQuery | DocumentDataSetQuery
export interface DataSetDefinition { name: string; query: DataSetQuery; repositoryBindings?: CoreQueryRepositoryBinding[] }
export interface DocumentDataSetSnapshot { identity: string; file: CoreOrgFile; tasks: CoreTask[] }
export interface TaskDataChange { task?: CoreTask; removed?: boolean; blocked?: boolean; error?: string; rejectedChanges?: TaskModification[] }
export class DataSetWriteError extends Error {
  readonly committed: boolean
  constructor(message: string, committed: boolean) { super(message); this.committed = committed }
}
export interface DataSetClock {
  owner: string
  next: () => number
  metadata?: (repoId: string, path: string) => CoreOrgFileMetadata | undefined
  subscribe: (name: string, request: CoreQuerySubscriptionRequest, activate: () => void) => Promise<CoreQuerySubscriptionStart>
  unsubscribe: (name: string) => void
  status: (name: string) => Promise<CoreQuerySubscriptionStatus>
}
export type DataSetDefinitionFactory = (config: AppConfig) => DataSetDefinition[]
interface DataSetSubmission { readonly operationId: string; readonly completion: Promise<void> }
export interface ManagedDataSet { readonly revision: number; readonly name: string; readonly version: number; readonly confirmedVersion: number; readonly data: CoreQueryResult; readonly optimistic: boolean }
export interface DataSetIdentity { before: string; after: string }
export interface DataSetEvent {
  name: string
  type: 'insert' | 'remove' | 'update' | 'refresh' | 'complete' | 'ready' | 'error' | 'document'
  version: number
  dataVersion?: number
  operationId: string
  optimistic: boolean
  added: string[]
  removed: string[]
  updated: string[]
  message?: string
  targetKey?: string
  rejectedChanges?: TaskModification[]
  identities?: DataSetIdentity[]
  succeeded?: boolean
  committed?: boolean
  result?: ManagedDataSet
}
interface PendingEdit {
  id: string; version: number; name: string; kind: 'update' | 'remove' | 'create' | 'move'; key: string
  files: string[]; changes: TaskModification[]; creation?: TaskCreation; draft?: CoreTask
  target?: CoreRefileTarget; sourceVersion: string; observed: Set<string>; identityFrames: Set<string>; missingFrames: Set<string>
}

// 按文件衔接用户编辑意图；真实查询、修改与同步的执行顺序由 Core 调度。
export class UserOperationQueue {
  private static tails: Map<string, Promise<void>> = new Map()
  private static pending: Set<Promise<void>> = new Set()
  private static listeners: Set<() => void> = new Set()
  static isIdle(): boolean { return UserOperationQueue.pending.size === 0 }
  static watchIdle(listener: () => void): () => void {
    UserOperationQueue.listeners.add(listener)
    return (): void => { UserOperationQueue.listeners.delete(listener) }
  }
  static async whenIdle(): Promise<void> {
    while (!UserOperationQueue.isIdle()) await Promise.all(Array.from(UserOperationQueue.pending))
  }
  static submit(work: () => Promise<void>, files: string[] = []): Promise<void> {
    const keys = Array.from(new Set(files))
    const before = keys.map(key => UserOperationQueue.tails.get(key) ?? Promise.resolve())
    const result = Promise.all(before).then(work)
    const settled = result.then((): void => {}, (): void => {})
    for (const key of keys) UserOperationQueue.tails.set(key, settled)
    UserOperationQueue.pending.add(settled)
    settled.then((): void => {
      UserOperationQueue.pending.delete(settled)
      for (const key of keys) if (UserOperationQueue.tails.get(key) === settled) UserOperationQueue.tails.delete(key)
      if (UserOperationQueue.isIdle()) for (const listener of UserOperationQueue.listeners) listener()
    })
    return result
  }
}

export class DataSet {
  private readonly context: Context
  private readonly pageName: string
  private owner: string = util.generateRandomUUID()
  private epoch: string = util.generateRandomUUID()
  private readonly clock: DataSetClock | undefined
  private documentSnapshot: DocumentDataSetSnapshot | undefined = undefined
  private readonly taskListeners: Set<(event: DataSetEvent) => void> = new Set()
  private readonly listeners: Set<(event: DataSetEvent) => void> = new Set()
  private readonly confirmed: Map<string, CoreQueryResult> = new Map()
  private readonly files: Map<string, CoreOrgFile> = new Map()
  private readonly versions: Map<string, number> = new Map()
  private readonly views: Map<string, ManagedDataSet> = new Map()
  private readonly taskIndex: Map<string, Map<string, CoreTask>> = new Map()
  private readonly rowIds: Map<string, Map<string, string>> = new Map()
  private readonly initialEvents: Map<string, CoreDataChangeEvent[]> = new Map()
  private readonly pending: PendingEdit[] = []
  private readonly writes: Set<Promise<void>> = new Set()
  private workspace: CoreWorkspace | undefined = undefined
  private initialization: Promise<void> | undefined = undefined
  private generation: string = ''
  private sequence: number = 0
  private ready: boolean = false
  private scopeChanged: boolean = false
  private closing: boolean = false
  private closed: boolean = false
  private shutdown: Promise<void> | undefined = undefined
  private externalWatch: number = 0
  private externalTimer: number = -1
  private dayTimer: number = -1
  private day: string = new Date().toDateString()
  private externalPending: boolean = false
  private externalRefreshing: boolean = false
  readonly name: string
  get identity(): string { return this.epoch }
  private config: AppConfig | undefined = undefined
  private connection: CoreWorkspace | undefined = undefined
  private definition: DataSetDefinition | undefined = undefined
  private queryWork: Promise<void> | undefined = undefined
  private queryRequest: number = 0
  private configureRequest: number = 0
  private queryChanged: ((query: DataSetQuery) => Promise<void>) | undefined = undefined
  constructor(context: Context, name: string, clock?: DataSetClock) {
    this.clock = clock
    if (clock) this.owner = clock.owner
    this.context = context; this.pageName = name; this.name = name
  }
  invalidate(): void {
    this.scopeChanged = true; this.ready = false; this.generation = ''
    this.clock?.unsubscribe(this.name)
    this.stopExternalUpdates()
    this.publish({ name: this.name, type: 'refresh', version: this.version, operationId: this.operationId(this.sequence, 'context'), optimistic: false, added: [], removed: [], updated: [] })
  }
  async configure(config: AppConfig, workspace: CoreWorkspace, definition?: DataSetDefinition): Promise<void> {
    const request = ++this.configureRequest
    this.scopeChanged = true; this.generation = ''; this.ready = false
    this.clock?.unsubscribe(this.name)
    this.stopExternalUpdates()
    await Promise.all(Array.from(this.writes).map(work => work.catch((): void => {})))
    if (this.connection) await UserOperationQueue.whenIdle()
    if (request !== this.configureRequest || this.closed) return
    this.documentSnapshot = undefined
    this.confirmed.clear(); this.versions.clear(); this.views.clear(); this.taskIndex.clear(); this.rowIds.clear(); this.files.clear()
    this.closed = false; this.closing = false; this.shutdown = undefined; this.scopeChanged = false
    this.epoch = util.generateRandomUUID(); this.sequence = 0
    this.initialization = undefined; this.config = config; this.connection = workspace
    this.definition = definition
    this.loadError = ''
    this.publish({ name: this.name, type: 'refresh', version: 0, operationId: this.operationId(0, 'query'), optimistic: false, added: [], removed: [], updated: [] })
  }
  private loadError: string = ''
  get error(): string { return this.loadError }
  reportError(error: Error): void { this.emitError(this.name, this.operationId(this.sequence, 'error'), error) }
  bindQueryChange(change: (query: DataSetQuery) => Promise<void>): void { this.queryChanged = change }
  async setQuery(query: DataSetQuery): Promise<void> {
    const request = ++this.queryRequest
    const work = (async (): Promise<void> => {
      try { await this.queryChanged?.(query) }
      catch (error) { if (request === this.queryRequest && !this.closed) this.reportError(error as Error) }
    })().finally((): void => { if (this.queryWork === work) this.queryWork = undefined })
    this.queryWork = work
    await work
  }
  get query(): DataSetQuery | undefined { return this.definition?.query }
  get repositoryBindings(): CoreQueryRepositoryBinding[] { return this.definition?.repositoryBindings ?? [] }
  get document(): DocumentDataSetSnapshot | undefined { return this.documentSnapshot }
  get data(): CoreQueryResult | undefined { return this.get(this.name)?.data }
  get version(): number { return this.get(this.name)?.version ?? 0 }
  get revision(): number { return this.get(this.name)?.revision ?? 0 }
  taskKey(id: string): string { return this.itemKey(this.name, id) }
  async createTask(value: TaskCreation, sourceVersion?: string): Promise<void> { await this.create(this.name, value, sourceVersion) }
  async moveTask(id: string, target: CoreRefileTarget): Promise<void> { await this.move(this.name, id, target) }
  async removeTask(id: string): Promise<void> { await this.remove(this.name, id) }
  async operate(execute: (operationId: string) => Promise<void>): Promise<void> { await this.runOperation(this.name, execute) }
  restore(data: CoreQueryResult): void { this.confirmed.set(this.name, data); this.versions.set(this.name, 0); this.rebuild(this.name, this.operationId(0, 'cache'), false) }
  async settle(): Promise<void> {
    if (this.queryWork) await this.queryWork
    if (this.initialization) await this.initialization.catch((): void => {})
    while (!this.closed && (this.externalPending || this.externalRefreshing || this.writes.size)) {
      if (this.externalPending && !this.externalRefreshing && this.ready) {
        clearTimeout(this.externalTimer); this.externalTimer = -1; this.externalPending = false
        await this.refresh()
      }
      await Promise.all(Array.from(this.writes).map(work => work.catch((): void => {})))
      if (this.externalRefreshing) await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
  }
  hasValidScope(): boolean { return !this.scopeChanged && !this.closed && !this.closing }
  isReady(): boolean { return this.ready && !this.scopeChanged && !this.closed }
  snapshot(): ManagedDataSet | undefined { return this.get(this.name) }
  get(name: string): ManagedDataSet | undefined { return this.views.get(name) }
  getConfirmed(name: string = this.name): ManagedDataSet | undefined {
    const data = this.confirmed.get(name)
    if (!data) return undefined
    const version = this.versions.get(name) ?? 0
    return { name, revision: this.views.get(name)?.revision ?? 0, version, confirmedVersion: version, data, optimistic: false }
  }
  itemKey(name: string, key: string): string {
    const task = this.findTask(name, key)
    const recordKey = task ? taskKey(task) : key
    const ids = this.rowIds.get(name)
    return ids?.get(recordKey) ?? JSON.stringify([this.pageName, name, recordKey])
  }
  subscribe(listener: (event: DataSetEvent) => void): () => void {
    this.listeners.add(listener)
    return (): void => { this.listeners.delete(listener) }
  }
  findTask(name: string, key: string): CoreTask | undefined {
    return this.taskIndex.get(name)?.get(key)
  }
  getTask(id: string, name: string = this.name): CoreTask | undefined { return this.findTask(name, id) }
  getFile(name: string = this.name): CoreOrgFile | undefined { return this.files.get(name) }
  updateTaskFields(id: string, changes: TaskModification[], sourceVersion?: string, name: string = this.name): CoreTask {
    return this.updateFields(name, id, changes, sourceVersion)
  }
  async updateTask(id: string, changes: TaskModification[], sourceVersion?: string, name: string = this.name): Promise<CoreTask> {
    const key = this.itemKey(name, id)
    await this.update(name, id, changes, sourceVersion)
    const task = this.getTask(key, name)
    if (!task) throw new Error('任务已离开当前数据集')
    return task
  }
  watchTask(id: string, listener: (change: TaskDataChange) => void, name: string = this.name): () => void {
    const key = this.itemKey(name, id)
    let previous = this.getTask(key, name)
    const receive = (event: DataSetEvent): void => {
      if (event.name !== name) return
      const current = this.getTask(key, name)
      const recordKey = previous ? taskKey(previous) : ''
      if (event.type === 'error') {
        if (!event.targetKey || event.targetKey === recordKey) listener({ task: current, error: event.message ?? '修改失败',
          blocked: event.committed === true || !!event.message && ['版本', '失效', '已变化'].some(value => event.message!.includes(value)), rejectedChanges: event.rejectedChanges })
        return
      }
      if (event.type === 'ready' || event.type === 'complete' || event.type === 'document') return
      if (!current && previous) { previous = undefined; listener({ removed: true }); return }
      if (current && (!previous || event.updated.includes(taskKey(current)) || event.added.includes(taskKey(current)) ||
        event.identities?.some(identity => identity.before === recordKey && identity.after !== recordKey))) {
        previous = current; listener({ task: current })
      }
    }
    this.taskListeners.add(receive)
    listener(previous ? { task: previous } : { removed: true })
    return (): void => { this.taskListeners.delete(receive) }
  }
  private operationId(version: number, kind: string): string { return `dataset/${this.owner}/${version}/${kind}/${this.epoch}` }
  private eventVersion(id: string | null): number | undefined {
    const prefix = `dataset/${this.owner}/`
    if (!id?.startsWith(prefix)) return undefined
    const value = Number(id.slice(prefix.length).split('/')[0])
    return Number.isSafeInteger(value) && value >= 0 ? value : undefined
  }
  start(): Promise<void> {
    if (this.closed || this.closing) return Promise.reject(new Error('页面数据集已关闭'))
    if (!this.initialization) {
      const initialization = this.initialize().catch((error: Error): never => { if (this.initialization === initialization) this.initialization = undefined; throw error })
      this.initialization = initialization
    }
    return this.initialization
  }
  private async initialize(): Promise<void> {
    if (this.scopeChanged || !this.connection) throw new Error('数据集尚未配置')
    this.workspace = this.connection
    if (!this.definition) {
      this.applyFullResult(this.name, { type: 'task', result: { tasks: [], categories: [] } }, this.operationId(1, 'refresh'))
      this.ready = true
      this.publish({ name: this.name, type: 'ready', version: 1, operationId: this.operationId(1, 'refresh'), optimistic: false, added: [], removed: [], updated: [] })
      return
    }
    // 缓存已由管理器发布；配置接入属于后台查询准备，不阻塞缓存恢复。
    // 立即把查询交给管理器收集；各监控注册的完成顺序不拆散页面首次批次。
    await Promise.all([this.connectExternalUpdates(), this.load(++this.sequence)])
  }
  private async connectExternalUpdates(): Promise<void> {
    const workspace = this.workspace
    if (!workspace || this.externalWatch) return
    const owner = this.epoch
    const id = await workspace.watchDataChanges((event: CoreDataChangeEvent): void => {
      if (owner !== this.epoch || workspace !== this.workspace || this.closed) return
      const definition = this.definition
      const file = definition?.query.type === 'document' ? definition.query.query : undefined
      if (file && event.repoId === file.repoId && event.changes.length) {
        const changes = event.changes.flatMap((change: CoreTaskDataChange): CoreTaskDataChange[] => {
          const before = change.before?.task.fullPath.file === file.path ? change.before : null
          const after = change.after?.task.fullPath.file === file.path ? change.after : null
          return before || after ? [{ kind: change.kind, before, after }] : []
        })
        if (changes.length) this.remapFileIdentities(this.name, changes, event.operationId ?? this.generation)
      }
      if (this.eventVersion(event.operationId) === undefined) this.requestExternalRefresh()
    })
    if (!this.hasValidScope() || owner !== this.epoch || workspace !== this.workspace) { workspace.stopWatchingDataChanges(id); return }
    this.externalWatch = id
    this.dayTimer = setInterval((): void => {
      const day = new Date().toDateString()
      if (day !== this.day) { this.day = day; this.requestExternalRefresh() }
    }, 60000)
  }
  private remapFileIdentities(name: string, changes: CoreTaskDataChange[], operationId: string): void {
    const data = this.confirmed.get(name)
    if (data?.type !== 'task') return
    const previousIds = this.rowIds.get(name) ?? new Map<string, string>()
    const ids = new Map(previousIds)
    const identities: DataSetIdentity[] = []
    for (const change of changes) if (change.before) ids.delete(taskKeyFromRaw(change.before.task.fullPath.repoId, change.before.task.id))
    for (const change of changes) {
      const before = change.before ? taskKeyFromRaw(change.before.task.fullPath.repoId, change.before.task.id) : ''
      const after = change.after ? taskKeyFromRaw(change.after.task.fullPath.repoId, change.after.task.id) : ''
      if (after) ids.set(after, previousIds.get(before) ?? util.generateRandomUUID())
      if (before && after) identities.push({ before, after })
      for (const pending of this.pending) if (pending.key === before && change.before) {
        const frame = identityFrame({ repoId: change.before.task.fullPath.repoId, changes: [change], files: [], type: 'repositoryChanged', operationId },
          change.before.task.fullPath.repoId, change.before.task.fullPath.file!)
        if (after && !pending.identityFrames.has(frame)) { pending.key = after; pending.identityFrames.add(frame) }
        if (!after && !pending.identityFrames.has(frame)) pending.missingFrames.add(frame)
      }
    }
    this.rowIds.set(name, ids)
    const tasks = data.result.tasks.flatMap((task: CoreTask): CoreTask[] => {
      const change = changes.find(item => item.before && taskKeyFromRaw(item.before.task.fullPath.repoId, item.before.task.id) === taskKey(task))
      if (!change) return [task]
      if (!change.after) return []
      const record = taskRecord(task)
      record.value.id = change.after.task.id; record.value.fullPath = change.after.task.fullPath
      return [new PageTaskSnapshot(record)]
    })
    this.confirmed.set(name, { type: 'task', result: { tasks, categories: data.result.categories } })
    this.rebuild(name, operationId, this.pending.length > 0, identities)
  }
  private stopExternalUpdates(): void {
    if (this.externalWatch) this.workspace?.stopWatchingDataChanges(this.externalWatch)
    this.externalWatch = 0
    clearTimeout(this.externalTimer); this.externalTimer = -1
    clearInterval(this.dayTimer); this.dayTimer = -1
    this.externalPending = false; this.externalRefreshing = false
  }
  private requestExternalRefresh(): void {
    if (!this.hasValidScope()) return
    this.externalPending = true
    this.scheduleExternalRefresh()
  }
  private scheduleExternalRefresh(): void {
    if (!this.externalPending || !this.ready || this.externalRefreshing || this.externalTimer >= 0 || !this.hasValidScope()) return
    const epoch = this.epoch
    this.externalTimer = setTimeout((): void => {
      this.externalTimer = -1
      if (!this.hasValidScope() || epoch !== this.epoch) return
      this.externalPending = false; this.externalRefreshing = true
      this.refresh().catch((error: Error): void => {
        if (this.hasValidScope()) this.emitError(this.name, this.operationId(this.sequence, 'refresh'), error)
      }).finally((): void => { if (epoch === this.epoch) { this.externalRefreshing = false; this.scheduleExternalRefresh() } })
    }, 50)
  }
  private async load(version: number): Promise<void> {
    const workspace = this.workspace
    if (!workspace) throw new Error('底层连接尚未建立')
    if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
    const operationId = this.operationId(version, 'refresh')
    const activate = (): void => {
      this.generation = operationId
      this.initialEvents.clear(); this.initialEvents.set(this.name, [])
    }
    const definition = this.definition!
    try {
      if (definition.query.type === 'document') {
        activate()
        await this.loadFile(definition, operationId)
      }
      else {
        if (!this.clock) throw new Error('数据集缺少订阅管理器')
        const result = await this.clock.subscribe(this.name, { query: definition.query, callback: (event: CoreDataChangeEvent): void => {
          if (this.closed || this.generation !== operationId) return
          const queue = this.initialEvents.get(this.name)
          if (queue) queue.push(event)
          else this.onCoreDataChanged(this.name, event, operationId)
        }, operationId, repositoryBindings: this.repositoryBindings }, activate)
        if (this.closed || this.generation !== operationId) {
          throw new Error('数据集查询已变化')
        }
        this.applyFullResult(this.name, result.data, result.operationId ?? operationId)
        const events = this.initialEvents.get(this.name) ?? []
        this.initialEvents.delete(this.name)
        for (const event of events) this.onCoreDataChanged(this.name, event, operationId)
      }
      this.ready = true
      this.publish({ name: this.name, type: 'ready', version, dataVersion: this.views.get(this.name)?.version,
        operationId, optimistic: false, added: [], removed: [], updated: [] })
      this.scheduleExternalRefresh()
    } catch (error) {
      if (this.generation !== operationId) throw error as Error
      this.clock?.unsubscribe(this.name)
      this.initialEvents.clear()
      this.generation = ''; this.ready = false
      this.emitError(this.name, operationId, error as Error)
      throw error as Error
    }
  }
  private async loadFile(definition: DataSetDefinition, operationId: string, acceptedOperationId?: string): Promise<void> {
    const reference = (definition.query as DocumentDataSetQuery).query
    const file = await this.workspace!.fileAt({ repoId: reference.repoId, file: reference.path, titles: [] })
    if (this.closed || this.scopeChanged || this.generation !== operationId) return
    this.files.set(definition.name, file)
    for (const edit of this.pending) if (edit.id === acceptedOperationId) edit.observed.add(definition.name)
    this.applyFullResult(definition.name, { type: 'task', result: { tasks: file.nodes(), categories: [] } }, operationId)
    const data = this.confirmed.get(this.name)!
    this.documentSnapshot = { identity: this.epoch, file, tasks: data.type === 'task' ? data.result.tasks : [] }
    this.publish({ name: definition.name, type: 'document', version: this.eventVersion(operationId) ?? this.sequence,
      operationId, optimistic: false, added: [], removed: [], updated: [] })
  }
  private applyFullResult(name: string, data: CoreQueryResult, operationId: string): void {
    this.loadError = ''
    this.confirmed.set(name, restoreDataSet(cacheDataSet(name, data)))
    this.versions.set(name, this.eventVersion(operationId) ?? 1)
    this.rebuild(name, operationId, false)
  }
  async refresh(): Promise<void> {
    await this.start()
    if (this.closing || this.closed) throw new Error('页面数据集已关闭')
    if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
    const version = this.clock ? this.clock.next() : this.sequence + 1
    this.sequence = version
    // 普通查询由管理器合并后统一排队；完整文档沿用单文件读取。
    const work = this.query?.type === 'document'
      ? UserOperationQueue.submit(async (): Promise<void> => { await this.load(version) },
        [...this.scopeFiles(), JSON.stringify(['$dataset', this.epoch, this.name])])
      : this.load(version)
    this.track(work)
    return work
  }
  async runOperation(name: string, execute: (operationId: string) => Promise<void>): Promise<void> {
    await this.start()
    if (!this.isReady() || this.closing) throw new Error('页面数据集当前不可编辑')
    const version = this.clock ? this.clock.next() : this.sequence + 1
    this.sequence = version
    const operationId = this.operationId(version, 'operation')
    const work = UserOperationQueue.submit(async (): Promise<void> => {
      try {
        if (!this.hasValidScope()) throw new Error('页面数据范围已变化')
        if (this.clock && await this.clock.status(this.name) !== 'current') {
          this.requestExternalRefresh(); throw new Error('数据订阅已失效，正在刷新页面')
        }
        await execute(operationId)
        this.versions.set(this.name, Math.max(this.versions.get(this.name) ?? 0, version))
        this.rebuild(this.name, operationId, this.pending.length > 0)
            this.publish({ name, type: 'complete', version, operationId, optimistic: false, added: [], removed: [], updated: [],
          succeeded: true, result: this.getConfirmed(name) })
      } catch (error) { this.emitError(name, operationId, error as Error); throw error as Error }
    }, this.scopeFiles())
    this.track(work)
    await work
  }
  private queueUpdate(name: string, key: string, changes: TaskModification[], sourceVersion?: string): DataSetSubmission {
    const task = this.findTask(name, key)
    if (!task) throw new Error('任务不在当前数据集中')
    const edit = this.edit(name, 'update', task, changes, sourceVersion)
    return { operationId: edit.id, completion: this.submit(edit) }
  }
  updateFields(name: string, key: string, changes: TaskModification[], sourceVersion?: string): CoreTask {
    const submitted = this.queueUpdate(name, key, changes, sourceVersion)
    submitted.completion.catch((): void => {})
    return this.findTask(name, key)!
  }
  async update(name: string, key: string, changes: TaskModification[], sourceVersion?: string): Promise<void> {
    if (!this.ready) await this.start()
    if (!changes.length) return
    await this.queueUpdate(name, key, changes, sourceVersion).completion
  }
  async remove(name: string, key: string): Promise<void> {
    if (!this.ready) await this.start()
    const task = this.findTask(name, key)
    if (!task) throw new Error('任务不在当前数据集中')
    await this.submit(this.edit(name, 'remove', task, []))
  }
  async create(name: string, value: TaskCreation, sourceVersion?: string): Promise<void> {
    if (!this.ready) await this.start()
    const target = this.confirmed.get(name)
    if (target?.type !== 'task') throw new Error('创建目标不是任务数据集')
    const metadata = this.clock?.metadata?.(value.position.parent.repoId, value.position.parent.file!) ?? Array.from(this.confirmed.values()).filter(item => item.type === 'file')
      .flatMap(item => item.type === 'file' ? item.result : []).find(file => file.repoId === value.position.parent.repoId && file.path === value.position.parent.file)
    if (!metadata) throw new Error('创建需要在页面数据集中包含目标文件元信息')
    const reference = Array.from(this.confirmed.values()).flatMap(item => item.type === 'task' ? item.result.tasks : [])
      .find(task => task.repoId === value.position.parent.repoId && task.filePath === value.position.parent.file)
    const version = sourceVersion ?? reference?.fileVersion ?? ''
    if ((value.position.parent.titles.length > 0 || value.position.after) && !version) throw new Error('创建位置需要对应的文件版本')
    const draft = createPageTask(metadata, '', value)
    const edit = this.edit(name, 'create', draft, [])
    edit.creation = JSON.parse(JSON.stringify(value)) as TaskCreation; edit.draft = draft; edit.sourceVersion = version
    await this.submit(edit)
  }
  async moveTargets(): Promise<CoreRefileTarget[]> { return await MoveToTargetService.targets(this.context) }
  async move(name: string, key: string, target: CoreRefileTarget): Promise<void> {
    if (!this.ready) await this.start()
    const task = this.findTask(name, key)
    if (!task) throw new Error('任务不在当前数据集中')
    const edit = this.edit(name, 'move', task, [])
    edit.target = JSON.parse(JSON.stringify(target)) as CoreRefileTarget
    edit.files.push(JSON.stringify([target.repoId, target.path]))
    await this.submit(edit)
  }
  private edit(name: string, kind: 'update' | 'remove' | 'create' | 'move', task: CoreTask, changes: TaskModification[], sourceVersion?: string): PendingEdit {
    if (this.closing || this.closed || !this.ready) throw new Error('页面数据集当前不可编辑')
    const version = this.clock ? this.clock.next() : this.sequence + 1
    this.sequence = version
    return { id: this.operationId(version, kind), version, name, kind, key: taskKey(task), files: [JSON.stringify([task.repoId, task.filePath])],
      sourceVersion: sourceVersion ?? task.fileVersion, changes: JSON.parse(JSON.stringify(changes)) as TaskModification[],
      observed: new Set(), identityFrames: new Set(), missingFrames: new Set() }
  }
  scopeFiles(): string[] {
    const files: string[] = []
    for (const data of this.confirmed.values()) {
      if (data.type === 'task') for (const task of data.result.tasks) files.push(JSON.stringify([task.repoId, task.filePath]))
      else if (data.type === 'file') for (const file of data.result) files.push(JSON.stringify([file.repoId, file.path]))
    }
    for (const edit of this.pending) files.push(...edit.files)
    return Array.from(new Set(files))
  }
  private submit(edit: PendingEdit): Promise<void> {
    for (const pending of this.pending) {
      if (pending.key === edit.key && pending.target) edit.files.push(JSON.stringify([pending.target.repoId, pending.target.path]))
    }
    this.pending.push(edit)
    this.rebuild(this.name, edit.id, true)
    const work = UserOperationQueue.submit(async (): Promise<void> => {
      const workspace = this.workspace
      if (!workspace) throw new Error('底层连接不可用')
      let committed: boolean = false
      try {
        if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
        if (this.clock && await this.clock.status(this.name) !== 'current') {
          this.requestExternalRefresh()
          throw new Error('数据订阅已失效，正在刷新页面')
        }
        let group: CoreTaskOperationGroup
        if (edit.kind === 'create') {
          const creation = edit.creation!
          const current = Array.from(this.confirmed.values()).flatMap(item => item.type === 'task' ? item.result.tasks : [])
            .find(task => task.repoId === creation.position.parent.repoId && task.filePath === creation.position.parent.file)
          const version = creation.position.parent.titles.length === 0 && !creation.position.after ? current?.fileVersion ?? edit.sourceVersion : edit.sourceVersion
          group = { operationId: edit.id, operations: [{ type: 'Creation', data: creation }],
            fileVersions: version ? [{ repoId: creation.position.parent.repoId, file: creation.position.parent.file!, version }] : [] }
        }
        else {
          const task = Array.from(this.confirmed.values()).flatMap(item => item.type === 'task' ? item.result.tasks : []).find(item => taskKey(item) === edit.key)
          if (!task || edit.missingFrames.size) throw new Error('任务已离开当前数据集')
          if (edit.kind === 'move' && edit.target) {
            group = { operationId: edit.id, operations: [{ type: 'Movement', data: { path: task.fullPath, position: { parent: edit.target.fullPath } } }],
              fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }, { repoId: edit.target.repoId, file: edit.target.path, version: edit.target.fileVersion }] }
          } else {
          const positional = edit.changes.some(change => change.field === 'CHECKLIST' || change.field === 'LINK' || change.field === 'CONTENT_BLOCK')
          group = { operationId: edit.id, fileVersions: [{ repoId: task.repoId, file: task.filePath, version: positional ? edit.sourceVersion : task.fileVersion }],
            operations: [edit.kind === 'remove' ? { type: 'Deletion', data: { path: task.fullPath } } :
              { type: 'Modification', data: { path: task.fullPath, modifications: edit.changes } }] }
          }
        }
        await workspace.executeTaskOperations(group)
        committed = true
        if (this.definition?.query.type === 'document') await this.loadFile(this.definition, this.generation, edit.id)
        // Native 保证本次产生的数据事件先于 Promise 完成；没有命中变化的操作也在此结束阶段。
        this.finishEdit(edit, false)
      } catch (error) {
        this.finishEdit(edit, true)
        this.emitError(edit.name, edit.id, error as Error, edit.key, edit.changes, committed)
        if (committed) throw new DataSetWriteError((error as Error).message, true)
        throw error as Error
      }
    }, edit.files)
    this.track(work)
    return work
  }
  private track(work: Promise<void>): void {
    this.writes.add(work)
    work.then((): void => { this.writes.delete(work) }, (): void => { this.writes.delete(work) })
  }
  private finishEdit(edit: PendingEdit, failed: boolean): void {
    const index = this.pending.indexOf(edit)
    if (index >= 0) this.pending.splice(index, 1)
    if (!failed && !this.scopeChanged) this.versions.set(this.name, Math.max(this.versions.get(this.name) ?? 0, edit.version))
    this.rebuild(this.name, edit.id, this.pending.length > 0)
    this.publish({ name: edit.name, type: 'complete', version: edit.version, operationId: edit.id,
      optimistic: false, dataVersion: this.views.get(edit.name)?.version, added: [], removed: [], updated: [], succeeded: !failed, result: this.scopeChanged ? undefined : this.getConfirmed(edit.name), message: failed ? '提交失败' : undefined })
  }
  private onCoreDataChanged(name: string, event: CoreDataChangeEvent, refreshId: string): void {
    const data = this.confirmed.get(name)
    if (!data) return
    const version = this.eventVersion(event.operationId) ?? this.eventVersion(refreshId) ?? 1
    const operationId = event.operationId ?? refreshId
    const edit = this.pending.find(item => item.id === event.operationId)
    if (edit) edit.observed.add(name)
    let createdIdentity: DataSetIdentity | undefined = undefined
    if (edit?.kind === 'create' && edit.draft && edit.creation) {
      const created = event.changes.find(change => !change.before && change.after?.view?.heading === edit.creation!.title &&
        change.after.task.fullPath.repoId === edit.creation!.position.parent.repoId && change.after.task.fullPath.file === edit.creation!.position.parent.file)
      if (created?.after) {
        createdIdentity = { before: taskKey(edit.draft), after: taskKeyFromRaw(created.after.task.fullPath.repoId, created.after.task.id) }
        const frame = identityFrame(event, created.after.task.fullPath.repoId, created.after.task.fullPath.file)
        for (const pending of this.pending) if (pending.key === createdIdentity.before) {
          pending.key = createdIdentity.after; pending.identityFrames.add(frame); pending.missingFrames.delete(frame)
        }
      }
    }
    if (data.type === 'task') {
      const beforeIds = this.rowIds.get(name) ?? new Map<string, string>()
      const nextIds = new Map(beforeIds)
      for (const change of event.changes) if (change.before) nextIds.delete(taskKeyFromRaw(change.before.task.fullPath.repoId, change.before.task.id))
      for (const change of event.changes) if (change.after) {
        const after = taskKeyFromRaw(change.after.task.fullPath.repoId, change.after.task.id)
        const before = change.before ? taskKeyFromRaw(change.before.task.fullPath.repoId, change.before.task.id) :
          createdIdentity?.after === after ? createdIdentity.before : ''
        nextIds.set(after, beforeIds.get(before) ?? util.generateRandomUUID())
      }
      this.rowIds.set(name, nextIds)
      for (const pending of this.pending) {
        const mapping = event.changes.find(change => change.before && taskKeyFromRaw(change.before.task.fullPath.repoId, change.before.task.id) === pending.key)
        if (mapping?.before) {
          const frame = identityFrame(event, mapping.before.task.fullPath.repoId, mapping.before.task.fullPath.file)
          if (mapping.after) {
            if (!pending.identityFrames.has(frame)) { pending.key = taskKeyFromRaw(mapping.after.task.fullPath.repoId, mapping.after.task.id); pending.identityFrames.add(frame) }
            pending.missingFrames.delete(frame)
          } else if (!pending.identityFrames.has(frame)) pending.missingFrames.add(frame)
        }
      }
      const removed = new Set(event.changes.filter(change => !!change.before).map(change => taskKeyFromRaw(change.before!.task.fullPath.repoId, change.before!.task.id)))
      const tasks = data.result.tasks.filter(task => !removed.has(taskKey(task)))
      for (const change of event.changes) if (change.after) {
        if (!change.after.view) { this.emitError(name, operationId, new Error('数据事件缺少任务显示快照')); return }
        tasks.push(new PageTaskSnapshot(taskRecord(change.after.view)))
      }
      tasks.sort(compareRecords)
      this.confirmed.set(name, { type: 'task', result: { tasks, categories: event.categories ?? data.result.categories } })
    } else if (data.type === 'file') {
      const keys = new Set((event.removedFiles ?? []).map(file => JSON.stringify([file.repoId, file.path])))
      for (const file of event.files ?? []) keys.add(JSON.stringify([file.after.repoId, file.after.path]))
      const files = data.result.filter(file => !keys.has(JSON.stringify([file.repoId, file.path])))
      for (const file of event.files ?? []) {
        if (!file.afterView) { this.emitError(name, operationId, new Error('数据事件缺少文件显示快照')); return }
        files.push(new PageMetadataSnapshot(metadataRecord(file.afterView)))
      }
      files.sort(compareRecords)
      this.confirmed.set(name, { type: 'file', result: files })
    }
    this.versions.set(name, Math.max(this.versions.get(name) ?? 0, version))
    const identities: DataSetIdentity[] = event.changes.filter(change => !!change.before && !!change.after).map((change): DataSetIdentity => ({
      before: taskKeyFromRaw(change.before!.task.fullPath.repoId, change.before!.task.id), after: taskKeyFromRaw(change.after!.task.fullPath.repoId, change.after!.task.id) }))
    if (createdIdentity) identities.push(createdIdentity)
    const removedRecords = event.changes.filter(change => !!change.before && !change.after).map(change => taskKeyFromRaw(change.before!.task.fullPath.repoId, change.before!.task.id))
    const addedRecords = event.changes.filter(change => !change.before && !!change.after).map(change => taskKeyFromRaw(change.after!.task.fullPath.repoId, change.after!.task.id))
    this.rebuild(name, operationId, this.pending.length > 0, identities, removedRecords, addedRecords)
  }
  private rebuild(name: string, operationId: string, optimistic: boolean, identities: DataSetIdentity[] = [], removedRecords: string[] = [], addedRecords: string[] = []): void {
    const confirmed = this.confirmed.get(name)
    if (!confirmed) return
    let data = confirmed
    let version = this.versions.get(name) ?? 0
    if (confirmed.type === 'task') {
      let tasks = confirmed.result.tasks.slice()
      for (const edit of this.pending) {
        version = Math.max(version, edit.version)
        if (edit.observed.has(name) || edit.missingFrames.size) continue
        if (edit.kind === 'create' && edit.name === name && edit.draft) tasks.unshift(edit.draft)
        if (edit.kind === 'remove') tasks = tasks.filter(task => taskKey(task) !== edit.key)
        if (edit.kind === 'update') tasks = tasks.map(task => taskKey(task) === edit.key ? projectTaskFields(task, edit.changes) : task)
      }
      data = { type: 'task', result: { tasks, categories: confirmed.result.categories } }
    }
    const previous = this.views.get(name)
    if (data.type === 'task') {
      const index = new Map<string, CoreTask>()
      for (const task of data.result.tasks) {
        if (!index.has(task.id)) index.set(task.id, task)
        if (task.taskId && !index.has(task.taskId)) index.set(task.taskId, task)
        index.set(taskKey(task), task)
      }
      this.taskIndex.set(name, index)
    }
    this.views.set(name, { name, revision: previous?.revision ?? 0, version, confirmedVersion: this.versions.get(name) ?? 0, data, optimistic: this.pending.length > 0 })
    const before = records(previous?.data)
    const after = records(data)
    const ids = this.rowIds.get(name) ?? new Map<string, string>()
    const retained = new Set(Array.from(after.keys()).concat(Array.from(records(confirmed).keys())))
    for (const key of retained) if (!ids.has(key)) ids.set(key, util.generateRandomUUID())
    for (const key of Array.from(ids.keys())) if (!retained.has(key)) ids.delete(key)
    this.rowIds.set(name, ids)
    if (data.type === 'task') for (const task of data.result.tasks) {
      const rowId = ids.get(taskKey(task))
      if (rowId) this.taskIndex.get(name)?.set(rowId, task)
    }
    const added = Array.from(new Set(Array.from(after.keys()).filter(key => !before.has(key)).concat(addedRecords)))
    const removed = Array.from(new Set(Array.from(before.keys()).filter(key => !after.has(key)).concat(removedRecords)))
    const updated = Array.from(after.keys()).filter(key => {
      const old = before.get(key); const current = after.get(key)
      if (!old || !current) return false
      return data.type === 'task' ? !samePageTask(old as CoreTask, current as CoreTask) :
        !samePageMetadata(old as CoreOrgFileMetadata, current as CoreOrgFileMetadata)
    })
    if (added.length || removed.length || updated.length || !samePageValue(previous?.data.type === 'task' ? previous.data.result.categories : [], data.type === 'task' ? data.result.categories : []) || !previous) {
      const view = this.views.get(name)!
      this.views.set(name, { name, revision: (previous?.revision ?? 0) + 1, version: view.version,
        confirmedVersion: view.confirmedVersion, data: view.data, optimistic: view.optimistic })
      this.publish({ name, type: added.length && !removed.length && !updated.length ? 'insert' : removed.length && !added.length && !updated.length ? 'remove' : updated.length && !added.length && !removed.length ? 'update' : 'refresh',
        version: this.eventVersion(operationId) ?? version, dataVersion: version, operationId, optimistic, added, removed, updated, identities })
    }
  }
  private publish(event: DataSetEvent): void {
    for (const listener of this.taskListeners) { try { listener(event) } catch (_) { console.error('任务记录监听处理失败') } }
    if (this.query?.type === 'document' && event.type !== 'document' && event.type !== 'ready' && !(event.type === 'error' && !event.targetKey)) return
    for (const listener of this.listeners) { try { listener(event) } catch (_) { console.error('页面数据监听处理失败') } }
  }
  private emitError(name: string, id: string, error: Error, targetKey?: string, rejectedChanges?: TaskModification[], committed: boolean = false): void {
    if (!targetKey) this.loadError = error.message
    this.publish({ name, type: 'error', version: this.eventVersion(id) ?? this.sequence, operationId: id,
      optimistic: false, added: [], removed: [], updated: [], message: error.message, targetKey, rejectedChanges, committed })
  }

  close(): Promise<void> {
    if (!this.shutdown) this.shutdown = this.closeInternal()
    return this.shutdown
  }
  private async closeInternal(): Promise<void> {
    if (this.closed) return
    this.closing = true
    try {
      if (this.initialization) { try { await this.initialization } catch (_) {} }
      await Promise.all(Array.from(this.writes).map(work => work.catch((): void => {})))
      await UserOperationQueue.whenIdle()
      // 固定关闭边界：先解除事件，再持久化最后一个已确认阶段。
      this.clock?.unsubscribe(this.name)
      this.closed = true
      this.stopExternalUpdates()
    } finally {
      this.closed = true
      this.stopExternalUpdates()
      this.clock?.unsubscribe(this.name); this.listeners.clear(); this.taskListeners.clear();
    }
  }
}
function taskKey(task: CoreTask): string { return taskKeyFromRaw(task.repoId, task.id) }
function taskKeyFromRaw(repoId: string, id: string): string { return JSON.stringify([repoId, id]) }
function records(data: CoreQueryResult | undefined): Map<string, CoreTask | CoreOrgFileMetadata> {
  const result = new Map<string, CoreTask | CoreOrgFileMetadata>()
  if (data?.type === 'task') for (const task of data.result.tasks) result.set(taskKey(task), task)
  if (data?.type === 'file') for (const file of data.result) result.set(JSON.stringify([file.repoId, file.path]), file)
  return result
}

function identityFrame(event: CoreDataChangeEvent, repoId: string, file: string | null): string {
  const change = event.files?.find(item => item.after.repoId === repoId && item.after.path === file)
  return JSON.stringify([repoId, file, change?.afterVersion])
}
