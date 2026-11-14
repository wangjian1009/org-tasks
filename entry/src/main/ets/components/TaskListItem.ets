import { ProjectNavigation } from '../services/ProjectNavigation'
import { TaskPriorityChoices } from './TaskPriorityChoices'
import { priorityColor, priorityBackground, priorityLabel } from '../ui/TaskPriorityPresentation'
import { TaskStateCategory, taskStateCategoryLabel } from '../ui/TaskStatePresentation'
import { CoreTask, CoreTaskChecklistItem, CoreTaskChecklistChange, CoreTaskModification, CoreTaskPlanningEdit, CoreRefileTarget, CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { TaskInlineService, TaskInlineSession, TaskInlineMissingError } from '../services/TaskInlineService'
import { CoreDataChangeState, emptyCoreDataChangeState } from '../services/CoreDataChangeService'
import { TaskDateDialog } from './TaskDateDialog'
import { TaskRepeatDialog } from './TaskRepeatDialog'
import { repeatSummary } from '../ui/TaskRepeatPresentation'
import { TaskTagsDialog } from './TaskTagsDialog'
import { MoveToTarget } from './MoveToTarget'
import { MoveToTargetService } from '../services/MoveToTargetService'
import { RefileSection, refileSections } from '../ui/MoveToTargetPresentation'
import { TaskRightSwipeAction } from '../ui/TaskActionPresentation'
import { PopupMenuButton } from './PopupMenuButton'
import { PopupMenuItem } from './PopupMenu'
import { inlineDateLabel, inlineDate, inlinePlanningLabel } from '../ui/TaskInlinePresentation'
import { UiColor, UiSize } from '../ui/Theme'
import { taskDateIsToday, taskDateText, taskDeadlineColor, taskDeadlineText, taskDateForDisplay, TaskDateDisplay,
  taskDurationDays, taskIndicators, taskRowLayout, taskTagColor,
  TaskRowLayout, taskTitleText, taskSourceText, RegionAreaPolicy, TaskRegionArea, taskRegionArea } from '../ui/TaskListPresentation'
import { TitleText } from './TitleText'
import { LinkEditController } from './LinkView'
import { CoreTextLink, CoreLinkValue } from '../services/NativeCoreService'
import { OrgContentView } from './OrgContentView'
import { TaskLogView } from './TaskLogView'
import { TaskChecklistView } from './TaskChecklistView'
import { TitleCounts } from './TitleCounts'
import { titleCounts, titleCountsWidth } from '../ui/TitleCountPresentation'
import { TaskInlineFocus } from '../ui/TaskInlineFocus'
import { TaskChecklistDrag, checklistSiblings, checklistMovePreview, checklistEdgeScroll } from '../ui/TaskChecklistReorder'
import { FrameCallback, KeyboardAvoidMode } from '@ohos.arkui.UIContext'
import { window } from '@kit.ArkUI'

class ChecklistFocusFrame extends FrameCallback {
  private callback: () => void
  constructor(callback: () => void) { super(); this.callback = callback }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.callback() }
}

// 快照与写入均来自 Core；只维护卡片、输入草稿和浮层状态。
@Component
export struct TaskListItem {
  @Prop task: CoreTask
  @Prop enableCompletionState: boolean = true
  @Prop readOnly: boolean = false
  @Prop documentMode: boolean = false
  @Prop expandOnRowClick: boolean = false
  @Prop hiddenTags: string[] = []
  @Prop allowCompletion: boolean = false
  @Prop instanceKey: string = ''
  @Prop dateDisplay: TaskDateDisplay = TaskDateDisplay.None
  @Prop regionAreaPolicy: RegionAreaPolicy | undefined = undefined
  @Prop enableSwipeActions: boolean = false
  @Prop rightSwipeAction: TaskRightSwipeAction = 'schedule'
  open: () => void = () => {}
  swipe: (left: boolean) => void = () => {}
  scrollHost: Scroller | undefined = undefined
  scrollHostId: string = ''
  @State expanded: boolean = false
  @State logbookExpanded: boolean = false
  @State editTask: CoreTask | undefined = undefined
  @State heading: string = ''
  @State headingInput: boolean = false
  @State notesInput: boolean = false
  @State notes: string = ''
  private headingEditing: boolean = false
  private notesEditing: boolean = false
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
  @State moveSections: RefileSection[] = []
  @State moveLoading: boolean = false
  @State moveBusy: boolean = false
  @State moveMessage: string = ''
  private moveRequest: number = 0
  @State message: string = ''
  @State rowWidth: number = 366
  @State deadlineWidth: number = 0
  @State checkId: string = ''
  @State checkText: string = ''
  @State addingCheck: boolean = false
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
  @StorageLink('taskInlineDateRequest') @Watch('dateRequested') dateRequest: string = ''
  @StorageLink('coreDataChanges') @Watch('dataChanged') dataChanges: CoreDataChangeState = emptyCoreDataChangeState()
  @Prop referenceTime: number = Date.now()
  private ownerKey: string = ''
  private appeared: boolean = false
  private dataRevision: number = -1
  private refreshRequest: number = 0
  private dateDialog: CustomDialogController | undefined = undefined
  private tagsDialog: CustomDialogController | undefined = undefined
  private repeatDialog: CustomDialogController | undefined = undefined
  private pending: Promise<void> = Promise.resolve()
  private checkSaving: Promise<boolean> | undefined = undefined
  private continueCheck: boolean = false
  private checklistTouch: boolean = false
  private checkHeights: Map<string, number> = new Map()
  private checkScroller: ListScroller = new ListScroller()
  private checkDrag: TaskChecklistDrag | undefined = undefined
  private checkScrollTimer: number = -1
  private dragPointerX: number = 0
  private dragPointerY: number = 0
  private dragEpoch: number = 0
  private gripPress: string = ''
  private gripX: number = 0
  private gripY: number = 0
  private headingController: TextAreaController = new TextAreaController()
  private notesController: TextAreaController = new TextAreaController()
  private hostWindow: window.Window | undefined = undefined
  private checkFocus: TaskInlineFocus = new TaskInlineFocus(
    (callback: () => void) => { this.getUIContext().postFrameCallback(new ChecklistFocusFrame(callback)) },
    (key: string) => { this.getUIContext().getFocusController().requestFocus(key) })
  private keyboardChanged = (height: number): void => {
    if (!this.expanded) return
    this.typing = height > 0
    AppStorage.setOrCreate('taskInlineTyping', this.typing)
  }

