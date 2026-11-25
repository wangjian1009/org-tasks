import { localizedDate, localizedText } from '../../ui/LocalizedText'
import { UiColor } from '../../ui/Theme'
import { CoreTaskModification, CoreTaskPlanningEdit, CoreTaskPlanningInfo } from '../../services/NativeCoreService'
import { inlineDate, TaskCalendarDay, taskCalendarDays } from '../../ui/TaskInlinePresentation'

// 仅编辑日期草稿并返回字段修改；持久化和提交频率由调用点决定。
@CustomDialog
export struct TaskDateDialog {
  controller: CustomDialogController
  title: string = ''
  allowTimeRange: boolean = true
  selected: string = ''
  planning: CoreTaskPlanningInfo | null = null
  deadline: boolean = false
  allowClear: boolean = true
  allowTime: boolean = true
  batch: boolean = false
  closeOnConfirm: boolean = true
  changed: (modification: CoreTaskModification) => void = () => {}
  confirmed: (modification: CoreTaskModification) => void = () => {}
  closed: () => void = () => {}
  @State year: number = new Date().getFullYear()
  @State month: number = new Date().getMonth()
  @State date: string = ''
  @State start: string = ''
  @State end: string = ''
  @State timeChanged: boolean = false
  @State editingTime: boolean = false
  @State timeField: string = 'start'
  @State draftStart: string = ''
  @State draftEnd: string = ''
  @State pickerDate: Date = new Date()
  @State busy: boolean = false
  @State message: string = ''

