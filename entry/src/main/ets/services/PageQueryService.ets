import { AppConfig } from '../models/OrgTask'
import { CoreQuery, CoreQueryResult, NativeCoreService, notificationResult } from './NativeCoreService'
import { NotificationManager } from './NotificationManager'
import { CoreDataChangeService } from './CoreDataChangeService'

// 页面数据与通知共用一次批量读取，订阅注册不再触发独立通知查询。
export class PageQueryService {
  static async query(config: AppConfig, queries: CoreQuery[]): Promise<CoreQueryResult[]> {
    const request = NotificationManager.begin()
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
    await CoreDataChangeService.connect(workspace)
    const notificationIndex = queries.findIndex(item => item.type === 'notification')
    const batch: CoreQuery[] = queries.slice()
    const notificationQuery = await NotificationManager.queryFor(config, workspace)
    if (notificationIndex < 0) batch.push(notificationQuery)
    else batch[notificationIndex] = notificationQuery
    const results = await workspace.query(batch)
    const index = notificationIndex < 0 ? queries.length : notificationIndex
    NotificationManager.publish(config, notificationResult(results[index]), request)
    return notificationIndex < 0 ? results.slice(0, queries.length) : results
  }
}
