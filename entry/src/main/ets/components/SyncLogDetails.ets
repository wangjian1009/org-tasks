import { localizedText } from '../ui/LocalizedText'
import { PageNavigator } from '../services/PageNavigator'
import { CoreBridgeError, CoreSyncFileRecord, CoreSyncHistoryError, CoreSyncRecordDetail,
  coreErrorMessage } from '../services/NativeCoreService'
import { SyncLogDetailDataManager } from '../services/ReadingDataManager'
import { SnapshotState } from '../services/SnapshotDataManager'
import { syncLogFileOutcomeLabel, syncLogTimeLabel, syncLogErrorLabel, syncLogTriggerLabel } from '../ui/SyncLogPresentation'
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
  private dataManager: SyncLogDetailDataManager | undefined = undefined
  private stopData: (() => void) | undefined = undefined

  aboutToAppear() { this.load() }
  aboutToDisappear() { this.stopData?.(); this.dataManager?.close(); this.dataManager = undefined }

  async load(reload: boolean = false) {
    if (!this.dataManager) {
      this.dataManager = new SyncLogDetailDataManager(this.getUIContext().getHostContext()!, this.repoId, this.syncId)
      this.stopData = this.dataManager.subscribe((state: SnapshotState<CoreSyncRecordDetail>): void => {
        if (!state.value && !state.message) return
        this.loading = false
        if (state.value) this.detail = state.value
        this.message = state.message ? localizedText($r('app.string.text_couldn_t_load_log_details'), String(state.message)) : ''
      })
    }
    if (reload) await this.dataManager.refresh()
    else await this.dataManager.start()
  }

  async openFile(file: CoreSyncFileRecord) {
    try {
      if (!file.path || !file.backup || file.outcome !== 'deleted') throw new Error(localizedText($r('app.string.text_there_is_no_readable_delete_backup_for')))
      await PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/OrgFileDetail',
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
        Text(file.backup?.title || file.path || localizedText($r('app.string.text_file_path_unknown'))).fontSize(15).fontColor(UiColor.text).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(file.path || localizedText($r('app.string.text_file_path_unknown'))).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1)
      Text(syncLogFileOutcomeLabel(file)).fontSize(12).fontColor(this.color(file)).flexShrink(0)
      if (file.path && file.backup && file.outcome === 'deleted') {
        Image($r('app.media.ui_next')).width(16).height(16)
      }
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .accessibilityText(`${file.path}，${syncLogFileOutcomeLabel(file)}${file.backup && file.outcome === 'deleted' ? localizedText($r('app.string.text_tap_to_see_delete_backup')) : ''}`)
      .onClick((): void => { if (file.path && file.backup && file.outcome === 'deleted') this.openFile(file) })
  }

  build() {
    Column({ space: 8 }) {
      if (this.loading) {
        Text($r('app.string.text_reading_file_state')).fontSize(13).fontColor(UiColor.secondary).padding(12)
      } else if (this.message) {
        Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%')
        Button($r('app.string.text_retry')).height(44).fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .onClick((): void => { this.load(true) })
      } else if (this.detail) {
        Text(`${syncLogTimeLabel(this.detail.summary.started_at)} · ${syncLogTriggerLabel(this.detail.summary)}`).fontSize(12).fontColor(UiColor.secondary)
          .width('100%').padding({ left: 8, right: 8, top: 4 })
        ForEach(this.detail.files, (file: CoreSyncFileRecord) => {
          this.fileRow(file)
        }, (file: CoreSyncFileRecord) => JSON.stringify(file))
        if (this.detail.files.length === 0) {
          Text($r('app.string.text_there_s_no_record_of_this')).fontSize(13).fontColor(UiColor.secondary).width('100%').padding(8)
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
