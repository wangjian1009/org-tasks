import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { DataSetManager, DataSetDefinition, DataSetEvent } from './DataSetManager'
import { TaskEditorDataManager } from './TaskEditorDataManager'
import { FileTargetService, FileTargetKind } from './FileTargetService'
import { overviewTaskQuery, todayPriorityQuery, plannedRegionQuery, overviewTitle, TaskOverview } from './TaskViewQueries'
import { CoreTask, CoreTaskQueryResult, CoreTaskPath, CoreRefileTarget, CoreTaskPlanningEdit, NativeCoreService } from './NativeCoreService'
import { TaskRegionData } from '../ui/TaskRegionPresentation'
import { plannedRegionOptions } from '../ui/PlannedPresentation'
import { InboxService, InboxAction } from './InboxService'
import { CaptureService } from './CaptureService'
import { LogbookService } from './LogbookService'

export interface TaskPageSnapshot {
  scope: number
  tasks: CoreTask[]
  recent: CoreTask[]
  priorityOrder: string[]
  tagOptions: string[]
  tagGroups: string[][]
  regionOptions: TaskRegionData[]
  selectedRegion: TaskRegionData | null
  needsConfiguration: boolean
  ready: boolean
  revision: number
  message: string
}

// 每个页面独立持有固定查询与提交队列；配置和计划筛选变化在管理层更换数据集。
export class TaskPageDataManager {
  private readonly context: Context
  readonly view: TaskOverview | 'inbox'
  private manager: DataSetManager | undefined = undefined
  private displayedManager: DataSetManager | undefined = undefined
  private runningGeneration: number = -1
  private stopData: (() => void) | undefined = undefined
  private readonly listeners: Set<(snapshot: TaskPageSnapshot) => void> = new Set()
  private editors: Map<string, TaskEditorDataManager> = new Map()
  private running: Promise<void> | undefined = undefined
  private generation: number = 0
  private closed: boolean = false
  private configured: boolean = true
  private selected: TaskRegionData | null = null
  private timer: number = -1
  private publishTimer: number = -1
  private message: string = ''
  private revision: number = 0
  private displaySet: string = 'tasks'
  private hasRange: boolean = false
  private configChanged = (): void => { this.replace() }

