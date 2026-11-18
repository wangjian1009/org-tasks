import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { AppConfigService } from './AppConfigService'
import { DataSet, DataSetDefinition, DataSetManager } from './DataSetManager'
import { CoreQuery, CoreQueryResult } from './NativeCoreService'
import { FileTargetKind, FileTargetService, configuredSpecialFileExclusions, fileTargetRepository, systemTrashExclusions } from './FileTargetService'
import { overviewTaskQuery, todayAttentionQuery, todayPriorityQuery } from './TaskViewQueries'

export const APP_DATA_SET_NAMES: string[] = ['todayTasks', 'todayPriority', 'files', 'orderFiles', 'todayAttention',
  'planned', 'anytime', 'waiting', 'logbook', 'projects', 'trash', 'badgeDeadline',
  'inboxTasks', 'inboxFile', 'somedayTasks', 'somedayFile', 'memoTasks', 'memoFile']

// 只定义 Core 查询；相同业务范围只保留一个 DataSet，各项共享同一批文件加载。
export function appDataDefinitions(config: AppConfig): DataSetDefinition[] {
  const trash = systemTrashExclusions(config)
  const task = (name: string, query: CoreQuery): DataSetDefinition => {
    if (query.type === 'task' && trash.files.length) query.query.excludeFiles = trash.files.slice()
    return { name, query, repositoryBindings: trash.repositoryBindings }
  }
  const definitions: DataSetDefinition[] = [
    task('todayTasks', { type: 'task', query: overviewTaskQuery('today') }),
    task('todayPriority', { type: 'task', query: todayPriorityQuery() }),
    { name: 'files', query: { type: 'file', query: {} } },
    task('todayAttention', { type: 'task', query: todayAttentionQuery() }),
    task('planned', { type: 'task', query: overviewTaskQuery('planned') }),
    task('anytime', { type: 'task', query: overviewTaskQuery('anytime') }),
    task('waiting', { type: 'task', query: overviewTaskQuery('waiting') }),
    task('logbook', { type: 'task', query: overviewTaskQuery('logbook') }),
    { name: 'projects', query: { type: 'file', query: { isProject: true, excludeFiles: trash.files } }, repositoryBindings: trash.repositoryBindings }
  ]
  const special = configuredSpecialFileExclusions(config)
  definitions.push({ name: 'orderFiles', query: { type: 'file', query: { excludeFiles: special.files } }, repositoryBindings: special.repositoryBindings })
  if (trash.files.length) definitions.push({ name: 'trash', query: { type: 'task', query: { expression: '.o.deleted', includeFiles: trash.files } }, repositoryBindings: trash.repositoryBindings })
  const inbox = FileTargetService.prepareConfigured(config, 'inbox')
  definitions.push({ name: 'badgeDeadline', query: { type: 'task', query: { expression: 'it.todo d.lt.tomorrow',
    excludeFiles: (inbox ? [inbox.reference] : []).concat(trash.files) } },
    repositoryBindings: (inbox?.repositoryBindings ?? []).concat(trash.repositoryBindings) })
  const kinds: FileTargetKind[] = ['inbox', 'someday', 'memo']
  for (const kind of kinds) {
    const target = FileTargetService.prepareConfigured(config, kind)
    if (target) definitions.push({ name: `${kind}Tasks`, query: target.task, repositoryBindings: target.repositoryBindings },
      { name: `${kind}File`, query: target.file, repositoryBindings: target.repositoryBindings })
  }
  return definitions
}

// 主界面会话共享的数据入口；组件只解除自己的订阅，不关闭全局管理器。
export class AppDataManager {
  private static current: AppDataManager | undefined = undefined
  readonly manager: DataSetManager
  private readonly context: Context
  private config: AppConfig | undefined = undefined

  static get active(): AppDataManager | undefined { return AppDataManager.current }
  static shared(context: Context): AppDataManager {
    if (!AppDataManager.current) AppDataManager.current = new AppDataManager(context)
    return AppDataManager.current
  }
  static async close(): Promise<void> {
    const current = AppDataManager.current
    AppDataManager.current = undefined
    await current?.manager.close()
  }
  private constructor(context: Context) {
    this.context = context
    this.manager = DataSetManager.create(context, 'app', (config: AppConfig): DataSetDefinition[] => {
      this.config = config
      return appDataDefinitions(config)
    })
    for (const name of APP_DATA_SET_NAMES) this.manager.dataSet(name)
  }
  dataSet(name: string): DataSet { return this.manager.dataSet(name) }
  async start(): Promise<void> { await this.manager.start() }
  async retryFailed(): Promise<void> {
    const failed = APP_DATA_SET_NAMES.map(name => this.dataSet(name)).filter(dataSet => !!dataSet.error)
    await Promise.all(failed.map(dataSet => dataSet.refresh()))
  }
  private hasTarget(kind: FileTargetKind): boolean { return !!this.config && !!fileTargetRepository(this.config, kind) }
  async targetConfigured(kind: FileTargetKind): Promise<boolean> {
    return !!fileTargetRepository(await AppConfigService.load(this.context, false), kind)
  }
  targetCount(kind: FileTargetKind, confirmed: boolean = false): number {
    if (!this.hasTarget(kind)) return -1
    const tasks = this.dataSet(`${kind}Tasks`), file = this.dataSet(`${kind}File`)
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
