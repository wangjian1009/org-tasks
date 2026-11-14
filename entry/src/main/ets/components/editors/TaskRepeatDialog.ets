import { CoreTask, CoreTaskRepeatMode, CoreTaskRepeatUnit, CoreTaskRepeatInfo, CoreTaskModification, CoreTaskPlanningEdit } from '../../services/NativeCoreService'
import { repeatUnits, repeatUnitLabels, repeatSummary, repeatModifications } from '../../ui/TaskRepeatPresentation'
import { inlineDate, inlineDateLabel } from '../../ui/TaskInlinePresentation'
import { TaskDateDialog } from './TaskDateDialog'
import { UiColor } from '../../ui/Theme'

// 参考 Things 3 iPhone：取消／保存、分段模式、分组字段和停止重复。
@CustomDialog
export struct TaskRepeatDialog {
  controller: CustomDialogController
  @Prop task: CoreTask
  initialDeadline: boolean = false
  closed: () => void = () => {}
  save: (changes: CoreTaskModification[]) => Promise<boolean> = async () => false
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
      choose: async (value: CoreTaskPlanningEdit | null): Promise<boolean> => { if (value) this.date = value.date; return true } }),
      customStyle: true, alignment: DialogAlignment.Center, autoCancel: true })
    this.dateDialog.open()
  }
  async commit(stop: boolean = false) {
    if (this.busy) return
    const interval = Number(this.interval)
    if (!stop && (!/^\d+$/.test(this.interval) || !Number.isSafeInteger(interval) || interval < 1 || interval > 4294967295)) {
      this.message = '请输入大于零的有效重复间隔'; return
    }
    if (!stop && this.unit === 'hour' && !this.info()?.hasTime) { this.message = '按小时重复需要任务已有具体时刻'; return }
    this.busy = true; this.message = ''
    try {
      const changes = repeatModifications(this.deadline, this.info()?.date || '', this.date,
        stop ? null : { mode: this.mode, interval, unit: this.unit })
      if (await this.save(changes)) { this.controller.close(); this.closed() }
      else this.message = '未能保存，请检查任务上的错误提示'
    } finally { this.busy = false }
  }
  build() {
    Column({ space: 16 }) {
      Row() {
        Button('取消').fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent).padding(0).height(44)
          .enabled(!this.busy).onClick(() => { this.close() })
        Text('重复').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
        Button('保存').id('repeat_save').fontSize(15).fontColor(UiColor.primary).backgroundColor(Color.Transparent).padding(0).height(44)
          .enabled(!this.busy).onClick(() => { this.commit() })
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 4 }) {
            Button('计划日期').type(ButtonType.Normal).layoutWeight(1).height(38).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(!this.deadline ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy).onClick(() => { this.load(false) })
            Button('截止日期').type(ButtonType.Normal).layoutWeight(1).height(38).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.deadline ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy).onClick(() => { this.load(true) })
          }.width('100%').padding(3).backgroundColor(UiColor.field).borderRadius(10)
          Row({ space: 4 }) {
            Button('定期').type(ButtonType.Normal).layoutWeight(1).height(38).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.mode !== 'afterCompletion' ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy)
              .onClick(() => { this.mode = this.info()?.rule?.mode === 'catchUp' ? 'catchUp' : 'cumulative' })
            Button('完成后').type(ButtonType.Normal).layoutWeight(1).height(38).fontSize(14).fontColor(UiColor.text)
              .backgroundColor(this.mode === 'afterCompletion' ? '#555655' : Color.Transparent).borderRadius(8).enabled(!this.busy)
              .onClick(() => { this.mode = 'afterCompletion' })
          }.width('100%').padding(3).backgroundColor(UiColor.field).borderRadius(10)
          Text(this.mode === 'afterCompletion' ? '从实际完成日期起，间隔一段时间后再次安排。' : '以任务日期为基准，按固定间隔重复。')
            .fontSize(13).fontColor(UiColor.secondary).width('100%')
          Row({ space: 8 }) {
            Text(this.mode === 'afterCompletion' ? '完成后' : '每隔').fontSize(15).fontColor(UiColor.text)
            TextInput({ text: this.interval }).id('repeat_interval').layoutWeight(1).height(44).type(InputType.Number)
              .fontSize(16).fontColor(UiColor.text).backgroundColor(UiColor.field).enabled(!this.busy)
              .accessibilityText('重复间隔').onChange((value: string) => { this.interval = value })
            Select(repeatUnitLabels.map((value: string): SelectOption => { return { value } }))
              .selected(repeatUnits.indexOf(this.unit)).value(repeatUnitLabels[repeatUnits.indexOf(this.unit)])
              .fontColor(UiColor.primary).backgroundColor(UiColor.field).enabled(!this.busy)
              .onSelect((index: number) => { this.unit = repeatUnits[index] })
          }.width('100%')
          Row() {
            Text('下次日期').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
            Text(inlineDateLabel(this.date)).fontSize(14).fontColor(UiColor.primary).constraintSize({ maxWidth: '64%' })
            Image($r('app.media.ui_next')).width(20).height(20).margin({ left: 8 }).accessibilityLevel('no')
          }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12 })
            .backgroundColor(UiColor.field).borderRadius(10).enabled(!this.busy).onClick(() => { this.chooseDate() })
          if (this.mode !== 'afterCompletion') {
            Row() {
              Text('错过日期时').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
              Text(this.mode === 'catchUp' ? '跳到未来' : '顺延一次').fontSize(14).fontColor(UiColor.primary)
              Image($r('app.media.ui_next')).width(20).height(20).margin({ left: 8 }).accessibilityLevel('no')
            }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12 })
              .backgroundColor(UiColor.field).borderRadius(10).enabled(!this.busy)
              .onClick(() => { this.mode = this.mode === 'catchUp' ? 'cumulative' : 'catchUp' })
            Text(this.mode === 'catchUp' ? '完成后推进到今天之后的下一个日期。' : '完成后只向前推进一个间隔，可能仍是过期日期。')
              .fontSize(12).fontColor(UiColor.secondary).width('100%')
          }
          if (this.info()?.rule) {
            Text(`当前：${repeatSummary(this.info()?.rule)}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
            Button('停止重复').id('repeat_stop').width('100%').height(44).fontColor(UiColor.error).backgroundColor('#443337')
              .enabled(!this.busy).onClick(() => { this.commit(true) })
          }
          if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: '65%' }).scrollBar(BarState.Auto)
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 390 })
      .padding(16).backgroundColor(UiColor.dialog).borderRadius(20)
  }
}
