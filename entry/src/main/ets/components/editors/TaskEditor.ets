import { showDangerousConfirmation } from '../controls/DangerousConfirmation'
import { reminderPlanning, reminderModification, reminderTimeLabel } from '../../ui/TaskReminderPresentation'
import { PageNavigator } from '../../services/PageNavigator'
import { ReminderManager } from '../../services/ReminderManager'
import { CallbackInternalLinkProcessor, InternalLinkProcessor } from '../../ui/InternalLinkProcessor'
import { OrgFileNavigation } from '../../services/OrgFileNavigation'
import { TaskPriorityChoices } from './TaskPriorityChoices'
import { priorityColor, priorityBackground, priorityLabel } from '../../ui/TaskPriorityPresentation'
import { TaskEditorController } from '../../ui/TaskEditorController'
import { TaskEditorActionResult } from '../../ui/TaskEditorActionResult'
import { TaskStateCategory, taskStateCategoryLabel } from '../../ui/TaskStatePresentation'
import { CoreTask, CoreTaskChecklistItem, CoreTaskChecklistChange, CoreTaskModification, CoreTaskModificationOperation, CoreTaskPlanningEdit, CoreTaskOperationGroup, CoreRefileTarget, CoreBridgeError, coreErrorMessage } from '../../services/NativeCoreService'
import { TaskInlineSession } from '../../services/TaskInlineService'
import { DataSet, DataSetWriteError, TaskDataChange, TaskDataSource } from '../../services/DataSet'
import { InboxService } from '../../services/InboxService'
import { taskModificationGroup, taskMovementGroup } from '../../services/TaskOperationGroups'
import { TaskInlineMissingError } from '../../services/TaskInlineService'
import { TaskDateDialog } from './TaskDateDialog'
import { TaskRepeatDialog } from './TaskRepeatDialog'
import { repeatSummary } from '../../ui/TaskRepeatPresentation'
import { TaskTagsDialog } from './TaskTagsDialog'
import { TaskNoteDialog } from './TaskNoteDialog'
import { MoveToTarget } from './MoveToTarget'
import { RefileSection, refileSections } from '../../ui/MoveToTargetPresentation'
import { PopupMenuButton } from '../controls/PopupMenuButton'
import { PopupMenuItem } from '../controls/PopupMenu'
import { inlineDateLabel, inlineDate, inlinePlanningLabel } from '../../ui/TaskInlinePresentation'
import { UiColor, UiSize } from '../../ui/Theme'
import { taskDateIsToday, taskDateText, taskDeadlineColor, taskDeadlineText, taskDateForDisplay, TaskDateDisplay,
  TaskTimeDisplay, taskTimeForDisplay,
  taskDurationDays, taskIndicators, taskRowLayout, taskTagColor,
  TaskRowLayout, taskTitleText, taskSourceText, RegionAreaPolicy, TaskRegionArea, taskRegionArea } from '../../ui/TaskListPresentation'
import { TitleText } from '../TitleText'
import { LinkEditController } from '../LinkView'
import { CoreTextLink, CoreLinkValue } from '../../services/NativeCoreService'
import { DraftLinkAction, DraftLinkSelection } from './DraftLinkAction'
import { TaskContentEditor } from './TaskContentEditor'
import { ChecklistFocusFrame, TaskChecklistBlock } from './TaskChecklistBlock'
import { TaskBlockController } from '../../ui/TaskBlockController'
import { CoreContentBlockChange, CoreContentNode, CoreContentBlock } from '../../services/NativeCoreService'
import { LogShowPolicy, taskLogVisible, taskNoteEntries, taskEventLogs } from '../../ui/TaskLogPresentation'
import { TaskLogView } from './TaskLogView'
import { TitleCounts } from '../TitleCounts'
import { titleCounts, titleCountsWidth } from '../../ui/TitleCountPresentation'
import { TaskInlineFocus } from '../../ui/TaskInlineFocus'
import { TaskChecklistDrag, checklistSiblings, checklistMovePreview, checklistEdgeScroll, checklistBlockEnd } from '../../ui/TaskChecklistReorder'
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext'
import { window } from '@kit.ArkUI'

// 通用任务编辑器，可嵌入列表项或项目文档；宿主按需提供滚动容器和展示策略。
// 数据读写与变化监控均使用传入的管理对象；只维护卡片、输入草稿和浮层状态。
@Component
export struct TaskEditor {
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  dataSet: DataSet | undefined = undefined
  taskId: string = ''
  controller: TaskEditorController | undefined = undefined
  private stopDataSet: (() => void) | undefined = undefined
  private recordSource: TaskDataSource | undefined = undefined
  @Prop enableCompletionState: boolean = true
  @Prop readOnly: boolean = false
  @Prop previewTask: CoreTask | undefined = undefined
  @Prop titleOnly: boolean = false
  @Prop previewTitleLinks: boolean = false
  @Prop bodyOnly: boolean = false
  previewExpanded: () => void = () => {}
  @Prop logShowPolicy: LogShowPolicy = LogShowPolicy.LogShowBySwitch
  @Prop contentHidden: boolean = false
  @Prop documentContent: boolean = false
  @Prop @Watch('addContentRequested') addContentRequest: number = 0
  @State contentMenuRequest: number = 0
  @Prop includeStructureActions: boolean = false
  @Prop shortActionLabels: boolean = false
  @Prop @Watch('attentionChanged') attentionRequested: boolean = false
  @State attentionOpacity: number = 0
  private attentionVisible: boolean = false
  private attentionPlayed: boolean = false
  attentionStarted: () => void = () => {}
  @Prop canOrderChildren: boolean = false
  structureActions: (canOrder: boolean) => PopupMenuItem[] = () => []
  @Prop hiddenTags: string[] = []
  @Prop allowCompletion: boolean = false
  @Prop allowDeletion: boolean = false
  @State deleteConfirming: boolean = false
  private moveAllowed: () => boolean = () => true
  private pendingAction: TaskEditorActionResult | undefined = undefined
  @Prop instanceKey: string = ''
  @Prop dateDisplay: TaskDateDisplay = TaskDateDisplay.None
  @Prop todayFlag: boolean = true
  @Prop timeDisplay: TaskTimeDisplay = TaskTimeDisplay.None
  @Prop regionAreaPolicy: RegionAreaPolicy | undefined = undefined
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  @State @Watch('reminderExpansionChanged') expanded: boolean = false
  @State logbookExpanded: boolean = false
  @State @Watch('reminderTaskChanged') editTask: CoreTask | undefined = undefined
  @State heading: string = ''
  @State headingInput: boolean = false
  @State notes: string = ''
  private headingDirty: boolean = false
  private notesDirty: boolean = false
  private headingBaseline: string = ''
  private headingEditing: boolean = false
  private notesEditing: boolean = false
  @State blockEditing: boolean = false
  private blockSaving: boolean = false
  private blockEditor: TaskBlockController = new TaskBlockController()
  @State dragBlockId: string = ''
  @State linkEditing: boolean = false
  private linkSaving: boolean = false
  private linkEditor: LinkEditController = new LinkEditController()
  @State removed: boolean = false
  @State typing: boolean = false
  @State working: boolean = false
  @State completing: boolean = false
  @State priorityOpen: boolean = false
  @State priorityBusy: boolean = false
  @State moveOpen: boolean = false
  @State moveSource: CoreTask | undefined = undefined
  @State moveDetent: string = '70%'
  @State moveSections: RefileSection[] = []
  @State moveRepositoryNames: Map<string, string> = new Map()
  @State moveLoading: boolean = false
  @State moveBusy: boolean = false
  @State moveMessage: string = ''
  private moveRequest: number = 0
  @State message: string = ''
  @State rowWidth: number = 366
  @State deadlineWidth: number = 0
  private cancelledBoxPosition: Position | undefined = undefined
  private cancelledTitlePosition: Position | undefined = undefined
  @State private cancelLineWidth: number = 0
  @State private cancelLineOffset: number = 0
  @State checkId: string = ''
  @State checkText: string = ''
  @State addingCheck: boolean = false
  @State checkAfter: string = ''
  @State newCheck: string = ''
  @State draggingCheck: boolean = false
  @State droppingCheck: boolean = false
  @State dragTop: number = 0
  @State dragHeight: number = 0
  @State dragPlaceholder: number = 0
  @State dragValid: boolean = true
  @State dragItems: CoreTaskChecklistItem[] = []
  @State checkPreview: CoreTaskChecklistItem[] = []
  @State checkLayoutRevision: number = 0
  @State snapshotBlocked: boolean = false
  @Prop referenceTime: number = Date.now()
  private ownerKey: string = ''
  private appeared: boolean = false
  private refreshRequest: number = 0
  private dateDialog: CustomDialogController | undefined = undefined
  private tagsDialog: CustomDialogController | undefined = undefined
  private stopReminder: (() => void) | undefined = undefined
  @State reminderChecking: boolean = false
  @State reminderChecked: boolean = false
  @State reminderError: string = ''
  private reminderCheckRequest: number = 0
  private reminderCheckKey: string = ''
  private reminderDialog: CustomDialogController | undefined = undefined
  private repeatDialog: CustomDialogController | undefined = undefined
  private noteDialog: CustomDialogController | undefined = undefined
  private noteFinish: ((note: string | undefined) => void) | undefined = undefined
  private noteInputOpen: boolean = false
  private pending: Promise<void> = Promise.resolve()
  private checkSaving: Promise<boolean> | undefined = undefined
  private continueCheck: boolean = false
  @State private checklistTouch: boolean = false
  private checkHeights: Map<string, number> = new Map()
  private checkScroller: ListScroller = new ListScroller()
  private checkDrag: TaskChecklistDrag | undefined = undefined
  private checkScrollTimer: number = -1
  private dragPointerX: number = 0
  private dragPointerY: number = 0
  private compactTouchMoved: boolean = false
  private compactTouchX: number = 0
  private compactTouchY: number = 0
  private dragEpoch: number = 0
  private gripPress: string = ''
  private gripX: number = 0
  private gripY: number = 0
  private headingController: TextAreaController = new TextAreaController()
  private headingSelection: DraftLinkSelection = new DraftLinkSelection()
  private hostWindow: window.Window | undefined = undefined
  private checkFocus: TaskInlineFocus = new TaskInlineFocus(
    (callback: () => void) => { this.getUIContext().postFrameCallback(new ChecklistFocusFrame(callback)) },
    (key: string) => { this.getUIContext().getFocusController().requestFocus(key) })
  private keyboardChanged = (height: number): void => {
    // 备注窗口独占输入；不能把其键盘视为卡片正文输入并阻止返回的操作组。
    if (this.noteInputOpen) return
    if (!this.expanded && (!this.bodyOnly || !TaskInlineSession.owns(this.ownerKey))) return
    this.typing = height > 0
    AppStorage.setOrCreate('taskInlineTyping', this.typing)
  }

  actionsAvailable(): boolean {
    return this.appeared && !this.readOnly && !this.completing && !this.working && !this.moveBusy && !this.moveOpen &&
      !this.snapshotBlocked && !this.removed && !this.typing && !this.checklistTouch && !this.draggingCheck && !this.deleteConfirming && !this.pendingAction
  }
  value(): CoreTask { return this.previewTask ?? this.editTask ?? this.recordSource?.task! }
  private localDataSet(): DataSet {
    if (!this.dataSet) throw new Error('未提供任务数据管理对象')
    return this.dataSet
  }
  private async currentTask(): Promise<CoreTask> {
    if (!this.recordSource) this.recordSource = this.localDataSet().taskSource(this.taskId)
    const task = this.recordSource.task
    if (!task) throw new TaskInlineMissingError()
    return task
  }
  private async modifyTask(task: CoreTask, changes: CoreTaskModification[]): Promise<void> {
    await this.localDataSet().updateTaskFields(this.recordSource?.rowId ?? this.taskId, changes, task.fileVersion)
  }

  deletionAvailable(): boolean {
    return this.appeared && (!this.readOnly || this.allowDeletion) && !this.completing && !this.working && !this.moveBusy && !this.moveOpen &&
      !this.snapshotBlocked && !this.removed && !this.typing && !this.checklistTouch && !this.draggingCheck && !this.deleteConfirming && !this.pendingAction
  }

  private actionError(error: Error): void {
    if (!this.appeared) return
    if (error instanceof TaskInlineMissingError) { this.removeDeletedTask(); return }
    this.message = coreErrorMessage(error as CoreBridgeError)
    try { this.getUIContext().getPromptAction().showToast({ message: this.message, duration: 3000 }) }
    catch (_) { /* 页面退出后提示可能不可用。 */ }
  }

  private async actionSource(allowed: () => boolean): Promise<CoreTask | undefined> {
    if (!allowed() || !await this.prepare() || !await this.finish(false)) return undefined
    if (!this.appeared || this.removed || !allowed()) return undefined
    if (this.localDataSet().error) throw new Error(this.localDataSet().error)
    const source = await this.currentTask()
    return this.appeared && !this.removed && allowed() ? source : undefined
  }

