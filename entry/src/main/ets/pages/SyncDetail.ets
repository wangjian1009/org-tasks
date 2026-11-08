import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreSyncFileRecord, CoreSyncHistoryError, CoreSyncRecord, CoreSyncRecordDetail,
  NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { syncLogConflictLabel, syncLogErrorLabel, syncLogFileOutcomeLabel, syncLogResultLabel,
  syncLogTimeLabel, syncLogTransferLabel } from '../ui/SyncLogPresentation'
import { UiColor, repositoryLabel } from '../ui/Theme'

interface SyncDetailParams {
  repoId: string
  syncId: string
}

@Entry
@Component
struct SyncDetail {
  @State detail: CoreSyncRecordDetail | null = null
  @State repositoryName: string = ''
  @State loading: boolean = true
  @State message: string = ''
  @State drawerOpen: boolean = false
  private requestId: number = 0
  private repoId: string = ''
  private syncId: string = ''

  onPageShow() { this.loadDetail() }

  async loadDetail() {
    const request = ++this.requestId
    this.loading = this.detail === null
    this.message = ''
    try {
      const params = this.getUIContext().getRouter().getParams() as SyncDetailParams | undefined
      this.repoId = this.repoId || params?.repoId || ''
      this.syncId = this.syncId || params?.syncId || ''
      if (!this.syncId || !this.repoId) throw new Error('缺少同步记录，请返回日志列表')
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const repository = config.repos.find((repo) => repo.id === this.repoId)
      if (!repository) throw new Error('此存储库已不存在，请返回日志列表')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const detail = await repo.historyDetail(this.syncId)
      if (request !== this.requestId) return
      this.repositoryName = repositoryLabel(repository)
      this.detail = detail
    } catch (e) {
      if (request === this.requestId) {
        this.detail = null
        this.message = `读取同步详情失败：${coreErrorMessage(e as CoreBridgeError)}`
      }
    } finally {
      if (request === this.requestId) this.loading = false
    }
  }

  resultIcon(record: CoreSyncRecord): Resource {
    switch (record.executionResult) {
      case 'succeeded': return $r('app.media.ui_sync_succeeded')
      case 'failed': return $r('app.media.ui_sync_failed')
      default: return $r('app.media.ui_sync_stopped')
    }
  }

  resultColor(record: CoreSyncRecord): string {
    return record.executionResult === 'succeeded' ? UiColor.done : record.executionResult === 'failed' ? UiColor.error : UiColor.secondary
  }

  fileColor(file: CoreSyncFileRecord): string {
    switch (file.outcome) {
      case 'conflict':
      case 'failed': return UiColor.error
      case 'uploaded':
      case 'created':
      case 'resolved': return UiColor.done
      case 'downloaded': return UiColor.primary
      default: return UiColor.secondary
    }
  }

  @Builder
  detailContent(detail: CoreSyncRecordDetail) {
    Scroll() {
      Column({ space: 20 }) {
        Text(this.repositoryName).fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
        Text(syncLogTimeLabel(detail.summary.started_at)).fontSize(13).fontColor(UiColor.secondary).width('100%')
        Row({ space: 10 }) {
          Image(this.resultIcon(detail.summary)).width(18).height(18)
          Text(syncLogResultLabel(detail.summary)).fontSize(16).fontColor(this.resultColor(detail.summary))
          if (syncLogConflictLabel(detail.summary).length > 0) {
            Text(syncLogConflictLabel(detail.summary)).fontSize(11).fontColor('#F5F5F5')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(10)
              .backgroundColor(detail.summary.pendingConflicts > 0 ? '#7F3548' : '#315C4B')
          }
        }.width('100%')
        Text(syncLogTransferLabel(detail.summary)).fontSize(16).fontColor(UiColor.text).width('100%')
        Divider().color(UiColor.outline).strokeWidth(0.5)
        Text('文件记录').fontSize(15).fontColor(UiColor.primary).width('100%')
        if (detail.files.length === 0) {
          Text('本次同步未生成文件记录').fontSize(14).fontColor(UiColor.secondary).width('100%')
        } else {
          Column() {
            ForEach(detail.files, (file: CoreSyncFileRecord) => {
              Row({ space: 12 }) {
                Text(file.path).fontSize(16).fontColor(UiColor.text).layoutWeight(1)
                Text(syncLogFileOutcomeLabel(file)).fontSize(14).fontColor(this.fileColor(file)).flexShrink(0)
              }.width('100%').constraintSize({ minHeight: 48 }).padding({ top: 8, bottom: 8 })
                .accessibilityGroup(true).accessibilityText(`${file.path}，${syncLogFileOutcomeLabel(file)}`)
            }, (file: CoreSyncFileRecord) => JSON.stringify(file))
          }.width('100%')
        }
        if (detail.errors.length > 0) {
          Text('错误信息').fontSize(15).fontColor(UiColor.primary).width('100%')
          ForEach(detail.errors, (error: CoreSyncHistoryError, index: number) => {
            Column({ space: 6 }) {
              if (error.path) { Text(error.path).fontSize(13).fontColor(UiColor.secondary).width('100%') }
              Text(error.message).fontSize(16).lineHeight(24).fontColor(UiColor.error).width('100%')
            }.width('100%')
          }, (error: CoreSyncHistoryError, index: number) => `${index}:${error.path || ''}:${error.message}`)
        } else if (detail.summary.executionResult === 'failed') {
          Text('错误信息').fontSize(15).fontColor(UiColor.primary).width('100%')
          Text(syncLogErrorLabel(detail.summary)).fontSize(16).lineHeight(24).fontColor(UiColor.error).width('100%')
        }
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 32 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).align(Alignment.TopStart).edgeEffect(EdgeEffect.None)
  }

  build() {
    Column() {
      AppShell({ title: '同步详情', back: true, drawerOpen: $drawerOpen,
        synchronized: (): void => { this.loadDetail() } }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: '正在读取同步详情', busy: true })
          } else if (this.message) {
            EmptyState({ title: '同步详情读取失败', detail: this.message, actionLabel: '重试', action: (): void => { this.loadDetail() } })
          } else if (this.detail) {
            this.detailContent(this.detail)
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
