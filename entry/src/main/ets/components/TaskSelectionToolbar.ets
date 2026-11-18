import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskBatchAction, TaskOperation, taskActionPolicy, taskBatchMenu } from '../ui/TaskActionPresentation'
import { TaskBatchToolbar } from './TaskBatchToolbar'
import { TaskBatchMoveSheet } from './editors/TaskBatchMoveSheet'
import { TaskBatchDateDialog } from './editors/TaskBatchDateDialog'

@Component
export struct TaskSelectionToolbar {
  @ObjectLink selection: TaskSelectionController
  @Prop operations: TaskBatchAction[] = []
  @Prop idPrefix: string = 'task_batch'

  build() {
    if (this.selection.selecting) {
      TaskBatchToolbar({ items: taskBatchMenu(taskActionPolicy({ bulkOperations: this.operations }), (action: TaskBatchAction): void => {
        this.selection.request(this.getUIContext(), action)
      }), count: this.selection.selectedKeys.length, busy: this.selection.blocked(),
        busyAction: this.selection.busyAction, invalid: this.selection.invalid, message: this.selection.message, idPrefix: this.idPrefix,
        retry: (): void => { this.selection.reset() }, cancel: (): void => { this.selection.reset() } })
      if (this.selection.pendingAction === TaskOperation.Move) {
        TaskBatchMoveSheet({ selection: this.selection })
      } else if (this.selection.pendingAction === TaskOperation.Schedule || this.selection.pendingAction === TaskOperation.Deadline) {
        TaskBatchDateDialog({ selection: this.selection, deadline: this.selection.pendingAction === TaskOperation.Deadline })
      }
    }
  }
}
