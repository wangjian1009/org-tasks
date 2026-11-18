import { UIContext } from '@kit.ArkUI'
import { DataSet } from '../services/DataSet'
import { CoreTask } from '../services/NativeCoreService'
import { TaskRecordOperations, TaskRecordOperation, TaskRecordResult } from '../services/TaskRecordOperations'
import { TaskOperation } from './TaskActionPresentation'
import { UiColor } from './Theme'

// 操作确认不提交数据；确认后以冻结快照规划的操作组统一提交。
export class TaskRecordActionController {
  private cancelConfirmation: (() => void) | undefined = undefined

  close(): void { this.cancelConfirmation?.(); this.cancelConfirmation = undefined }

  async execute(context: UIContext, dataSet: DataSet, tasks: CoreTask[], action: TaskRecordOperation,
    allowed: () => boolean): Promise<TaskRecordResult> {
    const cancelled: TaskRecordResult = { committed: false, retainedKeys: [] }
    if (!allowed()) return cancelled
    const group = await TaskRecordOperations.group(context.getHostContext()!, tasks, action)
    if (!allowed()) return cancelled
    if (action === TaskOperation.Delete || action === TaskOperation.Clear) {
      if (!await this.confirm(context, tasks, action) || !allowed()) return cancelled
    }
    return await TaskRecordOperations.submit(dataSet, tasks, action, group, allowed)
  }

  private confirm(context: UIContext, tasks: CoreTask[], action: TaskRecordOperation): Promise<boolean> {
    const clear = action === TaskOperation.Clear
    return new Promise<boolean>((resolve, reject): void => {
      let finished = false
      const finish = (confirmed: boolean): void => {
        if (finished) return
        finished = true; this.cancelConfirmation = undefined; resolve(confirmed)
      }
      this.cancelConfirmation = (): void => { finish(false) }
      try {
        context.showAlertDialog({
          title: clear ? `永久清除 ${tasks.length} 条记录？` : tasks.length === 1 ? '删除这条记录？' : `删除 ${tasks.length} 条记录？`,
          message: clear ? '清除后无法恢复。确定永久删除所选记录？' : tasks.length === 1 ?
            `“${tasks[0].heading}”将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。` :
            '所选任务将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。',
          cancel: (): void => { finish(false) },
          primaryButton: { value: '取消', action: (): void => { finish(false) } },
          secondaryButton: { value: clear ? '清除' : '删除', fontColor: UiColor.error, action: (): void => { finish(true) } }
        })
      } catch (error) { this.cancelConfirmation = undefined; reject(error as Error) }
    })
  }
}