  aboutToAppear() {
    this.date = this.planning?.date || this.selected
    this.start = this.planning?.time?.start || ''
    this.end = this.allowTimeRange === false ? '' : this.planning?.time?.end || ''
    const date = this.date ? new Date(`${this.date}T12:00:00`) : new Date()
    this.year = date.getFullYear(); this.month = date.getMonth()
  }
  color(): string { return this.deadline ? UiColor.error : UiColor.primary }
  close() { if (!this.busy) { this.controller.close(); this.closed() } }
  move(delta: number) {
    const next = new Date(this.year, this.month + delta, 1, 12)
    if (next.getFullYear() < 1 || next.getFullYear() > 9999) return
    this.year = next.getFullYear(); this.month = next.getMonth()
  }
  pick(value: string, notify: boolean = true) {
    this.date = value; this.message = ''
    if (value) {
      const date = new Date(`${value}T12:00:00`)
      this.year = date.getFullYear(); this.month = date.getMonth()
    }
    if (notify) this.changed(this.modification())
  }
  editTime() {
    this.draftStart = this.start || `${new Date().getHours().toString().padStart(2, '0')}:${new Date().getMinutes().toString().padStart(2, '0')}`
    this.draftEnd = this.end
    this.message = ''; this.editingTime = true; this.selectTime('start')
  }
  selectTime(field: string) {
    this.timeField = field
    const value = field === 'end' ? this.draftEnd : this.draftStart
    this.pickerDate = new Date(`2000-01-01T${value}:00`)
  }
  timeSelected(value: TimePickerResult) {
    const time = `${value.hour.toString().padStart(2, '0')}:${value.minute.toString().padStart(2, '0')}`
    if (this.timeField === 'end') this.draftEnd = time
    else this.draftStart = time
  }
  acceptTime() {
    if (this.draftEnd && this.draftEnd <= this.draftStart) { this.message = localizedText($r('app.string.text_the_end_must_be_later_than_the')); return }
    this.start = this.draftStart; this.end = this.draftEnd; this.timeChanged = true
    if (!this.date) this.pick(inlineDate(new Date()), false)
    this.editingTime = false; this.message = ''; this.changed(this.modification())
  }
  clearTime() {
    this.start = ''; this.end = ''; this.timeChanged = true
    this.editingTime = false; this.message = ''; this.changed(this.modification())
  }
  clearDate() {
    this.date = ''; this.start = ''; this.end = ''; this.timeChanged = true; this.message = ''
    this.changed(this.modification())
  }
  modification(): CoreTaskModification {
    const value: CoreTaskPlanningEdit | null = this.date ? { date: this.date } : null
    if (value && this.timeChanged) value.time = this.start ? { start: this.start, end: this.end || null } : null
    return { field: this.deadline ? 'DEADLINE' : 'SCHEDULE', value }
  }
  accept() {
    if (this.busy) return
    this.busy = true
    try { this.confirmed(this.modification()) }
    finally { this.busy = false }
    if (this.closeOnConfirm) this.close()
  }
  @Builder
  quick(label: string, days: number) {
    Row({ space: 8 }) {
      Image(this.deadline ? $r('app.media.ui_task_deadline') : days === 0 ? $r('app.media.nav_today') : $r('app.media.ui_task_calendar')).width(18).height(18)
      Text(label).fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      Text(inlineDate(new Date(new Date().getFullYear(), new Date().getMonth(), new Date().getDate() + days, 12)).slice(5))
        .fontSize(12).fontColor(UiColor.secondary)
    }.id(days === 0 ? 'inline_date_today' : 'inline_date_tomorrow').width('100%').height(44).enabled(!this.busy).onClick(() => {
      this.pick(inlineDate(new Date(new Date().getFullYear(), new Date().getMonth(), new Date().getDate() + days, 12)))
    })
  }
  @Builder
  day(day: TaskCalendarDay) {
    // 同月选日复用 ForEach 节点，选中样式必须直接观察当前日期草稿。
    Row() {
      Text(day.label).fontSize(13).textAlign(TextAlign.Center).width(30).height(30)
        .fontColor(day.date === this.date ? UiColor.onPrimary : day.today ? this.color() : day.inMonth ? UiColor.text : UiColor.disabled)
        .backgroundColor(day.date === this.date ? this.color() : Color.Transparent).borderRadius(15)
        .border({ width: day.today && day.date !== this.date ? 1 : 0, color: this.color() })
    }.id(`inline_day_${day.date}`).width('100%').height(40).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      .accessibilityText(`${day.date}${day.today ? localizedText($r('app.string.text_today_2')) : ''}${day.date === this.date ? localizedText($r('app.string.text_selected_2')) : ''}`)
      .enabled(!this.busy).onClick(() => { this.pick(day.date) })
  }
  @Builder
  timePanel() {
    Row() {
      Button($r('app.string.text_cancel')).fontColor(this.color()).backgroundColor(Color.Transparent).height(44)
        .onClick(() => { this.editingTime = false; this.message = '' })
      Text($r('app.string.text_time')).fontSize(17).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
      Button($r('app.string.text_ok')).id('inline_time_accept').fontColor(this.color()).backgroundColor(Color.Transparent).height(44)
        .onClick(() => { this.acceptTime() })
    }.width('100%')
    Row() {
      Text($r('app.string.text_start_time')).fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      Text(this.draftStart).fontSize(16).fontColor(this.timeField === 'start' ? this.color() : UiColor.text)
    }.id('inline_time_start').width('100%').height(48).onClick(() => { this.selectTime('start') })
    if (this.allowTimeRange !== false && this.draftEnd) {
      Row() {
        Row() {
          Text($r('app.string.text_end_time')).fontSize(15).fontColor(UiColor.text).layoutWeight(1)
          Text(this.draftEnd).fontSize(16).fontColor(this.timeField === 'end' ? this.color() : UiColor.text)
        }.layoutWeight(1).height(48).onClick(() => { this.selectTime('end') })
        Button($r('app.string.text_remove')).height(44).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .onClick(() => { this.draftEnd = ''; this.selectTime('start') })
      }.id('inline_time_end').width('100%').height(48)
    } else if (this.allowTimeRange !== false) {
      Button($r('app.string.text_add_end_time')).id('inline_time_add_end').width('100%').height(44).fontColor(this.color()).backgroundColor(Color.Transparent)
        .onClick(() => {
          const parts = this.draftStart.split(':')
          const minute = Math.min(1439, Number(parts[0]) * 60 + Number(parts[1]) + 60)
          this.draftEnd = `${Math.floor(minute / 60).toString().padStart(2, '0')}:${(minute % 60).toString().padStart(2, '0')}`
          this.selectTime('end')
        })
    }
    TimePicker({ selected: this.pickerDate }).id('inline_time_picker').useMilitaryTime(true).height(200).width('100%')
      .textStyle({ color: UiColor.secondary, font: { size: 18 } }).selectedTextStyle({ color: UiColor.text, font: { size: 22 } })
      .onChange((value: TimePickerResult) => { this.timeSelected(value) })
    Button($r('app.string.text_clear_time')).id('inline_time_clear').width('100%').height(44).fontColor(UiColor.error).backgroundColor('#443337')
      .onClick(() => { this.clearTime() })
  }
  @Builder
  datePanel() {
    Row() {
      Text(this.title || (this.deadline ? localizedText($r('app.string.text_deadline')) : localizedText($r('app.string.text_scheduled_date')))).fontSize(17).fontColor(UiColor.text).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_close')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.text_cancel_date_time_changes'))
        .enabled(!this.busy).onClick(() => { this.close() })
    }.width('100%')
    this.quick(localizedText($r('app.string.text_today')), 0)
    this.quick(localizedText($r('app.string.text_tomorrow')), 1)
    Row() {
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_back')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.text_last_month')).enabled(!this.busy).onClick(() => { this.move(-1) })
      Text(localizedDate(new Date(this.year, this.month, 1), { month: 'long', year: 'numeric' })).fontSize(14).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_next')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.text_next_month')).enabled(!this.busy).onClick(() => { this.move(1) })
    }.width('100%')
    Row() {
      ForEach([localizedText($r('app.string.text_mon')), localizedText($r('app.string.text_tue')), localizedText($r('app.string.text_wed')), localizedText($r('app.string.text_thu')), localizedText($r('app.string.text_fri')), localizedText($r('app.string.text_sat')), localizedText($r('app.string.text_sun'))], (label: string) => {
        Text(label).fontSize(11).fontColor(UiColor.secondary).textAlign(TextAlign.Center).layoutWeight(1)
      })
    }.width('100%').height(20)
    Grid() {
      ForEach(taskCalendarDays(this.year, this.month, this.date), (day: TaskCalendarDay) => {
        GridItem() { this.day(day) }
      }, (day: TaskCalendarDay) => day.key)
    }.width('100%').height(240).columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr').rowsGap(0).columnsGap(2)
      .enableScrollInteraction(false)
    if (this.allowTime) {
      Row() {
        Text(this.start ? localizedText($r('app.string.text_time')) : localizedText($r('app.string.text_add_time'))).fontSize(15).fontColor(this.color()).layoutWeight(1)
        if (this.start) { Text(`${this.start}${this.end ? `–${this.end}` : ''}`).fontSize(15).fontColor(UiColor.text) }
        Image($r('app.media.ui_next')).width(18).height(18)
      }.id('inline_date_time').width('100%').height(44).enabled(!this.busy).onClick(() => { this.editTime() })
      if (this.batch && !this.timeChanged) {
        Text($r('app.string.text_only_when_the_date_is_changed_each')).fontSize(12).fontColor(UiColor.secondary).width('100%')
      } else if (this.timeChanged && !this.start) {
        Text($r('app.string.text_modified_date_only')).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
    }
    if (this.date) { Text(localizedText($r('app.string.text_selected_3'), String(this.date))).fontSize(12).fontColor(UiColor.secondary).width('100%') }
    if (this.allowClear && (this.selected || this.date)) {
      Button($r('app.string.text_clear_date')).id('inline_date_clear').width('100%').height(44).backgroundColor('#443337').fontColor(UiColor.error)
        .enabled(!this.busy).onClick(() => { this.clearDate() })
    }
    Button($r('app.string.text_done')).id('inline_date_save').width('100%').height(44).backgroundColor(this.color()).fontColor(UiColor.onPrimary)
      .enabled(!this.busy && (!!this.date || !!this.selected)).onClick(() => { this.accept() })
  }
  build() {
    Scroll() {
      Column({ space: 4 }) {
        if (this.editingTime) { this.timePanel() } else { this.datePanel() }
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      }.width('100%').padding(12)
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 360, maxHeight: '90%' }).scrollBar(BarState.Auto)
      .backgroundColor(UiColor.dialog).borderRadius(20).clip(true)
  }
}
