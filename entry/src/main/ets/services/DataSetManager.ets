import { samePageTask, samePageMetadata, samePageValue } from './PageDataEquality'
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { TaskCreation, TaskModification, QueryOrderPart } from 'liborg_tasks_harmony.so'
import { AppConfigService } from './AppConfigService'
import { CoreDataChangeEvent, CoreQuery, CoreQueryResult, CoreTask, CoreOrgFileMetadata, CoreTaskOperationGroup, CoreWorkspace, CoreRefileTarget, CoreSettingsObject, NativeCoreService } from './NativeCoreService'
import { PageDataCache } from './PageDataCache'
import { PageTaskSnapshot, PageMetadataSnapshot, cacheDataSet, restoreDataSet, taskRecord, metadataRecord } from './PageDataSnapshot'
import { createPageTask, projectTaskFields } from './PageDataProjection'
import { MoveToTargetService } from './MoveToTargetService'

interface CacheScopeRepo { id: string; rootDirectory: string }
interface CacheScope { repositories: CacheScopeRepo[]; todoDefaults: string; coreSettings: CoreSettingsObject; definitions: DataSetDefinition[] }
interface RestoredDataSet { name: string; data: CoreQueryResult }

export interface DataSetDefinition { name: string; query: CoreQuery }
interface DataSetSubmission { readonly operationId: string; readonly completion: Promise<void> }
export interface ManagedDataSet { readonly revision: number; readonly name: string; readonly version: number; readonly confirmedVersion: number; readonly data: CoreQueryResult; readonly optimistic: boolean }
export interface DataSetIdentity { before: string; after: string }
export interface DataSetEvent {
  name: string
  type: 'insert' | 'remove' | 'update' | 'refresh' | 'complete' | 'ready' | 'error'
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
  result?: ManagedDataSet
}
interface PendingEdit {
  id: string; version: number; name: string; kind: 'update' | 'remove' | 'create' | 'move'; key: string
  changes: TaskModification[]; creation?: TaskCreation; draft?: CoreTask
  target?: CoreRefileTarget; sourceVersion: string; observed: Set<string>; identityFrames: Set<string>; missingFrames: Set<string>
}

// 共用用户操作队列，事件、缓存恢复与刷新均不能在此队列中生成修改操作。
class UserOperationQueue {
  private static tail: Promise<void> = Promise.resolve()
  private static outstanding: number = 0
  private static listeners: Set<() => void> = new Set()
  static isIdle(): boolean { return UserOperationQueue.outstanding === 0 }
  static watchIdle(listener: () => void): () => void {
    UserOperationQueue.listeners.add(listener)
    return (): void => { UserOperationQueue.listeners.delete(listener) }
  }
  static async whenIdle(): Promise<void> {
    while (true) {
      const tail = UserOperationQueue.tail
      await tail
      if (tail === UserOperationQueue.tail && UserOperationQueue.isIdle()) return
    }
  }
  static submit(work: () => Promise<void>): Promise<void> {
    UserOperationQueue.outstanding++
    const result = UserOperationQueue.tail.then(work)
    const settled = result.then((): void => {}, (): void => {})
    UserOperationQueue.tail = settled
    settled.then((): void => {
      UserOperationQueue.outstanding--
      if (UserOperationQueue.isIdle()) for (const listener of UserOperationQueue.listeners) listener()
    })
    return result
  }
}

