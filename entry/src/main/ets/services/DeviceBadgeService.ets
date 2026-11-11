import { Context } from '@kit.AbilityKit'
import { notificationManager } from '@kit.NotificationKit'
import { AppConfigService } from './AppConfigService'
import { FileTargetService } from './FileTargetService'
import { CoreQuery, CoreWorkspace, NativeCoreService, notificationResult, taskResult } from './NativeCoreService'

// 前台订阅与后台单次刷新共用；不持久化计数，不依赖页面快照。
export class DeviceBadgeService {
  private static foreground: Context | undefined = undefined
  private static workspace: CoreWorkspace | undefined = undefined
  private static subscriptionId: number = 0
  private static session: number = 0
  private static midnightTimer: number = -1
  private static pending: Context | undefined = undefined
  private static revision: number = 0
  private static running: Promise<void> | undefined = undefined
  private static configurationChanged = (): void => {
    if (DeviceBadgeService.foreground) DeviceBadgeService.refresh(DeviceBadgeService.foreground)
  }

  static start(context: Context): void {
    if (!DeviceBadgeService.foreground) AppConfigService.watchChanges(DeviceBadgeService.configurationChanged)
    DeviceBadgeService.foreground = context
    DeviceBadgeService.scheduleMidnight()
    DeviceBadgeService.refresh(context)
  }

  static stop(): void {
    DeviceBadgeService.foreground = undefined
    AppConfigService.stopWatchingChanges(DeviceBadgeService.configurationChanged)
    DeviceBadgeService.disconnect()
    if (DeviceBadgeService.midnightTimer !== -1) clearTimeout(DeviceBadgeService.midnightTimer)
    DeviceBadgeService.midnightTimer = -1
  }

  // 合并刷新请求并串行写系统角标，查询中收到新事件时丢弃旧结果并补查。
  static refresh(context: Context): Promise<void> {
    DeviceBadgeService.pending = context
    DeviceBadgeService.revision++
    if (!DeviceBadgeService.running) {
      DeviceBadgeService.running = DeviceBadgeService.drain().finally((): void => {
        DeviceBadgeService.running = undefined
      })
    }
    return DeviceBadgeService.running
  }

  private static async drain(): Promise<void> {
    while (DeviceBadgeService.pending) {
      const context = DeviceBadgeService.pending
      DeviceBadgeService.pending = undefined
      const revision = DeviceBadgeService.revision
      try {
        const config = await AppConfigService.load(context, false)
        const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults)
        if (DeviceBadgeService.foreground) await DeviceBadgeService.connect(workspace)
        const inbox = FileTargetService.prepare(config, await workspace.repos(), 'inbox')
        const queries: CoreQuery[] = [
          { type: 'task', query: { expression: 'it.todo d.lt.tomorrow', includeDone: false, includeComposeTasks: true } },
          { type: 'notification', query: {} }
        ]
        if (inbox) { queries.push(inbox.task); queries.push(inbox.file) }
        const results = await workspace.query(queries)
        const inboxCount = inbox ? FileTargetService.result(results[2], results[3])?.tasks.length ?? 0 : 0
        const deadlineCount = taskResult(results[0]).tasks.length
        const conflictCount = notificationResult(results[1]).filter(item => item.type === 'syncConflict').length
        if (revision !== DeviceBadgeService.revision) continue
        await notificationManager.setBadgeNumber(inboxCount + deadlineCount + conflictCount)
      } catch (_) {
        // 失败不清零，不影响已提交的数据或日历同步；后续触发时重试。
        console.error('更新设备提示计数失败')
      }
    }
  }

  private static disconnect(): void {
    DeviceBadgeService.session++
    if (DeviceBadgeService.workspace && DeviceBadgeService.subscriptionId !== 0) {
      DeviceBadgeService.workspace.stopWatchingDataChanges(DeviceBadgeService.subscriptionId)
    }
    DeviceBadgeService.workspace = undefined
    DeviceBadgeService.subscriptionId = 0
  }

  private static async connect(workspace: CoreWorkspace): Promise<void> {
    if (DeviceBadgeService.workspace === workspace) return
    DeviceBadgeService.disconnect()
    DeviceBadgeService.workspace = workspace
    const session = DeviceBadgeService.session
    try {
      const id = await workspace.watchDataChanges((): void => {
        if (session === DeviceBadgeService.session && DeviceBadgeService.foreground) {
          DeviceBadgeService.refresh(DeviceBadgeService.foreground)
        }
      })
      if (session !== DeviceBadgeService.session) workspace.stopWatchingDataChanges(id)
      else DeviceBadgeService.subscriptionId = id
    } catch (error) {
      if (session === DeviceBadgeService.session) DeviceBadgeService.disconnect()
      throw error as Error
    }
  }

  private static scheduleMidnight(): void {
    if (DeviceBadgeService.midnightTimer !== -1) clearTimeout(DeviceBadgeService.midnightTimer)
    const midnight = new Date()
    midnight.setHours(24, 0, 0, 0)
    DeviceBadgeService.midnightTimer = setTimeout((): void => {
      if (!DeviceBadgeService.foreground) return
      DeviceBadgeService.refresh(DeviceBadgeService.foreground)
      DeviceBadgeService.scheduleMidnight()
    }, midnight.getTime() - Date.now())
  }
}