  constructor(context: Context, view: TaskOverview | 'inbox') {
    this.context = context; this.view = view
    AppConfigService.watchChanges(this.configChanged)
  }
  subscribe(listener: (snapshot: TaskPageSnapshot) => void): () => void {
    this.listeners.add(listener)
    return (): void => { this.listeners.delete(listener) }
  }
  dataSets(): DataSetManager | undefined { return this.displayedManager ?? this.manager }
  editor(name: string = 'tasks'): TaskEditorDataManager {
    if (name === 'tasks') name = this.displaySet
    const manager = this.displayedManager ?? this.manager
    if (!manager) throw new Error('页面数据尚未建立')
    let editor = this.editors.get(name)
    if (!editor) { editor = TaskEditorDataManager.managed(manager, name); this.editors.set(name, editor) }
    return editor
  }
  private replace(): void {
    if (this.closed) return
    this.generation++
    this.stopData?.(); this.stopData = undefined
    const previous = this.manager; this.manager = undefined
    previous?.close().catch((): void => { console.error('保存页面数据失败') })
    clearTimeout(this.timer)
    this.timer = setTimeout((): void => { this.timer = -1; this.start() }, 0)
  }
  async selectRegion(region: TaskRegionData | null): Promise<void> {
    this.selected = region; this.replace()
    while (!this.closed) {
      const generation = this.generation
      await this.start()
      if (generation === this.generation) return
    }
  }
  start(): Promise<void> {
    if (this.closed) return Promise.resolve()
    if (this.running && this.runningGeneration === this.generation) return this.running
    const generation = this.generation
    this.runningGeneration = generation
    const running = this.open(generation).catch((error: Error): void => {
      if (!this.closed && generation === this.generation) { this.message = error.message; this.publish() }
    }).finally((): void => {
      if (this.running !== running) return
      this.running = undefined
      if (!this.closed && generation !== this.generation) this.start()
    })
    this.running = running
    return running
  }
  async refresh(): Promise<void> {
    await this.start()
    if (this.manager?.hasValidScope()) await this.manager.refresh()
    else { this.replace(); await this.start() }
  }
  private async open(generation: number): Promise<void> {
    if (this.manager?.hasValidScope()) { await this.manager.start(); this.publish(); return }
    const config = await AppConfigService.load(this.context, false)
    const definitions: DataSetDefinition[] = []
    this.configured = true
    if (this.view === 'inbox' || this.view === 'someday' || this.view === 'memo') {
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      const target = FileTargetService.prepare(config, await workspace.repos(), this.view as FileTargetKind)
      this.configured = !!target
      if (target) definitions.push({ name: 'tasks', query: target.task }, { name: 'target', query: target.file })
      if (this.view === 'inbox') definitions.push({ name: 'recent', query: { type: 'task', query: {
        expression: 'cr.ge.-2d cr.le.today .o.created', excludedFiles: target ? [target.reference] : [] } } })
    } else {
      definitions.push({ name: 'tasks', query: { type: 'task', query: overviewTaskQuery(this.view) } })
      if (this.view === 'today') definitions.push({ name: 'priority', query: { type: 'task', query: todayPriorityQuery() } })
      if (this.view === 'planned' && this.selected) {
        definitions[0].name = 'range'
        definitions.push({ name: 'tasks', query: plannedRegionQuery(this.selected) })
      }
    }
    // 未配置文件入口也保留文件数据集，以便缓存范围与后续配置切换有明确生命周期。
    definitions.push({ name: 'files', query: { type: 'file', query: {} } })
    if (this.closed || generation !== this.generation) return
    const manager = DataSetManager.create(this.context, this.view === 'inbox' ? '收件箱' : overviewTitle(this.view), definitions)
    this.manager = manager; this.hasRange = definitions.some(item => item.name === 'range'); this.message = ''
    this.stopData = manager.subscribe((event: DataSetEvent): void => {
      if (this.closed || manager !== this.manager) return
      if (event.type === 'error' && !event.targetKey) this.message = event.message ?? '页面数据更新失败'
      if (event.type !== 'complete' && event.type !== 'error') this.message = ''
      this.schedulePublish()
    })
    await manager.start()
    if (this.closed || generation !== this.generation) return
    this.publish()
  }
  private taskResult(name: string): CoreTaskQueryResult {
    const data = this.manager?.get(name)?.data
    return data?.type === 'task' ? data.result : { tasks: [], categories: [] }
  }
  private schedulePublish(): void {
    if (this.closed || this.publishTimer >= 0) return
    this.publishTimer = setTimeout((): void => { this.publishTimer = -1; this.publish() }, 0)
  }
  private publish(): void {
    if (this.closed || (!this.manager?.get('files') && !this.message)) return
    const target = this.manager?.get('target')?.data
    const file = target?.type === 'file' ? target.result[0] : undefined
    const options = this.view === 'planned' ? plannedRegionOptions(this.taskResult(this.hasRange ? 'range' : 'tasks').tasks) : []
    const selected = this.selected ? (this.manager?.isReady() ? options.find(item => item.key === this.selected?.key) ?? null : this.selected) : null
    if (this.selected && this.manager?.isReady() && !selected) this.selected = null
    this.displaySet = this.view === 'planned' && this.hasRange && !selected ? 'range' : 'tasks'
    const tasks = this.taskResult(this.displaySet).tasks
    if (this.displayedManager !== this.manager) { this.displayedManager = this.manager; this.editors.clear() }
    const snapshot: TaskPageSnapshot = { scope: this.generation, tasks, recent: this.taskResult('recent').tasks,
      priorityOrder: this.taskResult('priority').tasks.map(task => task.id), tagOptions: this.view === 'memo' ? file?.tagOptions ?? [] : [],
      tagGroups: this.view === 'memo' ? file?.tagGroups ?? [] : [], regionOptions: options, selectedRegion: selected,
      needsConfiguration: !this.configured || ((this.view === 'inbox' || this.view === 'memo' || this.view === 'someday') && !file),
      ready: this.manager?.isReady() ?? false, revision: ++this.revision, message: this.message }
    for (const listener of this.listeners) listener(snapshot)
  }
  current(task: CoreTask, name: string = 'tasks'): CoreTask | undefined { return this.manager?.findTask(name, JSON.stringify([task.repoId, task.id])) }
  async remove(task: CoreTask): Promise<void> { await this.manager?.remove('tasks', JSON.stringify([task.repoId, task.id])) }
  async targets(): Promise<CoreRefileTarget[]> { await this.start(); return await this.manager!.moveTargets() }
  async perform(tasks: CoreTask[], action: InboxAction, target?: CoreRefileTarget, date?: CoreTaskPlanningEdit | null): Promise<void> {
    await this.start()
    await this.manager!.runOperation('tasks', async (operationId: string): Promise<void> => {
      await InboxService.performMany(this.context, tasks, action, target, date, operationId)
    })
  }
  async merge(tasks: CoreTask[]): Promise<CoreTaskPath> {
    await this.start()
    let path: CoreTaskPath | undefined = undefined
    await this.manager!.runOperation('tasks', async (operationId: string): Promise<void> => { path = await InboxService.merge(this.context, tasks, operationId) })
    return path!
  }
  async capture(title: string): Promise<void> {
    await this.start()
    await this.manager!.runOperation('tasks', async (operationId: string): Promise<void> => { await CaptureService.save(this.context, title, operationId) })
  }
  async logbook(tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> {
    await this.start()
    await this.manager!.runOperation('tasks', async (operationId: string): Promise<void> => {
      if (action === 'restore') await LogbookService.restore(this.context, tasks, operationId)
      else await LogbookService.remove(this.context, tasks, operationId)
    })
  }
  async close(): Promise<void> {
    this.closed = true; this.generation++
    clearTimeout(this.timer); clearTimeout(this.publishTimer)
    AppConfigService.stopWatchingChanges(this.configChanged)
    this.stopData?.(); this.listeners.clear()
    await this.manager?.close()
  }
}
