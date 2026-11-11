import { AppConfig } from '../models/OrgTask'
import { CoreQuery, CoreQueryResult, NativeCoreService, notificationResult } from './NativeCoreService'
import { CoreNotificationService } from './CoreNotificationService'
import { CoreDataChangeService } from './CoreDataChangeService'

// 页面数据与通知共用一次批量读取，订阅注册不再触发独立通知查询。
export class PageQueryService {
  static async query(config: AppConfig, queries: CoreQuery[]): Promise<CoreQueryResult[]> {
    const request = CoreNotificationService.begin()
    const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
    await Promise.all([CoreNotificationService.connect(workspace), CoreDataChangeService.connect(workspace)])
    const notificationIndex = queries.findIndex(item => item.type === 'notification')
    const batch: CoreQuery[] = queries.slice()
    if (notificationIndex < 0) batch.push({ type: 'notification', query: {} })
    const results = await workspace.query(batch)
    const index = notificationIndex < 0 ? queries.length : notificationIndex
    CoreNotificationService.publish(config, notificationResult(results[index]), request)
    return notificationIndex < 0 ? results.slice(0, queries.length) : results
  }
}
