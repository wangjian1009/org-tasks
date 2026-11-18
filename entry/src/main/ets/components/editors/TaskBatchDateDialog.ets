import { TaskSelectionController } from '../../ui/TaskSelectionController'
import { TaskOperation } from '../../ui/TaskActionPresentation'
import { CoreTaskModification, CoreTaskPlanningEdit } from '../../services/NativeCoreService'
import { TaskDateDialog } from './TaskDateDialog'

// 日期窗口只返回修改数据；确认后由选择控制器发送一组操作。
@Component
export struct TaskBatchDateDialog {
  @ObjectLink selection: TaskSelectionController
  @Prop deadline: boolean = false
  private dialog: CustomDialogController | undefined = undefined
  private token: number = -1

  aboutToAppear(): void {
    this.token = this.selection.popupToken()
    const tasks = this.selection.tasks(), action = this.deadline ? TaskOperation.Deadline : TaskOperation.Schedule
    this.dialog = new CustomDialogController({
      builder: TaskDateDialog({ deadline: this.deadline, batch: tasks.length > 1,
        planning: tasks.length === 1 ? (this.deadline ? tasks[0].editContent.deadlinePlanning : tasks[0].editContent.scheduledPlanning) : null,
        selected: tasks.length === 1 ? (this.deadline ? tasks[0].deadline : tasks[0].scheduled) : '',
        confirmed: (modification: CoreTaskModification): void => {
          if (!this.selection.popupAvailable(action, this.token)) return
          this.selection.cancelPopup()
          this.selection.execute(this.getUIContext(), action, undefined, modification.value as CoreTaskPlanningEdit | null)
        },
        closed: (): void => { this.dismiss() } }),
      customStyle: true, autoCancel: false, alignment: DialogAlignment.Center,
      cancel: (): void => { this.dismiss() }
    })
    this.dialog.open()
  }
  dismiss(): void {
    if (this.token === this.selection.popupToken()) this.selection.cancelPopup()
  }
  aboutToDisappear(): void { this.dialog?.close(); this.dialog = undefined }
  build() { Column().width(0).height(0) }
}