  dateRequested() {
    if (this.dateRequest.startsWith(`${this.task.id}\n`)) this.dates(false)
  }
  value(): CoreTask { return this.editTask ?? this.task }
  horizontalSwipe(offsetX: number) {
    if ((this.readOnly && !this.allowCompletion) || this.typing || this.checklistTouch || this.draggingCheck) return
    if (offsetX > 48) this.rightSwipe()
    else if (offsetX < -48 && this.enableSwipeActions) this.swipe(true)
  }

  rightSwipe() {
    if (this.readOnly) return
    if (this.completing || this.working || this.moveBusy || this.moveOpen || this.snapshotBlocked || this.removed ||
      this.typing || this.checklistTouch || this.draggingCheck) return
    switch (this.rightSwipeAction) {
      case 'schedule': this.dates(false); break
      case 'doing': this.toggleDoing(); break
      case 'move': this.openMove(); break
      case 'none': break
    }
  }

  async openMove() {
    if (this.readOnly) return
    if (this.rightSwipeAction !== 'move' || this.completing || this.working || this.moveBusy || this.snapshotBlocked || this.draggingCheck || this.typing) return
    this.completing = true
    try {
      if (!await this.prepare() || !await this.finish(false)) return
      const current = await TaskInlineService.reload(this.getUIContext().getHostContext()!, this.value(), this.documentMode)
      if (!this.appeared || this.removed) return
      this.applySnapshot(current)
      this.moveSource = current
      this.moveOpen = true
    } catch (error) {
      if (!this.appeared) return
      if (error instanceof TaskInlineMissingError) this.removeDeletedTask()
      else if (this.moveOpen) this.moveMessage = coreErrorMessage(error as CoreBridgeError)
      else this.message = coreErrorMessage(error as CoreBridgeError)
    } finally {
      this.completing = false
      if (!this.moveOpen && !this.expanded) TaskInlineSession.release(this.ownerKey)
    }
    if (this.moveOpen) await this.loadMoveTargets()
  }

  async loadMoveTargets() {
    const request = ++this.moveRequest
    this.moveLoading = true
    this.moveMessage = ''
    this.moveSections = []
    try {
      const targets = await MoveToTargetService.targets(this.getUIContext().getHostContext()!)
      if (request === this.moveRequest && this.moveOpen) this.moveSections = refileSections(targets)
    } catch (error) {
      if (request === this.moveRequest && this.moveOpen) this.moveMessage = coreErrorMessage(error as CoreBridgeError)
    } finally {
      if (request === this.moveRequest) this.moveLoading = false
    }
  }

  closeMove() {
    if (this.moveBusy) return
    ++this.moveRequest
    this.moveOpen = false
    this.moveSource = undefined
    this.moveSections = []
    this.moveLoading = false
    this.moveMessage = ''
    if (!this.expanded) TaskInlineSession.release(this.ownerKey)
  }

  async moveTo(target: CoreRefileTarget) {
    const source = this.moveSource
    if (!source || !this.moveOpen || this.moveLoading || this.moveBusy || this.completing || this.snapshotBlocked) return
    this.moveBusy = true
    this.moveMessage = ''
    try {
      await MoveToTargetService.move(this.getUIContext().getHostContext()!, source, target)
      this.moveBusy = false
      this.closeMove()
      this.removeDeletedTask()
    } catch (error) {
      if (this.appeared && this.moveOpen) this.moveMessage = coreErrorMessage(error as CoreBridgeError)
    } finally { this.moveBusy = false }
  }

  @Builder
  movePanel() {
    MoveToTarget({ sections: this.moveSections, selectionKey: this.moveSource ? JSON.stringify([this.moveSource.fullPath, this.moveSource.fileVersion]) : '',
      loading: this.moveLoading, busy: this.moveBusy, message: this.moveMessage,
      choose: (target: CoreRefileTarget): void => { this.moveTo(target) }, retry: (): void => { this.openMove() } })
  }

