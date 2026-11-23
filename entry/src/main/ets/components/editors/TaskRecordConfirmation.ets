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
          title: clear ? `永久清除 ${tasks.length} 条记录？` : tasks.length === 1 ? '删除这条记录？' : `删除 ${tasks.length} 条记录？`,
          message: clear ? '清除后无法恢复。确定永久删除所选记录？' : tasks.length === 1 ?
            `“${tasks[0].heading}”将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。` :
            '所选任务将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。',
          confirmLabel: clear ? '清除' : '删除',
          onCancel: (): void => { finish(false) },
          onConfirm: (): void => { finish(true) }
        })
      } catch (error) { this.cancelConfirmation = undefined; reject(error as Error) }
    })
  }
}