export class DataSetManager {
  private static active: Set<DataSetManager> = new Set()
  private readonly context: Context
  private readonly pageName: string
  private readonly definitions: DataSetDefinition[]
  private readonly owner: string = util.generateRandomUUID()
  private readonly listeners: Set<(event: DataSetEvent) => void> = new Set()
  private readonly confirmed: Map<string, CoreQueryResult> = new Map()
  private readonly versions: Map<string, number> = new Map()
  private readonly views: Map<string, ManagedDataSet> = new Map()
  private readonly taskIndex: Map<string, Map<string, CoreTask>> = new Map()
  private readonly rowIds: Map<string, Map<string, string>> = new Map()
  private readonly subscriptions: Map<string, number> = new Map()
  private readonly initialEvents: Map<string, CoreDataChangeEvent[]> = new Map()
  private readonly pending: PendingEdit[] = []
  private readonly writes: Set<Promise<void>> = new Set()
  private workspace: CoreWorkspace | undefined = undefined
  private cache: PageDataCache | undefined = undefined
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
  private saveTimer: number = -1
  private confirmedRevision: number = 0
  private savedRevision: number = 0
  private stopQueueIdle: () => void
  private configurationChanged = (): void => {
    if (this.closed) return
    this.scopeChanged = true; this.ready = false; this.generation = ''
    for (const id of this.subscriptions.values()) this.workspace?.unsubscribeQuery(id)
    this.subscriptions.clear()
    this.stopExternalUpdates()
    this.emitError(this.definitions[0].name, this.operationId(this.sequence, 'scope'), new Error('页面数据范围已变化，请重新打开页面'))
  }

