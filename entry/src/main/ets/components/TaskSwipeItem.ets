import { TaskSelectionController } from '../ui/TaskSelectionController'
import { TaskRecordActionController } from '../ui/TaskRecordActionController'
import { TaskRecordOperations, TaskRecordOperation } from '../services/TaskRecordOperations'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { ProjectCreateService } from '../services/ProjectCreateService'
import { ProjectRepositoryOption } from '../ui/ProjectCreatePresentation'
import { TaskInlineSession } from '../services/TaskInlineService'
import { ProjectCreateSheet } from './editors/ProjectCreateSheet'
import { DataSet } from '../services/DataSet'
import { CoreTask, CoreTaskOperationGroup, CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { TaskSwipeOperations } from './TaskSwipeOperations'
import { TaskActionItem, TaskOperation, TaskSingleOperation, TaskRightSwipeAction, taskSingleMenu, taskSwipeMenu, taskActionPolicy, taskSwipeMenuWidth, taskSelectItem } from '../ui/TaskActionPresentation'
import { TaskStateCategory, taskStateToggleCategory, taskStateToggleWaitCategory } from '../ui/TaskStatePresentation'
import { TaskEditorController } from '../ui/TaskEditorController'
import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { RegionAreaPolicy, TaskDateDisplay, TaskTimeDisplay } from '../ui/TaskListPresentation'
import { TaskSwipeActions } from './TaskSwipeActions'
import { TaskSelectionRow } from './TaskSelectionRow'
import { TaskEditor } from './editors/TaskEditor'
import { RightSwipe, SwipeMenuCoordinator } from './controls/RightSwipe'
import { PopupMenuItem } from './controls/PopupMenu'

// 列表和文档共用双向滑动入口；页面专属菜单与动作通过插槽和回调接入。
@Component
export struct TaskSwipeItem {
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  @Prop readOnly: boolean = false
  @Prop busy: boolean = false
  @Prop interactionEnabled: boolean = true
  @Prop listItem: boolean = true
  menuCoordinator: SwipeMenuCoordinator | undefined = undefined
  @Prop listOutset: number = 0
  @Prop itemId: string = ''
  selection: TaskSelectionController | undefined = undefined
  @Prop menuIdPrefix: string = 'task_swipe'
  @Prop rightSwipeAction: TaskRightSwipeAction | undefined = undefined
  menuAvailable: (() => boolean) | undefined = undefined
  @BuilderParam menuContent: (activate: (action: TaskOperation) => void) => void = this.swipeMenu
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  @Prop contentHidden: boolean = false
  @Prop projectStructure: boolean = false
  @Prop canOrderChildren: boolean = false
  structureActions: (canOrder: boolean) => PopupMenuItem[] = () => []
  placeNode: () => void = () => {}
  selectNode: () => void = () => {}
  @Prop hiddenTags: string[] = []
  @Prop instanceKey: string = ''
  @Prop selecting: boolean = false
  @Prop selectionBusy: boolean = false
  @Prop selectedIndex: number = -1
  @Prop dateDisplay: TaskDateDisplay = TaskDateDisplay.None
  @Prop todayFlag: boolean = true
  @Prop timeDisplay: TaskTimeDisplay = TaskTimeDisplay.None
  @Prop regionAreaPolicy: RegionAreaPolicy | undefined = undefined
  @Prop referenceTime: number = Date.now()
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  private controller: TaskEditorController = new TaskEditorController((group: CoreTaskOperationGroup): void => {
    this.receiveOperation(group).catch((error: Error): void => { this.reportOperationError(error) })
  })
  @State projectOpen: boolean = false
  @State projectLoading: boolean = false
  @State projectGenerating: boolean = false
  @State projectTyping: boolean = false
  @State projectMessage: string = ''
  @State projectSource: CoreTask | undefined = undefined
  @State projectRepositories: ProjectRepositoryOption[] = []
  private projectOwner: string = ''
  private projectScope: string = ''
  private projectKeyboardAvoidMode: KeyboardAvoidMode | undefined = undefined
  private recordActions: TaskRecordActionController = new TaskRecordActionController()
  @State recordActionPending: boolean = false
  @State submitting: boolean = false
  @Prop @Watch('operationsChanged') singleOperations: TaskSingleOperation[] = []
  @State toggleStateCategory: TaskStateCategory | null = null
  @State toggleWaitCategory: TaskStateCategory | null = null
  @StorageLink('taskInlineTyping') inlineTyping: boolean = false
  @StorageLink('taskChecklistDragging') checklistDragging: boolean = false
  @BuilderParam content: (controller: TaskEditorController) => void = this.taskEditor
  private active: boolean = false
  private stopWatching: (() => void) | undefined = undefined

  aboutToAppear(): void {
    this.active = true
    this.operationsChanged()
  }
  aboutToDisappear(): void { this.active = false; this.recordActions.close(); this.closeProject(true); this.stopWatching?.(); this.stopWatching = undefined; this.controller.release() }

  private taskDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供页面数据管理对象')
    return this.dataSet
  }

  operationsChanged(): void {
    this.stopWatching?.(); this.stopWatching = undefined
    this.toggleStateCategory = null
    this.toggleWaitCategory = null
    if (!this.active || (!this.singleOperations.includes(TaskOperation.ToggleState) && !this.singleOperations.includes(TaskOperation.ToggleWait))) return
    this.stopWatching = this.taskDataSet().watchTask(this.taskId, (change): void => {
      if (!this.active) return
      if (this.singleOperations.includes(TaskOperation.ToggleState)) this.toggleStateCategory = taskStateToggleCategory(change.task)
      if (this.singleOperations.includes(TaskOperation.ToggleWait)) this.toggleWaitCategory = taskStateToggleWaitCategory(change.task)
    })
  }

  hostBlocked(): boolean {
    return !this.active || !this.interactionEnabled || this.readOnly || this.busy ||
      this.inlineTyping || this.checklistDragging
  }

  gesturesBlocked(): boolean { return this.hostBlocked() || this.recordActionPending || this.projectLoading || this.projectOpen }

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
    return action === TaskOperation.Select ? this.selection !== undefined :
      this.singleOperations.some(operation => operation === action) || this.rightSwipeAction === action
  }

  async activateOperation(action: TaskOperation): Promise<void> {
    const allowed = (): boolean => !this.hostBlocked() && this.operationEnabled(action)
    if (this.recordActionPending || this.projectOpen || this.projectLoading || !allowed()) return
    let group: CoreTaskOperationGroup | undefined = undefined
    try {
      switch (action) {
        case TaskOperation.Select: await this.selection?.start(this.taskId); return
        case TaskOperation.Reopen: case TaskOperation.Restore: case TaskOperation.Clear:
          await this.executeRecordAction(action, allowed); return
        case TaskOperation.Project: await this.openProject(allowed); return
        case TaskOperation.ToggleState:
          if (this.toggleStateCategory === TaskStateCategory.Doing) group = await this.controller.start(allowed)
          else if (this.toggleStateCategory === TaskStateCategory.Todo) group = await this.controller.stop(allowed)
          break
        case TaskOperation.ToggleWait:
          group = await this.controller.toggleWait(allowed)
          break
        case TaskOperation.Wait: group = await this.controller.wait(allowed); break
        case TaskOperation.Cancel: group = await this.controller.cancelTask(allowed); break
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

  private async executeRecordAction(action: TaskRecordOperation, allowed: () => boolean): Promise<void> {
    this.recordActionPending = true
    const dataSet = this.taskDataSet(), scope = dataSet.identity
    const valid = (): boolean => allowed() && scope === dataSet.identity
    try {
      if (!await TaskInlineSession.end(false)) return
      if (!valid()) return
      if (dataSet.error) throw new Error(dataSet.error)
      const source = dataSet.getTask(this.taskId)
      if (!source) throw new Error('任务已移除，请刷新后重试')
      const result = await this.recordActions.execute(this.getUIContext(), dataSet, [source], action, valid)
      if (valid() && result.retainedKeys.length) {
        try { this.getUIContext().getPromptAction().showToast({ message: TaskRecordOperations.retainedMessage(result.retainedKeys.length), duration: 3000 }) }
        catch (_) { /* 页面退出时提示可能不可用。 */ }
      }
    } finally { this.recordActionPending = false }
  }

  private async openProject(allowed: () => boolean): Promise<void> {
    this.projectLoading = true
    this.projectScope = this.taskDataSet().identity
    const valid = (): boolean => allowed() && this.taskDataSet().identity === this.projectScope
    try {
      if (this.listItem && this.scrollHost) {
        try { (this.scrollHost as ListScroller).closeAllSwipeActions() } catch (_) { /* 尚未绑定的列表无需收回菜单。 */ }
      }
      await new Promise<void>(resolve => setTimeout(resolve, 260))
      if (!valid() || !await TaskInlineSession.end(true)) return
      if (!valid()) return
      if (this.taskDataSet().error) throw new Error(this.taskDataSet().error)
      const source = this.taskDataSet().getTask(this.taskId)
      if (!source) return
      this.projectOwner = `project:${this.getUniqueId()}`
      if (!await TaskInlineSession.begin(this.projectOwner, async (): Promise<boolean> => {
        this.dismissProject()
        return false
      })) return
      const repositories = await ProjectCreateService.repositories(this.getUIContext().getHostContext()!)
      if (!valid()) return
      this.projectRepositories = repositories
      this.projectSource = source
      this.projectMessage = ''
      this.projectKeyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode()
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
      this.projectOpen = true
    } finally {
      this.projectLoading = false
      if (!this.projectOpen) this.closeProject()
    }
  }

  private dismissProject(): void {
    if (this.projectLoading || this.projectGenerating || this.submitting) return
    if (this.projectTyping) {
      this.getUIContext().getFocusController().clearFocus()
      this.projectTyping = false
      return
    }
    this.closeProject()
  }

  private closeProject(force: boolean = false): void {
    if (!force && (this.projectLoading || this.projectGenerating || this.submitting)) return
    if (this.projectKeyboardAvoidMode !== undefined) {
      this.getUIContext().setKeyboardAvoidMode(this.projectKeyboardAvoidMode)
      this.projectKeyboardAvoidMode = undefined
    }
    this.projectOpen = false
    this.projectTyping = false
    this.projectSource = undefined
    this.projectRepositories = []
    this.projectMessage = ''
    TaskInlineSession.release(this.projectOwner)
    this.projectOwner = ''
  }

  private async submitProject(group: CoreTaskOperationGroup): Promise<void> {
    if (!this.projectOpen || this.submitting) return
    this.projectMessage = ''
    try {
      const allowed = (): boolean => this.active && this.projectOpen && !this.hostBlocked() &&
        this.operationEnabled(TaskOperation.Project) && this.taskDataSet().identity === this.projectScope
      await this.submitOperationGroups([group], allowed)
      this.closeProject(true)
    } catch (error) { if (this.active) this.projectMessage = coreErrorMessage(error as CoreBridgeError) }
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
    const canSubmit = (): boolean => !this.hostBlocked() && allowed()
    if (!canSubmit()) throw new Error('操作已取消')
    this.submitting = true
    try { await TaskSwipeOperations.submit(this.taskDataSet(), groups, canSubmit) }
    finally { this.submitting = false }
  }

  swipeMenuItems(close?: () => void): TaskActionItem[] {
    const activate = (action: TaskOperation): void => { close?.(); this.activateOperation(action) }
    if (this.projectStructure) {
      const items = taskSingleMenu(this.singleOperations, activate, this.toggleStateCategory, this.toggleWaitCategory)
      items.unshift({ id: TaskOperation.Place, title: '放置', label: '在项目内放置任务', icon: $r('app.media.ui_place'),
        action: (): void => { close?.(); this.placeNode() } })
      items.push(taskSelectItem((): void => { close?.(); this.selectNode() }))
      return items
    }
    return this.selection ? taskSwipeMenu(taskActionPolicy({ singleOperations: this.singleOperations }), activate, this.toggleStateCategory, this.toggleWaitCategory) :
      taskSingleMenu(this.singleOperations, activate, this.toggleStateCategory, this.toggleWaitCategory)
  }

  @Builder
  swipeMenu(_activate: (action: TaskOperation) => void) {
    TaskSwipeActions({ busy: this.gesturesBlocked(), idPrefix: this.menuIdPrefix,
      items: this.swipeMenuItems() })
  }

  @Builder
  documentSwipeMenu(close: () => void) {
    TaskSwipeActions({ busy: this.gesturesBlocked() || this.submitting, idPrefix: this.menuIdPrefix,
      items: this.swipeMenuItems(close) })
  }

  @Builder
  projectPanel() {
    ProjectCreateSheet({ source: this.projectSource, repositories: this.projectRepositories,
      initialRepoId: this.projectSource?.repoId || '', initialRegion: this.projectSource?.category || '',
      initialName: this.projectSource?.heading || '', busy: this.submitting, generating: $projectGenerating,
      message: this.projectMessage, typingChanged: (typing: boolean): void => { this.projectTyping = typing },
      cancel: (): void => { this.closeProject() },
      generated: (group: CoreTaskOperationGroup): void => { this.submitProject(group) } })
  }

  @Builder
  editorContent(controller: TaskEditorController) {
    TaskEditor({ dataSet: this.dataSet, taskId: this.taskId, controller,
      internalLinkProcessor: this.internalLinkProcessor,
      contentHidden: this.contentHidden, hiddenTags: this.hiddenTags, instanceKey: this.instanceKey,
      structureActions: this.structureActions, canOrderChildren: this.canOrderChildren, projectStructure: this.projectStructure,
      readOnly: this.readOnly,
      dateDisplay: this.dateDisplay, todayFlag: this.todayFlag, timeDisplay: this.timeDisplay, regionAreaPolicy: this.regionAreaPolicy,
      referenceTime: this.referenceTime, scrollHost: this.scrollHost, scrollHostId: this.scrollHostId })
  }

  @Builder
  taskEditor(controller: TaskEditorController) {
    if (this.selection) {
      TaskSelectionRow({ selecting: this.selecting, busy: this.selectionBusy,
        selectedIndex: this.selectedIndex,
        heading: this.dataSet?.getTask(this.taskId)?.heading ?? '',
        begin: (): void => { this.selection?.start(this.taskId) },
        toggle: (): void => { this.selection?.toggle(this.taskId) } }) {
        this.editorContent(controller)
      }
    } else {
      this.editorContent(controller)
    }
  }

  @Builder
  swipeContent() {
    Column() {
      RightSwipe({ disabled: !this.interactionEnabled || this.readOnly || this.busy || this.rightSwipeAction === undefined,
        content: (): void => { this.content(this.controller) }, menuCoordinator: this.menuCoordinator,
        endMenu: (close: () => void): void => { this.documentSwipeMenu(close) },
        menuWidth: this.menuCoordinator && !this.gesturesBlocked() && !this.submitting ? taskSwipeMenuWidth(this.swipeMenuItems()) : 0,
        canOpenMenu: (): boolean => !this.submitting && !this.blocked(),
        canActivate: (): boolean => (this.listItem || !this.submitting) && this.rightSwipeAvailable(), action: (): void => {
          if (this.rightSwipeAction !== undefined) this.activateOperation(this.rightSwipeAction)
        } })
    }.width('100%').bindSheet($$this.projectOpen, this.projectPanel, {
      height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
      backgroundColor: '#363A38', showClose: false,
      onWillDismiss: (_action): void => { this.dismissProject() },
      onDisappear: (): void => { this.closeProject() }
    })
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
