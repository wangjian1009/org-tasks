import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { CoreTask, CoreOrgFile, CoreDataChangeEvent, CoreTaskModification, CoreRefileTarget, NativeCoreService } from './NativeCoreService'
import { AppConfigService } from './AppConfigService'
import { NotebookService } from './NotebookService'
import { CoreDataChangeService } from './CoreDataChangeService'
import { TaskEditorDataManager, TaskEditorDataSet, TaskEditorChange, TaskInlineMissingError } from './TaskEditorDataManager'
import { projectTaskFields } from './PageDataProjection'
import { PageTaskSnapshot, taskRecord } from './PageDataSnapshot'
import { samePageTask } from './PageDataEquality'

export interface ProjectFileSnapshot { file: CoreOrgFile | undefined; tasks: CoreTask[] }
interface ProjectEdit { id: string; data: TaskEditorDataSet; source: CoreTask; changes: CoreTaskModification[] }

// 项目只持有当前文件的运行时数据集：不读取或写入页面磁盘缓存。
export class ProjectDataManager extends TaskEditorDataManager {
  readonly repoId: string
  readonly path: string
  private readonly projectContext: Context
  private readonly owner: string = `project/${util.generateRandomUUID()}/`
  private sequence: number = 0
  private confirmed: CoreTask[] = []
  private tasks: Map<string, CoreTask> = new Map()
  private bindings: Map<string, TaskEditorDataSet> = new Map()
  private boundIds: Map<string, TaskEditorDataSet> = new Map()
  private recordIds: Map<string, string> = new Map()
  private aliases: Map<string, string> = new Map()
  private retired: Set<string> = new Set()
  private edits: ProjectEdit[] = []
  private tail: Promise<void> = Promise.resolve()
  private readingFile: Promise<ProjectFileSnapshot> | undefined = undefined
  private readGeneration: number = 0
  private timer: number = -1
  private closed: boolean = false
  private seen: Set<string> = new Set()
  private receipts: Map<string, () => void> = new Map()
  private stopEvents: () => void

  constructor(context: Context, repoId: string, path: string) {
    super(context, true)
    this.projectContext = context; this.repoId = repoId; this.path = path
    this.stopEvents = CoreDataChangeService.watchEvents(event => { this.receive(event) })
  }

