import { AppConfig } from '../models/OrgTask'
import { Context } from '@kit.AbilityKit'
import { AppDataManager } from './AppDataManager'
import { FileTargetService } from './FileTargetService'
import { CoreTask } from './NativeCoreService'

export class MemoNavigation {
  static async find(context: Context, memoId: string): Promise<CoreTask | undefined> {
    const app = AppDataManager.shared(context)
    await app.start()
    const dataSet = app.dataSet('memoTasks')
    if (dataSet.error) throw new Error(dataSet.error)
    return dataSet.getTask(memoId)
  }
  static async findInConfig(config: AppConfig, memoId: string): Promise<CoreTask | undefined> {
    const result = await FileTargetService.query(config, 'memo')
    return result?.tasks.find((task: CoreTask): boolean => task.id === memoId)
  }
}
