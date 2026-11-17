import { DataSet } from '../services/DataSet'
import { CoreTaskOperationGroup, CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { TaskSwipeOperations } from './TaskSwipeOperations'
import { TaskActionItem, TaskOperation, TaskSingleOperation, TaskRightSwipeAction, taskSingleMenu } from '../ui/TaskActionPresentation'
import { TaskStateCategory, taskStateToggleCategory } from '../ui/TaskStatePresentation'
import { TaskEditorController } from '../ui/TaskEditorController'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { RegionAreaPolicy, TaskDateDisplay, TaskTimeDisplay } from '../ui/TaskListPresentation'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskEditor } from './editors/TaskEditor'
import { RightSwipe } from './controls/RightSwipe'

// 列表和文档共用双向滑动入口；页面专属菜单与动作通过插槽和回调接入。
@Component
export struct TaskSwipeItem {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  @Prop readOnly: boolean = false
  @Prop busy: boolean = false
  @Prop interactionEnabled: boolean = true
  @Prop listItem: boolean = true
  @Prop listOutset: number = 0
  @Prop itemId: string = ''
  @Prop rightSwipeAction: TaskRightSwipeAction | undefined = undefined
  menuAvailable: (() => boolean) | undefined = undefined
  @BuilderParam menuContent: (activate: (action: TaskOperation) => void) => void = this.swipeMenu
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop contentHidden: boolean = false
  @Prop hiddenTags: string[] = []
  @Prop instanceKey: string = ''
  @Prop expandOnRowClick: boolean = false
  @Prop dateDisplay: TaskDateDisplay = TaskDateDisplay.None
  @Prop timeDisplay: TaskTimeDisplay = TaskTimeDisplay.None
  @Prop regionAreaPolicy: RegionAreaPolicy | undefined = undefined
  @Prop referenceTime: number = Date.now()
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  private controller: TaskEditorController = new TaskEditorController((group: CoreTaskOperationGroup): void => {
    this.receiveOperation(group).catch((error: Error): void => { this.reportOperationError(error) })
  })
  @State submitting: boolean = false
  @Prop @Watch('operationsChanged') singleOperations: TaskSingleOperation[] = []
  @State toggleStateCategory: TaskStateCategory | null = null
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  @BuilderParam content: (controller: TaskEditorController) => void = this.taskEditor
  private active: boolean = false
  private stopWatching: (() => void) | undefined = undefined

  aboutToAppear(): void {
    this.active = true
    this.operationsChanged()
  }
  aboutToDisappear(): void { this.active = false; this.stopWatching?.(); this.stopWatching = undefined; this.controller.release() }

  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  operationsChanged(): void {
    this.stopWatching?.(); this.stopWatching = undefined
    this.toggleStateCategory = null
    if (!this.active || !this.singleOperations.includes(TaskOperation.ToggleState)) return
    this.stopWatching = this.taskDataSet().watchTask(this.taskId, (change): void => {
      if (this.active && this.singleOperations.includes(TaskOperation.ToggleState)) this.toggleStateCategory = taskStateToggleCategory(change.task)
    })
  }

  hostBlocked(): boolean {
    return !this.active || !this.interactionEnabled || this.readOnly || this.busy ||
      this.inlineTyping || this.checklistDragging
  }

  gesturesBlocked(): boolean { return this.hostBlocked() || this.submitting }

  blocked(): boolean {
    return this.gesturesBlocked() || !!this.controller?.isBound() && !this.controller.canActivate()
  }

  rightSwipeAvailable(): boolean {
    return !this.blocked() && this.rightSwipeAction !== undefined && this.controller.canActivate()
  }

  leftSwipeAvailable(): boolean {
    // 原生菜单只依赖宿主响应式状态；编辑器在子控件更新期间的瞬时状态由按钮执行时校验。
    return !this.gesturesBlocked() && (this.menuAvailable ? this.menuAvailable() : this.swipeMenuItems().length > 0)
  }

  operationEnabled(action: TaskOperation): boolean {
    return this.singleOperations.some(operation => operation === action) || this.rightSwipeAction === action
  }

