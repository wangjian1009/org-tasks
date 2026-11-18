import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskBatchAction, taskActionPolicy, taskBatchMenu } from '../ui/TaskActionPresentation'
import { TaskBatchToolbar } from './TaskBatchToolbar'

@Component
export struct TaskSelectionToolbar {
  @ObjectLink selection: TaskSelectionController
  @Prop operations: TaskBatchAction[] = []
  @Prop idPrefix: string = 'task_batch'

  build() {
    if (this.selection.selecting) {
      TaskBatchToolbar({ items: taskBatchMenu(taskActionPolicy({ bulkOperations: this.operations }), (action: TaskBatchAction): void => {
        this.selection.execute(this.getUIContext(), action)
      }), count: this.selection.selectedKeys.length, busy: this.selection.busy,
        busyAction: this.selection.busyAction, idPrefix: this.idPrefix,
        cancel: (): void => { this.selection.reset() } })
    }
  }
}
