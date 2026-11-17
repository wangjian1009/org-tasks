import { AppConfig } from '../models/OrgTask'
import { CoreQuery, CoreQueryResult, NativeCoreService } from './NativeCoreService'
import { CoreDataChangeService } from './CoreDataChangeService'

// 页面批次只读取自身数据，通知由应用级订阅接收。
export class PageQueryService {
  static async query(config: AppConfig, queries: CoreQuery[]): Promise<CoreQueryResult[]> {
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await CoreDataChangeService.connect(workspace)
    return workspace.query(queries)
  }
}
