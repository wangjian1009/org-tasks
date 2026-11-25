import { localizedText } from '../../ui/LocalizedText'
import { UIContext } from '@kit.ArkUI'
import { CoreTask } from '../../services/NativeCoreService'
import { TaskRecordOperation } from '../../services/TaskRecordOperations'
import { TaskOperation } from '../../ui/TaskActionPresentation'
import { showDangerousConfirmation } from '../controls/DangerousConfirmation'

// 删除与永久清除的专用确认窗口；取消和控件退出只结束会话。
export class TaskRecordConfirmation {
  private cancelConfirmation: (() => void) | undefined = undefined
  close(): void { this.cancelConfirmation?.(); this.cancelConfirmation = undefined }

  open(context: UIContext, tasks: CoreTask[], action: TaskRecordOperation): Promise<boolean> {
    this.close()
    const clear = action === TaskOperation.Clear
    return new Promise<boolean>((resolve, reject): void => {
      let finished = false
      const finish = (confirmed: boolean): void => {
        if (finished) return
        finished = true; this.cancelConfirmation = undefined; resolve(confirmed)
      }
      this.cancelConfirmation = (): void => { finish(false) }
      try {
        showDangerousConfirmation(context, {
          title: clear ? localizedText($r('app.string.text_permanent_clearance_of_entry_records'), String(tasks.length)) : tasks.length === 1 ? localizedText($r('app.string.text_delete_this_record')) : localizedText($r('app.string.text_delete_record'), String(tasks.length)),
          message: clear ? localizedText($r('app.string.text_unable_to_recover_after_removal_determines_to')) : tasks.length === 1 ?
            localizedText($r('app.string.text_will_be_moved_to_the_waste_paper'), String(tasks[0].heading)) :
            localizedText($r('app.string.text_the_selected_task_will_be_moved_to')),
          confirmLabel: clear ? localizedText($r('app.string.text_delete_permanently')) : localizedText($r('app.string.text_delete')),
          onCancel: (): void => { finish(false) },
          onConfirm: (): void => { finish(true) }
        })
      } catch (error) { this.cancelConfirmation = undefined; reject(error as Error) }
    })
  }
}
