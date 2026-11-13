import { common, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { RepositorySyncState } from './RepositorySyncService'

// 更新系统为数据传输任务创建的实况窗，不另建独立通知。
export class BackgroundSyncPresentation {
  private task: backgroundTaskManager.ContinuousTaskNotification | undefined = undefined
  private notification: notificationManager.NotificationRequest | undefined = undefined
  private agent: object | undefined = undefined
  private pending: RepositorySyncState | undefined = undefined
  private timer: number = -1
  private queue: Promise<void> = Promise.resolve()
  private closing: boolean = false
  private published: boolean = false
  private context: common.UIAbilityContext

  constructor(context: common.UIAbilityContext) { this.context = context }

  async start(): Promise<void> {
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1002,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      })
      this.agent = agent
      this.task = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent)
    } catch (error) {
      throw error as Error
    }
    try {
      const active = await notificationManager.getActiveNotifications()
      this.notification = active.find((item: notificationManager.NotificationRequest) => item.id === this.task?.notificationId)
    } catch (_) {
      // 系统已显示后台任务；读取通知失败不阻断文件同步。
      console.error('读取后台同步实况窗失败')
    }
  }

  update(state: RepositorySyncState): void {
    if (this.closing || !this.task) return
    // 订阅时可能先收到上一轮的完成快照；等本轮真正进入运行态再创建首个展示。
    if (!this.published && !state.running) return
    this.pending = state
    if (this.timer !== -1) return
    if (state.running && !this.published) {
      this.flush()
      return
    }
    // 文件事件可能连续到达；仅保留最新快照，每秒最多更新一次。
    this.timer = setTimeout((): void => {
      this.timer = -1
      this.flush()
    }, 1000)
  }

  private flush(): void {
    const state = this.pending
    this.pending = undefined
    if (!state) return
    this.published = true
    this.queue = this.queue.then(async (): Promise<void> => {
      try { await this.publish(state) }
      catch (_) { console.error('更新后台同步实况窗失败') }
    })
  }

  private async publish(state: RepositorySyncState): Promise<void> {
    const task = this.task
    if (!task) return
    // 系统通知创建或查询可能稍晚于长时任务，后续进度允许重新取得通知。
    await this.loadNotification(task.notificationId)
    const original = this.notification
    const title = state.running ? '正在同步' : state.error ? '同步失败' : '同步完成'
    const text = state.message || title
    const capsule = state.running && state.determinate ? `同步 ${state.progress}%` : title
    const content: notificationManager.NotificationContent = task.contentType ===
      notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW
      ? { notificationContentType: task.contentType, systemLiveView: {
        // 任务类型由系统代理返回；通知尚未出现在列表时也先提交更新，系统登记后会接收同一 ID。
        typeCode: original?.content.systemLiveView?.typeCode ?? 0, title: title, text: text,
        capsule: { title: capsule },
        progress: { maxValue: 100, currentValue: state.progress, isPercentage: state.determinate }
      } }
      : { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: title, text: text } }
    try {
      await notificationManager.publish({ id: task.notificationId, label: original?.label,
        notificationSlotType: task.slotType, content: content, wantAgent: original?.wantAgent ?? this.agent,
        isAlertOnce: true })
    } catch (error) {
      throw error as Error
    }
  }

  private async loadNotification(id: number): Promise<void> {
    if (this.notification) return
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const active = await notificationManager.getActiveNotifications()
        this.notification = active.find((item: notificationManager.NotificationRequest) => item.id === id)
        if (this.notification) return
      } catch (error) {
        if (attempt === 4) throw error as Error
      }
      if (attempt < 4) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100) })
    }
  }

  async finish(): Promise<void> {
    this.closing = true
    if (this.timer !== -1) clearTimeout(this.timer)
    this.timer = -1
    this.flush()
    await this.queue
    if (!this.task) return
    try {
      if (this.task.continuousTaskId !== undefined) {
        await backgroundTaskManager.stopBackgroundRunning(this.context, this.task.continuousTaskId)
      } else {
        await backgroundTaskManager.stopBackgroundRunning(this.context)
      }
    } catch (error) {
      throw error as Error
    } finally {
      this.task = undefined
      this.notification = undefined
      this.agent = undefined
    }
  }
}
