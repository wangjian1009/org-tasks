import { UIContext } from '@kit.ArkUI'
import { DataSet } from '../services/DataSet'
import { CoreTask } from '../services/NativeCoreService'
import { TaskRecordOperations, TaskRecordOperation, TaskRecordResult } from '../services/TaskRecordOperations'
import { TaskOperation } from './TaskActionPresentation'
import { TaskRecordConfirmation } from '../components/editors/TaskRecordConfirmation'

// 操作确认不提交数据；确认后以冻结快照规划的操作组统一提交。
export class TaskRecordActionController {
  private confirmation: TaskRecordConfirmation = new TaskRecordConfirmation()

  close(): void { this.confirmation.close() }

  async execute(context: UIContext, dataSet: DataSet, tasks: CoreTask[], action: TaskRecordOperation,
    allowed: () => boolean): Promise<TaskRecordResult> {
    const cancelled: TaskRecordResult = { committed: false, retainedKeys: [] }
    if (!allowed()) return cancelled
    const group = await TaskRecordOperations.group(context.getHostContext()!, tasks, action)
    if (!allowed()) return cancelled
    if (action === TaskOperation.Delete || action === TaskOperation.Clear) {
      if (!await this.confirmation.open(context, tasks, action) || !allowed()) return cancelled
    }
    return await TaskRecordOperations.submit(dataSet, tasks, action, group, allowed)
  }

}