  async start(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.changeState([TaskStateCategory.Todo, TaskStateCategory.Wait], TaskStateCategory.Doing, allowed)
  }
  private async requestNote(stateChange: boolean): Promise<string | undefined> {
    return await new Promise<string | undefined>((resolve) => {
      this.noteInputOpen = true
      let settled: boolean = false
      const finish = (note: string | undefined): void => {
        if (settled) return
        settled = true; this.noteFinish = undefined; resolve(note)
      }
      this.noteFinish = finish
      this.noteDialog = new CustomDialogController({
        builder: TaskNoteDialog({ stateChange, finished: finish }),
        customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
        onDidDisappear: (): void => { this.noteInputOpen = false },
        onWillDismiss: (action: DismissDialogAction): void => { finish(undefined); action.dismiss() }
      })
      this.noteDialog.open()
    })
  }
  private async withStateNote(source: CoreTask, group: CoreTaskOperationGroup, allowed: () => boolean): Promise<CoreTaskOperationGroup | undefined> {
    const required = source.editContent.noteRequiredStates ?? []
    const needsNote = group.operations.some((operation): boolean => {
      if (operation.type !== 'Modification') return false
      const data = operation.data as CoreTaskModificationOperation
      return data.modifications.some((change: CoreTaskModification): boolean =>
        change.field === 'TODO' && typeof change.value === 'string' && required.includes(change.value))
    })
    if (needsNote) {
      const note = await this.requestNote(true)
      if (note !== undefined && note.trim()) {
        group.operations.forEach((operation): void => {
          if (operation.type !== 'Modification') return
          const data = operation.data as CoreTaskModificationOperation
          if (data.modifications.some((change: CoreTaskModification): boolean => change.field === 'TODO')) data.note = note
        })
      }
    }
    return this.appeared && !this.removed && allowed() ? group : undefined
  }
  async startNote(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return undefined
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (!source) return undefined
      const note = await this.requestNote(false)
      if (note === undefined || !note.trim() || !this.appeared || this.removed || !allowed()) return undefined
      return { operations: [{ type: 'Note', data: { path: source.fullPath, note } }],
        fileVersions: [{ repoId: source.repoId, file: source.filePath, version: source.fileVersion }] }
    } finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }
  async stop(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.changeState([TaskStateCategory.Doing], TaskStateCategory.Todo, allowed)
  }
  async wait(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.changeState(undefined, TaskStateCategory.Wait, allowed)
  }
  async cancelTask(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.changeState(undefined, TaskStateCategory.Cancel, allowed)
  }
  async toggleWait(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (!source || !allowed()) return
      const category = source.state?.category
      const to = category === TaskStateCategory.Wait ? TaskStateCategory.Todo :
        (category === TaskStateCategory.Todo || category === TaskStateCategory.Doing) ? TaskStateCategory.Wait : undefined
      if (to === undefined) return
      const state = source.taskStateOf(to)
      if (!state) {
        if (to === TaskStateCategory.Wait) throw new Error('文件没有可用的等待状态，请检查 TODO 流程')
        return
      }
      return await this.withStateNote(source, taskModificationGroup(source, [{ field: 'TODO', value: state.name }]), allowed)
    } finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }
  private async changeState(from: TaskStateCategory[] | undefined, to: TaskStateCategory, allowed: () => boolean): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (!source || !allowed() || (from !== undefined && !from.some(category => source.state?.category === category)) || source.state?.category === to) return
      const state = source.taskStateOf(to)
      if (!state) {
        if (to === TaskStateCategory.Wait) throw new Error('文件没有可用的等待状态，请检查 TODO 流程')
        if (to === TaskStateCategory.Cancel) throw new Error('文件没有可用的取消状态，请检查 TODO 流程')
        return
      }
      const modifications: CoreTaskModification[] = [{ field: 'TODO', value: state.name }]
      if (to === TaskStateCategory.Doing) {
        const now = new Date()
        const today = `${now.getFullYear().toString().padStart(4, '0')}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`
        if (!source.scheduled || source.scheduled > today) modifications.push({ field: 'SCHEDULE', value: { date: today } })
      }
      return await this.withStateNote(source, taskModificationGroup(source, modifications), allowed)
    }
    finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }

  async startDelete(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.deletionAvailable() || !allowed()) return undefined
    this.completing = true
    let action: TaskEditorActionResult | undefined = undefined
    try {
      const source = await this.actionSource(allowed)
      if (!source || !allowed()) return undefined
      const groups = await InboxService.operationGroups(this.getUIContext().getHostContext()!, [source], 'delete')
      if (!this.appeared || !allowed()) return undefined
      const result = new TaskEditorActionResult()
      action = result; this.pendingAction = result
      this.deleteConfirming = true
      showDangerousConfirmation(this.getUIContext(), { title: '删除这条记录？', message: `“${source.heading}”将移入废纸篓，可在废纸篓中恢复。有子记录时请先处理子记录。`,
        onCancel: (): void => { this.cancelDelete() },
        confirmLabel: '删除', onConfirm: (): void => {
          if (!this.appeared || !allowed()) { result.finish(); return }
          result.finish(groups[0])
        } })
      this.completing = false
      return await result.result
    } catch (error) { this.actionError(error as Error); return undefined }
    finally {
      this.completing = false; this.deleteConfirming = false
      if (this.pendingAction === action) this.pendingAction = undefined
      if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  private cancelDelete(): void { if (this.appeared) this.pendingAction?.finish() }

  async remove(allowed: () => boolean = () => true, expectedVersion?: string): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.deletionAvailable() || !allowed()) return
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (!source) return
      if (expectedVersion && source.fileVersion !== expectedVersion) throw new Error('文件已变化，请重新确认删除')
      const groups = await InboxService.operationGroups(this.getUIContext().getHostContext()!, [source], 'delete')
      return groups[0]
    } finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }

  private async emitAction(action: Promise<CoreTaskOperationGroup | undefined>): Promise<void> {
    try {
      const group = await action
      if (!group || !this.appeared) return
      if (!this.controller) throw new Error('编辑器未接入修改操作接收接口')
      this.controller.emitOperation(group)
    } catch (error) { this.actionError(error as Error) }
  }

  async moveToSomeday(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> { return await this.organize('someday', allowed) }
  async convertToMemo(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> { return await this.organize('memo', allowed) }
  private async organize(destination: 'someday' | 'memo', allowed: () => boolean): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (!source || !allowed()) return
      const groups = await InboxService.operationGroups(this.getUIContext().getHostContext()!, [source], destination)
      if (!this.appeared || !allowed()) return
      return await this.withStateNote(source, groups[0], allowed)
    }
    finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }

  async startMove(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return undefined
    this.completing = true
    let action: TaskEditorActionResult | undefined = undefined
    try {
      const current = await this.actionSource(allowed)
      if (!current) return undefined
      const result = new TaskEditorActionResult()
      action = result; this.pendingAction = result
      this.applySnapshot(current)
      this.moveDetent = '70%'
      this.moveAllowed = allowed; this.moveSource = current; this.moveOpen = true
      this.completing = false
      this.loadMoveTargets()
      return await result.result
    } catch (error) { this.actionError(error as Error); return undefined }
    finally {
      this.completing = false
      if (this.pendingAction === action) this.pendingAction = undefined
      if (this.moveOpen) this.closeMove()
      if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }

  private async refreshMove(): Promise<void> {
    if (!this.appeared || !this.moveOpen || this.moveBusy || !this.moveAllowed()) return
    try {
      const source = await this.currentTask()
      if (!this.appeared || !this.moveOpen || !this.moveAllowed()) return
      this.moveSource = source
      await this.loadMoveTargets()
    } catch (error) { if (this.appeared) this.moveMessage = coreErrorMessage(error as CoreBridgeError) }
  }

  async loadMoveTargets() {
    const request = ++this.moveRequest
    this.moveLoading = true
    this.moveMessage = ''
    this.moveSections = []
    try {
      const snapshot = await this.localDataSet().moveTargets()
      if (request === this.moveRequest && this.moveOpen) {
        this.moveRepositoryNames = snapshot.repositoryNames
        this.moveSections = refileSections(snapshot.targets)
      }
    } catch (error) {
      if (request === this.moveRequest && this.moveOpen) this.moveMessage = coreErrorMessage(error as CoreBridgeError)
    } finally {
      if (request === this.moveRequest) this.moveLoading = false
    }
  }

  closeMove(dismiss?: () => void): void {
    if (!this.moveOpen || this.moveBusy) return
    ++this.moveRequest
    this.pendingAction?.finish()
    this.moveOpen = false
    dismiss?.()
    this.moveSource = undefined
    this.moveSections = []
    this.moveLoading = false
    this.moveMessage = ''
    if (!this.expanded) TaskInlineSession.release(this.ownerKey)
  }

  async moveTo(target: CoreRefileTarget, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.appeared || this.readOnly || this.removed || this.snapshotBlocked || !allowed()) return
    const source = this.moveSource ?? await this.actionSource(allowed)
    if (!source) return
    const current = await this.currentTask()
    if (current.fileVersion !== source.fileVersion) throw new Error('文件已变化，请刷新移动位置后重试')
    if (!this.appeared || !allowed()) return
    return taskMovementGroup(current, target)
  }

  private confirmMove(target: CoreRefileTarget): void {
    const source = this.moveSource
    if (!this.appeared || !source || !this.moveOpen || this.moveLoading || this.moveBusy || !this.moveAllowed()) return
    this.pendingAction?.finish(taskMovementGroup(source, target))
    this.closeMove()
  }

  @Builder
  moveSourcePreview() {
    if (this.moveSource) {
      TaskMovePreview({ tasks: [this.moveSource], hiddenTags: this.hiddenTags, expandPanel: (): void => { this.moveDetent = '90%' } })
    }
  }

  @Builder
  movePanel() {
    MoveToTarget({ sections: this.moveSections, repositoryNames: this.moveRepositoryNames,
      selectionKey: this.moveSource ? JSON.stringify([this.moveSource.fullPath, this.moveSource.fileVersion]) : '',
      loading: this.moveLoading, busy: this.moveBusy, message: this.moveMessage, close: (): void => { this.closeMove() },
      sourcePreview: (): void => { this.moveSourcePreview() },
      choose: (target: CoreRefileTarget): void => { this.confirmMove(target) }, retry: (): void => { this.refreshMove() } })
  }

  async complete() {
    if (this.readOnly && !this.allowCompletion) return
    const reopen = this.value().isDone()
    const category = reopen ? TaskStateCategory.Todo : TaskStateCategory.Done
    if (this.completing || this.working || this.snapshotBlocked || this.value().state === null || !this.value().taskStateOf(category)) return
    this.completing = true
    try {
      if (!await this.prepare() || !await this.finish(false)) return
      const source = await this.currentTask()
      const state = source.taskStateOf(category)
      if (source.state === null || source.isDone() !== reopen || !state) return
      const group = await this.withStateNote(source, taskModificationGroup(source, [{ field: 'TODO', value: state.name }]), () => this.appeared && !this.removed)
      if (!group) return
      await this.localDataSet().submitOperationGroup(group, () => this.appeared && !this.removed)
      const current = this.recordSource?.task
      if (current) this.applySnapshot(current)
      else this.removeDeletedTask()
      this.expanded = false
    } catch (error) { this.actionError(error as Error)
    } finally {
      this.completing = false
      if (!this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  applySnapshot(current: CoreTask | undefined, savedCheck: boolean = false) {
    if (!current) { this.removeDeletedTask(); return }
    if (this.draggingCheck && current.fileVersion !== this.value().fileVersion) this.cancelCheckDrag()
    if (this.blockEditing && !this.blockSaving && current.fileVersion !== this.value().fileVersion) {
      this.snapshotBlocked = true; this.message = '文件已变化，区块草稿已保留。'
      return
    }
    if (this.linkEditing && !this.linkSaving && current.fileVersion !== this.value().fileVersion) {
      this.snapshotBlocked = true; this.message = '文件已变化，链接草稿已保留，请取消编辑并重新载入后继续'
      return
    }
    if ((this.checkId || this.checkAfter) && current.fileVersion !== this.value().fileVersion && !savedCheck) {
      this.snapshotBlocked = true
      this.message = '文件已变化，清单输入已保留，请重新载入后继续编辑'
      return
    }
    if (!this.headingEditing) this.heading = current.heading
    if (!this.notesEditing) this.notes = current.editContent.notes.trimEnd()
    this.editTask = current
    if (this.snapshotBlocked) this.message = ''
    this.snapshotBlocked = false
  }
  removeDeletedTask() {
    if (this.removed) return
    this.priorityOpen = false
    this.closeMove()
    this.pendingAction?.finish()
    this.removed = true; this.snapshotBlocked = true
    this.expanded = false; this.typing = false; this.message = ''
    this.headingEditing = false; this.notesEditing = false
    this.headingInput = false
    this.continueCheck = false
    this.checkFocus.cancel()
    this.cancelCheckDrag()
    this.dateDialog?.close(); this.tagsDialog?.close(); this.repeatDialog?.close(); this.reminderDialog?.close()
    this.noteFinish?.(undefined); this.noteDialog?.close()
    TaskInlineSession.release(this.ownerKey)
  }
  aboutToAppear() {
    if (this.previewTask) { this.ownerKey = this.instanceKey; return }
    this.stopDataSet?.()
    this.recordSource = this.localDataSet().taskSource(this.taskId)
    this.ownerKey = this.instanceKey || this.recordSource.rowId
    this.appeared = true
    if (!this.bodyOnly) {
      this.stopReminder = ReminderManager.subscribe((): void => {
        if (this.reminderExpired() || !this.reminderChecking) this.checkReminder(true)
      })
    }
    this.controller?.bind(this)
    this.stopDataSet = this.recordSource.monitor((change: TaskDataChange): void => {
      if (!this.appeared) return
      ++this.refreshRequest
      if (change.removed) { this.removeDeletedTask(); return }
      if (change.error) {
        for (const field of change.rejectedChanges ?? []) {
          if (field.field === 'TITLE' && this.heading === field.value) { this.headingEditing = true; this.headingDirty = true }
          if (field.field === 'NOTES' && this.notes === field.value) { this.notesEditing = true; this.notesDirty = true }
        }
        if (change.task) this.applySnapshot(change.task)
        if (change.blocked) this.snapshotBlocked = true
        this.message = change.error
        return
      }
      if (change.task) this.applySnapshot(change.task)
    })
  }
  aboutToDisappear() {
    if (this.previewTask) return
    this.stopReminder?.(); this.stopReminder = undefined
    ++this.reminderCheckRequest
    this.stopDataSet?.(); this.stopDataSet = undefined; this.recordSource = undefined
    this.priorityOpen = false
    this.deleteConfirming = false
    this.appeared = false
    this.attentionVisible = false
    this.attentionOpacity = 0
    this.pendingAction?.finish()
    this.pendingAction = undefined
    this.controller?.release()
    this.closeMove()
    ++this.refreshRequest
    this.cancelCheckDrag()
    this.checkFocus.dispose()
    this.dateDialog?.close(); this.tagsDialog?.close(); this.repeatDialog?.close(); this.reminderDialog?.close()
    this.noteFinish?.(undefined); this.noteDialog?.close()
    if (this.hostWindow) this.hostWindow.off('keyboardHeightChange', this.keyboardChanged)
    TaskInlineSession.release(this.ownerKey)
  }

  private attentionChanged(): void {
    if (!this.attentionRequested) {
      this.attentionPlayed = false
      return
    }
    if (!this.appeared || !this.attentionVisible || this.attentionPlayed) return
    this.attentionPlayed = true
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 120, curve: Curve.EaseOut, event: (): void => { this.attentionOpacity = 0.32 } },
      { duration: 260, curve: Curve.Linear, event: (): void => { this.attentionOpacity = 0.34 } },
      { duration: 520, curve: Curve.EaseOut, event: (): void => { this.attentionOpacity = 0 } }
    ])
    this.attentionStarted()
  }
  async prepare(): Promise<boolean> {
    if (this.removed) return false
    if (!this.recordSource) this.recordSource = this.localDataSet().taskSource(this.taskId)
    if (!this.ownerKey) this.ownerKey = this.instanceKey || this.recordSource.rowId
    if (!await TaskInlineSession.begin(this.ownerKey, async (collapse: boolean) => await this.finish(collapse))) return false
    if (!this.editTask) {
      const task = this.recordSource.task
      if (!task) return false
      this.editTask = task; this.heading = task.heading; this.notes = task.editContent.notes.trimEnd()
    }
    if (this.readOnly) return true
    this.applySnapshot(this.recordSource.task)
    if (!this.hostWindow) {
      try {
        this.hostWindow = await window.getLastWindow(this.getUIContext().getHostContext()!)
        this.hostWindow.on('keyboardHeightChange', this.keyboardChanged)
      } catch (_) {}
    }
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    return true
  }
  async toggle() {
    if (this.expanded) { await this.finish(true); return }
    await this.expand()
  }
  private async expand(): Promise<void> {
    if (!this.previewTask && !await this.prepare()) return
    this.logbookExpanded = false
    this.referenceTime = Date.now()
    if (this.previewTask) this.previewExpanded()
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = true })
  }
  async addContentRequested(): Promise<void> {
    const request = this.addContentRequest
    if (!request || this.bodyOnly || this.contentHidden || this.readOnly || this.working || this.snapshotBlocked) return
    if (!this.expanded) await this.expand()
    if (this.expanded && request === this.addContentRequest) this.contentMenuRequest = request
  }
  private collapseAnimated(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = false })
  }
  private compactTouch(event: TouchEvent): void {
    const touch = event.touches[0]
    if (event.type === TouchType.Down && touch) {
      this.compactTouchMoved = false
      this.compactTouchX = touch.windowX
      this.compactTouchY = touch.windowY
    } else if (event.type === TouchType.Move && touch &&
      Math.hypot(touch.windowX - this.compactTouchX, touch.windowY - this.compactTouchY) > 8) {
      this.compactTouchMoved = true
    } else if (event.type === TouchType.Cancel) {
      this.compactTouchMoved = true
    }
  }
  private toggleFromCompact(): void {
    if (this.titleOnly || this.compactTouchMoved) return
    this.toggle()
  }
  async finish(collapse: boolean): Promise<boolean> {
    if (this.readOnly) {
      if (collapse) {
        this.collapseAnimated()
        if (!this.previewTask) TaskInlineSession.release(this.ownerKey)
      }
      return true
    }
    if (this.moveBusy || this.headingSelection.busy) return false
    if (collapse && this.moveOpen) this.closeMove()
    this.cancelCheckDrag()
    this.continueCheck = false
    this.checkFocus.cancel()
    this.headingController.stopEditing()
    this.getUIContext().getFocusController().clearFocus()
    this.typing = false; AppStorage.setOrCreate('taskInlineTyping', false)
    if (!await this.saveText() || !await this.saveCheck(false)) return false
    await this.pending
    this.checkFocus.cancel()
    if (this.snapshotBlocked) return false
    if (!this.newCheck.trim() && !this.checkId) { this.addingCheck = false; this.checkAfter = '' }
    this.headingInput = false
    if (!this.snapshotBlocked) this.message = ''
    if (collapse) {
      this.priorityOpen = false
      if (!this.bodyOnly) this.collapseAnimated()
      TaskInlineSession.release(this.ownerKey)
    }
    return true
  }
  inputFocus() {
    if (this.readOnly) return
    this.typing = true; AppStorage.setOrCreate('taskInlineTyping', true)
  }

  async editHeading() {
    if (this.readOnly || this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.blockEditor.finish() || !await this.linkEditor.finish() || this.snapshotBlocked || this.removed) return
    if (!this.headingEditing) {
      this.headingBaseline = this.value().heading
      this.headingSelection.reset()
    }
    this.headingInput = true
    this.checkFocus.request(`inline_title_${this.ownerKey}`)
  }

  async finishHeading() {
    if (this.headingSelection.busy) return
    if (await this.saveText()) this.headingInput = false
  }

  private changeHeading(value: string): void {
    this.heading = value
    this.headingEditing = true
    this.headingDirty = value !== this.headingBaseline
  }

  async persist(modifications: CoreTaskModification[], sourceVersion?: string): Promise<boolean> {
    if (this.readOnly && !this.allowCompletion) return false
    if (this.snapshotBlocked) return false
    let success: boolean = false
    const operation = this.pending.then(async () => {
      if (this.removed || this.snapshotBlocked) return
      this.working = true; this.message = ''
      try {
        const source = this.value()
        if (sourceVersion !== undefined && sourceVersion !== source.fileVersion) throw new Error('文件已变化，请重新选择移动位置')
        const waitForCommit = sourceVersion !== undefined || modifications.some(modification => modification.field === 'CHECKLIST')
        const confirmed = waitForCommit ? await this.localDataSet().commitTaskFields(this.recordSource?.rowId ?? this.taskId, modifications, sourceVersion ?? source.fileVersion) : undefined
        if (!waitForCommit) await this.modifyTask(source, modifications)
        for (const modification of modifications) {
          if (modification.field === 'TITLE' && this.heading === modification.value) { this.headingEditing = false; this.headingDirty = false }
          if (modification.field === 'NOTES' && this.notes === modification.value) { this.notesEditing = false; this.notesDirty = false }
        }
        success = true
        // 下一次编辑直接使用管理类的本地快照，无需等待底层确认。
        ++this.refreshRequest
        const current = confirmed ?? await this.currentTask()
        const savedCheck = modifications.some((modification: CoreTaskModification): boolean => {
          if (modification.field !== 'CHECKLIST') return false
          const change = modification.value as CoreTaskChecklistChange
          return change.type === 'edit' && change.id === this.checkId && change.text === this.checkText ||
            change.type === 'insertAfter' && change.id === this.checkAfter && change.text === this.newCheck
        })
        if (this.appeared && !this.removed) this.applySnapshot(current, savedCheck)
      } catch (error) {
        success = success || (error as DataSetWriteError).committed === true
        // 移动或删除的事件可能晚于保存前读取；源节点已消失时直接结束原会话。
        if (error instanceof TaskInlineMissingError) this.removeDeletedTask()
        else {
          if (success) this.snapshotBlocked = true
          this.message = success ? `修改已保存，读取最新内容失败：${coreErrorMessage(error as CoreBridgeError)}` :
            coreErrorMessage(error as CoreBridgeError)
        }
      }
      finally { this.working = false }
    })
    this.pending = operation
    await operation
    await this.pending
    return success
  }
  async saveText(): Promise<boolean> {
    if (this.readOnly) return true
    if (!await this.blockEditor.finish() || !await this.linkEditor.finish()) return false
    await this.pending
    if (this.removed) return false
    if (this.bodyOnly) return true
    if (!this.heading.trim()) { this.message = '标题不能为空'; return false }
    const modifications: CoreTaskModification[] = []
    if (this.headingDirty && this.heading !== this.value().heading) modifications.push({ field: 'TITLE', value: this.heading })
    if (this.notesDirty && this.notes !== this.value().editContent.notes.trimEnd()) modifications.push({ field: 'NOTES', value: this.notes })
    if (modifications.length > 0) return await this.persist(modifications)
    this.headingEditing = false; this.notesEditing = false
    this.headingDirty = false; this.notesDirty = false
    this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
    return true
  }
  linkEditingChanged(editing: boolean) {
    this.linkEditing = editing
    if (editing) {
      this.inputFocus()
      if (this.bodyOnly) this.prepare().then((): void => { this.releaseBodySession() })
    } else {
      this.releaseBodySession()
    }
  }
  private releaseBodySession(): void {
    if (this.bodyOnly && !this.working && !this.blockEditing && !this.linkEditing && !this.blockSaving && !this.linkSaving &&
      !this.checkId && !this.addingCheck && !this.checkSaving) {
      this.typing = false
      TaskInlineSession.release(this.ownerKey)
    }
  }
  private bodyEditingChanged(editing: boolean): void {
    this.blockEditing = editing
    if (editing) this.inputFocus()
    else this.releaseBodySession()
  }
  linksEditable(): boolean {
    return (this.expanded || this.bodyOnly) && !this.readOnly && !this.snapshotBlocked
  }
  async changeLink(field: 'title' | 'notes', link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    if (!this.linksEditable()) throw new Error('请展开可编辑任务后再修改链接')
    this.linkSaving = true
    try {
      // 标题链接改名后 Core 身份变化，旧卡片退出并刷新属于已提交成功。
      if (!await this.persist([{ field: 'LINK', value: { field, link, value } }]) || this.snapshotBlocked && !this.removed) {
        throw new Error(this.message || '修改链接失败，请重试')
      }
    } finally { this.linkSaving = false }
  }
  async saveCheck(next: boolean): Promise<boolean> {
    if (this.readOnly) return true
    if (this.checkSaving) return await this.checkSaving
    this.continueCheck = next
    this.checkSaving = this.commitCheck()
    const result = await this.checkSaving
    this.checkSaving = undefined
    if (result && this.continueCheck && !this.snapshotBlocked && this.appeared && !this.removed) {
      if (this.checkId) this.checkFocus.request(`inline_check_${this.checkId}`)
      else if (this.addingCheck) this.checkFocus.request(`inline_new_check_${this.ownerKey}`)
    }
    this.continueCheck = false
    return result
  }
  private async commitCheck(): Promise<boolean> {
    await this.pending
    const id = this.checkId
    const text = id ? this.checkText : this.newCheck
    if (!id && !text.trim()) {
      this.addingCheck = false; this.checkAfter = ''; this.newCheck = ''
      return true
    }
    if (this.snapshotBlocked || this.removed) return false
    if (!text.trim()) { this.message = '清单条目不能为空'; return false }
    const items = this.listItems()
    const anchor = id || this.checkAfter
    const index = items.findIndex(item => item.id === anchor)
    if (anchor && index < 0) { this.message = '清单条目已变化，请重新载入'; return false }
    const change: CoreTaskChecklistChange = id ? { type: 'edit', id, text } :
      anchor ? { type: 'insertAfter', id: anchor, text } : { type: 'add', text }
    if ((!id || items[index].text !== text) && !await this.persist([{ field: 'CHECKLIST', value: change }])) return false
    const continueEditing = this.continueCheck && !this.snapshotBlocked && !this.removed
    const current = this.listItems()
    const afterSubtree = anchor ? checklistBlockEnd(items, index) : current.length - 1
    const next = continueEditing && id && items[afterSubtree]?.siblingGroup === items[index].siblingGroup ?
      current[afterSubtree] : undefined
    this.addingCheck = continueEditing && !next
    this.checkAfter = this.addingCheck ? current[id ? index : afterSubtree]?.id ?? '' : ''
    this.checkText = next?.text ?? ''; this.newCheck = ''; this.checkId = next?.id ?? ''
    return true
  }
  async changeCheck(change: CoreTaskChecklistChange) {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.prepare()) return
    try {
      const id = change.type === 'add' ? '' : change.id
      const index = this.listItems().findIndex(item => item.id === id)
      const version = this.value().fileVersion
      if (!await this.saveText() || !await this.saveCheck(false) || version !== this.value().fileVersion) return
      const current = this.listItems()[index]
      if (change.type === 'setChecked' && current) change = { type: 'setChecked', id: current.id, checked: change.checked }
      else if (change.type === 'remove' && current) change = { type: 'remove', id: current.id }
      await this.persist([{ field: 'CHECKLIST', value: change }])
    } finally { this.releaseBodySession() }
  }
  async editCheck(item: CoreTaskChecklistItem) {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.prepare()) return
    const index = this.listItems().findIndex(current => current.id === item.id)
    const version = this.value().fileVersion
    if (!await this.saveText() || !await this.saveCheck(false) || version !== this.value().fileVersion) {
      this.releaseBodySession()
      return
    }
    const current = this.listItems()[index]
    if (!current) {
      this.releaseBodySession()
      return
    }
    this.addingCheck = false; this.checkAfter = ''
    this.checkId = current.id; this.checkText = current.text
    this.checkFocus.request(`inline_check_${current.id}`)
  }
  async addCheck(after: string = '') {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    const version = this.value().fileVersion
    if (!await this.prepare()) return
    if (!await this.saveText() || !await this.saveCheck(false) || (after && version !== this.value().fileVersion)) {
      this.releaseBodySession()
      return
    }
    this.checkAfter = after || this.value().editContent.checklist.filter(item => item.depth === 0).pop()?.id || ''
    this.addingCheck = true
    this.checkFocus.request(`inline_new_check_${this.ownerKey}`)
  }
  async setSchedule(value: CoreTaskPlanningEdit | null, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.planningGroup('SCHEDULE', value, allowed)
  }
  async setDeadline(value: CoreTaskPlanningEdit | null, allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> {
    return await this.planningGroup('DEADLINE', value, allowed)
  }
  private async planningGroup(field: 'SCHEDULE' | 'DEADLINE', value: CoreTaskPlanningEdit | null, allowed: () => boolean): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return
    this.completing = true
    try {
      const source = await this.actionSource(allowed)
      if (source) return taskModificationGroup(source, [{ field, value }])
      return undefined
    } finally { this.completing = false; if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey) }
  }

  async startSchedule(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> { return await this.startDate(false, allowed) }
  async startDeadline(allowed: () => boolean = () => true): Promise<CoreTaskOperationGroup | undefined> { return await this.startDate(true, allowed) }
  private async startDate(deadline: boolean, allowed: () => boolean): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || !allowed()) return undefined
    this.completing = true
    let action: TaskEditorActionResult | undefined = undefined
    try {
      const source = await this.actionSource(allowed)
      if (!source) return undefined
      const result = new TaskEditorActionResult()
      action = result; this.pendingAction = result
      this.dateDialog = new CustomDialogController({
        builder: TaskDateDialog({ closed: (): void => { result.finish() }, selected: deadline ? source.deadline : source.scheduled,
          planning: deadline ? source.editContent.deadlinePlanning : source.editContent.scheduledPlanning, deadline,
          confirmed: (modification: CoreTaskModification): void => {
            if (!this.appeared || !allowed()) { result.finish(); return }
            result.finish(taskModificationGroup(source, [modification]))
          } }),
        customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
        onWillDismiss: (dismiss: DismissDialogAction): void => { dismiss.dismiss(); result.finish() }
      })
      this.completing = false
      this.dateDialog.open()
      return await result.result
    } catch (error) { this.actionError(error as Error); return undefined }
    finally {
      this.completing = false
      if (this.pendingAction === action) this.pendingAction = undefined
      if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  private async startReminder(): Promise<CoreTaskOperationGroup | undefined> {
    if (!this.actionsAvailable() || this.value().state === null) return undefined
    this.completing = true
    let action: TaskEditorActionResult | undefined = undefined
    try {
      const source = await this.actionSource(() => this.appeared && !this.removed)
      if (!source) return undefined
      const result = new TaskEditorActionResult()
      action = result; this.pendingAction = result
      this.reminderDialog = new CustomDialogController({
        builder: TaskDateDialog({ title: '提醒时间', allowTimeRange: false,
          selected: reminderPlanning(source)?.date ?? '', planning: reminderPlanning(source),
          closed: (): void => { result.finish() }, confirmed: (change: CoreTaskModification): void => {
            if (!this.appeared || this.removed) { result.finish(); return }
            const modification = reminderModification(source, change.value as CoreTaskPlanningEdit | null)
            result.finish(modification.value === source.reminderAt ? undefined : taskModificationGroup(source, [modification]))
          } }), customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
        onWillDismiss: (dismiss: DismissDialogAction): void => { dismiss.dismiss(); result.finish() }
      })
      this.completing = false; this.reminderDialog.open()
      return await result.result
    } catch (error) { this.actionError(error as Error); return undefined }
    finally {
      this.completing = false
      if (this.pendingAction === action) this.pendingAction = undefined
      if (this.appeared && !this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  hasReminder(): boolean { return this.value().reminderAt !== null && this.value().reminderAt !== undefined }
  private reminderExpired(): boolean {
    const when = this.value().reminderAt
    return when !== null && when !== undefined && when <= Date.now()
  }
  private reminderExpansionChanged(): void {
    ++this.reminderCheckRequest
    this.reminderCheckKey = ''; this.reminderChecked = false; this.reminderChecking = false; this.reminderError = ''
    if (this.expanded) this.checkReminder(true)
  }
  private reminderTaskChanged(): void { this.checkReminder() }
  private async checkReminder(force: boolean = false): Promise<void> {
    if (!this.appeared || !this.expanded || this.removed) return
    const task = this.value()
    const key = this.hasReminder() && !this.reminderExpired() ?
      JSON.stringify([task.id, ReminderManager.contentKey(task), task.state]) : JSON.stringify([task.id, task.reminderAt])
    if (!force && key === this.reminderCheckKey) return
    this.reminderCheckKey = key
    const request = ++this.reminderCheckRequest
    this.reminderChecked = false; this.reminderError = ''; this.reminderChecking = this.hasReminder() && !this.reminderExpired()
    if (!this.hasReminder() || this.reminderExpired()) return
    const current = (): boolean => this.appeared && this.expanded && !this.removed && request === this.reminderCheckRequest
    try {
      const result = await ReminderManager.checkRegistered(task)
      if (!current()) return
      this.reminderChecked = true
      this.reminderError = result.registered ? '' : result.reason
    } catch (error) {
      if (current()) this.reminderError = coreErrorMessage(error as CoreBridgeError)
    } finally { if (current()) this.reminderChecking = false }
  }
  reminderStatus(): string {
    if (this.reminderExpired()) return '已过期'
    if (this.reminderChecking) return '正在检查…'
    if (this.reminderError) return '检查失败'
    return this.reminderChecked ? '✓ 已登记' : ''
  }
  private async openReminderSettings(): Promise<void> {
    if (!this.appeared || this.removed || this.working || this.completing || this.moveBusy || this.pendingAction || this.snapshotBlocked) return
    this.completing = true
    try {
      if (!await this.finish(false)) return
      await this.localDataSet().settle()
      if (!this.appeared || this.removed || this.snapshotBlocked) return
      if (this.localDataSet().error) throw new Error(this.localDataSet().error)
      await PageNavigator.shared.pushPage(this.getUIContext(), { url: 'pages/Settings', params: { section: '任务提醒' } })
    } catch (error) { this.actionError(error as Error) }
    finally { this.completing = false }
  }
  async priorities() {
    if (this.readOnly) return
    if (this.working || this.snapshotBlocked || !await this.prepare() || !await this.finish(false)) return
    this.priorityOpen = true
  }
  async choosePriority(name: string | null) {
    if (this.readOnly) return
    if (this.working || this.priorityBusy || this.snapshotBlocked) return
    if ((this.value().priority?.name ?? null) === name) { this.priorityOpen = false; return }
    this.priorityBusy = true
    try {
      if (await this.persist([{ field: 'PRIORITY', value: name }])) this.priorityOpen = false
    } finally { this.priorityBusy = false }
  }
  @Builder
  priorityPopup() {
    TaskPriorityChoices({ options: this.value().priorityOptions, current: this.value().priority,
      disabled: this.working || this.priorityBusy || this.snapshotBlocked, maximumWidth: Math.max(60, this.rowWidth - 32),
      choose: (name: string | null): void => { this.choosePriority(name) } })
  }
  @Builder
  priorityBadge(editable: boolean = false) {
    if (this.value().priority) {
      Text(this.value().priority!.name).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(priorityColor(this.value().priority!.category)).textAlign(TextAlign.Center)
        .constraintSize({ minWidth: 24, minHeight: 22 }).padding({ left: 5, right: 5, top: 2, bottom: 2 })
        .backgroundColor(priorityBackground(this.value().priority!.category)).borderRadius(6).flexShrink(0)
        .responseRegion({ x: 0, y: -11, width: '100%', height: 44 })
        .accessibilityText(`${priorityLabel(this.value().priority)}，点击${editable ? '修改' : '展开'}`)
        .onClick(() => { if (editable) this.priorities(); else this.toggleFromCompact() })
    }
  }

  async repeats(deadline: boolean = false) {
    if (this.readOnly) return
    if (!await this.prepare() || !await this.finish(false)) return
    this.repeatDialog = new CustomDialogController({
      builder: TaskRepeatDialog({ task: this.value(), initialDeadline: deadline,
        confirmed: (changes: CoreTaskModification[]): void => {
          if (!this.appeared || this.readOnly || this.removed) return
          this.persist(changes).then((success: boolean): void => { if (!success) this.actionError(new Error(this.message || '未能修改重复设置')) })
        } }),
      customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => { if (!this.working) action.dismiss() }
    })
    this.repeatDialog.open()
  }
  reloadDraft() {
    if (this.working) return
    showDangerousConfirmation(this.getUIContext(), { title: '重新载入任务？', message: '将放弃卡片中未保存的输入，读取文件中的最新内容。',
      confirmLabel: '重新载入', onConfirm: async () => {
        this.working = true
        try {
          await this.localDataSet().refresh()
          this.editTask = await this.currentTask()
          this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
          this.blockEditor.cancel(); this.blockEditing = false
          this.headingEditing = false; this.notesEditing = false
          this.headingDirty = false; this.notesDirty = false
          this.checkId = ''; this.checkText = ''; this.newCheck = ''; this.addingCheck = false; this.checkAfter = ''; this.message = ''
          this.snapshotBlocked = false; this.checkPreview = []
        } catch (error) {
          if (error instanceof TaskInlineMissingError) this.removeDeletedTask()
          else this.message = coreErrorMessage(error as CoreBridgeError)
        }
        finally { this.working = false }
      } })
  }
  async tags() {
    if (this.readOnly) return
    if (!await this.prepare() || !await this.finish(false)) return
    try {
      this.tagsDialog = new CustomDialogController({
        builder: TaskTagsDialog({ supportTags: this.value().supportTags, ownTags: this.value().ownTags, visibleTags: this.displayTags(),
          inheritedTags: this.value().inheritedTags, hiddenTags: this.hiddenTags,
          changed: (modification: CoreTaskModification): void => {
            if (!this.appeared || this.readOnly || this.removed) return
            this.persist([modification]).then((success: boolean): void => { if (!success) this.actionError(new Error(this.message || '未能修改标签')) })
          } }),
        customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
        onWillDismiss: (action: DismissDialogAction) => { if (!this.working) action.dismiss() }
      })
      this.tagsDialog.open()
    } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
  }

  listItems(task: CoreTask = this.value()): CoreTaskChecklistItem[] {
    return task.editContent.blocks?.flatMap(block => block.items) ?? task.editContent.checklist
  }

  checkItems(): CoreTaskChecklistItem[] {
    const items = this.listItems()
    if (!this.draggingCheck && !(this.working && this.checkPreview.length > 0)) return items
    const preview = this.checkPreview
    let index = 0
    return items.map((item: CoreTaskChecklistItem): CoreTaskChecklistItem => preview.some((next: CoreTaskChecklistItem): boolean => next.id === item.id) ? preview[index++] : item)
  }
  checkHeight(_revision: number): number {
    return this.checkItems().reduce((sum: number, item: CoreTaskChecklistItem) => sum + (this.checkHeights.get(item.id) ?? 44), 0)
      + (this.addingCheck ? 44 : 0) + 44
  }
  checkMeasured(item: CoreTaskChecklistItem, area: Area) {
    if (this.draggingCheck) return
    const height = Math.max(44, parseFloat(area.height.toString()))
    if (Math.abs((this.checkHeights.get(item.id) ?? 0) - height) < 0.5) return
    this.checkHeights.set(item.id, height)
    this.checkLayoutRevision++
  }
  canSortCheck(): boolean {
    return !this.working && !this.typing && !this.blockEditing && !this.linkEditing && !this.checkId && !this.addingCheck && !this.checkSaving &&
      !this.snapshotBlocked && !this.droppingCheck && this.heading === this.value().heading && this.notes === this.value().editContent.notes.trimEnd()
  }
  cancelCheckDrag() {
    this.dragEpoch++
    if (this.checkScrollTimer >= 0) clearInterval(this.checkScrollTimer)
    this.checkScrollTimer = -1
    if (this.draggingCheck) AppStorage.setOrCreate('taskChecklistDragging', false)
    this.checkDrag = undefined; this.draggingCheck = false; this.droppingCheck = false; this.dragItems = []
    this.checkPreview = []
  }
  startCheckDrag(item: CoreTaskChecklistItem, event: GestureEvent) {
    if (this.readOnly) return
    if (this.gripPress !== item.id || !this.canSortCheck() || this.draggingCheck || checklistSiblings(this.listItems(), item.id).length < 2) return
    const finger = event.fingerList[0]
    const block = this.value().editContent.blocks.find((block: CoreContentBlock): boolean => block.items.some((entry: CoreTaskChecklistItem): boolean => entry.id === item.id))
    this.dragBlockId = block?.id ?? ''
    const node = this.getUIContext().getFrameNodeById(`inline_checks_${this.ownerKey}_${this.dragBlockId}`)
    if (!finger || !node) return
    try {
      this.checkScroller.closeAllSwipeActions()
    } catch (_) {
      // 尚未完成布局时无需关闭已不存在的侧滑操作。
    }
    this.checkFocus.cancel()
    const localY = finger.globalY - node.getPositionToWindow().y
    this.checkDrag = new TaskChecklistDrag(block?.items ?? this.listItems(), item.id, this.checkHeights, localY)
    this.dragItems = this.checkDrag.moving
    this.dragHeight = this.checkDrag.height
    this.dragTop = this.checkDrag.top
    this.dragPlaceholder = this.checkDrag.placeholderTop()
    this.dragValid = true
    this.checkPreview = this.checkDrag.preview()
    this.draggingCheck = true
    this.checklistTouch = true
    AppStorage.setOrCreate('taskChecklistDragging', true)
    this.dragPointerX = finger.globalX; this.dragPointerY = finger.globalY
    this.checkScrollTimer = setInterval(() => { this.scrollCheckDrag() }, 16)
  }
  updateCheckDrag(event?: GestureEvent) {
    if (!this.checkDrag || this.droppingCheck) return
    const finger = event?.fingerList[0]
    if (finger) { this.dragPointerX = finger.globalX; this.dragPointerY = finger.globalY }
    const node = this.getUIContext().getFrameNodeById(`inline_checks_${this.ownerKey}_${this.dragBlockId}`)
    if (!node) { this.cancelCheckDrag(); return }
    const position = node.getPositionToWindow()
    // FrameNode 的窗口位置使用 vp，测量尺寸使用 px；手势坐标同为 vp。
    const x = this.dragPointerX - position.x
    const y = this.dragPointerY - position.y
    const before = this.checkDrag.beforeId
    this.checkDrag.update(y, x >= 0 && x <= this.getUIContext().px2vp(node.getMeasuredSize().width))
    this.dragTop = this.checkDrag.top
    this.dragValid = this.checkDrag.valid
    if (before !== this.checkDrag.beforeId) {
      this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseInOut }, () => {
        this.checkPreview = this.checkDrag!.preview()
        this.dragPlaceholder = this.checkDrag!.placeholderTop()
      })
    }
  }
  scrollCheckDrag() {
    if (!this.checkDrag || this.droppingCheck) return
    const host = this.scrollHostId ? this.getUIContext().getFrameNodeById(this.scrollHostId) : null
    if (host && this.scrollHost) {
      const top = host.getPositionToWindow().y
      const bottom = top + this.getUIContext().px2vp(host.getMeasuredSize().height)
      const velocity = checklistEdgeScroll(this.dragPointerY, top, bottom)
      if (velocity) this.scrollHost.scrollBy(0, velocity * 0.016)
    }
    this.updateCheckDrag()
  }
  endCheckDrag() {
    if (!this.checkDrag || this.droppingCheck) return
    if (!this.checkDrag.valid || !this.checkDrag.changed()) { this.cancelCheckDrag(); return }
    const id = this.checkDrag.id
    const beforeId = this.checkDrag.beforeId
    const epoch = this.dragEpoch
    this.droppingCheck = true
    if (this.checkScrollTimer >= 0) clearInterval(this.checkScrollTimer)
    this.checkScrollTimer = -1
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseInOut }, () => { this.dragTop = this.dragPlaceholder })
    setTimeout(() => {
      if (epoch !== this.dragEpoch) return
      this.cancelCheckDrag()
      this.sortCheck(id, beforeId)
    }, 150)
  }
  async sortCheck(id: string, beforeId: string | null) {
    if (!this.canSortCheck() || this.draggingCheck) return
    const task = this.value()
    const items = this.listItems(task)
    this.checkPreview = checklistMovePreview(items, id, beforeId)
    if (!this.checkPreview.some((item: CoreTaskChecklistItem, index: number) => item.id !== items[index].id)) return
    this.working = true; this.message = ''
    const operation = this.pending.then(async () => {
      let committed = false
      const context = this.getUIContext().getHostContext()!
      try {
        await this.modifyTask(task, [{ field: 'CHECKLIST', value: { type: 'move', id, beforeId } }])
        committed = true
        this.editTask = await this.currentTask()
        this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
      } catch (error) {
        if (error instanceof TaskInlineMissingError) { this.removeDeletedTask(); return }
        const message = coreErrorMessage(error as CoreBridgeError)
        if (committed) {
          this.snapshotBlocked = true
          this.message = '顺序已保存，读取最新内容失败，请重新载入'
        } else if (message.includes('版本') || message.includes('已变化')) {
          this.message = '文件已变化，请刷新后重新排序'
          try {
            this.editTask = await this.currentTask()
            this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
          }
          catch (error) {
            if (error instanceof TaskInlineMissingError) this.removeDeletedTask()
            else { this.snapshotBlocked = true; this.message += '；读取失败，请重新载入' }
          }
        } else { this.message = '排序未保存，请重试' }
      } finally { this.checkPreview = []; this.working = false }
    })
    this.pending = operation
    await operation
  }
  accessibleCheckOrder(item: CoreTaskChecklistItem) {
    if (!this.canSortCheck()) return
    const siblings = checklistSiblings(this.listItems(), item.id)
    const index = siblings.findIndex(current => current.id === item.id)
    const sheets: SheetInfo[] = []
    if (index > 0) sheets.push({ title: '上移', action: () => { this.sortCheck(item.id, siblings[index - 1].id) } })
    if (index < siblings.length - 1) sheets.push({ title: '下移', action: () => { this.sortCheck(item.id, siblings[index + 2]?.id ?? null) } })
    this.getUIContext().showActionSheet({ title: `调整顺序：${item.text}`, message: '选择移动方向', sheets })
  }

  duration(): number { return taskDurationDays(this.value(), new Date(this.referenceTime)) }

  leadingDate(): string { return taskDateText(taskDateForDisplay(this.value(), this.dateDisplay), true, new Date(this.referenceTime)) }

  expandedDateLabel(display: TaskDateDisplay): string {
    const value = taskDateForDisplay(this.value(), display)
    return value ? inlineDateLabel(value) : ''
  }

  leadingTime(): string { return taskTimeForDisplay(this.value(), this.timeDisplay) }

  showTodayFlag(): boolean { return !this.expanded && this.todayFlag && taskDateIsToday(this.value().scheduled, new Date(this.referenceTime)) }

  leadingWidth(): number {
    return (this.leadingTime() ? 54 : 0)
      + (this.showTodayFlag() ? 26 : 0)
      + (this.hasReminder() ? 26 : 0)
      + (taskDateForDisplay(this.value(), this.dateDisplay).length > 0 ? this.leadingDate().length * 7 + 18 : 0)
      + (this.value().isHabit || this.value().isRepeating ? 26 : 0)
  }

  deadlineColor(): string { return taskDeadlineColor(this.value(), new Date(this.referenceTime)) }

  deadlineIcon(): Resource {
    return this.deadlineColor() === UiColor.deadline
      ? $r('app.media.ui_task_deadline') : $r('app.media.ui_task_deadline_neutral')
  }

  countBudget(): number {
    if (this.titleOnly) return Math.max(14, Math.min(140, this.rowWidth - 92))
    return Math.max(14, Math.min(140, this.rowWidth - this.deadlineWidth - this.leadingWidth() - (this.value().priority ? 28 : 0) - 126))
  }

  layout(): TaskRowLayout {
    return taskRowLayout(this.rowWidth - 16 - this.leadingWidth() - (this.value().priority ? 28 : 0), this.displayTags().length, taskIndicators(this.value()).length,
      this.duration(), this.value().deadline.length > 0 ? this.deadlineWidth : 0,
      titleCountsWidth(this.value().headingParts, this.countBudget()))
  }

  titleWidth(): number { return Math.max(40, this.rowWidth - 88) }

  indicatorIcon(kind: string): Resource {
    switch (kind) {
      case 'list': return $r('app.media.ui_task_list')
      default: return $r('app.media.ui_task_body')
    }
  }

  @Builder
  completionState() {
    Button({ type: ButtonType.Normal }) {
      if (this.value().state?.category === TaskStateCategory.Done) {
        Image($r('app.media.ui_task_done')).width(18).height(18).syncLoad(true)
      } else {
        Stack() {
          Text('').width(18).height(18)
            .border({ width: 1.4, color: this.value().state?.category === TaskStateCategory.Cancel ?
              UiColor.disabled : '#8B8986' }).borderRadius(4)
          if (this.value().state?.category === TaskStateCategory.Wait) {
            Row({ space: 3 }) {
              Rect().width(1.4).height(8).fill(UiColor.text)
              Rect().width(1.4).height(8).fill(UiColor.text)
            }
          }
        }.width(18).height(18)
      }
    }.id('task_complete_button').width(18).height(18).padding(0).backgroundColor(Color.Transparent)
      .stateEffect(false)
      .responseRegion({ x: 0, y: -13, width: 18, height: 44 })
      .enabled((!this.readOnly || this.allowCompletion) && !this.completing && !this.working && !this.snapshotBlocked && !!this.value().taskStateOf(this.value().isDone() ? TaskStateCategory.Todo : TaskStateCategory.Done))
      .accessibilityText(this.readOnly && !this.allowCompletion ? taskStateCategoryLabel(this.value().state?.category) : `${taskStateCategoryLabel(this.value().state?.category)}，${this.value().isDone() ? '点击重新打开任务' : '点击完成任务'}`).onClick(() => { this.complete() })
  }

  private updateCancelLine(): void {
    const box = this.cancelledBoxPosition
    const title = this.cancelledTitlePosition
    if (this.value().state?.category !== TaskStateCategory.Cancel || !box || !title) {
      this.cancelLineWidth = 0
      return
    }
    // 标题保留原生删除线，以首行字形的位置连接前面的状态框。
    this.cancelLineWidth = Math.max(0, Number(title.x) - Number(box.x) + 0.5)
    this.cancelLineOffset = Number(title.y) - Number(box.y) + UiSize.taskTitleLineHeight / 2 + 1.25
  }

  private locateCancelTitle(area: Area): void {
    this.cancelledTitlePosition = area.globalPosition
    this.updateCancelLine()
  }

  @Builder
  stateIndicator() {
    if (this.value().state === null) {
      Image($r('app.media.ui_note')).width(18).height(18)
        .accessibilityText('笔记，无任务状态')
    } else if (this.value().state?.category === TaskStateCategory.Cancel) {
      Stack({ alignContent: Alignment.TopStart }) {
        Row() { this.completionState() }
          .offset({ y: this.cancelLineWidth > 0 ? Math.min(0, this.cancelLineOffset - 5) : 0 })
        if (this.cancelLineWidth > 0) {
          Rect().width(this.cancelLineWidth).height(1).fill(UiColor.disabled)
            .position({ x: 0, y: this.cancelLineOffset })
            .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        }
      }.width(18).height(18).clip(false)
        .onAreaChange((_old: Area, area: Area): void => {
          this.cancelledBoxPosition = area.globalPosition
          this.updateCancelLine()
        })
    } else {
      this.completionState()
    }
  }

  displayTags(): string[] { return this.value().tags.filter(tag => !this.hiddenTags.includes(tag)) }

  @Builder
  compactTags() {
    Row({ space: 4 }) {
      Text(this.displayTags()[0]).fontSize(11).fontColor('#F5F5F5').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(taskTagColor(this.displayTags()[0])).borderRadius(10)
        .constraintSize({ maxWidth: this.layout().firstTagWidth }).flexShrink(0)
      if (this.layout().showMoreTags) {
        Text('…').fontSize(12).fontColor(UiColor.secondary).width(22).height(21).textAlign(TextAlign.Center)
          .border({ width: 1, color: '#686561' }).borderRadius(10)
      }
    }.constraintSize({ maxWidth: this.layout().tagWidth }).alignItems(VerticalAlign.Center).flexShrink(0)
      .accessibilityText(`标签：${this.displayTags().join('、')}`)
      .onClick((): void => { this.toggleFromCompact() })
  }

  @Builder
  compactIndicators() {
    Row({ space: 4 }) {
      if (this.layout().showAllIndicators) {
        ForEach(taskIndicators(this.value()), (kind: string) => {
          Image(this.indicatorIcon(kind)).width(14).height(14)
        }, (kind: string) => kind)
      } else {
        Text('…').fontSize(13).fontColor(UiColor.secondary).width(14).maxLines(1)
      }
    }.width(this.layout().indicatorWidth).alignItems(VerticalAlign.Center).flexShrink(0)
      .accessibilityText(`${this.value().hasText ? '有正文；' : ''}${this.value().hasList ? '有列表' : ''}`)
  }

  async openProject() {
    try {
      if (this.value().project() === null) return
      await OrgFileNavigation.open(this.getUIContext(), this.value().repoId, this.value().filePath, false,
        () => this.recordSource?.task?.fullPath)
    } catch (_) { this.message = '暂时无法打开项目，请重试。' }
  }

  @Builder
  categoryProject() {
    Row({ space: 4 }) {
      if (this.regionArea().category) {
        Text(this.regionArea().category).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.regionArea().project === null ? '100%' : '40%' })
      }
      if (this.regionArea().project !== null) {
        if (this.regionArea().category) { Text('·').fontSize(12).fontColor(UiColor.secondary) }
        Text(this.regionArea().project || '未命名项目').fontSize(12).fontColor(UiColor.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .constraintSize({ minHeight: 48 }).onClick((): void => { this.openProject() })
      }
    }.width('100%').accessibilityText(taskSourceText(this.value(), false, this.regionPolicy()))
  }

  regionArea(): TaskRegionArea {
    return taskRegionArea(this.value(), this.regionPolicy())
  }

  regionPolicy(): RegionAreaPolicy {
    // 未显式配置的旧调用方保留原折叠／展开布局；显式策略同时控制两种状态。
    return this.regionAreaPolicy ?? (this.expanded ? RegionAreaPolicy.CategoryProject : RegionAreaPolicy.None)
  }

  @Builder
  compactTitle() {
    Row({ space: 6 }) {
      Row({ space: 4 }) {
        if (!this.titleOnly) { this.priorityBadge() }
        Column({ space: 2 }) {
          TitleText({ internalLinkProcessor: this.internalLinkProcessor, text: this.value().heading, parts: this.value().headingParts,
            editable: false, openLinks: this.previewTitleLinks || !this.titleOnly && !this.previewTask,
            lineLimit: this.previewTitleLinks ? 0 : 1, lineHeight: UiSize.taskTitleLineHeight,
            showCounts: false, cancelled: (this.value().state?.category === TaskStateCategory.Cancel),
            activate: (): void => { this.toggleFromCompact() } })
            .width('100%').constraintSize({ minWidth: 0 })
            .onAreaChange((_old: Area, area: Area): void => { this.locateCancelTitle(area) })
          if (!this.titleOnly && taskSourceText(this.value(), false, this.regionPolicy())) {
            this.categoryProject()
          }
        }.layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minWidth: 0 }).alignItems(VerticalAlign.Center)
      if (titleCounts(this.value().headingParts).length > 0) {
        TitleCounts({ parts: this.value().headingParts, budget: this.countBudget() })
          .width(titleCountsWidth(this.value().headingParts, this.countBudget())).flexShrink(0)
          .onClick((): void => { this.toggleFromCompact() })
      }
      if (!this.titleOnly) {
        if (this.displayTags().length > 0 && this.layout().tagWidth > 0) { this.compactTags() }
        if (this.layout().indicatorWidth > 0) { this.compactIndicators() }
        if (this.layout().durationWidth > 0) {
          Text(`${this.duration()}天`).fontSize(11).fontColor(UiColor.secondary)
            .width(this.layout().durationWidth).flexShrink(0).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .accessibilityText(`持续 ${this.duration()} 天`)
        }
      }
    }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow }).alignItems(VerticalAlign.Center)
      .accessibilityText(this.titleOnly ? taskTitleText(this.value()) : `${taskTitleText(this.value())}，点击展开`)
  }

  @Builder
  compactDeadline() {
    Row({ space: 4 }) {
      Image(this.deadlineIcon()).width(16).height(16)
      Text(this.leadingTime() && this.timeDisplay === TaskTimeDisplay.Deadline ? '截止' : taskDeadlineText(this.value(), new Date(this.referenceTime)))
        .fontSize(12).fontColor(this.deadlineColor()).maxLines(1)
    }.alignItems(VerticalAlign.Center).flexShrink(0)
      .onAreaChange((oldArea: Area, area: Area) => { this.deadlineWidth = parseFloat(area.width.toString()) })
  }
  @Builder
  compactTime() {
    if (this.leadingTime()) {
      Text(this.leadingTime()).fontSize(15)
        .fontColor(this.timeDisplay === TaskTimeDisplay.Deadline ? this.deadlineColor() : UiColor.selection)
        .width(48).maxLines(1).flexShrink(0)
        .accessibilityText(`${this.timeDisplay === TaskTimeDisplay.Deadline ? '截止' :
          this.timeDisplay === TaskTimeDisplay.Deleted ? '删除' : this.timeDisplay === TaskTimeDisplay.Creation ? '创建' : this.timeDisplay === TaskTimeDisplay.Closed ? '完成' : '计划'} ${this.leadingTime()}`)
        .onClick((): void => { this.toggleFromCompact() })
    }
  }

  @Builder
  compactLeadingInfo() {
    if (this.showTodayFlag()) {
      Image($r('app.media.nav_today')).width(20).height(20).flexShrink(0).accessibilityText('计划于今天')
    }
    if (this.hasReminder()) {
      Image($r('app.media.ui_reminder')).id('task_reminder_compact_icon').width(20).height(20).flexShrink(0)
        .fillColor(UiColor.secondary).accessibilityText('已设置提醒')
    }
    if (taskDateForDisplay(this.value(), this.dateDisplay)) {
      Text(this.leadingDate()).fontSize(11).fontColor(UiColor.text).backgroundColor('#5A5856').borderRadius(3)
        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).maxLines(1).flexShrink(0)
    }
    if (this.value().isHabit) {
      Image($r('app.media.ui_task_habit')).width(20).height(20).flexShrink(0).accessibilityText('习惯任务')
    } else if (this.value().isRepeating) {
      Image($r('app.media.ui_task_repeat')).width(20).height(20).flexShrink(0).accessibilityText('循环任务')
    }
  }

  @Builder
  compactContent() {
    this.compactLeadingInfo()
    this.compactTitle()
    if (this.value().deadline) { this.compactDeadline() }
  }

  @Builder
  compactRow() {
    Row() {
        if (this.leadingTime()) {
          Row() { this.compactTime() }.padding({ left: 8, right: 6 })
        }
        if (this.value().state !== null) {
          Row() { this.stateIndicator() }
            .padding({ left: this.leadingTime() ? 0 : 8 }).constraintSize({ minHeight: UiSize.taskRow })
        }
        Row({ space: 6 }) {
          if (this.value().state === null) { this.stateIndicator() }
          this.compactContent()
        }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow })
          .padding({ left: this.value().state === null ? (this.leadingTime() ? 0 : 8) : 6, right: 8 })
          .accessibilityText(`${taskTitleText(this.value())}，点击展开`)
          .onClick((): void => { if (!LinkEditController.interactionProtected()) this.toggleFromCompact() })
      if (this.includeStructureActions && this.canOrderChildren) {
          PopupMenuButton({ icon: $r('app.media.ui_more_horizontal'), label: '节点操作', iconSize: 20,
            buttonWidth: 44, buttonHeight: 44, items: this.structureMenuItems(),
            disabled: this.working || this.snapshotBlocked })
        }
    }.width('100%').constraintSize({ minHeight: UiSize.taskRow })
      .onTouch((event: TouchEvent) => { this.compactTouch(event) })
  }

  @Builder
  checkGripLines() {
    Column({ space: 2.5 }) {
      Rect().width(14).height(1.5).fill(UiColor.secondary).radius(0.75)
      Rect().width(14).height(1.5).fill(UiColor.secondary).radius(0.75)
      Rect().width(14).height(1.5).fill(UiColor.secondary).radius(0.75)
    }.width(44).height(44).justifyContent(FlexAlign.Center)
  }
  @Builder
  checkGrip(item: CoreTaskChecklistItem) {
    Row() { this.checkGripLines() }
      .id(`inline_check_grip_${this.ownerKey}_${item.id}`)
      .width(44).height(44).flexShrink(0).opacity(this.canSortCheck() || this.draggingCheck ? 1 : 0.35)
      .onTouch((event: TouchEvent) => {
        const touch = event.touches[0]
        if (event.type === TouchType.Down && touch) {
          this.gripPress = item.id; this.gripX = touch.windowX; this.gripY = touch.windowY
        } else if (event.type === TouchType.Move && touch && !this.draggingCheck &&
          Math.hypot(touch.windowX - this.gripX, touch.windowY - this.gripY) > 8) {
          this.gripPress = ''
        } else if (event.type === TouchType.Cancel) { this.cancelCheckDrag() }
      })
      .accessibilityText(`调整顺序：${item.text}`).accessibilityDescription('激活后选择上移或下移')
      .onAccessibilityActionIntercept((action: AccessibilityAction) => {
        if (action === AccessibilityAction.ACCESSIBILITY_CLICK) {
          this.accessibleCheckOrder(item)
          return AccessibilityActionInterceptResult.ACTION_INTERCEPT
        }
        return AccessibilityActionInterceptResult.ACTION_CONTINUE
      })
      .priorityGesture(GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false, duration: 350 }).onAction((event: GestureEvent) => { this.startCheckDrag(item, event) }),
        PanGesture({ direction: PanDirection.All, distance: 0 })
          .onActionUpdate((event: GestureEvent) => { this.updateCheckDrag(event) })
          .onActionEnd((event: GestureEvent) => { this.updateCheckDrag(event); this.endCheckDrag() })
      ).onCancel(() => { if (!this.droppingCheck) this.cancelCheckDrag() }))
  }
  @Builder
  checklistGrip(item: CoreTaskChecklistItem, floating: boolean) {
    if (floating) { this.checkGripLines() }
    else { this.checkGrip(item) }
  }

  blockItems(block: CoreContentBlock): CoreTaskChecklistItem[] {
    return this.checkItems().filter((item: CoreTaskChecklistItem): boolean => block.items.some((original: CoreTaskChecklistItem): boolean => original.id === item.id))
  }

  // Builder 只保留区块序号，每次渲染从当前快照读取位置 ID 和条目。
  checkBlock(index: number): CoreContentBlock {
    return this.value().editContent.blocks[index] ?? { id: 'new', kind: 'checklist', paragraph: false, blankLinesBefore: 0, source: '', html: '', items: [] }
  }

  private fileLinks: InternalLinkProcessor = new CallbackInternalLinkProcessor(
    (target: string): Promise<boolean> =>
      OrgFileNavigation.hasInternalTarget(this.getUIContext(), this.value().repoId, this.value().filePath, target),
    (target: string): Promise<void> =>
      OrgFileNavigation.openInternal(this.getUIContext(), this.value().repoId, this.value().filePath, target)
  )

  private contentLinks(): InternalLinkProcessor { return this.internalLinkProcessor ?? this.fileLinks }

  private tree(): CoreContentNode[] | undefined { return this.value().editContent.contentTree }

  async writeContentNode(change: CoreContentBlockChange): Promise<void> {
    this.blockSaving = true; this.linkSaving = true
    try {
      if (!await this.persist([{ field: 'CONTENT_BLOCK', value: change }], this.value().fileVersion) || this.snapshotBlocked) {
        throw new Error(this.message || '修改正文失败，请重试')
      }
    } finally { this.blockSaving = false; this.linkSaving = false }
  }

  @Builder
  checklistBlock(index: () => number) {
    TaskChecklistBlock({ items: this.blockItems(this.checkBlock(index())), readonly: this.readOnly, sorting: true,
      tree: this.tree()?.find(node => node.id === this.checkBlock(index()).id), revision: this.value().fileVersion,
      processor: this.contentLinks(), editor: this.blockEditor, linkEditor: this.linkEditor,
      beginNode: (): Promise<boolean> => this.beginBlock(this.checkBlock(index())), writeNode: change => this.writeContentNode(change),
      editingChanged: (editing: boolean): void => { this.bodyEditingChanged(editing) },
      linkEditingChanged: (editing: boolean): void => { this.linkEditingChanged(editing) },
      disabled: this.working || this.snapshotBlocked, editingId: this.checkId, editingText: this.checkText,
      adding: this.addingCheck && (this.checkAfter ? this.checkBlock(index()).items.some(item => item.id === this.checkAfter) :
        this.lastChecklist(this.checkBlock(index()))), addingAfter: this.checkAfter, newText: this.newCheck,
      showAdd: index() >= 0, ownerKey: this.ownerKey, blockId: this.checkBlock(index()).id,
      dragging: this.draggingCheck && this.dragBlockId === this.checkBlock(index()).id,
      dragTop: this.dragTop, dragHeight: this.dragHeight, dragPlaceholder: this.dragPlaceholder,
      dragValid: this.dragValid, dragItems: this.dragItems, scroller: this.checkScroller,
      grip: (item: CoreTaskChecklistItem, floating: boolean): void => { this.checklistGrip(item, floating) },
      toggle: (change: CoreTaskChecklistChange): void => { this.changeCheck(change) },
      edit: (item: CoreTaskChecklistItem): void => { this.editCheck(item) },
      editChanged: (text: string): void => { this.checkText = text },
      newChanged: (text: string): void => { this.newCheck = text },
      save: (next: boolean, id: string): void => {
        if (id ? id === this.checkId : this.addingCheck) this.saveCheck(next).finally((): void => { this.releaseBodySession() })
      },
      remove: (item: CoreTaskChecklistItem): void => { this.changeCheck({ type: 'remove', id: item.id }) },
      add: (): void => { this.addCheck(this.checkBlock(index()).items.filter(item => item.depth === 0).pop()?.id ?? '') },
      focused: (): void => { this.inputFocus() },
      measured: (item: CoreTaskChecklistItem, area: Area): void => { this.checkMeasured(item, area) },
      touchChanged: (touching: boolean): void => { this.checklistTouch = touching },
      inputAppeared: (id: string): void => { this.checkFocus.appeared(id) },
      inputDisappeared: (id: string): void => { this.checkFocus.disappeared(id) },
      inputVisible: (id: string): void => { this.checkFocus.visible(id) } }).width('100%')
  }

  lastChecklist(block: CoreContentBlock): boolean {
    const blocks = this.value().editContent.blocks.filter((entry: CoreContentBlock): boolean => entry.kind === 'checklist')
    return blocks.length === 0 || blocks[blocks.length - 1].id === block.id
  }

  async beginBlock(block: CoreContentBlock): Promise<boolean> {
    if (this.readOnly || this.snapshotBlocked || this.working || this.draggingCheck) return false
    const version = this.value().fileVersion
    const ready = await this.prepare() && await this.saveText() && await this.saveCheck(false) &&
      version === this.value().fileVersion &&
      this.value().editContent.blocks.some((current: CoreContentBlock): boolean => current.id === block.id && current.source === block.source)
    if (!ready) this.releaseBodySession()
    return ready
  }

  async saveBlock(block: CoreContentBlock, source: string): Promise<boolean> {
    return await this.saveBlockChange({ field: 'CONTENT_BLOCK', value: { type: 'replace', id: block.id, source } })
  }

  private async saveBlockChange(change: CoreTaskModification): Promise<boolean> {
    if (this.readOnly || this.snapshotBlocked) return false
    this.blockSaving = true
    try { return await this.persist([change], this.value().fileVersion) && !this.snapshotBlocked }
    finally { this.blockSaving = false }
  }

  async changeBlockLink(block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    if (!this.linksEditable()) throw new Error('请展开可编辑任务后再修改链接')
    const version = this.value().fileVersion
    if (this.bodyOnly && !TaskInlineSession.owns(this.ownerKey) && !await this.prepare()) throw new Error('请先结束当前编辑')
    this.linkSaving = true
    try {
      if (!await this.persist([{ field: 'CONTENT_BLOCK', value: { type: 'link', id: block.id, link, value } }],
        this.bodyOnly ? version : undefined) || this.snapshotBlocked) {
        throw new Error(this.message || '修改链接失败，请重试')
      }
    } finally { this.linkSaving = false }
  }

  @Builder
  bodyBlocks() {
    TaskContentEditor({ internalLinkProcessor: this.contentLinks(), blocks: this.value().editContent.blocks, contentTree: this.tree(),
      showEmptyPrompt: !this.documentContent, addMenuRequest: this.bodyOnly ? this.addContentRequest : this.contentMenuRequest,
      addMenuOpened: (): void => { this.contentMenuRequest = 0 },
      saveFirstChecklist: (text: string): Promise<boolean> => this.saveBlockChange({ field: 'CHECKLIST', value: { type: 'add', text } }),
      writeNode: change => this.writeContentNode(change), toggle: change => { this.changeCheck(change) },
      addChecklistItem: (after: string): void => { this.addCheck(after) },
      beginEmpty: async (): Promise<boolean> => await this.prepare() && await this.saveText() && await this.saveCheck(false)
        && this.value().editContent.blocks.length === 0, readonly: this.readOnly, horizontalParentFirst: !this.bodyOnly,
      checklistEditing: this.checkId !== '' || this.addingCheck,
      disabled: this.working || this.snapshotBlocked || this.draggingCheck,
      revision: this.value().fileVersion, moveVersion: this.value().fileVersion, ownerKey: this.ownerKey,
      scrollHost: this.scrollHost, scrollHostId: this.scrollHostId,
      moveContent: (id: string, beforeId: string | null, version: string): Promise<boolean> =>
        this.persist([{ field: 'CONTENT_BLOCK', value: { type: 'move', id, beforeId } }], version),
      moveEnded: (): void => { this.releaseBodySession() },
      contentBackground: '#00000000',
      editor: this.blockEditor, linkEditor: this.linkEditor,
      checklist: (index: () => number): void => { this.checklistBlock(index) },
      begin: (block: CoreContentBlock): Promise<boolean> => this.beginBlock(block),
      save: (block: CoreContentBlock, source: string): Promise<boolean> => this.saveBlock(block, source),
      changeLink: (block: CoreContentBlock, link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeBlockLink(block, link, value),
      editingChanged: (editing: boolean): void => { this.bodyEditingChanged(editing) },
      linkEditingChanged: (editing: boolean): void => { this.linkEditingChanged(editing) } }).width('100%')
    if (!this.readOnly && this.addingCheck && !this.checkAfter && this.value().editContent.checklist.length === 0) {
      this.checklistBlock((): number => -1)
    }
  }

  @Builder
  expandedHeader() {
    // 控件固定在首行槽位；标题留白由行高推导，后续文字只向下增长。
    Row({ space: 6 }) {
      Row() { this.stateIndicator() }.height(UiSize.taskRow)
      Row({ space: 4 }) {
        if (this.value().priority) {
          Row() { this.priorityBadge(!this.readOnly) }.height(UiSize.taskRow)
        }
        Column({ space: 2 }) {
          if (this.headingInput) {
            TextArea({ text: this.heading, controller: this.headingController, placeholder: '标题' }).id(`inline_title_${this.ownerKey}`)
              .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
              .width('100%').lineHeight(UiSize.taskTitleLineHeight).height('auto').minLines(1).maxLines(1000).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(this.value().state?.category === TaskStateCategory.Cancel ? UiColor.disabled : UiColor.text)
              .decoration({ type: this.value().state?.category === TaskStateCategory.Cancel ? TextDecorationType.LineThrough : TextDecorationType.None,
                color: UiColor.disabled })
              .backgroundColor(Color.Transparent).padding(0).borderRadius(0)
              .enterKeyType(EnterKeyType.Done).onSubmit(() => { TaskInlineSession.end(false) })
              .onChange((value: string) => { this.changeHeading(value) })
              .onTextSelectionChange((start: number, end: number): void => { this.headingSelection.update(start, end) })
              .onFocus(() => { this.headingEditing = true; this.inputFocus() })
              .onBlur(() => { this.finishHeading() })
              .onAppear(() => { this.checkFocus.appeared(`inline_title_${this.ownerKey}`) })
              .onDisAppear(() => { this.checkFocus.disappeared(`inline_title_${this.ownerKey}`) })
              .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.checkFocus.visible(`inline_title_${this.ownerKey}`) })
              .onAreaChange((_old: Area, area: Area): void => { this.locateCancelTitle(area) })
            DraftLinkAction({ source: this.heading, disabled: this.working || this.draggingCheck || this.snapshotBlocked,
              inputId: `inline_title_${this.ownerKey}`, editor: this.linkEditor, selection: this.headingSelection,
              write: (value: string): void => { this.changeHeading(value) },
              select: (start: number, end: number): void => {
                this.headingController.setTextSelection(start, end, { menuPolicy: MenuPolicy.HIDE })
              } })
          } else {
            TitleText({ internalLinkProcessor: this.internalLinkProcessor, text: this.value().heading, parts: this.value().headingParts,
              lineLimit: 1000, openLinks: !this.previewTask,
              weight: FontWeight.Medium, cancelled: this.value().state?.category === TaskStateCategory.Cancel,
              editable: this.linksEditable(), revision: this.value().fileVersion, linkEditor: this.linkEditor, showCounts: true, lineHeight: UiSize.taskTitleLineHeight,
              changeLink: (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink('title', link, value),
              linkEditingChanged: (editing: boolean): void => { this.linkEditingChanged(editing) },
              activate: (): void => { if (this.readOnly) this.toggle(); else this.editHeading() } }).width('100%')
              .onAreaChange((_old: Area, area: Area): void => { this.locateCancelTitle(area) })
          }
        }.layoutWeight(1).constraintSize({ minWidth: 0 }).padding({ top: (UiSize.taskRow - UiSize.taskTitleLineHeight) / 2,
            bottom: (UiSize.taskRow - UiSize.taskTitleLineHeight) / 2 })
          .alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow }).alignItems(VerticalAlign.Top)
      this.collapseButton()
    }.width('100%').padding({ left: 8 }).alignItems(VerticalAlign.Top)
      .bindPopup(this.priorityOpen, { builder: this.priorityPopup, placement: Placement.BottomLeft,
        targetSpace: 6, enableArrow: false, radius: 10, popupColor: UiColor.menu,
        backgroundBlurStyle: BlurStyle.NONE, mask: { color: Color.Transparent }, focusable: true,
        autoCancel: !this.working && !this.priorityBusy, onWillDismiss: !this.working && !this.priorityBusy,
        onStateChange: (event): void => { this.priorityOpen = event.isVisible } })
  }

  @Builder
  logbookNotes() {
    if (taskNoteEntries(this.value().logs).length > 0) {
      TaskLogView({ internalLinkProcessor: this.internalLinkProcessor,
        logs: taskNoteEntries(this.value().logs), notesOnly: true,
        contentBackground: '#00000000' }).width('100%').margin({ top: 6, bottom: 10 })
    }
  }

  @Builder
  bodyError() {
    if (this.message) {
      Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%')
      Button('重新载入').height(36).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
        .enabled(!this.working).onClick((): void => { this.reloadDraft() })
    }
  }

  @Builder
  editorContent() {
    this.expandedHeader()
    Column({ space: 12 }) {
      if (!this.contentHidden) { this.bodyBlocks() }
      if (this.displayTags().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.displayTags(), (tag: string) => {
            Text(tag).fontSize(12).fontColor('#F5F5F5').wordBreak(WordBreak.BREAK_ALL)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10).backgroundColor(taskTagColor(tag))
              .constraintSize({ maxWidth: this.rowWidth - 64 }).margin({ right: 6, bottom: 6 })
              .onClick(() => { this.tags() })
          }, (tag: string) => tag)
        }.width('100%')
      }
      this.logbookNotes()
      this.bodyError()
    }.width('100%').padding({ left: UiSize.taskBodyIndent })
  }

  @Builder
  collapseButton() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ui_up')).width(14).height(14)
      }.id('inline_collapse_button').width(14).height(14).padding(0)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .responseRegion({ x: -9, y: -9, width: 32, height: 32 })
        .accessibilityText('收起任务').onClick(() => { this.toggle() })
    }.width(14).height(UiSize.taskRow).justifyContent(FlexAlign.Center).flexShrink(0)
  }

  @Builder
  attributeButton(icon: Resource, label: string, activate: () => void) {
    Button({ type: ButtonType.Normal }) { Image(icon).width(18).height(18) }
      .id(label === '设置标签' ? 'inline_tags_button' : 'inline_checklist_button')
      .width(36).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
      .accessibilityText(label).onClick(activate)
  }
  @Builder
  moreButton() {
    PopupMenuButton({ icon: $r('app.media.ui_more_horizontal'), label: '更多任务操作',
      buttonWidth: 36, buttonHeight: 44, iconSize: 20, disabled: this.working || this.draggingCheck || this.snapshotBlocked,
      items: this.moreItems() })
  }
  moreItems(): PopupMenuItem[] {
    const items = this.structureMenuItems()
    if (!this.readOnly) {
      items.push({ title: this.shortActionLabels ? '备注' : '备注…', icon: $r('app.media.ui_note_action'), action: () => { this.emitAction(this.startNote()) } },
        { title: this.shortActionLabels ? '优先' : '优先级…', icon: $r('app.media.ui_priority_action'), action: () => { this.priorities() } })
      if (this.value().state !== null) {
        items.push({ title: this.shortActionLabels ? '提醒' : '提醒…', icon: $r('app.media.ui_reminder'), action: () => { this.emitAction(this.startReminder()) } })
      }
      items.push({ title: this.shortActionLabels ? '重复' : '重复…', icon: $r('app.media.ui_repeat_action'), action: () => { this.repeats() } })
    }
    if (this.logShowPolicy === LogShowPolicy.LogShowBySwitch && taskEventLogs(this.value().logs).length > 0) {
      items.push({ title: '日志',
        icon: this.logbookExpanded ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
        action: () => { this.logbookExpanded = !this.logbookExpanded } })
    }
    return items
  }
  private structureMenuItems(): PopupMenuItem[] {
    return this.includeStructureActions ? this.structureActions(this.canOrderChildren)
      .filter(item => item.title === '移动' || item.title === '排序') : []
  }
  @Builder
  reminderLine() {
    if (this.hasReminder()) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Image($r('app.media.ui_reminder')).id('task_reminder_expanded_icon').width(18).height(18).fillColor(UiColor.secondary)
          Text(reminderTimeLabel(this.value())).id('task_reminder_time').fontSize(12).fontColor(UiColor.secondary)
          if (this.reminderChecking && !this.reminderExpired()) {
            LoadingProgress().id('task_reminder_checking').width(14).height(14).color(UiColor.secondary)
              .accessibilityText('正在检查系统提醒')
          }
          Text(this.reminderStatus()).id('task_reminder_status').fontSize(12)
            .fontColor(this.reminderError ? UiColor.error : this.reminderChecked ? UiColor.primary : UiColor.secondary)
        }.width('100%').onClick(() => { if (!this.readOnly) this.emitAction(this.startReminder()) })
        if (this.reminderError) {
          Text(this.reminderError).id('task_reminder_error').fontSize(12).fontColor(UiColor.error).width('100%')
          Row({ space: 8 }) {
            Button('重试').id('task_reminder_retry').fontSize(12).fontColor(UiColor.primary)
              .height(28).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
              .onClick((): void => { this.checkReminder(true) })
            Button('前往设置').id('task_reminder_settings').fontSize(12).fontColor(UiColor.primary)
              .height(28).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
              .enabled(!this.working && !this.completing && !this.snapshotBlocked)
              .accessibilityText('前往任务提醒设置')
              .onClick((): void => { this.openReminderSettings() })
          }.width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 4 })
    }
  }
  @Builder
  attributes() {
    Column({ space: 4 }) {
      this.reminderLine()
      if (this.value().editContent.scheduledRepeat?.rule) {
        this.repeatRule(false)
      }
      if (this.value().editContent.deadlineRepeat?.rule) {
        this.repeatRule(true)
      }
      if (this.dateDisplay === TaskDateDisplay.Closed && this.expandedDateLabel(TaskDateDisplay.Closed)) {
        Row({ space: 5 }) {
          Image($r('app.media.ui_task_done')).width(16).height(16).accessibilityLevel('no')
          Text(this.expandedDateLabel(TaskDateDisplay.Closed)).fontSize(12).fontColor(UiColor.secondary)
        }.width('100%').accessibilityText(`完成日期 ${this.expandedDateLabel(TaskDateDisplay.Closed)}`)
      }
      Row() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Image(this.value().scheduled === inlineDate(new Date()) ? $r('app.media.nav_today') : $r('app.media.ui_task_calendar')).width(18).height(18)
            if (this.value().scheduled) { Text(inlinePlanningLabel(this.value().scheduled, this.value().editContent.scheduledPlanning)).fontSize(12).fontColor(UiColor.text).maxLines(2) }
          }
        }.id('inline_schedule_button').flexShrink(1).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked).constraintSize({ minWidth: 36, maxWidth: '46%' })
          .stateEffect(!this.readOnly).focusable(!this.readOnly)
          .accessibilityText(this.readOnly ? `计划日期 ${inlinePlanningLabel(this.value().scheduled ?? '', this.value().editContent.scheduledPlanning)}` : '设置或修改计划日期')
          .onClick(() => { if (!this.readOnly) this.emitAction(this.startSchedule()) })
        Blank().layoutWeight(1)
        if (!this.readOnly) {
          this.attributeButton($r('app.media.ui_tags'), '设置标签', () => { this.tags() })
          if (!this.contentHidden) { this.attributeButton($r('app.media.ui_task_list'), '编辑检查清单', () => { this.addCheck() }) }
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Image(this.deadlineIcon()).width(16).height(16)
            if (this.value().deadline) { Text(inlinePlanningLabel(this.value().deadline, this.value().editContent.deadlinePlanning)).fontSize(12).fontColor(this.deadlineColor()).maxLines(2) }
          }
        }.id('inline_deadline_button').flexShrink(1).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked).constraintSize({ minWidth: 36, maxWidth: '34%' })
          .stateEffect(!this.readOnly).focusable(!this.readOnly)
          .accessibilityText(this.readOnly ? `截止日期 ${inlinePlanningLabel(this.value().deadline ?? '', this.value().editContent.deadlinePlanning)}` : '设置或修改截止日期')
          .onClick(() => { if (!this.readOnly) this.emitAction(this.startDeadline()) })
        if (this.moreItems().length > 0) { this.moreButton() }
      }.width('100%')
    }.width('100%').padding({ left: 27 })
  }
  @Builder
  repeatRule(deadline: boolean) {
    Row({ space: 7 }) {
      if (!this.value().isHabit) { Image($r('app.media.ui_task_repeat')).width(18).height(18) }
      Text(`${deadline ? '截止' : '计划'} · ${repeatSummary(deadline ? this.value().editContent.deadlineRepeat?.rule : this.value().editContent.scheduledRepeat?.rule)}`)
        .fontSize(13).fontColor(UiColor.primary).layoutWeight(1)
      if (!this.readOnly) { Image($r('app.media.ui_next')).width(18).height(18).accessibilityLevel('no') }
    }.width('100%').constraintSize({ minHeight: 44 }).enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
      .accessibilityText(this.readOnly ? `${deadline ? '截止' : '计划'}重复规则` : `编辑${deadline ? '截止' : '计划'}重复规则`)
      .onClick(() => { if (!this.readOnly) this.repeats(deadline) })
  }
  @Builder
  readOnlyContent() {
    this.expandedHeader()
    Column({ space: 12 }) {
      if (!this.contentHidden) { this.bodyBlocks() }
      if (this.displayTags().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.displayTags(), (tag: string) => {
            Text(tag).fontSize(12).fontColor('#F5F5F5').wordBreak(WordBreak.BREAK_ALL)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10).backgroundColor(taskTagColor(tag))
              .margin({ right: 6, bottom: 6 })
          }, (tag: string) => tag)
        }.width('100%')
      }
      this.logbookNotes()
    }.width('100%').padding({ left: UiSize.taskBodyIndent })
  }

  @Builder
  attentionOverlay() {
    Row().width('100%').height('100%').borderRadius(12)
      .backgroundColor(UiColor.primary).opacity(this.attentionOpacity)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }

  build() {
    Column() {
      if (this.bodyOnly) {
        this.bodyBlocks()
        this.bodyError()
      } else if (this.titleOnly) {
        Row({ space: 6 }) {
          this.stateIndicator()
          this.compactTitle()
        }.width('100%').padding({ left: 8 })
          .hitTestBehavior(this.previewTitleLinks ? HitTestMode.Default : HitTestMode.None)
      } else if (this.expanded) {
        Column() {
          Column({ space: 8 }) {
            if (this.readOnly) {
              this.readOnlyContent()
            } else {
              Column({ space: 12 }) { this.editorContent() }.width('100%')
            }
            this.attributes()
          }.width('100%')
          if (taskEventLogs(this.value().logs).length > 0) {
            TaskLogView({ internalLinkProcessor: this.internalLinkProcessor,
              logs: taskEventLogs(this.value().logs), expanded: taskLogVisible(this.logShowPolicy, this.logbookExpanded),
              contentBackground: '#00000000' }).width('100%').padding({ left: 27 })
              .margin({ top: taskLogVisible(this.logShowPolicy, this.logbookExpanded) ? 8 : 0 })
          }
        }.width('100%').padding({ right: 8, bottom: 12 })
          .backgroundColor(this.value().state?.category === TaskStateCategory.Doing ? Color.Transparent : UiColor.taskCard).borderRadius(12)
        if (taskSourceText(this.value(), true, this.regionPolicy())) {
          Text(taskSourceText(this.value(), true, this.regionPolicy())).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(11).fontColor(UiColor.secondary)
            .width('100%').textAlign(TextAlign.End).padding({ top: 6, right: 12, bottom: 4 })
            .constraintSize({ minHeight: this.regionArea().project !== null ? 48 : 0 })
            .onClick((): void => {
              if (this.regionArea().project !== null) this.openProject()
            })
        }
      } else {
        this.compactRow()
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      }
    }.width('100%').visibility(this.removed ? Visibility.None : Visibility.Visible)
      .backgroundColor(!this.bodyOnly && this.value().state?.category === TaskStateCategory.Doing ? UiColor.taskDoingTint : Color.Transparent).borderRadius(12)
      .overlay(this.attentionOverlay())
      .onVisibleAreaChange([0], (visible: boolean): void => {
        this.attentionVisible = visible
        if (visible) this.attentionChanged()
      })
      .alignItems(HorizontalAlign.Start).margin({ bottom: this.expanded ? 8 : 0 })
      .onAreaChange((oldArea: Area, area: Area) => {
        this.rowWidth = parseFloat(area.width.toString())
      })
      .hitTestBehavior(this.titleOnly ? HitTestMode.None : HitTestMode.Default)
      .onClick(() => {})
      .bindSheet($$this.moveOpen, this.movePanel, {
        height: '70%', detents: ['70%', '90%'], detentSelection: this.moveDetent,
        preferType: SheetType.BOTTOM, dragBar: true, showClose: false, backgroundColor: '#363A38',
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
        onWillDismiss: (action): void => { this.closeMove((): void => { action.dismiss() }) }
      })
  }

}

