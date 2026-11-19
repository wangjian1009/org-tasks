import { DataSet } from '../services/DataSetManager'
import { CoreTask, CoreTaskModification, CoreTaskPlanningEdit, coreErrorMessage, CoreBridgeError } from '../services/NativeCoreService'
import { TaskEventManager } from '../services/TaskEventManager'
import { reminderPlanning, reminderModification } from '../ui/TaskReminderPresentation'
import { TaskDateDialog } from './editors/TaskDateDialog'
import { UiColor } from '../ui/Theme'

// 只消费全局事件管理器持有的 DataSet；离开设置页不关闭共享查询或事件维护。
@Component
export struct TaskReminderList {
  @State tasks: CoreTask[] = []
  @State loading: boolean = true
  @State message: string = ''
  @State busy: boolean = false
  @State revision: number = 0
  private dataSet: DataSet | undefined = undefined
  private stopData: (() => void) | undefined = undefined
  private stopStatus: (() => void) | undefined = undefined
  private dialog: CustomDialogController | undefined = undefined
  private active: boolean = false

  aboutToAppear(): void {
    this.active = true
    this.dataSet = TaskEventManager.dataSet(this.getUIContext().getHostContext()!)
    this.stopData = this.dataSet.subscribe((): void => { this.update() })
    this.stopStatus = TaskEventManager.subscribe((): void => { this.revision++ })
    this.load()
  }
  aboutToDisappear(): void {
    this.active = false; this.dialog?.close()
    this.stopData?.(); this.stopStatus?.()
  }
  private async load(): Promise<void> {
    this.loading = true; this.message = ''
    try {
      if (this.dataSet?.error) await this.dataSet.refresh()
      else await TaskEventManager.refresh(this.getUIContext().getHostContext()!)
    }
    catch (error) { if (this.active) this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { if (this.active) { this.loading = false; this.update() } }
  }
  private update(): void {
    if (!this.active || !this.dataSet) return
    const data = this.dataSet.data
    if (data?.type === 'task') this.tasks = data.result.tasks.slice()
    if (this.dataSet.error) this.message = this.dataSet.error
  }
  private label(task: CoreTask): string {
    const planning = reminderPlanning(task)
    return planning ? `${planning.date} ${planning.time?.start ?? ''}` : ''
  }
  private status(task: CoreTask): string {
    if (this.revision < 0) return ''
    return TaskEventManager.status(task)
  }
  private edit(task: CoreTask): void {
    if (this.busy || !this.dataSet?.isReady()) return
    const rowId = this.dataSet.taskKey(task.id)
    this.dialog = new CustomDialogController({
      builder: TaskDateDialog({ title: '提醒时间', selected: reminderPlanning(task)?.date ?? '',
        planning: reminderPlanning(task), allowTimeRange: false,
        confirmed: (change: CoreTaskModification): void => {
          if (!this.active) return
          const modification = reminderModification(task, change.value as CoreTaskPlanningEdit | null)
          if (modification.value !== task.reminderAt) this.save(rowId, task.fileVersion, modification)
        } }), customStyle: true, autoCancel: true, alignment: DialogAlignment.Center
    })
    this.dialog.open()
  }
  private async save(rowId: string, version: string, change: CoreTaskModification): Promise<void> {
    this.busy = true; this.message = ''
    try { await this.dataSet!.updateTaskFields(rowId, [change], version) }
    catch (error) { if (this.active) this.message = coreErrorMessage(error as CoreBridgeError) }
    finally { if (this.active) this.busy = false }
  }
  build() {
    Column({ space: 8 }) {
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(24).height(24).color(UiColor.primary)
          Text('正在读取提醒任务…').fontSize(14).fontColor(UiColor.secondary)
        }.width('100%').padding(16)
      }
      if (this.message) {
        Text(this.message).fontSize(14).fontColor(UiColor.error).width('100%').padding(16)
        Button('重新读取').onClick((): void => { this.load() }).enabled(!this.loading && !this.busy).margin(12)
      }
      if (!this.loading && !this.message && !this.tasks.length) {
        Text('暂无设置提醒时间的未完成任务').id('reminder_list_empty').fontSize(14).fontColor(UiColor.secondary).padding(20)
      }
      ForEach(this.tasks, (task: CoreTask) => {
        Column({ space: 6 }) {
          Text(task.heading).fontSize(16).fontColor(UiColor.text).width('100%')
          Text(this.label(task)).fontSize(14).fontColor(UiColor.primary).width('100%')
          Text(this.status(task)).fontSize(12).fontColor(UiColor.secondary).width('100%')
        }.id(`reminder_list_${task.id}`).width('100%').padding(16)
          .border({ width: { bottom: 0.5 }, color: UiColor.divider }).enabled(!this.busy)
          .accessibilityText(`${task.heading}，${this.label(task)}，点击修改提醒时间`)
          .onClick((): void => { this.edit(task) })
      // 行内没有草稿；版本变化时同步替换显示值及点击回调使用的编辑快照。
      }, (task: CoreTask): string => JSON.stringify([this.dataSet!.taskKey(task.id), task.fileVersion]))
    }.width('100%')
  }
}