  static create(context: Context, pageName: string, definitions: DataSetDefinition[]): DataSetManager {
    return new DataSetManager(context, pageName, definitions)
  }
  private constructor(context: Context, pageName: string, definitions: DataSetDefinition[]) {
    if (!definitions.length || new Set(definitions.map(item => item.name)).size !== definitions.length ||
      definitions.some(item => !item.name || item.query.type === 'notification')) throw new Error('页面数据集定义无效')
    this.context = context; this.pageName = pageName
    this.definitions = JSON.parse(JSON.stringify(definitions)) as DataSetDefinition[]
    this.stopQueueIdle = UserOperationQueue.watchIdle((): void => { this.scheduleSave() })
    AppConfigService.watchChanges(this.configurationChanged)
    DataSetManager.active.add(this)
  }
  static async flushAll(): Promise<void> { await Promise.all(Array.from(DataSetManager.active).map(item => item.flush())) }
  hasValidScope(): boolean { return !this.scopeChanged && !this.closed && !this.closing }
  isReady(): boolean { return this.ready && !this.scopeChanged && !this.closed }
  get(name: string): ManagedDataSet | undefined { return this.views.get(name) }
  getConfirmed(name: string): ManagedDataSet | undefined {
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
  private operationId(version: number, kind: string): string { return `dataset/${this.owner}/${version}/${kind}` }
  private eventVersion(id: string | null): number | undefined {
    const prefix = `dataset/${this.owner}/`
    if (!id?.startsWith(prefix)) return undefined
    const value = Number(id.slice(prefix.length).split('/')[0])
    return Number.isSafeInteger(value) && value >= 0 ? value : undefined
  }
  start(): Promise<void> {
    if (this.closed || this.closing) return Promise.reject(new Error('页面数据集已关闭'))
    if (!this.initialization) {
      this.initialization = this.initialize().catch((error: Error): never => { this.initialization = undefined; throw error })
    }
    return this.initialization
  }
  private async initialize(): Promise<void> {
    const config = await AppConfigService.load(this.context, false)
    if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
    const identity: CacheScope = { repositories: config.repos.map((repo): CacheScopeRepo => ({ id: repo.id, rootDirectory: repo.rootDirectory })),
      todoDefaults: config.todoDefaults, coreSettings: config.coreSettings, definitions: this.definitions }
    const scope = JSON.stringify(identity)
    this.cache = new PageDataCache(this.context, this.pageName, scope)
    try {
      const cached = await this.cache.read()
      if (cached && cached.length === this.definitions.length && this.definitions.every(definition =>
        cached.some(item => item.name === definition.name && item.type === definition.query.type))) {
        const restored = cached.map((item): RestoredDataSet => ({ name: item.name, data: restoreDataSet(item) }))
        for (const item of restored) {
          this.confirmed.set(item.name, item.data); this.versions.set(item.name, 0)
          this.rebuild(item.name, this.operationId(0, 'cache'), false)
        }
      }
    } catch (_) { /* 损坏或不可用缓存只影响快速恢复，初始查询继续执行。 */ }
    this.workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await this.connectExternalUpdates()
    await this.load(++this.sequence)
  }
  private async connectExternalUpdates(): Promise<void> {
    const workspace = this.workspace
    if (!workspace || this.externalWatch) return
    const id = await workspace.watchDataChanges((event: CoreDataChangeEvent): void => {
      if (this.eventVersion(event.operationId) === undefined) this.requestExternalRefresh()
    })
    if (!this.hasValidScope()) { workspace.stopWatchingDataChanges(id); return }
    this.externalWatch = id
    this.dayTimer = setInterval((): void => {
      const day = new Date().toDateString()
      if (day !== this.day) { this.day = day; this.requestExternalRefresh() }
    }, 60000)
  }
  private stopExternalUpdates(): void {
    if (this.externalWatch) this.workspace?.stopWatchingDataChanges(this.externalWatch)
    this.externalWatch = 0
    clearTimeout(this.externalTimer); this.externalTimer = -1
    clearInterval(this.dayTimer); this.dayTimer = -1
    this.externalPending = false
  }
  private requestExternalRefresh(): void {
    if (!this.hasValidScope()) return
    this.externalPending = true
    this.scheduleExternalRefresh()
  }
  private scheduleExternalRefresh(): void {
    if (!this.externalPending || !this.ready || this.externalRefreshing || this.externalTimer >= 0 || !this.hasValidScope()) return
    this.externalTimer = setTimeout((): void => {
      this.externalTimer = -1
      if (!this.hasValidScope()) return
      this.externalPending = false; this.externalRefreshing = true
      this.refresh().catch((error: Error): void => {
        if (this.hasValidScope()) this.emitError(this.definitions[0].name, this.operationId(this.sequence, 'refresh'), error)
      }).finally((): void => { this.externalRefreshing = false; this.scheduleExternalRefresh() })
    }, 50)
  }
  private async load(version: number): Promise<void> {
    const workspace = this.workspace
    if (!workspace) throw new Error('底层连接尚未建立')
    if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
    const operationId = this.operationId(version, 'refresh')
    this.generation = operationId
    for (const id of this.subscriptions.values()) workspace.unsubscribeQuery(id)
    this.subscriptions.clear(); this.initialEvents.clear()
    for (const definition of this.definitions) this.initialEvents.set(definition.name, [])
    try {
      for (const definition of this.definitions) {
        if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
        const result = await workspace.subscribeQuery(definition.query, (event: CoreDataChangeEvent): void => {
          if (this.closed || this.generation !== operationId) return
          const queue = this.initialEvents.get(definition.name)
          if (queue) queue.push(event)
          else this.onCoreDataChanged(definition.name, event, operationId)
        }, operationId)
        if (this.closed || this.generation !== operationId) {
          workspace.unsubscribeQuery(result.subscriptionId)
          throw new Error('页面数据范围已变化，请重新打开页面')
        }
        this.subscriptions.set(definition.name, result.subscriptionId)
        this.applyFullResult(definition.name, result.data, result.operationId ?? operationId)
        const events = this.initialEvents.get(definition.name) ?? []
        this.initialEvents.delete(definition.name)
        for (const event of events) this.onCoreDataChanged(definition.name, event, operationId)
      }
      this.ready = true
      for (const definition of this.definitions) this.publish({ name: definition.name, type: 'ready',
        version, dataVersion: this.views.get(definition.name)?.version, operationId, optimistic: false, added: [], removed: [], updated: [] })
      this.scheduleSave()
      this.scheduleExternalRefresh()
    } catch (error) {
      for (const id of this.subscriptions.values()) workspace.unsubscribeQuery(id)
      this.subscriptions.clear(); this.initialEvents.clear()
      this.generation = ''; this.ready = false
      this.emitError(this.definitions[0].name, operationId, error as Error)
      throw error as Error
    }
  }
  private applyFullResult(name: string, data: CoreQueryResult, operationId: string): void {
    this.confirmed.set(name, restoreDataSet(cacheDataSet(name, data)))
    this.versions.set(name, this.eventVersion(operationId) ?? 1)
    this.confirmedRevision++
    this.rebuild(name, operationId, false)
  }
  async refresh(): Promise<void> {
    await this.start()
    if (this.closing || this.closed) throw new Error('页面数据集已关闭')
    if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
    const version = ++this.sequence
    const work = UserOperationQueue.submit(async (): Promise<void> => { await this.load(version) })
    this.track(work)
    return work
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
    const metadata = Array.from(this.confirmed.values()).filter(item => item.type === 'file')
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
    await this.submit(edit)
  }
  private edit(name: string, kind: 'update' | 'remove' | 'create' | 'move', task: CoreTask, changes: TaskModification[], sourceVersion?: string): PendingEdit {
    if (this.closing || this.closed || !this.ready) throw new Error('页面数据集当前不可编辑')
    const version = ++this.sequence
    return { id: this.operationId(version, kind), version, name, kind, key: taskKey(task),
      sourceVersion: sourceVersion ?? task.fileVersion, changes: JSON.parse(JSON.stringify(changes)) as TaskModification[],
      observed: new Set(), identityFrames: new Set(), missingFrames: new Set() }
  }
  private submit(edit: PendingEdit): Promise<void> {
    this.pending.push(edit)
    for (const definition of this.definitions) this.rebuild(definition.name, edit.id, true)
    const work = UserOperationQueue.submit(async (): Promise<void> => {
      const workspace = this.workspace
      if (!workspace) throw new Error('底层连接不可用')
      try {
        if (this.scopeChanged) throw new Error('页面数据范围已变化，请重新打开页面')
        for (const id of this.subscriptions.values()) {
          if (await workspace.querySubscriptionStatus(id) !== 'current') {
            this.requestExternalRefresh()
            throw new Error('数据订阅已失效，正在刷新页面')
          }
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
        // Native 保证本次产生的数据事件先于 Promise 完成；没有命中变化的操作也在此结束阶段。
        this.finishEdit(edit, false)
      } catch (error) {
        this.finishEdit(edit, true)
        this.emitError(edit.name, edit.id, error as Error, edit.key, edit.changes)
        throw error as Error
      }
    })
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
    for (const definition of this.definitions) {
      if (!failed && !this.scopeChanged) this.versions.set(definition.name, Math.max(this.versions.get(definition.name) ?? 0, edit.version))
      this.rebuild(definition.name, edit.id, this.pending.length > 0)
    }
    if (!failed) this.confirmedRevision++
    this.publish({ name: edit.name, type: 'complete', version: edit.version, operationId: edit.id,
      optimistic: false, dataVersion: this.views.get(edit.name)?.version, added: [], removed: [], updated: [], succeeded: !failed, result: this.scopeChanged ? undefined : this.getConfirmed(edit.name), message: failed ? '提交失败' : undefined })
    this.scheduleSave()
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
    this.confirmedRevision++
    const identities: DataSetIdentity[] = event.changes.filter(change => !!change.before && !!change.after).map((change): DataSetIdentity => ({
      before: taskKeyFromRaw(change.before!.task.fullPath.repoId, change.before!.task.id), after: taskKeyFromRaw(change.after!.task.fullPath.repoId, change.after!.task.id) }))
    if (createdIdentity) identities.push(createdIdentity)
    const removedRecords = event.changes.filter(change => !!change.before && !change.after).map(change => taskKeyFromRaw(change.before!.task.fullPath.repoId, change.before!.task.id))
    const addedRecords = event.changes.filter(change => !change.before && !!change.after).map(change => taskKeyFromRaw(change.after!.task.fullPath.repoId, change.after!.task.id))
    this.rebuild(name, operationId, this.pending.length > 0, identities, removedRecords, addedRecords)
    this.scheduleSave()
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
    for (const listener of this.listeners) { try { listener(event) } catch (_) { console.error('页面数据监听处理失败') } }
  }
  private emitError(name: string, id: string, error: Error, targetKey?: string, rejectedChanges?: TaskModification[]): void {
    this.publish({ name, type: 'error', version: this.eventVersion(id) ?? this.sequence, operationId: id,
      optimistic: false, added: [], removed: [], updated: [], message: error.message, targetKey, rejectedChanges })
  }
  private scheduleSave(): void {
    if (!this.ready || this.closed || this.saveTimer >= 0 || this.pending.length || this.writes.size ||
      !UserOperationQueue.isIdle() || this.confirmedRevision <= this.savedRevision) return
    this.saveTimer = setTimeout((): void => { this.saveTimer = -1; if (this.confirmedRevision <= this.savedRevision) return; this.flush().catch((error: Error): void => this.emitError(this.definitions[0].name, this.operationId(this.sequence, 'cache'), error)) }, 250)
  }
  async flush(): Promise<void> {
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1 }
    // 只在所有用户修改及其事件处理完成的边界取快照，不保存任何中间阶段。
    while (true) {
      await UserOperationQueue.whenIdle()
      await Promise.all(Array.from(this.writes).map(work => work.catch((): void => {})))
      if (!this.ready || !this.cache || this.confirmed.size !== this.definitions.length) return
      const revision = this.confirmedRevision
      const dataSets = this.definitions.map((definition: DataSetDefinition) => {
        const result = cacheDataSet(definition.name, this.confirmed.get(definition.name)!)
        result.version = this.versions.get(definition.name) ?? 0
        return result
      })
      const result = await this.cache.write(dataSets, (): boolean => this.ready && UserOperationQueue.isIdle() && this.pending.length === 0 &&
        this.writes.size === 0 && this.confirmedRevision === revision)
      if (result === 'deferred') continue
      this.savedRevision = Math.max(this.savedRevision, revision)
      return
    }
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
      for (const id of this.subscriptions.values()) this.workspace?.unsubscribeQuery(id)
      this.subscriptions.clear()
      this.closed = true
      this.stopExternalUpdates()
      await this.flush()
    } finally {
      this.closed = true
      this.stopExternalUpdates()
      for (const id of this.subscriptions.values()) this.workspace?.unsubscribeQuery(id)
      this.subscriptions.clear(); this.listeners.clear(); this.stopQueueIdle(); AppConfigService.stopWatchingChanges(this.configurationChanged); DataSetManager.active.delete(this)
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

interface OrderedRecord { readonly orderKey?: QueryOrderPart[] }
// 键与方向均由 Core 给出；这里只比较标量，不解释表达式或领域字段。
function compareRecords(left: OrderedRecord, right: OrderedRecord): number {
  if (!left.orderKey || !right.orderKey) return 0
  for (let index = 0; index < Math.min(left.orderKey.length, right.orderKey.length); index++) {
    const a = left.orderKey[index]; const b = right.orderKey[index]
    if (a.value === null && b.value === null) continue
    if (a.value === null || b.value === null) {
      const value: number = a.value === null ? -1 : 1
      if (a.missingLast) return -value
      return a.descending ? -value : value
    }
    let value: number = 0
    if (typeof a.value === 'number' && typeof b.value === 'number') value = a.value < b.value ? -1 : a.value > b.value ? 1 : 0
    if (typeof a.value === 'string' && typeof b.value === 'string') value = a.value < b.value ? -1 : a.value > b.value ? 1 : 0
    if (value) return a.descending ? -value : value
  }
  return 0
}
