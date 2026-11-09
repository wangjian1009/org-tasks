import { AppShell } from '../components/AppShell'
import { FileItem } from '../components/FileItem'
import { EmptyState } from '../components/Controls'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreSyncFileRecord, CoreSyncHistoryError, CoreSyncRecord, CoreSyncRecordDetail,
  NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { syncLogConflictLabel, syncLogErrorLabel, syncLogResultLabel,
  syncLogTimeLabel } from '../ui/SyncLogPresentation'
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

  sectionFiles(section: string): CoreSyncFileRecord[] {
    return this.detail?.files.filter((file: CoreSyncFileRecord) => file.section === section) || []
  }

  async openFile(file: CoreSyncFileRecord) {
    try {
      if (!file.backup) throw new Error('该日志未保存文件备份，无法打开历史内容')
      if (file.outcome === 'conflict') {
        await this.getUIContext().getRouter().pushUrl({ url: 'pages/ConflictFile',
          params: { repoId: this.repoId, syncId: this.syncId, path: file.path } })
      } else {
        await this.getUIContext().getRouter().pushUrl({ url: 'pages/FileDetail',
          params: { repoId: this.repoId, syncId: this.syncId, path: file.path, resolved: file.outcome === 'resolved', repositoryName: this.repositoryName,
            backupTime: file.backup.modifiedAt, backupPath: file.backup.path } })
      }
    } catch (e) {
      try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(e as CoreBridgeError) }) } catch (_) {}
    }
  }

  resultColor(record: CoreSyncRecord): string {
    return record.executionResult === 'succeeded' ? UiColor.done : record.executionResult === 'failed' ? UiColor.error : UiColor.secondary
  }

  resultBackground(record: CoreSyncRecord): string {
    return record.executionResult === 'succeeded' ? '#315C4B' : record.executionResult === 'failed' ? '#7F3548' : UiColor.field
  }

  @Builder
  fileSection(label: string, section: string, color: string) {
    if (this.sectionFiles(section).length > 0) {
      Column() {
        Row() {
          Image(section === 'upload' ? $r('app.media.ui_sync_upload') : section === 'download' ? $r('app.media.ui_sync_download') : $r('app.media.ui_notification_conflict')).width(18).height(18).margin({ right: 8 })
          Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(color).layoutWeight(1)
          Text(`${this.sectionFiles(section).length}`).fontSize(13).fontColor(UiColor.secondary)
        }.width('100%').height(32).padding({ left: 8, right: 8 })
        Divider().color(UiColor.outline).strokeWidth(0.5).margin({ left: 8, right: 8 })
        ForEach(this.sectionFiles(section), (file: CoreSyncFileRecord) => {
          if (file.backup) {
            FileItem({ file: file.backup,
              statusColor: file.outcome === 'resolved' ? UiColor.done : UiColor.error,
              open: (): void => { this.openFile(file) } })
          } else {
            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Text(file.path).fontSize(16).fontColor(UiColor.text).layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (file.outcome !== 'deleted') {
                  Text('未备份').fontSize(11).fontColor(UiColor.warning)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6).backgroundColor(UiColor.container)
                }
              }.width('100%')
              if (file.outcome === 'deleted') {
                Text('远端已删除').fontSize(12).fontColor(UiColor.secondary).width('100%')
              }
            }.width('100%').height(56).padding({ left: 8, right: 8 }).justifyContent(FlexAlign.Center)
              .onClick((): void => { if (file.outcome !== 'deleted') this.openFile(file) })
          }
        }, (file: CoreSyncFileRecord) => JSON.stringify(file))
      }.width('100%')
    }
  }

  @Builder
  detailContent(detail: CoreSyncRecordDetail) {
    Scroll() {
      Column({ space: 20 }) {
        Text(this.repositoryName).fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%').padding({ left: 8, right: 8 })
        Text(syncLogTimeLabel(detail.summary.started_at)).fontSize(13).fontColor(UiColor.secondary).width('100%').padding({ left: 8, right: 8 })
        Row() {
          Text(syncLogResultLabel(detail.summary)).fontSize(12)
            .fontColor(this.resultColor(detail.summary))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(6)
            .backgroundColor(this.resultBackground(detail.summary))
          if (syncLogConflictLabel(detail.summary).length > 0) {
            Text(syncLogConflictLabel(detail.summary)).fontSize(11).fontColor('#F5F5F5')
              .padding({ left: 6, right: 6, top: 3, bottom: 3 }).borderRadius(6)
              .backgroundColor(detail.summary.pendingConflicts > 0 ? '#7F3548' : '#315C4B').margin({ left: 8 })
          }
        }.width('100%').padding({ left: 8, right: 8 })
        this.fileSection('上传', 'upload', UiColor.done)
        this.fileSection('下载', 'download', UiColor.primary)
        this.fileSection('冲突', 'conflict', UiColor.error)
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
      }.width('100%').padding({ left: 12, right: 12, top: 20, bottom: 32 }).alignItems(HorizontalAlign.Start)
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
