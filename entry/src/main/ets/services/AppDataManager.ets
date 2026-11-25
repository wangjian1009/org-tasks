import { localizedText } from '../ui/LocalizedText'
import { ReminderManager } from './ReminderManager'
import { TaskRegionData } from '../ui/TaskRegionPresentation'
import { TrashService } from './TrashService'
import { TrashSettingsService } from './TrashSettingsService'
import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { DataSet, DataSetDefinition, DataSetManager } from './DataSetManager'
import { CoreOrgFileRef, CoreQuery, CoreQueryResult } from './NativeCoreService'
import { FileTargetKind, FileTargetService, configuredSpecialFileExclusions, fileTargetRepository, systemTrashExclusions } from './FileTargetService'
import { TaskView, overviewTaskQuery, plannedRegionQuery, todayAttentionQuery, todayPriorityQuery } from './TaskViewQueries'

export const APP_DATA_SET_NAMES: string[] = ['todayTasks', 'todayPriority', 'files', 'categories', 'todayAttention',
  'planned', 'anytime', 'waiting', 'logbook', 'projects', 'trash', 'badgeDeadline',
  'inboxTasks', 'inboxFile', 'somedayTasks', 'somedayFile', 'memoTasks', 'memoFile', 'inboxRecent', 'plannedFiltered', 'trashExpired', 'notebookFiles', 'reminderTasks', 'appLinkTasks']

// 只定义 Core 查询；相同业务范围只保留一个 DataSet，各项共享同一批文件加载。
export function appDataDefinitions(config: AppConfig, trashRetentionDays: number): DataSetDefinition[] {
  const trash = systemTrashExclusions(config)
  const task = (name: string, query: CoreQuery): DataSetDefinition => {
    if (query.type === 'task' && trash.files.length) query.query.excludeFiles = trash.files.slice()
    return { name, query, repositoryBindings: trash.repositoryBindings }
  }
  const definitions: DataSetDefinition[] = [
    task('todayTasks', { type: 'task', query: overviewTaskQuery('today') }),
    task('todayPriority', { type: 'task', query: todayPriorityQuery() }),
    { name: 'files', query: { type: 'file', query: {} } },
    { name: 'notebookFiles', query: { type: 'file', query: { includeIgnored: true } } },
    task('todayAttention', { type: 'task', query: todayAttentionQuery() }),
    task('planned', { type: 'task', query: overviewTaskQuery('planned') }),
    task('plannedFiltered', plannedRegionQuery(null)),
    task('anytime', { type: 'task', query: overviewTaskQuery('anytime') }),
    task('waiting', { type: 'task', query: overviewTaskQuery('waiting') }),
    task('logbook', { type: 'task', query: overviewTaskQuery('logbook') }),
    { name: 'projects', query: { type: 'file', query: { isProject: true, excludeFiles: trash.files } }, repositoryBindings: trash.repositoryBindings }
  ]
  const special = configuredSpecialFileExclusions(config)
  definitions.push({ name: 'categories', query: { type: 'file', query: { excludeFiles: special.files } }, repositoryBindings: special.repositoryBindings })
  if (trash.files.length) definitions.push(
    { name: 'trash', query: { type: 'task', query: { expression: '.o.deleted', includeFiles: trash.files } }, repositoryBindings: trash.repositoryBindings },
    { name: 'trashExpired', query: trashExpirationQuery(trash.files, trashRetentionDays), repositoryBindings: trash.repositoryBindings })
  const inbox = FileTargetService.prepareConfigured(config, 'inbox')
  definitions.push({ name: 'badgeDeadline', query: { type: 'task', query: { expression: 'it.todo d.lt.tomorrow',
    excludeFiles: (inbox ? [inbox.reference] : []).concat(trash.files) } },
    repositoryBindings: (inbox?.repositoryBindings ?? []).concat(trash.repositoryBindings) })
  definitions.push(task('inboxRecent', { type: 'task', query: { expression: 'cr.ge.-2d cr.le.today .o.created' } }))
  const recent = definitions[definitions.length - 1]
  if (recent.query.type === 'task') recent.query.query.excludeFiles = (inbox ? [inbox.reference] : []).concat(trash.files)
  recent.repositoryBindings = (inbox?.repositoryBindings ?? []).concat(trash.repositoryBindings)
  const kinds: FileTargetKind[] = ['inbox', 'someday', 'memo']
  for (const kind of kinds) {
    const target = FileTargetService.prepareConfigured(config, kind)
    if (target) definitions.push({ name: `${kind}Tasks`, query: target.task, repositoryBindings: target.repositoryBindings },
      { name: `${kind}File`, query: target.file, repositoryBindings: target.repositoryBindings })
  }
  definitions.push(task('reminderTasks', { type: 'task', query: { expression: 'it.todo has.reminder reminder.ge.-30min o.reminder' } }))
  definitions.push(task('appLinkTasks', { type: 'task', query: { expression: 'has.app' } }))
  return definitions
}

function trashExpirationQuery(files: CoreOrgFileRef[] | undefined, days: number): CoreQuery {
  return { type: 'task', query: { expression: `deleted.lt.-${days}d`, includeFiles: files } }
}

