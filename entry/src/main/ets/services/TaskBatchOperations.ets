import { localizedText } from '../ui/LocalizedText'
import { Context } from '@kit.AbilityKit'
import { CoreTask, CoreTaskOperationGroup, CoreTaskPath, CoreRefileTarget, CoreTaskPlanningEdit } from './NativeCoreService'
import { InboxService } from './InboxService'
import { mergeTaskOperationGroups } from './TaskOperationGroups'
import { TaskBatchAction, TaskOperation } from '../ui/TaskActionPresentation'

export interface TaskBatchPlan { group: CoreTaskOperationGroup; mainPath?: CoreTaskPath }

// 只生成操作数据；执行和 operationId 分配统一交给当前 DataSet。
export class TaskBatchOperations {
  static async plan(context: Context, tasks: CoreTask[], sourceOrder: CoreTask[], action: TaskBatchAction,
    target?: CoreRefileTarget, date?: CoreTaskPlanningEdit | null): Promise<TaskBatchPlan> {
    if (action === TaskOperation.Merge) {
      const plan = await InboxService.mergePlan(context, tasks)
      return { group: plan.operationGroup, mainPath: plan.mainPath }
    }
    switch (action) {
      case TaskOperation.Move: case TaskOperation.Someday: case TaskOperation.Memo:
      case TaskOperation.Schedule: case TaskOperation.Deadline: {
        // 同名记录沿原列表逆序移出，避免前一条移动后 occurrence 改变。
        const ordered = [...tasks].sort((a: CoreTask, b: CoreTask): number =>
          sourceOrder.findIndex(item => item.id === b.id) - sourceOrder.findIndex(item => item.id === a.id))
        const groups = await InboxService.operationGroups(context, ordered, action, target, date)
        return { group: mergeTaskOperationGroups(groups) }
      }
      default: throw new Error(localizedText($r('app.string.text_this_operation_does_not_support_batch_planning')))
    }
  }
}
