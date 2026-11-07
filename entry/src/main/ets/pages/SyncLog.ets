import { router } from '@kit.ArkUI'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreSyncRecord, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor, repositoryLabel } from '../ui/Theme'

interface SyncLogItem {
  repository: string
  record: CoreSyncRecord
}

@Entry
@Component
struct SyncLog {
  @State items: SyncLogItem[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  private requestId: number = 0

  onPageShow() { this.loadLogs() }

  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    return false
  }

  async loadLogs() {
    const request = ++this.requestId
    this.loading = this.items.length === 0
    this.message = ''
    try {
      const config = await AppConfigService.load(getContext(this))
      const items: SyncLogItem[] = []
      for (const repository of config.repos) {
        const records = await NativeCoreService.repositoryHistory(config.repos, repository, config.todoDefaults)
        for (const record of records) items.push({ repository: repositoryLabel(repository), record })
      }
      if (request !== this.requestId) return
      items.sort((left: SyncLogItem, right: SyncLogItem): number => right.record.started_at - left.record.started_at)
      this.items = items
    } catch (e) {
      if (request === this.requestId) {
        this.items = []
        this.message = `读取同步日志失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  timeLabel(timestamp: number): string {
    const date = new Date(timestamp)
    if (isNaN(date.getTime())) return '时间未知'
    const pad = (value: number): string => value.toString().padStart(2, '0')
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  }

  resultLabel(result: string): string {
    switch (result) {
      case 'succeeded': return '同步成功'
      case 'failed': return '同步失败'
      case 'cancelled': return '已取消'
      case 'interrupted': return '已中断'
      default: return '同步完成'
    }
  }

  resultColor(result: string): string {
    return result === 'succeeded' ? UiColor.done : result === 'failed' ? UiColor.error : UiColor.secondary
  }

  @Builder
  logItem(item: SyncLogItem) {
    Column({ space: 8 }) {
      Row() {
        Text(this.resultLabel(item.record.result)).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.resultColor(item.record.result)).layoutWeight(1)
        Text(this.timeLabel(item.record.started_at)).fontSize(13).fontColor(UiColor.secondary)
      }.width('100%')
      Text(item.repository).fontSize(14).fontColor(UiColor.text).width('100%')
      Row({ space: 16 }) {
        Text(`${item.record.files} 个文件`).fontSize(13).fontColor(UiColor.secondary)
        if (item.record.conflicts.length > 0) {
          Text(`${item.record.conflicts.length} 个冲突`).fontSize(13).fontColor(UiColor.error)
        }
      }.width('100%')
    }.width('100%').padding({ left: 20, right: 20, top: 14, bottom: 14 })
      .border({ width: { bottom: 0.5 }, color: UiColor.divider })
      .accessibilityGroup(true)
      .accessibilityText(`${this.resultLabel(item.record.result)}，${item.repository}，${this.timeLabel(item.record.started_at)}，${item.record.files} 个文件${item.record.conflicts.length > 0 ? `，${item.record.conflicts.length} 个冲突` : ''}`)
  }

  @Builder
  content() {
    if (this.loading) {
      EmptyState({ title: '正在读取同步日志', busy: true })
    } else if (this.message) {
      EmptyState({ title: '同步日志读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadLogs() } })
    } else if (this.items.length === 0) {
      EmptyState({ title: '暂无同步日志', detail: '完成一次文件同步后，记录会显示在这里。' })
    } else {
      List() {
        ForEach(this.items, (item: SyncLogItem) => {
          ListItem() { this.logItem(item) }
        }, (item: SyncLogItem) => `${item.record.id}:${item.record.started_at}`)
      }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.None)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
  }

  build() {
    Column() {
      AppShell({ title: '同步日志', back: true, backAction: (): void => { router.back() },
        synchronized: (): void => { this.loadLogs() }, drawerOpen: $drawerOpen, pullToSync: true }) {
        Column() { this.content() }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