@Component
export struct TaskMovePreview {
  @Prop tasks: CoreTask[] = []
  @Prop hiddenTags: string[] = []
  @State showAll: boolean = false
  expandPanel: () => void = () => {}

  build() {
    Column({ space: 5 }) {
      Text(this.tasks.length > 1 ? `待移动任务 · ${this.tasks.length} 条` : '待移动任务')
        .width('100%').padding({ left: 3 }).fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary)
      Column() {
        ForEach(this.showAll ? this.tasks : this.tasks.slice(0, 2), (task: CoreTask) => {
          TaskEditor({ readOnly: true, previewTask: task, previewExpanded: this.expandPanel, hiddenTags: this.hiddenTags,
            regionAreaPolicy: RegionAreaPolicy.None, instanceKey: `move-preview:${task.id}` })
        }, (task: CoreTask): string => task.id)
      }.width('100%').backgroundColor(UiColor.surface).borderRadius(9).clip(true)
      if (this.tasks.length > 2) {
        Row({ space: 5 }) {
          Text(this.showAll ? '收起其余任务' : `查看其余 ${this.tasks.length - 2} 条`)
            .fontSize(13).fontColor(UiColor.primary).fontWeight(FontWeight.Medium)
          Image($r('app.media.ui_next')).width(14).height(14).fillColor(UiColor.primary)
            .rotate({ angle: this.showAll ? -90 : 0 }).accessibilityLevel('no')
        }.width('100%').height(32).padding({ left: 3 }).id('move_source_show_all')
          .onClick((): void => {
            this.showAll = !this.showAll
            if (this.showAll) this.expandPanel()
          })
      }
    }.width('100%')
  }
}
