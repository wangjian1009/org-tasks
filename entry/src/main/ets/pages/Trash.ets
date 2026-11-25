import { localizedText } from '../ui/LocalizedText'
import { TaskOperation } from '../ui/TaskActionPresentation'
import { AppShell } from '../components/AppShell'
import { NotificationEmptyState } from '../components/NotificationEmptyState'
import { LogbookTaskList } from '../components/LogbookTaskList'
import { TrashDataManager } from '../services/TrashDataManager'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { PageNavigator } from '../services/PageNavigator'
import { LogbookGroup, logbookGroups } from '../ui/LogbookPresentation'

@Entry
@Component
struct Trash {
  private dataManager: TrashDataManager | undefined = undefined
  private stop: (() => void) | undefined = undefined
  private active: boolean = false
  @State groups: LogbookGroup[] = []
  @State ready: boolean = false
  @State loading: boolean = true
  @State message: string = ''
  private maintenanceError: string = ''
  @State drawerOpen: boolean = false
  @State hasParent: boolean = PageNavigator.shared.path.depth > 1
  @State referenceTime: number = Date.now()

  aboutToAppear() { this.active = true; this.load() }
  onPageShow(): void { this.hasParent = PageNavigator.shared.path.depth > 1 }
  aboutToDisappear() {
    this.active = false; this.stop?.()
    this.dataManager?.close().catch((): void => { console.error('保存废纸篓页面数据失败') })
    this.dataManager = undefined
  }
  onBackPress(): boolean {
    if (this.drawerOpen) { this.drawerOpen = false; return true }
    PageNavigator.shared.back(this.getUIContext()); return true
  }
  applySnapshot() {
    if (!this.active || !this.dataManager) return
    const dataSet = this.dataManager.tasks, data = dataSet.data
    this.ready = dataSet.isReady()
    this.loading = !data && !dataSet.error
    this.message = dataSet.error || this.maintenanceError
    this.groups = logbookGroups(data?.type === 'task' ? data.result.tasks : [], new Date(this.referenceTime),
      (task: CoreTask): number | null => task.deletedAt, (task: CoreTask): string => dataSet.taskKey(task.id))
  }
  async load(reload: boolean = false) {
    if (!this.dataManager) {
      this.dataManager = new TrashDataManager(this.getUIContext().getHostContext()!)
      this.stop = this.dataManager.tasks.subscribe((): void => { this.applySnapshot() })
    }
    this.applySnapshot()
    try { this.message = ''; this.maintenanceError = ''; if (reload) await this.dataManager.refresh(); else await this.dataManager.start() }
    catch (error) { if (this.active) this.maintenanceError = coreErrorMessage(error as CoreBridgeError) }
    finally { if (this.active) { this.applySnapshot(); this.loading = false } }
  }
  build() {
    Column() {
    AppShell({ title: localizedText($r('app.string.text_trash')), titleIcon: $r('app.media.ui_delete'), activeRoute: 'pages/Trash', drawerOpen: $drawerOpen,
      back: this.hasParent, backAction: (): void => { this.onBackPress() } }) {
      Column() {
        if (this.message) {
          Text(localizedText($r('app.string.text_tap_to_try_again_2'), String(this.message))).fontSize(14).fontColor('#FFB4AB').padding(16).width('100%')
            .onClick((): void => { this.load(true) })
        }
        if (this.groups.length > 0 && this.dataManager) {
          LogbookTaskList({ trashMode: true, singleOperations: [TaskOperation.Restore, TaskOperation.Clear],
            bulkOperations: [TaskOperation.Restore, TaskOperation.Clear], ready: this.ready, dataSet: this.dataManager.tasks,
            groups: this.groups, referenceTime: this.referenceTime })
        } else {
          NotificationEmptyState({ title: this.loading ? localizedText($r('app.string.text_reading_waste_paper')) : localizedText($r('app.string.text_waste_paper_is_empty')),
            detail: localizedText($r('app.string.text_the_deleted_records_are_stored_here_left')), busy: this.loading })
        }
      }.width('100%').height('100%')
    }
    }.width('100%').height('100%')
  }
}
