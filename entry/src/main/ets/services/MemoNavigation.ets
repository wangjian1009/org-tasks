import { AppConfig } from '../models/OrgTask'
import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { FileTargetService } from './FileTargetService'
import { CoreTask } from './NativeCoreService'

export class MemoNavigation {
  static async find(context: Context, memoId: string): Promise<CoreTask | undefined> {
    const config = await AppConfigService.load(context, false)
    return MemoNavigation.findInConfig(config, memoId)
  }
  static async findInConfig(config: AppConfig, memoId: string): Promise<CoreTask | undefined> {
    const result = await FileTargetService.query(config, 'memo')
    return result?.tasks.find((task: CoreTask): boolean => task.id === memoId)
  }
}
