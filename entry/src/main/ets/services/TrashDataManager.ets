import { Context } from '@kit.AbilityKit'
import { AppConfig } from '../models/OrgTask'
import { SYSTEM_REPOSITORY_ID, TRASH_FILE } from '../models/SystemRepository'
import { DataSetManager, DataSet, DataSetDefinition } from './DataSetManager'
import { CoreTask, CoreOrgFileRef, CoreQueryRepositoryBinding } from './NativeCoreService'
import { TrashService } from './TrashService'
import { TrashSettingsService } from './TrashSettingsService'

// 废纸篓的查询、外部变化和清理统一经过页面数据集，不直接读写文件。
export class TrashDataManager {
  readonly manager: DataSetManager
  readonly tasks: DataSet
  private readonly context: Context
  private days: number = 30
  private starting: Promise<void> | undefined = undefined
  private cleaned: boolean = false
  constructor(context: Context) {
    this.context = context
    this.manager = DataSetManager.create(context, '废纸篓', (config: AppConfig): DataSetDefinition[] => {
      const repository = config.repos.find(repo => repo.id === SYSTEM_REPOSITORY_ID)
      if (!repository) throw new Error('系统仓库尚未初始化')
      const includeFiles: CoreOrgFileRef[] = [{ repoId: repository.id, path: TRASH_FILE }]
      const repositoryBindings: CoreQueryRepositoryBinding[] = [{ id: repository.id, rootDirectory: repository.rootDirectory }]
      return [
        { name: 'tasks', query: { type: 'task', query: { expression: '.o.deleted', includeFiles }, repoIds: [repository.id] }, repositoryBindings },
        { name: 'expired', query: { type: 'task', query: { expression: `deleted.lt.-${this.days}d`, includeFiles }, repoIds: [repository.id] }, repositoryBindings },
        { name: 'files', query: { type: 'file', query: { includeFiles } }, repositoryBindings }
      ]
    })
    this.tasks = this.manager.dataSet('tasks')
  }
  start(): Promise<void> {
    if (this.starting) return this.starting
    const work = this.initialize().finally((): void => { if (this.starting === work) this.starting = undefined })
    this.starting = work
    return work
  }
  private async initialize(): Promise<void> {
    this.days = await TrashSettingsService.retentionDays(this.context)
    await this.manager.start()
    if (this.cleaned || !this.manager.isReady()) return
    const expired = this.manager.dataSet('expired')
    if (!expired.isReady() || expired.version === 0 || expired.error) throw new Error(expired.error || '过期记录尚未读取完成')
    const data = expired.data
    if (data?.type === 'task' && data.result.tasks.length) await this.perform(data.result.tasks, 'delete')
    this.cleaned = true
  }
  async perform(tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> {
    await this.tasks.operate(async (operationId: string): Promise<void> => {
      await TrashService.perform(this.context, tasks, action === 'delete' ? 'clear' : 'restore', operationId)
    })
    await this.tasks.settle()
  }
  async refresh(): Promise<void> { await this.manager.refresh(); this.cleaned = false; await this.start() }
  async close(): Promise<void> { await this.manager.close() }
}