  private async readFile(): Promise<ProjectFileSnapshot> {
    if (this.readingFile) return await this.readingFile
    const generation = this.readGeneration
    const reading = (async (): Promise<ProjectFileSnapshot> => {
      const config = await AppConfigService.load(this.projectContext, false)
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      await CoreDataChangeService.connect(workspace)
      const file = await NotebookService.open(config.repos, this.repoId, this.path, config.todoDefaults, config.coreSettings)
      if (generation !== this.readGeneration) return await this.readFile()
      return { file, tasks: file?.nodes() ?? [] }
    })()
    this.readingFile = reading
    try { return await reading } finally { if (this.readingFile === reading) this.readingFile = undefined }
  }
  async load(): Promise<ProjectFileSnapshot> {
    const snapshot = await this.readFile()
    if (!this.closed) { this.confirmed = snapshot.tasks; this.rebuild() }
    return snapshot
  }
  dataSet(task: CoreTask): TaskEditorDataSet {
    const existing = this.dataSetForTaskId(task.taskId ?? task.id)
    if (existing) return existing
    throw new TaskInlineMissingError()
  }
  dataSetForTaskId(taskId: string): TaskEditorDataSet | undefined {
    const task = this.tasks.get(taskId) ?? this.tasks.get(this.aliases.get(taskId) ?? taskId)
    if (!task) return undefined
    const key = `project-task/${util.generateRandomUUID()}`
    let data = this.boundIds.get(task.id)
    if (!data) {
      data = new TaskEditorDataSet(key, task)
      this.bindings.set(key, data); this.recordIds.set(key, task.id); this.boundIds.set(task.id, data)
    }
    return data
  }
  snapshot(data: TaskEditorDataSet): CoreTask | undefined { if (this.retired.has(data.key)) return undefined; return this.tasks.get(this.recordIds.get(data.key) ?? data.task.id) }
  async current(data: TaskEditorDataSet): Promise<CoreTask> {
    const task = this.snapshot(data)
    if (!task) throw new TaskInlineMissingError()
    return task
  }
  watchDataSet(data: TaskEditorDataSet, listener: (change: TaskEditorChange) => void): () => void {
    data.listeners.add(listener)
    const task = this.snapshot(data)
    listener(task ? { task } : { removed: true })
    return (): void => { data.listeners.delete(listener) }
  }
  async modify(data: TaskEditorDataSet, source: CoreTask, changes: CoreTaskModification[]): Promise<void> {
    if (!changes.length) return
    if (this.closed || !this.snapshot(data)) throw new TaskInlineMissingError()
    const edit: ProjectEdit = { id: `${this.owner}${++this.sequence}`, data, source, changes }
    this.edits.push(edit); this.rebuild()
    const work = this.tail.then(async (): Promise<void> => {
      try {
        if (this.retired.has(data.key)) throw new TaskInlineMissingError()
        const id = this.recordIds.get(data.key)
        const task = this.confirmed.find(item => item.id === id)
        if (!task) throw new TaskInlineMissingError()
        const config = await AppConfigService.load(this.projectContext, false)
        const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
        await CoreDataChangeService.connect(workspace)
        const positional = changes.some(change => change.field === 'CHECKLIST' || change.field === 'LINK' || change.field === 'CONTENT_BLOCK')
        await workspace.executeTaskOperations({ operationId: edit.id,
          operations: [{ type: 'Modification', data: { path: task.fullPath, modifications: changes } }],
          fileVersions: [{ repoId: task.repoId, file: task.filePath, version: positional ? source.fileVersion : task.fileVersion }] })
        this.readGeneration++; this.readingFile = undefined
        const result = await this.readFile()
        // 改名的身份只来自提交事件，不根据标题或节点顺序猜测对应关系。
        if (!result.tasks.some(item => item.id === this.recordIds.get(data.key)) && !this.seen.has(edit.id)) {
          await new Promise<void>(resolve => { this.receipts.set(edit.id, resolve) })
        }
        this.confirmed = result.tasks
        this.edits.splice(this.edits.indexOf(edit), 1); this.rebuild()
      } catch (error) {
        const index = this.edits.indexOf(edit)
        if (index >= 0) this.edits.splice(index, 1)
        try { this.confirmed = (await this.readFile()).tasks } catch (_) { /* 保留最近确认数据及后续用户字段。 */ }
        this.rebuild()
        const message = (error as Error).message
        for (const listener of data.listeners) listener({ task: this.snapshot(data), error: message, rejectedChanges: changes,
          blocked: ['版本', '已变化'].some(value => message.includes(value)) })
      } finally { this.seen.delete(edit.id); this.receipts.delete(edit.id) }
    })
    this.tail = work.catch((): void => {})
  }
  private rebuild(): void {
    const tasks = new Map<string, CoreTask>()
    for (const task of this.confirmed) tasks.set(task.id, task)
    for (const edit of this.edits) {
      const id = this.recordIds.get(edit.data.key)
      const task = id ? tasks.get(id) : undefined
      if (task) tasks.set(id!, projectTaskFields(task, edit.changes))
    }
    for (const task of Array.from(tasks.values())) if (task.taskId) tasks.set(task.taskId, task)
    this.tasks = tasks
    this.boundIds = new Map()
    for (const data of this.bindings.values()) {
      const task = this.snapshot(data)
      const changed = task ? data.removed || !samePageTask(data.task, task) : !data.removed
      data.removed = !task
      if (task) { data.task = task; data.recordKey = JSON.stringify([task.repoId, task.id]); this.boundIds.set(task.id, data) }
      if (changed) for (const listener of data.listeners) listener(task ? { task } : { removed: true })
    }
  }
  private receive(event: CoreDataChangeEvent): void {
    if (this.closed || event.repoId !== this.repoId || (event.files !== null &&
      !event.files?.some(file => file.after.path === this.path) && !event.changes.some(change =>
        change.before?.task.fullPath.file === this.path || change.after?.task.fullPath.file === this.path))) return
    this.readGeneration++; this.readingFile = undefined
    const beforeIds = new Map(this.recordIds)
    const beforeAliases = new Map(this.aliases)
    for (const data of this.bindings.values()) {
      const id = beforeIds.get(data.key)
      const change = event.changes.find(item => item.before?.task.id === id && item.before?.task.fullPath.file === this.path)
      const after = change?.after?.task.fullPath.file === this.path ? change.after.task : undefined
      if (change && !after) this.retired.add(data.key)
      if (after && !this.retired.has(data.key)) {
        this.recordIds.set(data.key, after.id)
        if (id) this.aliases.set(id, after.id)
        if (data.task.taskId) this.aliases.set(data.task.taskId, after.id)
      }
    }
    beforeAliases.forEach((id: string, alias: string): void => {
      const after = event.changes.find(item => item.before?.task.id === id)?.after?.task
      if (after?.fullPath.file === this.path) this.aliases.set(alias, after.id)
    })
    this.confirmed = this.confirmed.flatMap((task: CoreTask): CoreTask[] => {
      const change = event.changes.find(item => item.before?.task.id === task.id && item.before?.task.fullPath.file === this.path)
      if (!change) return [task]
      const after = change.after?.task.fullPath.file === this.path ? change.after.task : undefined
      if (!after) return []
      const record = taskRecord(task)
      record.value.id = after.id; record.value.fullPath = after.fullPath; record.value.fileVersion = after.fileVersion
      return [new PageTaskSnapshot(record)]
    })
    const version = event.files?.find(file => file.after.path === this.path)?.afterVersion
    if (version) this.confirmed = this.confirmed.map((task: CoreTask): CoreTask => {
      if (task.fileVersion === version) return task
      const record = taskRecord(task); record.value.fileVersion = version; return new PageTaskSnapshot(record)
    })
    this.rebuild()
    if (event.operationId?.startsWith(this.owner)) {
      this.seen.add(event.operationId); this.receipts.get(event.operationId)?.(); return
    }
    if (this.timer >= 0) return
    this.timer = setTimeout((): void => {
      this.timer = -1
      this.load().catch((error: Error): void => { for (const data of this.bindings.values()) for (const listener of data.listeners) listener({ error: error.message }) })
    }, 0)
  }
  async targets(): Promise<CoreRefileTarget[]> { await this.tail; return await super.targets() }
  async moveDataSet(data: TaskEditorDataSet, _source: CoreTask, target: CoreRefileTarget): Promise<void> {
    await this.tail
    await super.moveDataSet(data, await this.current(data), target)
  }
  async refresh(_data?: TaskEditorDataSet): Promise<void> { await this.load() }
  async close(): Promise<void> {
    await this.tail
    this.closed = true; clearTimeout(this.timer); this.stopEvents()
  }
}