  async toggleDoing() {
    if (this.readOnly) return
    const previous = this.value().state?.category
    const category = previous === TaskStateCategory.Doing ? TaskStateCategory.Todo : TaskStateCategory.Doing
    if (this.rightSwipeAction !== 'doing' || this.completing || this.working || this.draggingCheck || this.typing || this.snapshotBlocked ||
      this.value().state === null || this.value().isDone() || !this.value().taskStateOf(category)) return
    this.completing = true
    try {
      if (!await this.prepare() || !await this.finish(false)) return
      const state = this.value().taskStateOf(category)
      if (this.value().state?.category !== previous || !state) return
      await this.persist([{ field: 'TODO', value: state.name }])
    } finally {
      this.completing = false
      if (!this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  async complete() {
    if (this.readOnly && !this.allowCompletion) return
    const reopen = this.value().isDone()
    const category = reopen ? TaskStateCategory.Todo : TaskStateCategory.Done
    if (this.completing || this.working || this.snapshotBlocked || this.value().state === null || !this.value().taskStateOf(category)) return
    this.completing = true
    try {
      if (!await this.prepare() || !await this.finish(false)) return
      const state = this.value().taskStateOf(category)
      if (this.value().state === null || this.value().isDone() !== reopen || !state) return
      if (await this.persist([{ field: 'TODO', value: state.name }])) {
        this.expanded = false
      }
    } finally {
      this.completing = false
      if (!this.expanded) TaskInlineSession.release(this.ownerKey)
    }
  }
  dataChanged() {
    if (!this.appeared || this.removed || this.dataRevision === this.dataChanges.revision) return
    const revision = this.dataChanges.revision
    this.dataRevision = revision
    const request = ++this.refreshRequest
    // 关联任务与当前卡片共用事件快照；同一任务的写入与刷新仍顺序执行。
    const refresh = this.pending.then(async () => {
      if (!this.appeared || this.removed || request !== this.refreshRequest) return
      const previous = this.value()
      try {
        const current = await TaskInlineService.findChanged(this.getUIContext().getHostContext()!, previous, revision, this.documentMode)
        if (!this.appeared || this.removed || request !== this.refreshRequest) return
        this.applySnapshot(current)
      } catch (error) {
        if (this.appeared && request === this.refreshRequest) this.message = coreErrorMessage(error as CoreBridgeError)
      }
    })
    this.pending = refresh
  }
  applySnapshot(current: CoreTask | undefined, savedCheck: boolean = false) {
    if (!current) { this.removeDeletedTask(); return }
    if (this.linkEditing && !this.linkSaving && current.fileVersion !== this.value().fileVersion) {
      this.snapshotBlocked = true; this.message = '文件已变化，链接草稿已保留，请取消编辑并重新载入后继续'
      return
    }
    if (this.checkId && current.fileVersion !== this.value().fileVersion && !savedCheck) {
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
    this.priorityOpen = false
    ++this.moveRequest
    this.moveOpen = false; this.moveSource = undefined
    this.removed = true; this.snapshotBlocked = true
    this.expanded = false; this.typing = false; this.message = ''
    this.headingEditing = false; this.notesEditing = false
    this.headingInput = false
    this.notesInput = false
    this.continueCheck = false
    this.checkFocus.cancel()
    this.cancelCheckDrag()
    this.dateDialog?.close(); this.tagsDialog?.close(); this.repeatDialog?.close()
    TaskInlineSession.release(this.ownerKey)
  }
  aboutToAppear() {
    this.ownerKey = this.instanceKey || this.task.id
    this.appeared = true
    this.dataRevision = this.dataChanges.revision
  }
  aboutToDisappear() {
    this.priorityOpen = false
    this.appeared = false
    ++this.moveRequest
    this.moveOpen = false; this.moveSource = undefined
    ++this.refreshRequest
    this.cancelCheckDrag()
    this.checkFocus.dispose()
    this.dateDialog?.close(); this.tagsDialog?.close(); this.repeatDialog?.close()
    if (this.hostWindow) this.hostWindow.off('keyboardHeightChange', this.keyboardChanged)
    TaskInlineSession.release(this.ownerKey)
  }
  async prepare(): Promise<boolean> {
    if (this.removed) return false
    if (!this.ownerKey) this.ownerKey = this.instanceKey || this.task.id
    if (!await TaskInlineSession.begin(this.ownerKey, async (collapse: boolean) => await this.finish(collapse))) return false
    if (!this.editTask) { this.editTask = this.task; this.heading = this.task.heading; this.notes = this.task.editContent.notes.trimEnd() }
    if (this.readOnly) return true
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
    if (!await this.prepare()) return
    this.logbookExpanded = false
    this.referenceTime = Date.now()
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = true })
  }
  async finish(collapse: boolean): Promise<boolean> {
    if (this.readOnly) {
      if (collapse) { this.expanded = false; TaskInlineSession.release(this.ownerKey) }
      return true
    }
    if (this.moveBusy) return false
    if (collapse && this.moveOpen) this.closeMove()
    this.cancelCheckDrag()
    this.continueCheck = false
    this.checkFocus.cancel()
    this.headingController.stopEditing(); this.notesController.stopEditing()
    this.getUIContext().getFocusController().clearFocus()
    this.typing = false; AppStorage.setOrCreate('taskInlineTyping', false)
    if (!await this.saveText() || !await this.saveCheck(false)) return false
    await this.pending
    this.checkFocus.cancel()
    if (this.snapshotBlocked) return false
    if (!this.newCheck.trim() && !this.checkId) this.addingCheck = false
    this.headingInput = false
    this.notesInput = false
    if (!this.snapshotBlocked) this.message = ''
    if (collapse) {
      this.priorityOpen = false
      this.expanded = false
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
    if (!await this.linkEditor.finish() || this.snapshotBlocked || this.removed) return
    this.headingInput = true
    this.checkFocus.request(`inline_title_${this.ownerKey}`)
  }

  async finishHeading() {
    if (await this.saveText()) this.headingInput = false
  }

  async editNotes() {
    if (this.readOnly || this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.linkEditor.finish() || this.snapshotBlocked || this.removed) return
    this.notesInput = true
    this.checkFocus.request(`inline_notes_${this.ownerKey}`)
  }

  async finishNotes() {
    if (await this.saveText() && !this.snapshotBlocked) this.notesInput = false
  }
  async persist(modifications: CoreTaskModification[]): Promise<boolean> {
    if (this.readOnly && !this.allowCompletion) return false
    if (this.snapshotBlocked) return false
    let success: boolean = false
    const operation = this.pending.then(async () => {
      if (this.removed || this.snapshotBlocked) return
      this.working = true; this.message = ''
      try {
        const context = this.getUIContext().getHostContext()!
        await TaskInlineService.modify(context, this.value(), modifications, this.documentMode)
        for (const modification of modifications) {
          if (modification.field === 'TITLE' && this.heading === modification.value) this.headingEditing = false
          if (modification.field === 'NOTES' && this.notes === modification.value) this.notesEditing = false
        }
        success = true
        // 提交后的快照是下一次编辑的起点，不依赖原生事件先于 Promise 送达。
        ++this.refreshRequest
        const current = await TaskInlineService.findChanged(context, this.value(), this.dataChanges.revision, this.documentMode)
        const savedCheck = modifications.some((modification: CoreTaskModification): boolean => {
          if (modification.field !== 'CHECKLIST') return false
          const change = modification.value as CoreTaskChecklistChange
          return change.type === 'edit' && change.id === this.checkId && change.text === this.checkText
        })
        if (this.appeared && !this.removed) this.applySnapshot(current, savedCheck)
      } catch (error) {
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
    if (!await this.linkEditor.finish()) return false
    await this.pending
    if (this.removed) return false
    if (!this.heading.trim()) { this.message = '标题不能为空'; return false }
    const modifications: CoreTaskModification[] = []
    if (this.headingEditing && this.heading !== this.value().heading) modifications.push({ field: 'TITLE', value: this.heading })
    if (this.notesEditing && this.notes !== this.value().editContent.notes.trimEnd()) modifications.push({ field: 'NOTES', value: this.notes })
    if (modifications.length > 0) return await this.persist(modifications)
    this.headingEditing = false; this.notesEditing = false
    return true
  }
  linkEditingChanged(editing: boolean) {
    this.linkEditing = editing
    if (editing) this.inputFocus()
  }
  linksEditable(): boolean {
    return this.expanded && !this.readOnly && !this.snapshotBlocked
  }
  async changeLink(field: 'title' | 'notes', link: CoreTextLink, value: CoreLinkValue | null): Promise<void> {
    if (!this.linksEditable()) throw new Error('请展开可编辑任务后再修改链接')
    this.linkSaving = true
    try {
      if (!await this.persist([{ field: 'LINK', value: { field, link, value } }]) || this.snapshotBlocked) {
        throw new Error(this.message || '修改链接失败，请重试')
      }
    } finally { this.linkSaving = false }
  }
  async saveCheck(next: boolean): Promise<boolean> {
    if (this.readOnly) return true
    if (next) this.continueCheck = true
    if (this.checkSaving) return await this.checkSaving
    this.checkSaving = this.commitCheck()
    const result = await this.checkSaving
    this.checkSaving = undefined
    if (result && this.continueCheck) {
      this.addingCheck = true
      this.checkFocus.request(`inline_new_check_${this.ownerKey}`)
    }
    this.continueCheck = false
    return result
  }
  private async commitCheck(): Promise<boolean> {
    await this.pending
    const id = this.checkId
    const text = id ? this.checkText : this.newCheck
    if (!id && !text.trim()) return true
    if (!text.trim()) { this.message = '清单条目不能为空'; return false }
    const original = this.value().editContent.checklist.find(item => item.id === id)
    if (id && original?.text === text) { this.checkId = ''; return true }
    const change: CoreTaskChecklistChange = id ? { type: 'edit', id, text } : { type: 'add', text }
    if (!await this.persist([{ field: 'CHECKLIST', value: change }])) return false
    this.checkId = ''; this.checkText = ''; this.newCheck = ''; this.addingCheck = this.continueCheck
    return true
  }
  async changeCheck(change: CoreTaskChecklistChange) {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.prepare()) return
    const id = change.type === 'add' ? '' : change.id
    const index = this.value().editContent.checklist.findIndex(item => item.id === id)
    if (!await this.saveText() || !await this.saveCheck(false)) return
    const current = this.value().editContent.checklist[index]
    if (change.type === 'setChecked' && current) change = { type: 'setChecked', id: current.id, checked: change.checked }
    else if (change.type === 'remove' && current) change = { type: 'remove', id: current.id }
    await this.persist([{ field: 'CHECKLIST', value: change }])
  }
  async editCheck(item: CoreTaskChecklistItem) {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.prepare()) return
    const index = this.value().editContent.checklist.findIndex(current => current.id === item.id)
    if (!await this.saveText() || !await this.saveCheck(false)) return
    const current = this.value().editContent.checklist[index]
    if (!current) return
    this.checkId = current.id; this.checkText = current.text
    this.checkFocus.request(`inline_check_${current.id}`)
  }
  async addCheck() {
    if (this.readOnly) return
    if (this.working || this.draggingCheck || this.snapshotBlocked) return
    if (!await this.prepare()) return
    if (!await this.saveText() || !await this.saveCheck(false)) return
    this.addingCheck = true
    this.checkFocus.request(`inline_new_check_${this.ownerKey}`)
  }
  async dates(deadline: boolean) {
    if (this.readOnly) return
    if (!await this.prepare() || !await this.finish(false)) return
    const wasExpanded = this.expanded
    this.dateDialog = new CustomDialogController({
      builder: TaskDateDialog({ closed: () => { if (!wasExpanded) TaskInlineSession.release(this.ownerKey) }, selected: deadline ? this.value().deadline : this.value().scheduled,
        planning: deadline ? this.value().editContent.deadlinePlanning : this.value().editContent.scheduledPlanning, deadline,
        failureMessage: (): string => this.message || '未能保存，请重试',
        choose: async (value: CoreTaskPlanningEdit | null): Promise<boolean> => {
          return await this.persist([{ field: deadline ? 'DEADLINE' : 'SCHEDULE', value }])
        } }),
      customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => { if (this.working) return; action.dismiss(); if (!wasExpanded) TaskInlineSession.release(this.ownerKey) }
    })
    this.dateDialog.open()
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
        .onClick(() => { if (editable) this.priorities(); else this.toggle() })
    }
  }

  async repeats(deadline: boolean = false) {
    if (this.readOnly) return
    if (!await this.prepare() || !await this.finish(false)) return
    this.repeatDialog = new CustomDialogController({
      builder: TaskRepeatDialog({ task: this.value(), initialDeadline: deadline,
        save: async (changes: CoreTaskModification[]): Promise<boolean> => await this.persist(changes) }),
      customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => { if (!this.working) action.dismiss() }
    })
    this.repeatDialog.open()
  }
  reloadDraft() {
    if (this.working) return
    this.getUIContext().showAlertDialog({ title: '重新载入任务？', message: '将放弃卡片中未保存的输入，读取文件中的最新内容。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重新载入', action: async () => {
        this.working = true
        try {
          this.editTask = await TaskInlineService.reload(this.getUIContext().getHostContext()!, this.value(), this.documentMode)
          this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
          this.headingEditing = false; this.notesEditing = false
          this.checkId = ''; this.checkText = ''; this.newCheck = ''; this.addingCheck = false; this.message = ''
          this.snapshotBlocked = false; this.checkPreview = []
        } catch (error) {
          if (error instanceof TaskInlineMissingError) this.removeDeletedTask()
          else this.message = coreErrorMessage(error as CoreBridgeError)
        }
        finally { this.working = false }
      } } })
  }
  async tags() {
    if (this.readOnly) return
    if (!await this.prepare() || !await this.finish(false)) return
    try {
      this.tagsDialog = new CustomDialogController({
        builder: TaskTagsDialog({ supportTags: this.value().supportTags, ownTags: this.value().ownTags, visibleTags: this.displayTags(),
          inheritedTags: this.value().inheritedTags, hiddenTags: this.hiddenTags,
          change: async (tags: string[]): Promise<boolean> => await this.persist([{ field: 'TAGS', value: tags }]) }),
        customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
        onWillDismiss: (action: DismissDialogAction) => { if (!this.working) action.dismiss() }
      })
      this.tagsDialog.open()
    } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
  }

  checkItems(): CoreTaskChecklistItem[] {
    return this.draggingCheck || this.working && this.checkPreview.length > 0 ? this.checkPreview : this.value().editContent.checklist
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
    return !this.working && !this.typing && !this.checkId && !this.newCheck.trim() && !this.checkSaving &&
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
    if (this.gripPress !== item.id || !this.canSortCheck() || this.draggingCheck || checklistSiblings(this.value().editContent.checklist, item.id).length < 2) return
    const finger = event.fingerList[0]
    const node = this.getUIContext().getFrameNodeById(`inline_checks_${this.ownerKey}`)
    if (!finger || !node) return
    try {
      this.checkScroller.closeAllSwipeActions()
    } catch (_) {
      // 尚未完成布局时无需关闭已不存在的侧滑操作。
    }
    this.checkFocus.cancel()
    const localY = finger.globalY - node.getPositionToWindow().y
    this.checkDrag = new TaskChecklistDrag(this.value().editContent.checklist, item.id, this.checkHeights, localY)
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
    const node = this.getUIContext().getFrameNodeById(`inline_checks_${this.ownerKey}`)
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
    this.checkPreview = checklistMovePreview(task.editContent.checklist, id, beforeId)
    if (!this.checkPreview.some((item: CoreTaskChecklistItem, index: number) => item.id !== task.editContent.checklist[index].id)) return
    this.working = true; this.message = ''
    const operation = this.pending.then(async () => {
      let committed = false
      const context = this.getUIContext().getHostContext()!
      try {
        await TaskInlineService.modify(context, task, [{ field: 'CHECKLIST', value: { type: 'move', id, beforeId } }], this.documentMode)
        committed = true
        this.editTask = await TaskInlineService.reload(context, task, this.documentMode)
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
            this.editTask = await TaskInlineService.reload(context, task, this.documentMode)
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
    const siblings = checklistSiblings(this.value().editContent.checklist, item.id)
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

  expandedPlanningText(): string {
    const parts: string[] = []
    if (this.value().scheduled) parts.push(`计划：${inlinePlanningLabel(this.value().scheduled, this.value().editContent.scheduledPlanning)}`)
    if (this.value().deadline) parts.push(`截止：${inlinePlanningLabel(this.value().deadline, this.value().editContent.deadlinePlanning)}`)
    if (this.dateDisplay === TaskDateDisplay.Closed) {
      const closed = this.expandedDateLabel(TaskDateDisplay.Closed)
      if (closed) parts.push(`完成：${closed}`)
    }
    return parts.join('    ')
  }

  leadingWidth(): number {
    return (taskDateForDisplay(this.value(), this.dateDisplay).length > 0 ? this.leadingDate().length * 7 + 18 : 0)
      + (this.value().isHabit || this.value().isRepeating ? 26 : 0)
  }

  deadlineColor(): string { return taskDeadlineColor(this.value(), new Date(this.referenceTime)) }

  deadlineIcon(): Resource {
    return this.deadlineColor() === UiColor.deadline
      ? $r('app.media.ui_task_deadline') : $r('app.media.ui_task_deadline_neutral')
  }

  countBudget(): number {
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
      } else if (this.value().state?.category === TaskStateCategory.Cancel) {
        Stack() {
          Text('').width(18).height(18)
            .border({ width: 1.4, color: UiColor.disabled }).borderRadius(4)
          Divider().width(18).strokeWidth(1.4).color(UiColor.disabled)
        }.width(18).height(18)
      } else {
        Stack() {
          Text('').width(18).height(18)
            .border({ width: 1.4, color: '#8B8986' }).borderRadius(4)
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

  @Builder
  stateIndicator() {
    if (this.value().state === null) {
      Image($r('app.media.ui_note')).width(18).height(18)
        .accessibilityText('笔记，无任务状态')
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
      .onClick((): void => { this.toggle() })
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
      await ProjectNavigation.open(this.getUIContext(), this.value().repoId, this.value().filePath)
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
        this.priorityBadge()
        Column({ space: 2 }) {
          TitleText({ text: this.value().heading, parts: this.value().headingParts, editable: false,
            lineLimit: 1, showCounts: false, cancelled: (this.value().state?.category === TaskStateCategory.Cancel) })
            .width('100%').constraintSize({ minWidth: 0 })
          if (taskSourceText(this.value(), false, this.regionPolicy())) {
            this.categoryProject()
          }
        }.layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .onClick((): void => { this.toggle() })
      }.layoutWeight(1).constraintSize({ minWidth: 0 }).alignItems(VerticalAlign.Center)
      if (titleCounts(this.value().headingParts).length > 0) {
        TitleCounts({ parts: this.value().headingParts, budget: this.countBudget() })
          .width(titleCountsWidth(this.value().headingParts, this.countBudget())).flexShrink(0)
          .onClick((): void => { this.toggle() })
      }
      if (this.displayTags().length > 0 && this.layout().tagWidth > 0) { this.compactTags() }
      if (this.layout().indicatorWidth > 0) { this.compactIndicators() }
      if (this.layout().durationWidth > 0) {
        Text(`${this.duration()}天`).fontSize(11).fontColor(UiColor.secondary)
          .width(this.layout().durationWidth).flexShrink(0).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .accessibilityText(`持续 ${this.duration()} 天`)
      }
    }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow }).alignItems(VerticalAlign.Center)
      .accessibilityText(`${taskTitleText(this.value())}，点击展开`)
  }

  @Builder
  compactDeadline() {
    Row({ space: 4 }) {
      Image(this.deadlineIcon()).width(16).height(16)
      Text(taskDeadlineText(this.value(), new Date(this.referenceTime))).fontSize(12).fontColor(this.deadlineColor()).maxLines(1)
    }.alignItems(VerticalAlign.Center).flexShrink(0)
      .onAreaChange((oldArea: Area, area: Area) => { this.deadlineWidth = parseFloat(area.width.toString()) })
  }
  @Builder
  compactLeadingInfo() {
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
    if (this.expandOnRowClick) {
      Row() {
        if (this.value().state !== null) {
          Row() { this.stateIndicator() }
            .padding({ left: 8 }).constraintSize({ minHeight: UiSize.taskRow })
        }
        Row({ space: 6 }) {
          if (this.value().state === null) { this.stateIndicator() }
          this.compactContent()
        }.layoutWeight(1).constraintSize({ minWidth: 0, minHeight: UiSize.taskRow })
          .padding({ left: this.value().state === null ? 8 : 6, right: 8 })
          .accessibilityText(`${taskTitleText(this.value())}，点击展开`)
          // 整个内容区统一识别点击，避免子控件截获或重复触发展开；状态框位于手势区域之外。
          .priorityGesture(TapGesture().onAction((): void => { this.toggle() }), GestureMask.IgnoreInternal)
      }.width('100%').constraintSize({ minHeight: UiSize.taskRow })
    } else {
      Row({ space: 6 }) {
        this.stateIndicator()
        this.compactContent()
      }.width('100%').padding({ left: 8, right: 8 }).constraintSize({ minHeight: UiSize.taskRow })
    }
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
  checklistRow(item: CoreTaskChecklistItem, floating: boolean = false) {
    Row({ space: 4 }) {
      Button(item.checked ? '✓' : item.partial ? '−' : '○').width(28).height(44).padding(0)
        .fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
        .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked && !floating)
        .accessibilityText(item.checked ? `恢复未完成：${item.text}` : `完成：${item.text}`)
        .onClick(() => { this.changeCheck({ type: 'setChecked', id: item.id, checked: !item.checked }) })
      if (!floating && this.checkId === item.id) {
        TextInput({ text: this.checkText }).id(`inline_check_${item.id}`).layoutWeight(1).fontSize(14)
          .fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0).enterKeyType(EnterKeyType.Next)
          .onChange((text: string) => { this.checkText = text }).onFocus(() => { this.inputFocus() })
          .onBlur(() => { this.saveCheck(false) })
          .onAppear(() => { this.checkFocus.appeared(`inline_check_${item.id}`) })
          .onDisAppear(() => { this.checkFocus.disappeared(`inline_check_${item.id}`) })
          .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.checkFocus.visible(`inline_check_${item.id}`) })
          .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => { event?.keepEditableState(); this.saveCheck(true) })
      } else {
        Text(item.text).layoutWeight(1).fontSize(14).fontColor(item.checked ? UiColor.disabled : UiColor.text)
          .decoration({ type: item.checked ? TextDecorationType.LineThrough : TextDecorationType.None })
          .onClick(() => { this.editCheck(item) })
      }
      if (checklistSiblings(this.value().editContent.checklist, item.id).length > 1) {
        if (floating) { this.checkGripLines() }
        else { this.checkGrip(item) }
      }
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(item.depth, 6) * 12 })
  }
  @Builder
  deleteCheck(item: CoreTaskChecklistItem) {
    Button({ type: ButtonType.Circle }) { Image($r('app.media.ui_delete')).width(24).height(24) }
      .width(44).height(44).padding(0).backgroundColor('#513A40')
      .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked).accessibilityText(`删除清单条目：${item.text}`)
      .onClick(() => { this.changeCheck({ type: 'remove', id: item.id }) })
  }

  // 项目文档使用原生正文滚动，清单控件复用任务卡的快照与保存回调。
  @Builder
  documentChecklist() {
    if (this.value().editContent.checklist.length > 0 || this.addingCheck) {
      TaskChecklistView({ items: this.checkItems(), editable: !this.readOnly, working: this.working,
        snapshotBlocked: this.snapshotBlocked, editingId: this.checkId, editingText: this.checkText,
        adding: this.addingCheck, newText: this.newCheck, showAdd: true,
        ownerKey: this.ownerKey,
        toggle: (change: CoreTaskChecklistChange): void => { this.changeCheck(change) },
        edit: (item: CoreTaskChecklistItem): void => { this.editCheck(item) },
        editChanged: (text: string): void => { this.checkText = text },
        editBlur: (): void => { this.saveCheck(false) },
        editSubmit: (): void => { this.saveCheck(true) },
        remove: (item: CoreTaskChecklistItem): void => { this.changeCheck({ type: 'remove', id: item.id }) },
        add: (): void => { this.addCheck() },
        newChanged: (text: string): void => { this.newCheck = text },
        newBlur: (): void => { this.saveCheck(false) },
        newSubmit: (): void => { this.saveCheck(true) },
        focused: (): void => { this.inputFocus() },
        inputAppeared: (id: string): void => { this.checkFocus.appeared(id) },
        inputDisappeared: (id: string): void => { this.checkFocus.disappeared(id) },
        inputVisible: (id: string): void => { this.checkFocus.visible(id) } })
        .width('100%')
    }
  }
  @Builder
  editorContent() {
    Row({ space: 6 }) {
      this.stateIndicator()
      if (this.value().isHabit) {
        Image($r('app.media.ui_task_habit')).width(20).height(20).accessibilityText('习惯任务')
      } else if (this.value().isRepeating) {
        Image($r('app.media.ui_task_repeat')).width(20).height(20).accessibilityText('循环任务')
      }
      Row({ space: 4 }) {
        this.priorityBadge(true)
        if (this.headingInput) {
          TextArea({ text: this.heading, controller: this.headingController, placeholder: '标题' }).id(`inline_title_${this.ownerKey}`)
            .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
            .layoutWeight(1).height('auto').minLines(1).maxLines(1000).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.value().state?.category === TaskStateCategory.Cancel ? UiColor.disabled : UiColor.text)
            .decoration({ type: this.value().state?.category === TaskStateCategory.Cancel ? TextDecorationType.LineThrough : TextDecorationType.None })
            .backgroundColor(Color.Transparent).padding(0).borderRadius(0)
            .enterKeyType(EnterKeyType.Done).onSubmit(() => { TaskInlineSession.end(false) })
            .onChange((value: string) => { this.heading = value; this.headingEditing = true })
            .onFocus(() => { this.headingEditing = true; this.inputFocus() })
            .onBlur(() => { this.finishHeading() })
            .onAppear(() => { this.checkFocus.appeared(`inline_title_${this.ownerKey}`) })
            .onDisAppear(() => { this.checkFocus.disappeared(`inline_title_${this.ownerKey}`) })
            .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.checkFocus.visible(`inline_title_${this.ownerKey}`) })
        } else {
          TitleText({ text: this.value().heading, parts: this.value().headingParts, lineLimit: 1000,
            weight: FontWeight.Medium, cancelled: this.value().state?.category === TaskStateCategory.Cancel,
            editable: this.linksEditable(), revision: this.value().fileVersion, linkEditor: this.linkEditor,
            changeLink: (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink('title', link, value),
            linkEditingChanged: (editing: boolean): void => { this.linkEditingChanged(editing) },
            activate: (): void => { this.editHeading() } })
            .layoutWeight(1).constraintSize({ minHeight: 24 })
        }
      }.layoutWeight(1).constraintSize({ minWidth: 0 }).alignItems(VerticalAlign.Top)
    }.width('100%').alignItems(VerticalAlign.Top)
      .bindPopup(this.priorityOpen, { builder: this.priorityPopup, placement: Placement.BottomLeft,
        targetSpace: 6, enableArrow: false, radius: 10, popupColor: UiColor.menu,
        backgroundBlurStyle: BlurStyle.NONE, mask: { color: Color.Transparent }, focusable: true,
        autoCancel: !this.working && !this.priorityBusy, onWillDismiss: !this.working && !this.priorityBusy,
        onStateChange: (event): void => { this.priorityOpen = event.isVisible } })
    Column({ space: 12 }) {
      if (this.documentMode) {
        this.documentChecklist()
      } else {
      if (this.notesInput) {
      TextArea({ text: this.notes, controller: this.notesController, placeholder: '备注' }).id(`inline_notes_${this.ownerKey}`)
        .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
        .width('100%').height('auto').minLines(1).maxLines(1000).fontSize(14).fontColor(UiColor.text)
        .placeholderColor(UiColor.disabled).backgroundColor(Color.Transparent).padding(0).borderRadius(0)
        .onChange((value: string) => { this.notes = value; this.notesEditing = true })
        .onFocus(() => { this.notesEditing = true; this.inputFocus() })
        .onBlur(() => { this.finishNotes() })
        .onAppear(() => { this.checkFocus.appeared(`inline_notes_${this.ownerKey}`) })
        .onDisAppear(() => { this.checkFocus.disappeared(`inline_notes_${this.ownerKey}`) })
        .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.checkFocus.visible(`inline_notes_${this.ownerKey}`) })
      } else if (this.value().editContent.notesHtml) {
        OrgContentView({ fragment: this.value().editContent.notesHtml, embedded: true, embeddedPadding: 0,
          editable: this.linksEditable(), revision: this.value().fileVersion, linkEditor: this.linkEditor,
          changeLink: (link: CoreTextLink, value: CoreLinkValue | null): Promise<void> => this.changeLink('notes', link, value),
          linkEditingChanged: (editing: boolean): void => { this.linkEditingChanged(editing) },
          contentBackground: this.value().state?.category === TaskStateCategory.Doing ? '#00000000' : UiColor.taskCard,
          activate: (): void => { this.editNotes() } }).width('100%')
      } else {
        Text('备注').fontSize(14).fontColor(UiColor.disabled).width('100%').constraintSize({ minHeight: 24 })
          .onClick(() => { this.editNotes() })
      }
      if (this.value().editContent.checklist.length > 0 || this.addingCheck) {
        Stack({ alignContent: Alignment.TopStart }) {
        List({ scroller: this.checkScroller }) {
          ForEach(this.checkItems(), (item: CoreTaskChecklistItem) => {
            ListItem() { this.checklistRow(item) }
              .opacity(this.draggingCheck && this.checkDrag?.contains(item.id) ? 0 : 1)
              .onAreaChange((_old: Area, area: Area) => { this.checkMeasured(item, area) })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) this.checklistTouch = true
                if (event.type === TouchType.Up || event.type === TouchType.Cancel) setTimeout(() => { this.checklistTouch = false }, 100)
              })
              .swipeAction(this.draggingCheck || this.working || this.snapshotBlocked ? {} : { end: this.deleteCheck(item), edgeEffect: SwipeEdgeEffect.None })
          }, (item: CoreTaskChecklistItem) => `${item.id}:${item.text}:${item.checked}`)
          if (this.addingCheck) {
            ListItem() {
              Row({ space: 4 }) {
                Text('○').width(28).fontSize(19).fontColor(UiColor.secondary)
                TextInput({ text: this.newCheck, placeholder: '清单项' }).id(`inline_new_check_${this.ownerKey}`)
                  .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
                  .layoutWeight(1).fontSize(14).fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0)
                  .enterKeyType(EnterKeyType.Next).onFocus(() => { this.inputFocus() })
                  .onChange((text: string) => { this.newCheck = text }).onBlur(() => { this.saveCheck(false) })
                  .onAppear(() => { this.checkFocus.appeared(`inline_new_check_${this.ownerKey}`) })
                  .onDisAppear(() => { this.checkFocus.disappeared(`inline_new_check_${this.ownerKey}`) })
                  .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) this.checkFocus.visible(`inline_new_check_${this.ownerKey}`) })
                  .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => { event?.keepEditableState(); this.saveCheck(true) })
              }.width('100%').height(44)
            }
          }
          ListItem() {
            Text('+  添加清单项').fontSize(14).fontColor(UiColor.secondary).width('100%').height(44)
              .enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
              .onClick(() => { this.addCheck() })
          }
        }.width('100%').height(this.checkHeight(this.checkLayoutRevision))
          .scrollBar(BarState.Off).enableScrollInteraction(false)
        if (this.draggingCheck) {
          Column().width('100%').height(this.dragHeight).backgroundColor('#303330').borderRadius(8)
            .position({ x: 0, y: this.dragPlaceholder }).hitTestBehavior(HitTestMode.None)
          if (this.dragValid) {
            Rect().width('100%').height(2).fill(UiColor.primary)
              .position({ x: 0, y: this.dragPlaceholder }).hitTestBehavior(HitTestMode.None)
          }
          Column() {
            ForEach(this.dragItems, (item: CoreTaskChecklistItem) => {
              this.checklistRow(item, true)
            }, (item: CoreTaskChecklistItem) => item.id)
          }.width('100%').height(this.dragHeight).backgroundColor('#494743').borderRadius(8)
            .shadow({ radius: 8, color: '#52000000', offsetY: 4 })
            .position({ x: 0, y: this.dragTop - 4 }).hitTestBehavior(HitTestMode.None)
        }
        }.id(`inline_checks_${this.ownerKey}`).width('100%').height(this.checkHeight(this.checkLayoutRevision))
      }
      }
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
      if (this.message) {
        Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%')
        Button('重新载入').height(36).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
          .enabled(!this.working).onClick(() => { this.reloadDraft() })
      }
    }.width('100%').padding({ left: 27 })
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
    const items: PopupMenuItem[] = []
    if (!this.readOnly) {
      items.push({ title: '优先级…', icon: $r('app.media.ui_priority'), action: () => { this.priorities() } },
        { title: '重复…', icon: $r('app.media.ui_repeat_action'), action: () => { this.repeats() } })
    }
    if (this.value().logs.length > 0) {
      items.push({ title: '日志',
        icon: this.logbookExpanded ? $r('app.media.ui_visibility_off') : $r('app.media.ui_visibility'),
        action: () => { this.logbookExpanded = !this.logbookExpanded } })
    }
    return items
  }
  @Builder
  attributes() {
    Column({ space: 4 }) {
      if (this.value().editContent.scheduledRepeat?.rule) {
        this.repeatRule(false)
      }
      if (this.value().editContent.deadlineRepeat?.rule) {
        this.repeatRule(true)
      }
      Row() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Image(this.value().scheduled === inlineDate(new Date()) ? $r('app.media.nav_today') : $r('app.media.ui_task_calendar')).width(18).height(18)
            if (this.value().scheduled) { Text(inlinePlanningLabel(this.value().scheduled, this.value().editContent.scheduledPlanning)).fontSize(12).fontColor(UiColor.text).maxLines(2) }
          }
        }.id('inline_schedule_button').flexShrink(1).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked).constraintSize({ minWidth: 36, maxWidth: '46%' })
          .accessibilityText('设置或修改计划日期').onClick(() => { this.dates(false) })
        Blank().layoutWeight(1)
        this.attributeButton($r('app.media.ui_tags'), '设置标签', () => { this.tags() })
        if (!this.documentMode) { this.attributeButton($r('app.media.ui_task_list'), '编辑检查清单', () => { this.addCheck() }) }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Image(this.deadlineIcon()).width(16).height(16)
            if (this.value().deadline) { Text(inlinePlanningLabel(this.value().deadline, this.value().editContent.deadlinePlanning)).fontSize(12).fontColor(this.deadlineColor()).maxLines(2) }
          }
        }.id('inline_deadline_button').flexShrink(1).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked).constraintSize({ minWidth: 36, maxWidth: '34%' })
          .accessibilityText('设置或修改截止日期').onClick(() => { this.dates(true) })
        this.moreButton()
      }.width('100%')
    }.width('100%').padding({ left: 27 })
  }
  @Builder
  repeatRule(deadline: boolean) {
    Row({ space: 7 }) {
      if (!this.value().isHabit) { Image($r('app.media.ui_task_repeat')).width(18).height(18) }
      Text(`${deadline ? '截止' : '计划'} · ${repeatSummary(deadline ? this.value().editContent.deadlineRepeat?.rule : this.value().editContent.scheduledRepeat?.rule)}`)
        .fontSize(13).fontColor(UiColor.primary).layoutWeight(1)
      Image($r('app.media.ui_next')).width(18).height(18).accessibilityLevel('no')
    }.width('100%').constraintSize({ minHeight: 44 }).enabled(!this.working && !this.draggingCheck && !this.snapshotBlocked)
      .accessibilityText(`编辑${deadline ? '截止' : '计划'}重复规则`).onClick(() => { this.repeats(deadline) })
  }
  @Builder
  readOnlyContent() {
    Row({ space: 6 }) {
      this.stateIndicator()
      if (this.value().isHabit) {
        Image($r('app.media.ui_task_habit')).width(20).height(20).accessibilityText('习惯任务')
      } else if (this.value().isRepeating) {
        Image($r('app.media.ui_task_repeat')).width(20).height(20).accessibilityText('循环任务')
      }
      Row({ space: 4 }) {
        this.priorityBadge()
        TitleText({ text: this.value().heading, parts: this.value().headingParts, lineLimit: 1000,
          editable: false,
          cancelled: this.value().state?.category === TaskStateCategory.Cancel,
          activate: (): void => { this.toggle() } }).layoutWeight(1)
      }.layoutWeight(1).constraintSize({ minWidth: 0 }).alignItems(VerticalAlign.Top)
    }.width('100%').alignItems(VerticalAlign.Top)
    Column({ space: 8 }) {
      if (!this.documentMode && this.value().bodyHtml) {
        OrgContentView({ fragment: this.value().bodyHtml, embedded: true, embeddedPadding: 0,
          editable: false, contentBackground: UiColor.taskCard }).width('100%')
      }
      if (this.displayTags().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.displayTags(), (tag: string) => {
            Text(tag).fontSize(12).fontColor('#F5F5F5').wordBreak(WordBreak.BREAK_ALL)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10).backgroundColor(taskTagColor(tag))
              .margin({ right: 6, bottom: 6 })
          }, (tag: string) => tag)
        }.width('100%')
      }
      if (this.expandedPlanningText()) {
        Text(this.expandedPlanningText())
          .fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
      if (this.value().editContent.scheduledRepeat?.rule) {
        Text(`计划重复：${repeatSummary(this.value().editContent.scheduledRepeat?.rule)}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
      if (this.value().editContent.deadlineRepeat?.rule) {
        Text(`截止重复：${repeatSummary(this.value().editContent.deadlineRepeat?.rule)}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
      if (this.value().logs.length > 0) {
        Row() { this.moreButton() }.width('100%').justifyContent(FlexAlign.End)
      }
    }.width('100%').padding({ left: 27 })
  }

  build() {
    Column() {
      if (this.expanded) {
        Column() {
          Column({ space: 8 }) {
            if (this.readOnly) {
              this.readOnlyContent()
            } else {
              Column({ space: 12 }) { this.editorContent() }.width('100%')
              this.attributes()
            }
          }.width('100%')
          if (this.value().logs.length > 0) {
            TaskLogView({ logs: this.value().logs, expanded: this.logbookExpanded,
              contentBackground: this.value().state?.category === TaskStateCategory.Doing
                ? '#00000000' : UiColor.taskCard }).width('100%').padding({ left: 27 })
              .margin({ top: this.logbookExpanded ? 8 : 0 })
          }
        }.width('100%').padding(12)
          .backgroundColor(this.value().state?.category === TaskStateCategory.Doing ? Color.Transparent : UiColor.taskCard).borderRadius(12)
        if (taskSourceText(this.value(), true, this.regionPolicy())) {
          Text(taskSourceText(this.value(), true, this.regionPolicy())).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(11).fontColor(UiColor.secondary)
            .width('100%').textAlign(TextAlign.End).padding({ top: 6, right: 12, bottom: 4 })
            .constraintSize({ minHeight: this.regionArea().project !== null ? 48 : 0 })
            .onClick((): void => {
              if (this.regionArea().project !== null) this.openProject()
            })
        }
      } else if (this.documentMode) {
        Row({ space: 8 }) {
          this.stateIndicator()
          this.priorityBadge()
          TitleText({ text: this.value().heading, parts: this.value().headingParts, lineLimit: 1000,
            editable: false,
            weight: FontWeight.Medium, cancelled: this.value().state?.category === TaskStateCategory.Cancel,
            activate: (): void => { this.toggle() } }).layoutWeight(1)
        }.width('100%').constraintSize({ minHeight: 48 }).alignItems(VerticalAlign.Center)
        if (this.displayTags().length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.displayTags(), (tag: string) => {
              Text(tag).fontSize(12).fontColor('#F5F5F5').wordBreak(WordBreak.BREAK_ALL)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10)
                .backgroundColor(taskTagColor(tag)).margin({ right: 6, bottom: 6 })
            }, (tag: string) => tag)
          }.width('100%').padding({ left: 26 })
        }
        if (this.expandedPlanningText()) {
          Text(this.expandedPlanningText()).fontSize(12).fontColor(UiColor.secondary)
            .width('100%').padding({ left: 26, bottom: 8 })
        }
        this.documentChecklist()
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      } else {
        this.compactRow()
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      }
    }.width('100%').visibility(this.removed ? Visibility.None : Visibility.Visible)
      .backgroundColor(this.value().state?.category === TaskStateCategory.Doing ? UiColor.taskDoingTint : Color.Transparent).borderRadius(12)
      .alignItems(HorizontalAlign.Start).margin({ top: this.expanded ? 8 : 0, bottom: this.expanded ? 8 : 0 })
      .onAreaChange((oldArea: Area, area: Area) => {
        this.rowWidth = parseFloat(area.width.toString())
      })
      .onClick(() => {})
      .bindSheet($$this.moveOpen, this.movePanel, {
        height: '70%', detents: ['70%', '90%'], preferType: SheetType.BOTTOM,
        backgroundColor: '#363A38', showClose: true,
        onWillDismiss: (action): void => {
          if (!this.moveBusy) { action.dismiss(); this.closeMove() }
        },
        onDisappear: (): void => { this.closeMove() }
      })
      .priorityGesture(PanGesture({ direction: this.enableSwipeActions ? PanDirection.Right : PanDirection.Horizontal, distance: 48 }).onActionEnd((event: GestureEvent) => {
        this.horizontalSwipe(event.offsetX)
      }))
      .onGestureJudgeBegin(() => this.readOnly || this.rightSwipeAction === 'none' || this.checklistTouch || this.typing ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
  }
}