// 主界面会话共享的数据入口；组件只解除自己的订阅，不关闭全局管理器。
export class AppDataManager {
  private static current: AppDataManager | undefined = undefined
  readonly manager: DataSetManager
  private readonly context: Context
  private config: AppConfig | undefined = undefined
  private trashCleaning: Promise<void> | undefined = undefined

  static get active(): AppDataManager | undefined { return AppDataManager.current }
  static shared(context: Context): AppDataManager {
    if (!AppDataManager.current) AppDataManager.current = new AppDataManager(context)
    return AppDataManager.current
  }
  static async close(): Promise<void> {
    const current = AppDataManager.current
    AppDataManager.current = undefined
    if (current) {
      await ReminderManager.stop()
      await current.manager.close()
    }
  }
  private constructor(context: Context) {
    this.context = context
    this.manager = DataSetManager.create(context, 'app', async (config: AppConfig): Promise<DataSetDefinition[]> => {
      this.config = config
      const days = await TrashSettingsService.retentionDays(context).catch((): number => 30)
      return appDataDefinitions(config, days)
    }, { names: APP_DATA_SET_NAMES, uncachedDataSets: ['reminderTasks'] })
    ReminderManager.register(context, this.manager.dataSet('reminderTasks'))
  }
  get configuration(): AppConfig | undefined { return this.config }
  dataSet(name: string): DataSet { return this.manager.dataSet(name) }
  async start(): Promise<void> {
    try { await this.manager.start() }
    finally { ReminderManager.start() }
  }
  taskDataSet(view: TaskView): DataSet {
    const name = view === 'today' ? 'todayTasks' : view === 'memo' || view === 'someday' ? `${view}Tasks` : view
    return this.dataSet(name)
  }
  async selectPlannedRegion(region: TaskRegionData): Promise<void> {
    await this.start()
    const trash = systemTrashExclusions(this.config!)
    const query = plannedRegionQuery(region)
    if (query.type === 'task' && trash.files.length) query.query.excludeFiles = trash.files
    try { await this.manager.setQuery('plannedFiltered', query, trash.repositoryBindings) }
    catch (error) { this.dataSet('plannedFiltered').reportError(error as Error) }
  }
  async cleanTrash(): Promise<void> {
    if (this.trashCleaning) return this.trashCleaning
    const work = this.performTrashCleanup().finally((): void => { if (this.trashCleaning === work) this.trashCleaning = undefined })
    this.trashCleaning = work
    return work
  }
  private async performTrashCleanup(): Promise<void> {
    await this.start()
    const days = await TrashSettingsService.retentionDays(this.context)
    const trash = this.dataSet('trash')
    if (trash.query?.type !== 'task') throw new Error(localizedText($r('app.string.text_system_repository_not_yet_initialized')))
    const query = trashExpirationQuery(trash.query.query.includeFiles, days)
    const expired = this.dataSet('trashExpired')
    if (JSON.stringify(expired.query) !== JSON.stringify(query)) await this.manager.setQuery('trashExpired', query, trash.repositoryBindings)
    else if (expired.error) await expired.refresh()
    if (!expired.isReady() || expired.version === 0 || expired.error) throw new Error(expired.error || localizedText($r('app.string.text_obsolete_records_not_read_yet_completed')))
    const data = expired.data
    if (data?.type === 'task' && data.result.tasks.length) {
      await trash.operate((operationId: string): Promise<void> => TrashService.perform(this.context, data.result.tasks, 'clear', operationId))
      await trash.settle()
    }
  }
  async retryFailed(): Promise<void> {
    const failed = APP_DATA_SET_NAMES.map(name => this.dataSet(name)).filter(dataSet => !!dataSet.query && !!dataSet.error)
    await Promise.all(failed.map(dataSet => dataSet.refresh()))
  }
  private hasTarget(kind: FileTargetKind): boolean { return !!this.config && !!fileTargetRepository(this.config, kind) }
  targetCount(kind: FileTargetKind, confirmed: boolean = false): number {
    if (!this.hasTarget(kind)) return -1
    const tasks = this.dataSet(`${kind}Tasks`), file = this.dataSet(`${kind}File`)
    if (!tasks.hasValidScope() || !file.hasValidScope()) return -1
    const taskData = confirmed ? tasks.getConfirmed()?.data : tasks.data
    const fileData = confirmed ? file.getConfirmed()?.data : file.data
    if (taskData?.type !== 'task' || fileData?.type !== 'file') return -1
    return FileTargetService.result(taskData, fileData)?.tasks.length ?? -1
  }
  badgeCount(): number | undefined {
    const deadline = this.dataSet('badgeDeadline')
    if (!deadline.isReady() || deadline.error) return undefined
    if (this.hasTarget('inbox') && ['inboxTasks', 'inboxFile'].some(name => !this.dataSet(name).isReady() || !!this.dataSet(name).error)) return undefined
    const data: CoreQueryResult | undefined = deadline.getConfirmed()?.data
    return data?.type === 'task' ? data.result.tasks.length + Math.max(0, this.targetCount('inbox', true)) : undefined
  }
}
