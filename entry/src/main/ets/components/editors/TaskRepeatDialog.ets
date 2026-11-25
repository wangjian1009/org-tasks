import { localizedText } from '../../ui/LocalizedText'
import { CoreTask, CoreTaskRepeatMode, CoreTaskRepeatUnit, CoreTaskRepeatInfo, CoreTaskModification, CoreTaskPlanningEdit } from '../../services/NativeCoreService'
import { repeatUnits, repeatUnitLabels, repeatSummary, repeatModifications } from '../../ui/TaskRepeatPresentation'
import { inlineDate, inlineDateLabel } from '../../ui/TaskInlinePresentation'
import { TaskDateDialog } from './TaskDateDialog'
import { UiColor, UiSize } from '../../ui/Theme'

// 参考 Things 3 iPhone：取消／保存、分段模式、分组字段和停止重复。
@CustomDialog
export struct TaskRepeatDialog {
  controller: CustomDialogController
  @Prop task: CoreTask
  initialDeadline: boolean = false
  closed: () => void = () => {}
  closeOnConfirm: boolean = true
  confirmed: (changes: CoreTaskModification[]) => void = () => {}
  @State deadline: boolean = false
  @State mode: CoreTaskRepeatMode = 'cumulative'
  @State interval: string = '1'
  @State unit: CoreTaskRepeatUnit = 'week'
  @State date: string = ''
  @State busy: boolean = false
  @State message: string = ''
  private dateDialog: CustomDialogController | undefined = undefined

