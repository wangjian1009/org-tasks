import { DataSet } from '../services/DataSet'
import { CoreBridgeError, CoreTask, coreErrorMessage } from '../services/NativeCoreService'
import { TaskInlineSession } from '../services/TaskInlineService'
import { TaskOperation, taskSingleMenu } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'
import { TaskSwipeActions } from './TaskSwipeActions'

// 原生列表项统一承载左滑删除；卡片内容与右滑由内容槽保留。
@Component
export struct TaskSwipeItem {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  @Prop readOnly: boolean = false
  @Prop busy: boolean = false
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  @BuilderParam content: () => void = this.emptyContent
  @State preparing: boolean = false
  @State deleting: boolean = false
  @State confirming: boolean = false
  private active: boolean = false

  @Builder
  emptyContent() {}

  aboutToAppear(): void { this.active = true }
  aboutToDisappear(): void { this.active = false }

  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  blocked(): boolean {
    return !this.active || this.readOnly || this.busy || this.preparing || this.deleting || this.confirming ||
      this.inlineTyping || this.checklistDragging
  }

  report(error: Error): void {
    try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(error as CoreBridgeError), duration: 3000 }) }
    catch (_) { /* 页面退出时提示可能不可用。 */ }
  }

  async confirmDelete(): Promise<void> {
    if (this.blocked()) return
    this.preparing = true
    try {
      if (!await TaskInlineSession.end(false) || !this.active || this.readOnly || this.busy) return
      await this.taskDataSet().settle()
      if (!this.active || this.readOnly || this.busy) return
      if (this.taskDataSet().error) throw new Error(this.taskDataSet().error)
      const source = this.taskDataSet().getTask(this.taskId)
      if (!source) return
      this.confirming = true
      this.getUIContext().showAlertDialog({ title: '删除这条记录？',
        message: `“${source.heading}”及其子记录将从文件中删除。`,
        cancel: (): void => { this.confirming = false },
        primaryButton: { value: '取消', action: (): void => { this.confirming = false } },
        secondaryButton: { value: '删除', fontColor: UiColor.error,
          action: (): void => { this.confirming = false; this.deleteTask(source) } } })
    } catch (error) { this.confirming = false; this.report(error as Error) }
    finally { this.preparing = false }
  }

  async deleteTask(source: CoreTask): Promise<void> {
    if (this.blocked()) return
    this.deleting = true
    try {
      const current = this.taskDataSet().getTask(this.taskId)
      if (!current) return
      if (current.fileVersion !== source.fileVersion) throw new Error('文件已变化，请重新确认删除')
      await this.taskDataSet().removeTask(this.taskId)
    } catch (error) { this.report(error as Error) }
    finally { this.deleting = false }
  }

  @Builder
  deleteMenu() {
    TaskSwipeActions({ busy: this.blocked(), idPrefix: 'task_swipe',
      items: taskSingleMenu([TaskOperation.Delete], (): void => { this.confirmDelete() }) })
  }

  build() {
    ListItem() { this.content() }
      .swipeAction(this.blocked() ? {} : {
        end: { builder: (): void => { this.deleteMenu() } }, edgeEffect: SwipeEdgeEffect.None })
      .shouldBuiltInRecognizerParallelWith((_current: GestureRecognizer, others: GestureRecognizer[]): GestureRecognizer => {
        for (const recognizer of others) {
          if (recognizer.getTag() === 'shared_right_swipe') return recognizer
        }
        return _current
      })
  }
}
