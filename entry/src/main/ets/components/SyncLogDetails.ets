import { CoreBridgeError, CoreSyncFileRecord, CoreSyncHistoryError, CoreSyncRecordDetail,
  NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { AppConfigService } from '../services/AppConfigService'
import { syncLogFileOutcomeLabel, syncLogTimeLabel, syncLogErrorLabel } from '../ui/SyncLogPresentation'
import { UiColor } from '../ui/Theme'

// 展开项按日志身份请求 Core 投影，包含无变化文件；不在页面推导同步状态。
@Component
export struct SyncLogDetails {
  @Prop repoId: string = ''
  @Prop syncId: string = ''
  @Prop repositoryName: string = ''
  @State detail: CoreSyncRecordDetail | undefined = undefined
  @State loading: boolean = true
  @State message: string = ''
  private requestId: number = 0

  aboutToAppear() { this.load() }
  aboutToDisappear() { this.requestId++ }

  async load() {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!)
      const repository = config.repos.find((repo) => repo.id === this.repoId)
      if (!repository) throw new Error('此存储库已不存在')
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults)
      const detail = await repo.historyDetail(this.syncId)
      if (request === this.requestId) this.detail = detail
    } catch (e) {
      if (request === this.requestId) this.message = `读取日志详情失败：${coreErrorMessage(e as CoreBridgeError)}`
    } finally { if (request === this.requestId) this.loading = false }
  }

  async openFile(file: CoreSyncFileRecord) {
    try {
      if (!file.backup || file.outcome !== 'deleted') throw new Error('此记录没有可阅读的删除备份')
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/FileDetail',
        params: { repoId: this.repoId, syncId: this.syncId, path: file.path,
          repositoryName: this.repositoryName, backupTime: file.backup.modifiedAt, backupPath: file.backup.path } })
    } catch (e) {
      try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(e as CoreBridgeError) }) } catch (_) {}
    }
  }

  color(file: CoreSyncFileRecord): string {
    if (file.outcome === 'failed') return UiColor.error
    if (file.outcome === 'conflict') return UiColor.secondary
    if (file.outcome === 'merged') return UiColor.done
    if (file.outcome === 'unchanged' || file.outcome === 'skipped') return UiColor.secondary
    return UiColor.primary
  }

  @Builder
  fileRow(file: CoreSyncFileRecord) {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(file.backup?.title || file.path).fontSize(15).fontColor(UiColor.text).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(file.path).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1)
      Text(syncLogFileOutcomeLabel(file)).fontSize(12).fontColor(this.color(file)).flexShrink(0)
      if (file.backup && file.outcome === 'deleted') {
        Image($r('app.media.ui_next')).width(16).height(16)
      }
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .accessibilityText(`${file.path}，${syncLogFileOutcomeLabel(file)}${file.backup && file.outcome === 'deleted' ? '，点击查看删除备份' : ''}`)
      .onClick((): void => { if (file.backup && file.outcome === 'deleted') this.openFile(file) })
  }

  build() {
    Column({ space: 8 }) {
      if (this.loading) {
        Text('正在读取文件状态…').fontSize(13).fontColor(UiColor.secondary).padding(12)
      } else if (this.message) {
        Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%')
        Button('重试').height(44).fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .onClick((): void => { this.load() })
      } else if (this.detail) {
        Text(syncLogTimeLabel(this.detail.summary.started_at)).fontSize(12).fontColor(UiColor.secondary)
          .width('100%').padding({ left: 8, right: 8, top: 4 })
        ForEach(this.detail.files, (file: CoreSyncFileRecord) => {
          this.fileRow(file)
        }, (file: CoreSyncFileRecord) => JSON.stringify(file))
        if (this.detail.files.length === 0) {
          Text('本次没有文件处理记录').fontSize(13).fontColor(UiColor.secondary).width('100%').padding(8)
        }
        ForEach(this.detail.errors, (error: CoreSyncHistoryError, index: number) => {
          Text(`${error.path ? `${error.path}：` : ''}${error.message}`).fontSize(13).lineHeight(20)
            .fontColor(UiColor.error).width('100%').padding(8)
        }, (error: CoreSyncHistoryError, index: number) => `${index}:${error.path}:${error.message}`)
        if (this.detail.errors.length === 0 && this.detail.summary.executionResult === 'failed') {
          Text(syncLogErrorLabel(this.detail.summary)).fontSize(13).fontColor(UiColor.error).width('100%').padding(8)
        }
      }
    }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 12 }).borderRadius(10).backgroundColor(UiColor.container)
  }
}