  aboutToAppear() { this.load(this.initialDeadline) }
  aboutToDisappear() { this.dateDialog?.close() }
  info(): CoreTaskRepeatInfo | null { return (this.deadline ? this.task.editContent.deadlineRepeat : this.task.editContent.scheduledRepeat) ?? null }
  load(deadline: boolean) {
    this.deadline = deadline
    const info = this.info()
    this.mode = info?.rule?.mode ?? 'cumulative'
    this.interval = `${info?.rule?.interval ?? 1}`
    this.unit = info?.rule?.unit ?? 'week'
    this.date = info?.date || inlineDate(new Date())
    this.message = ''
  }
  close() { if (!this.busy) { this.controller.close(); this.closed() } }
  chooseDate() {
    this.dateDialog = new CustomDialogController({ builder: TaskDateDialog({ selected: this.date, deadline: this.deadline, allowClear: false, allowTime: false,
      confirmed: (modification: CoreTaskModification): void => { const value = modification.value as CoreTaskPlanningEdit | null; if (value) this.date = value.date } }),
      customStyle: true, alignment: DialogAlignment.Center, autoCancel: true })
    this.dateDialog.open()
  }
  accept(stop: boolean = false) {
    if (this.busy) return
    const interval = Number(this.interval)
    if (!stop && (!/^\d+$/.test(this.interval) || !Number.isSafeInteger(interval) || interval < 1 || interval > 4294967295)) {
      this.message = localizedText($r('app.string.text_please_enter_a_valid_repeat_interval_greater')); return
    }
    if (!stop && this.unit === 'hour' && !this.info()?.hasTime) { this.message = localizedText($r('app.string.text_we_ve_got_a_specific_moment_to')); return }
    this.busy = true; this.message = ''
    try {
      const changes = repeatModifications(this.deadline, this.info()?.date || '', this.date,
        stop ? null : { mode: this.mode, interval, unit: this.unit })
      this.confirmed(changes)
      if (this.closeOnConfirm) { this.controller.close(); this.closed() }
    } finally { this.busy = false }
  }
  build() {
    Column({ space: 16 }) {
      Row() {
        Button($r('app.string.text_cancel')).fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent).padding(0).height(44)
          .enabled(!this.busy).onClick(() => { this.close() })
        Text($r('app.string.text_repeat')).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
        Button($r('app.string.text_save')).id('repeat_save').fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent).padding(0).height(44)
          .enabled(!this.busy).onClick(() => { this.accept() })
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 4 }) {
            Button($r('app.string.text_scheduled_date')).type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(!this.deadline ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy).onClick(() => { this.load(false) })
            Button($r('app.string.text_deadline')).type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.deadline ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy).onClick(() => { this.load(true) })
          }.width('100%').padding(3).backgroundColor(UiColor.field).borderRadius(10)
          Row({ space: 4 }) {
            Button($r('app.string.text_periodic')).type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.mode !== 'afterCompletion' ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy)
              .onClick(() => { this.mode = this.info()?.rule?.mode === 'catchUp' ? 'catchUp' : 'cumulative' })
            Button($r('app.string.text_after_completion')).type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: UiSize.taskRow }).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.mode === 'afterCompletion' ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy)
              .onClick(() => { this.mode = 'afterCompletion' })
          }.width('100%').padding(3).backgroundColor(UiColor.field).borderRadius(10)
          Text(this.mode === 'afterCompletion' ? localizedText($r('app.string.text_from_the_actual_date_of_completion_arrangements')) : localizedText($r('app.string.text_the_date_of_the_mandate_is_used')))
            .fontSize(13).fontColor(UiColor.secondary).width('100%')
          Row({ space: 8 }) {
            Text(this.mode === 'afterCompletion' ? localizedText($r('app.string.text_after_completion')) : localizedText($r('app.string.text_every'))).fontSize(15).fontColor(UiColor.text)
            TextInput({ text: this.interval }).id('repeat_interval').layoutWeight(1).height(44).type(InputType.Number)
              .fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field).enabled(!this.busy)
              .accessibilityText($r('app.string.text_repeat_interval')).onChange((value: string) => { this.interval = value })
            Select(repeatUnitLabels.map((value: Resource): SelectOption => { return { value } }))
              .selected(repeatUnits.indexOf(this.unit)).value(repeatUnitLabels[repeatUnits.indexOf(this.unit)])
              .fontColor(UiColor.primary).backgroundColor(UiColor.field).enabled(!this.busy)
              .onSelect((index: number) => { this.unit = repeatUnits[index] })
          }.width('100%')
          Row() {
            Text($r('app.string.text_next_date')).fontSize(15).fontColor(UiColor.text).layoutWeight(1)
            Text(inlineDateLabel(this.date)).fontSize(14).fontColor(UiColor.primary).constraintSize({ maxWidth: '64%' })
            Image($r('app.media.ui_next')).width(20).height(20).margin({ left: 8 }).accessibilityLevel('no')
          }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12 })
            .backgroundColor(UiColor.field).borderRadius(10).enabled(!this.busy).onClick(() => { this.chooseDate() })
          if (this.mode !== 'afterCompletion') {
            Row() {
              Text($r('app.string.text_missing_date')).fontSize(15).fontColor(UiColor.text).layoutWeight(1)
              Text(this.mode === 'catchUp' ? localizedText($r('app.string.text_jump_to_the_future')) : localizedText($r('app.string.text_one_extension'))).fontSize(14).fontColor(UiColor.primary)
              Image($r('app.media.ui_next')).width(20).height(20).margin({ left: 8 }).accessibilityLevel('no')
            }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12 })
              .backgroundColor(UiColor.field).borderRadius(10).enabled(!this.busy)
              .onClick(() => { this.mode = this.mode === 'catchUp' ? 'cumulative' : 'catchUp' })
            Text(this.mode === 'catchUp' ? localizedText($r('app.string.text_after_completion_move_forward_to_the_next')) : localizedText($r('app.string.text_only_one_interval_will_be_moved_forward')))
              .fontSize(12).fontColor(UiColor.secondary).width('100%')
          }
          if (this.info()?.rule) {
            Text(localizedText($r('app.string.text_current_2'), String(repeatSummary(this.info()?.rule)))).fontSize(12).fontColor(UiColor.secondary).width('100%')
            Button($r('app.string.text_stop_repeating')).id('repeat_stop').width('100%').height(44).fontColor(UiColor.error).backgroundColor('#443337')
              .enabled(!this.busy).onClick(() => { this.accept(true) })
          }
          if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: '65%' }).scrollBar(BarState.Auto)
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 390 })
      .padding(16).backgroundColor(UiColor.dialog).borderRadius(20)
  }
}