  async activateOperation(action: TaskOperation): Promise<void> {
    const allowed = (): boolean => !this.hostBlocked() && this.operationEnabled(action)
    if (this.submitting || !allowed()) return
    let group: CoreTaskOperationGroup | undefined = undefined
    try {
      switch (action) {
        case TaskOperation.ToggleState:
          if (this.toggleStateCategory === TaskStateCategory.Doing) group = await this.controller.start(allowed)
          else if (this.toggleStateCategory === TaskStateCategory.Todo) group = await this.controller.stop(allowed)
          break
        case TaskOperation.Delete: group = await this.controller.startDelete(allowed); break
        case TaskOperation.Move: group = await this.controller.startMove(allowed); break
        case TaskOperation.Schedule: group = await this.controller.startSchedule(allowed); break
        case TaskOperation.Deadline: group = await this.controller.startDeadline(allowed); break
        case TaskOperation.Someday: group = await this.controller.moveToSomeday(allowed); break
        case TaskOperation.Memo: group = await this.controller.convertToMemo(allowed); break
      }
      if (group) await this.receiveOperation(group, allowed)
    } catch (error) { this.reportOperationError(error as Error) }
  }

  private reportOperationError(error: Error): void {
    if (!this.active) return
    try { this.getUIContext().getPromptAction().showToast({ message: coreErrorMessage(error as CoreBridgeError), duration: 3000 }) }
    catch (_) { /* 页面退出后提示可能不可用。 */ }
  }

  async receiveOperation(group: CoreTaskOperationGroup, allowed: () => boolean = () => true): Promise<void> {
    if (this.hostBlocked() || !allowed()) return
    await this.submitOperationGroups([group], allowed)
  }

  async submitOperationGroups(groups: CoreTaskOperationGroup[], allowed: () => boolean = () => true): Promise<void> {
    if (this.submitting) throw new Error('任务操作正在提交，请稍后重试')
    const canSubmit = (): boolean => !this.hostBlocked() && allowed()
    if (!canSubmit()) throw new Error('操作已取消')
    this.submitting = true
    try { await TaskSwipeOperations.submit(this.taskDataSet(), groups, canSubmit) }
    finally { this.submitting = false }
  }

  swipeMenuItems(): TaskActionItem[] {
    return taskSingleMenu(this.singleOperations, (action: TaskSingleOperation): void => {
      this.activateOperation(action)
    }, this.toggleStateCategory)
  }

  @Builder
  swipeMenu(_activate: (action: TaskOperation) => void) {
    TaskSwipeActions({ busy: this.gesturesBlocked(), idPrefix: 'task_swipe',
      items: this.swipeMenuItems() })
  }

  @Builder
  taskEditor(controller: TaskEditorController) {
    TaskEditor({ dataSet: this.dataSet, taskId: this.taskId, controller,
      internalLinkProcessor: this.internalLinkProcessor,
      contentHidden: this.contentHidden, hiddenTags: this.hiddenTags, instanceKey: this.instanceKey,
      readOnly: this.readOnly, expandOnRowClick: this.expandOnRowClick,
      dateDisplay: this.dateDisplay, timeDisplay: this.timeDisplay, regionAreaPolicy: this.regionAreaPolicy,
      referenceTime: this.referenceTime, scrollHost: this.scrollHost, scrollHostId: this.scrollHostId })
  }

  @Builder
  swipeContent() {
    RightSwipe({ disabled: !this.interactionEnabled || this.readOnly || this.busy || this.rightSwipeAction === undefined,
      canActivate: (): boolean => this.rightSwipeAvailable(), action: (): void => {
        if (this.rightSwipeAction !== undefined) this.activateOperation(this.rightSwipeAction)
      } }) {
      this.content(this.controller)
    }
  }

  build() {
    if (this.listItem) {
      ListItem() { this.swipeContent() }
      .enabled(this.interactionEnabled)
      .id(this.itemId || this.taskId)
      .width(this.listOutset > 0 ? `calc(100% + ${this.listOutset * 2}vp)` : '100%')
      .margin({ left: -this.listOutset, right: -this.listOutset })
      .swipeAction(!this.leftSwipeAvailable() ? {} : {
        end: { builder: (): void => { this.menuContent((action: TaskOperation): void => { this.activateOperation(action) }) } }, edgeEffect: SwipeEdgeEffect.None })
      .shouldBuiltInRecognizerParallelWith((_current: GestureRecognizer, others: GestureRecognizer[]): GestureRecognizer => {
        for (const recognizer of others) {
          if (recognizer.getTag() === 'shared_right_swipe') return recognizer
        }
        return _current
      })
    } else {
      this.swipeContent()
    }
  }
}
