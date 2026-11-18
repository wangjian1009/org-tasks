import { Context } from '@kit.AbilityKit'
import { AppDataManager } from './AppDataManager'
import { DataSetManager, DataSet } from './DataSetManager'
import { CoreTask } from './NativeCoreService'
import { TrashService } from './TrashService'

// 页面只编排显式清理和用户操作；任务、订阅与缓存归应用级实例所有。
export class TrashDataManager {
  readonly manager: DataSetManager
  readonly tasks: DataSet
  private readonly app: AppDataManager
  private readonly context: Context
  constructor(context: Context) {
    this.context = context
    this.app = AppDataManager.shared(context)
    this.manager = this.app.manager
    this.tasks = this.app.dataSet('trash')
  }
  async start(): Promise<void> { await this.app.cleanTrash() }
  async perform(tasks: CoreTask[], action: 'delete' | 'restore'): Promise<void> {
    await this.tasks.operate((operationId: string): Promise<void> =>
      TrashService.perform(this.context, tasks, action === 'delete' ? 'clear' : 'restore', operationId))
    await this.tasks.settle()
  }
  async refresh(): Promise<void> {
    await this.tasks.refresh()
    await this.app.dataSet('trashExpired').refresh()
    await this.start()
  }
  async close(): Promise<void> { await this.tasks.settle() }
}
