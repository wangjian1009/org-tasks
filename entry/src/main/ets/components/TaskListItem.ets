import { CoreTask, CoreTaskChecklistItem, CoreTaskChecklistChange, CoreTaskModification, CoreBridgeError, coreErrorMessage } from '../services/NativeCoreService'
import { TaskInlineService, TaskInlineSession } from '../services/TaskInlineService'
import { TaskDateDialog } from './TaskDateDialog'
import { TaskTagsDialog } from './TaskTagsDialog'
import { inlineDateLabel, inlineDate } from '../ui/TaskInlinePresentation'
import { UiColor, UiSize } from '../ui/Theme'
import { taskDateIsToday, taskDateText, taskDeadlineColor, taskDeadlineText, taskDisplayDate,
  taskDurationDays, taskIndicators, taskRowLayout, taskTagColor,
  TaskRowLayout, taskTitleText } from '../ui/TaskListPresentation'
import { TitleText } from './TitleText'
import { TitleCounts } from './TitleCounts'
import { titleCounts, titleCountsWidth } from '../ui/TitleCountPresentation'
import { TaskInlineFocus } from '../ui/TaskInlineFocus'
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
  @Prop showDate: boolean = false
  @Prop showCategory: boolean = false
  @Prop enableSwipeActions: boolean = false
  open: () => void = () => {}
  swipe: (left: boolean) => void = () => {}
  @State expanded: boolean = false
  @State editTask: CoreTask | undefined = undefined
  @State heading: string = ''
  @State notes: string = ''
  @State typing: boolean = false
  @State working: boolean = false
  @State message: string = ''
  @State rowWidth: number = 366
  @State deadlineWidth: number = 0
  @State checkId: string = ''
  @State checkText: string = ''
  @State addingCheck: boolean = false
  @State newCheck: string = ''
  @StorageLink('taskInlineDateRequest') @Watch('dateRequested') dateRequest: string = ''
  @Prop referenceTime: number = Date.now()
  private ownerKey: string = ''
  private dateDialog: CustomDialogController | undefined = undefined
  private tagsDialog: CustomDialogController | undefined = undefined
  private pending: Promise<void> = Promise.resolve()
  private checkSaving: Promise<boolean> | undefined = undefined
  private continueCheck: boolean = false
  private checklistTouch: boolean = false
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
  aboutToAppear() { this.ownerKey = this.task.id }
  aboutToDisappear() {
    this.checkFocus.dispose()
    this.dateDialog?.close(); this.tagsDialog?.close()
    if (this.hostWindow) this.hostWindow.off('keyboardHeightChange', this.keyboardChanged)
    TaskInlineSession.release(this.ownerKey)
  }
  async prepare(): Promise<boolean> {
    if (!this.ownerKey) this.ownerKey = this.task.id
    if (!await TaskInlineSession.begin(this.ownerKey, async (collapse: boolean) => await this.finish(collapse))) return false
    if (!this.editTask) { this.editTask = this.task; this.heading = this.task.heading; this.notes = this.task.editContent.notes.trimEnd() }
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
    this.referenceTime = Date.now()
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = true })
  }
  async finish(collapse: boolean): Promise<boolean> {
    this.continueCheck = false
    this.checkFocus.cancel()
    this.headingController.stopEditing(); this.notesController.stopEditing()
    this.getUIContext().getFocusController().clearFocus()
    this.typing = false; AppStorage.setOrCreate('taskInlineTyping', false)
    if (!await this.saveText() || !await this.saveCheck(false)) return false
    await this.pending
    this.checkFocus.cancel()
    if (!this.newCheck.trim() && !this.checkId) this.addingCheck = false
    this.message = ''
    if (collapse) {
      this.expanded = false
      TaskInlineSession.release(this.ownerKey)
    }
    return true
  }
  inputFocus() {
    this.typing = true; AppStorage.setOrCreate('taskInlineTyping', true)
  }
  async persist(modifications: CoreTaskModification[]): Promise<boolean> {
    let success: boolean = false
    const operation = this.pending.then(async () => {
      this.working = true; this.message = ''
      try {
        this.editTask = await TaskInlineService.modify(this.getUIContext().getHostContext()!, this.value(), modifications)
        success = true
      } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
      finally { this.working = false }
    })
    this.pending = operation
    await operation
    return success
  }
  async saveText(): Promise<boolean> {
    await this.pending
    if (!this.heading.trim()) { this.message = '标题不能为空'; return false }
    const modifications: CoreTaskModification[] = []
    if (this.heading !== this.value().heading) modifications.push({ field: 'TITLE', value: this.heading })
    if (this.notes !== this.value().editContent.notes.trimEnd()) modifications.push({ field: 'NOTES', value: this.notes })
    return modifications.length === 0 ? true : await this.persist(modifications)
  }
  async saveCheck(next: boolean): Promise<boolean> {
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
    if (this.working) return
    const id = change.type === 'add' ? '' : change.id
    const index = this.value().editContent.checklist.findIndex(item => item.id === id)
    if (!await this.saveText() || !await this.saveCheck(false)) return
    const current = this.value().editContent.checklist[index]
    if (change.type === 'setChecked' && current) change = { type: 'setChecked', id: current.id, checked: change.checked }
    else if (change.type === 'remove' && current) change = { type: 'remove', id: current.id }
    await this.persist([{ field: 'CHECKLIST', value: change }])
  }
  async editCheck(item: CoreTaskChecklistItem) {
    const index = this.value().editContent.checklist.findIndex(current => current.id === item.id)
    if (!await this.saveText() || !await this.saveCheck(false)) return
    const current = this.value().editContent.checklist[index]
    if (!current) return
    this.checkId = current.id; this.checkText = current.text
    this.checkFocus.request(`inline_check_${current.id}`)
  }
  async addCheck() {
    if (!await this.saveText() || !await this.saveCheck(false)) return
    this.addingCheck = true
    this.checkFocus.request(`inline_new_check_${this.ownerKey}`)
  }
  async dates(deadline: boolean) {
    if (!await this.prepare() || !await this.finish(false)) return
    const wasExpanded = this.expanded
    this.dateDialog = new CustomDialogController({
      builder: TaskDateDialog({ closed: () => { if (!wasExpanded) TaskInlineSession.release(this.ownerKey) }, selected: deadline ? this.value().deadline : this.value().scheduled, deadline,
        choose: async (date: string): Promise<boolean> => {
          return await this.persist([{ field: deadline ? 'DEADLINE_DATE' : 'SCHEDULE_DATE', value: date || null }])
        } }),
      customStyle: true, autoCancel: true, alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => { if (this.working) return; action.dismiss(); if (!wasExpanded) TaskInlineSession.release(this.ownerKey) }
    })
    this.dateDialog.open()
  }
  reloadDraft() {
    if (this.working) return
    this.getUIContext().showAlertDialog({ title: '重新载入任务？', message: '将放弃卡片中未保存的输入，读取文件中的最新内容。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重新载入', action: async () => {
        this.working = true
        try {
          this.editTask = await TaskInlineService.reload(this.getUIContext().getHostContext()!, this.value())
          this.heading = this.value().heading; this.notes = this.value().editContent.notes.trimEnd()
          this.checkId = ''; this.checkText = ''; this.newCheck = ''; this.addingCheck = false; this.message = ''
        } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
        finally { this.working = false }
      } } })
  }
  async tags() {
    if (!await this.prepare() || !await this.finish(false)) return
    try {
      this.tagsDialog = new CustomDialogController({
        builder: TaskTagsDialog({ supportTags: this.value().supportTags, ownTags: this.value().ownTags, visibleTags: this.value().tags,
          inheritedTags: this.value().inheritedTags,
          change: async (tags: string[]): Promise<boolean> => await this.persist([{ field: 'TAGS', value: tags }]) }),
        customStyle: true, autoCancel: true, alignment: DialogAlignment.Center
      })
      this.tagsDialog.open()
    } catch (error) { this.message = coreErrorMessage(error as CoreBridgeError) }
  }

  duration(): number { return taskDurationDays(this.value(), new Date(this.referenceTime)) }

  leadingDate(): string { return taskDateText(taskDisplayDate(this.value()), true, new Date(this.referenceTime)) }

  leadingWidth(): number {
    return (this.showDate && taskDisplayDate(this.value()).length > 0 ? this.leadingDate().length * 7 + 18 : 0)
      + (this.value().isRepeating ? 28 : 0)
  }

  deadlineColor(): string { return taskDeadlineColor(this.value(), new Date(this.referenceTime)) }

  deadlineIcon(): Resource {
    return this.deadlineColor() === UiColor.deadline
      ? $r('app.media.ui_task_deadline') : $r('app.media.ui_task_deadline_neutral')
  }

  countBudget(): number {
    return Math.max(14, Math.min(140, this.rowWidth - this.deadlineWidth - this.leadingWidth() - 126))
  }

  layout(): TaskRowLayout {
    return taskRowLayout(this.rowWidth - 16 - this.leadingWidth(), this.value().tags.length, taskIndicators(this.value()).length,
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
    if (this.value().todoKind === 'done' && !this.value().isCancelled) {
      Image($r('app.media.ui_task_done')).width(18).height(18)
        .accessibilityText('已完成，只读')
    } else {
      Text(this.value().isCancelled ? '−' : '').width(18).height(18).fontSize(13)
        .textAlign(TextAlign.Center).fontColor(UiColor.disabled)
        .border({ width: 1.4, color: '#8B8986' }).borderRadius(4)
        .accessibilityText(this.value().isCancelled ? '已取消，只读' : '未完成，只读')
    }
  }

  @Builder
  stateIndicator() {
    if (this.value().todoKind === null) {
      Image($r('app.media.ui_note')).width(18).height(18)
        .accessibilityText('笔记，无任务状态')
    } else {
      this.completionState()
    }
  }

  @Builder
  compactTags() {
    Row({ space: 4 }) {
      Text(this.value().tags[0]).fontSize(11).fontColor('#F5F5F5').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(taskTagColor(this.value().tags[0])).borderRadius(10)
        .constraintSize({ maxWidth: this.layout().firstTagWidth }).flexShrink(0)
      if (this.layout().showMoreTags) {
        Text('…').fontSize(12).fontColor(UiColor.secondary).width(22).height(21).textAlign(TextAlign.Center)
          .border({ width: 1, color: '#686561' }).borderRadius(10)
      }
    }.constraintSize({ maxWidth: this.layout().tagWidth }).alignItems(VerticalAlign.Center).flexShrink(0)
      .accessibilityText(`标签：${this.value().tags.join('、')}`)
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

  @Builder
  compactTitle() {
    Row({ space: 6 }) {
      Column({ space: 2 }) {
        TitleText({ text: this.value().heading, parts: this.value().headingParts, lineLimit: 1, showCounts: false, cancelled: this.value().isCancelled })
          .width('100%').constraintSize({ minWidth: 0 })
        if (this.showCategory && this.value().category) {
          Text(this.value().category).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => { this.toggle() })
      if (titleCounts(this.value().headingParts).length > 0) {
        TitleCounts({ parts: this.value().headingParts, budget: this.countBudget() })
          .width(titleCountsWidth(this.value().headingParts, this.countBudget())).flexShrink(0)
          .onClick((): void => { this.toggle() })
      }
      if (this.value().tags.length > 0 && this.layout().tagWidth > 0) { this.compactTags() }
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
    if (this.showDate && taskDisplayDate(this.value())) {
      Text(this.leadingDate()).fontSize(11).fontColor(UiColor.text).backgroundColor('#5A5856').borderRadius(3)
        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).maxLines(1).flexShrink(0)
    }
    if (this.value().isRepeating) { Image($r('app.media.ui_task_repeat')).width(20).height(20).flexShrink(0) }
  }
  @Builder
  checklistRow(item: CoreTaskChecklistItem) {
    Row({ space: 4 }) {
      Button(item.checked ? '✓' : item.partial ? '−' : '○').width(28).height(44).padding(0)
        .fontSize(19).fontColor(UiColor.secondary).backgroundColor(Color.Transparent).enabled(!this.working)
        .accessibilityText(item.checked ? `恢复未完成：${item.text}` : `完成：${item.text}`)
        .onClick(() => { this.changeCheck({ type: 'setChecked', id: item.id, checked: !item.checked }) })
      if (this.checkId === item.id) {
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
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(item.depth, 6) * 12 })
  }
  @Builder
  deleteCheck(item: CoreTaskChecklistItem) {
    Button('×').width(44).height(44).fontColor(Color.White).backgroundColor(UiColor.deadline).fontSize(20)
      .enabled(!this.working).accessibilityText(`删除清单条目：${item.text}`)
      .onClick(() => { this.changeCheck({ type: 'remove', id: item.id }) })
  }
  @Builder
  editorContent() {
    Row({ space: 9 }) {
      this.stateIndicator()
      TextArea({ text: this.heading, controller: this.headingController, placeholder: '标题' }).id(`inline_title_${this.ownerKey}`)
        .layoutWeight(1).height('auto').minLines(1).maxLines(1000).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(UiColor.text).backgroundColor(Color.Transparent).padding(0).borderRadius(0)
        .enterKeyType(EnterKeyType.Done).onSubmit(() => { TaskInlineSession.end(false) })
        .onChange((value: string) => { this.heading = value }).onFocus(() => { this.inputFocus() })
        .onBlur(() => { this.saveText() })
    }.width('100%').alignItems(VerticalAlign.Top)
    Column({ space: 12 }) {
      TextArea({ text: this.notes, controller: this.notesController, placeholder: '备注' }).id(`inline_notes_${this.ownerKey}`)
        .width('100%').height('auto').minLines(1).maxLines(1000).fontSize(14).fontColor(UiColor.text)
        .placeholderColor(UiColor.disabled).backgroundColor(Color.Transparent).padding(0).borderRadius(0)
        .onChange((value: string) => { this.notes = value }).onFocus(() => { this.inputFocus() })
        .onBlur(() => { this.saveText() })
      if (this.value().editContent.checklist.length > 0 || this.addingCheck) {
        List() {
          ForEach(this.value().editContent.checklist, (item: CoreTaskChecklistItem) => {
            ListItem() { this.checklistRow(item) }
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) this.checklistTouch = true
                if (event.type === TouchType.Up || event.type === TouchType.Cancel) setTimeout(() => { this.checklistTouch = false }, 100)
              })
              .swipeAction({ end: this.deleteCheck(item), edgeEffect: SwipeEdgeEffect.None })
          }, (item: CoreTaskChecklistItem) => `${item.id}:${item.text}:${item.checked}`)
          if (this.addingCheck) {
            ListItem() {
              Row({ space: 4 }) {
                Text('○').width(28).fontSize(19).fontColor(UiColor.secondary)
                TextInput({ text: this.newCheck, placeholder: '清单项' }).id(`inline_new_check_${this.ownerKey}`)
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
              .onClick(() => { this.addCheck() })
          }
        }.width('100%').height((this.value().editContent.checklist.length + (this.addingCheck ? 1 : 0) + 1) * 44)
          .scrollBar(BarState.Off).enableScrollInteraction(false)
      }
      if (this.value().tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.value().tags, (tag: string) => {
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
      .width(36).height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working)
      .accessibilityText(label).onClick(activate)
  }
  @Builder
  attributes() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          Image(this.value().scheduled === inlineDate(new Date()) ? $r('app.media.nav_today') : $r('app.media.ui_task_calendar')).width(18).height(18)
          if (this.value().scheduled) { Text(inlineDateLabel(this.value().scheduled)).fontSize(12).fontColor(UiColor.text).maxLines(2) }
        }
      }.id('inline_schedule_button').height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working).constraintSize({ minWidth: 36, maxWidth: '46%' })
        .accessibilityText('设置或修改计划日期').onClick(() => { this.dates(false) })
      Blank().layoutWeight(1)
      this.attributeButton($r('app.media.ui_tags'), '设置标签', () => { this.tags() })
      this.attributeButton($r('app.media.ui_task_list'), '编辑检查清单', () => { this.addCheck() })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 4 }) {
          Image(this.deadlineIcon()).width(16).height(16)
          if (this.value().deadline) { Text(inlineDateLabel(this.value().deadline)).fontSize(12).fontColor(this.deadlineColor()).maxLines(2) }
        }
      }.id('inline_deadline_button').height(44).padding(0).backgroundColor(Color.Transparent).enabled(!this.working).constraintSize({ minWidth: 36, maxWidth: '34%' })
        .accessibilityText('设置或修改截止日期').onClick(() => { this.dates(true) })
    }.width('100%').padding({ left: 27 })
  }
  build() {
    Column() {
      if (this.expanded) {
        Column({ space: 8 }) {
          Column({ space: 12 }) { this.editorContent() }.width('100%')
          this.attributes()
        }.width('100%').padding(12).backgroundColor(UiColor.taskCard).borderRadius(12)
        Text(this.value().category || this.value().fileName).fontSize(11).fontColor(UiColor.secondary)
          .width('100%').textAlign(TextAlign.End).padding({ top: 6, right: 12, bottom: 4 })
      } else {
        Row({ space: 8 }) {
          this.stateIndicator()
          this.compactLeadingInfo()
          this.compactTitle()
          if (this.value().deadline) { this.compactDeadline() }
        }.width('100%').padding({ left: 8, right: 8 }).constraintSize({ minHeight: UiSize.taskRow })
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: this.expanded ? 8 : 0, bottom: this.expanded ? 8 : 0 })
      .onAreaChange((oldArea: Area, area: Area) => {
        this.rowWidth = parseFloat(area.width.toString())
      })
      .onClick(() => {})
      .priorityGesture(PanGesture({ direction: PanDirection.Horizontal, distance: 48 }).onActionEnd((event: GestureEvent) => {
        if (event.offsetX > 48 && !this.typing && !this.checklistTouch) this.dates(false)
        else if (event.offsetX < -48 && this.enableSwipeActions && !this.typing && !this.checklistTouch) this.swipe(true)
      }))
      .onGestureJudgeBegin(() => this.checklistTouch || this.typing || this.enableSwipeActions ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
  }
}
