import { UiColor } from '../ui/Theme'
import { CoreTaskPlanningEdit, CoreTaskPlanningInfo } from '../services/NativeCoreService'
import { inlineDate, TaskCalendarDay, taskCalendarDays } from '../ui/TaskInlinePresentation'

// 日期与时间均为草稿；只有主面板的“完成”向 Core 提交。
@CustomDialog
export struct TaskDateDialog {
  controller: CustomDialogController
  selected: string = ''
  planning: CoreTaskPlanningInfo | null = null
  deadline: boolean = false
  allowClear: boolean = true
  allowTime: boolean = true
  batch: boolean = false
  failureMessage: () => string = () => '未能修改，请检查任务卡片上的错误提示'
  closed: () => void = () => {}
  choose: (value: CoreTaskPlanningEdit | null) => Promise<boolean> = async () => false
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
    this.end = this.planning?.time?.end || ''
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
  pick(value: string) {
    this.date = value; this.message = ''
    if (value) {
      const date = new Date(`${value}T12:00:00`)
      this.year = date.getFullYear(); this.month = date.getMonth()
    }
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
    if (this.draftEnd && this.draftEnd <= this.draftStart) { this.message = '结束时间必须晚于开始时间'; return }
    this.start = this.draftStart; this.end = this.draftEnd; this.timeChanged = true
    if (!this.date) this.pick(inlineDate(new Date()))
    this.editingTime = false; this.message = ''
  }
  clearTime() {
    this.start = ''; this.end = ''; this.timeChanged = true
    this.editingTime = false; this.message = ''
  }
  async commit() {
    if (this.busy) return
    this.busy = true; this.message = ''
    const value: CoreTaskPlanningEdit | null = this.date ? { date: this.date } : null
    if (value && this.timeChanged) value.time = this.start ? { start: this.start, end: this.end || null } : null
    try {
      if (await this.choose(value)) { this.controller.close(); this.closed() }
      else this.message = this.failureMessage()
    } finally { this.busy = false }
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
    Row() {
      Text(day.label).fontSize(13).textAlign(TextAlign.Center).width(30).height(30)
        .fontColor(day.selected ? UiColor.onPrimary : day.today ? this.color() : day.inMonth ? UiColor.text : UiColor.disabled)
        .backgroundColor(day.selected ? this.color() : Color.Transparent).borderRadius(15)
        .border({ width: day.today && !day.selected ? 1 : 0, color: this.color() })
    }.id(`inline_day_${day.date}`).width('100%').height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      .accessibilityText(`${day.date}${day.today ? '，今天' : ''}${day.selected ? '，已选中' : ''}`)
      .enabled(!this.busy).onClick(() => { this.pick(day.date) })
  }
  @Builder
  timePanel() {
    Row() {
      Button('取消').fontColor(this.color()).backgroundColor(Color.Transparent).height(44)
        .onClick(() => { this.editingTime = false; this.message = '' })
      Text('时间').fontSize(17).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
      Button('确定').id('inline_time_accept').fontColor(this.color()).backgroundColor(Color.Transparent).height(44)
        .onClick(() => { this.acceptTime() })
    }.width('100%')
    Row() {
      Text('开始时间').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
      Text(this.draftStart).fontSize(16).fontColor(this.timeField === 'start' ? this.color() : UiColor.text)
    }.id('inline_time_start').width('100%').height(48).onClick(() => { this.selectTime('start') })
    if (this.draftEnd) {
      Row() {
        Row() {
          Text('结束时间').fontSize(15).fontColor(UiColor.text).layoutWeight(1)
          Text(this.draftEnd).fontSize(16).fontColor(this.timeField === 'end' ? this.color() : UiColor.text)
        }.layoutWeight(1).height(48).onClick(() => { this.selectTime('end') })
        Button('移除').height(44).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .onClick(() => { this.draftEnd = ''; this.selectTime('start') })
      }.id('inline_time_end').width('100%').height(48)
    } else {
      Button('＋ 添加结束时间').id('inline_time_add_end').width('100%').height(44).fontColor(this.color()).backgroundColor(Color.Transparent)
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
    Button('清除时间').id('inline_time_clear').width('100%').height(44).fontColor(UiColor.error).backgroundColor('#443337')
      .onClick(() => { this.clearTime() })
  }
  @Builder
  datePanel() {
    Row() {
      Text(this.deadline ? '截止日期' : '计划日期').fontSize(17).fontColor(UiColor.text).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_close')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('取消日期与时间修改')
        .enabled(!this.busy).onClick(() => { this.close() })
    }.width('100%')
    this.quick('今天', 0)
    this.quick('明天', 1)
    Row() {
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_back')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('上个月').enabled(!this.busy).onClick(() => { this.move(-1) })
      Text(`${this.year}年${this.month + 1}月`).fontSize(14).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_next')).width(20).height(20) }
        .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('下个月').enabled(!this.busy).onClick(() => { this.move(1) })
    }.width('100%')
    Row() {
      ForEach(['一', '二', '三', '四', '五', '六', '日'], (label: string) => {
        Text(label).fontSize(11).fontColor(UiColor.secondary).textAlign(TextAlign.Center).layoutWeight(1)
      })
    }.width('100%').height(24)
    Grid() {
      ForEach(taskCalendarDays(this.year, this.month, this.date), (day: TaskCalendarDay) => {
        GridItem() { this.day(day) }
      }, (day: TaskCalendarDay) => day.key)
    }.width('100%').height(264).columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr').rowsGap(0).columnsGap(2)
    if (this.allowTime) {
      Row() {
        Text(this.start ? '时间' : '＋ 添加时间').fontSize(15).fontColor(this.color()).layoutWeight(1)
        if (this.start) { Text(`${this.start}${this.end ? `–${this.end}` : ''}`).fontSize(15).fontColor(UiColor.text) }
        Image($r('app.media.ui_next')).width(18).height(18)
      }.id('inline_date_time').width('100%').height(48).enabled(!this.busy).onClick(() => { this.editTime() })
      if (this.batch && !this.timeChanged) {
        Text('只改日期时，各任务保留原时间；添加或清除时间将应用到全部选中任务。').fontSize(12).fontColor(UiColor.secondary).width('100%')
      } else if (this.timeChanged && !this.start) {
        Text('保存后仅保留日期').fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
    }
    if (this.date) { Text(`已选：${this.date}`).fontSize(12).fontColor(UiColor.secondary).width('100%') }
    if (this.allowClear && (this.selected || this.date)) {
      Button('清除日期').id('inline_date_clear').width('100%').height(44).backgroundColor('#443337').fontColor(UiColor.error)
        .enabled(!this.busy).onClick(() => { this.date = ''; this.start = ''; this.end = ''; this.timeChanged = true; this.message = '' })
    }
    Button('完成').id('inline_date_save').width('100%').height(44).backgroundColor(this.color()).fontColor(UiColor.onPrimary)
      .enabled(!this.busy && (!!this.date || !!this.selected)).onClick(() => { this.commit() })
  }
  build() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.editingTime) { this.timePanel() } else { this.datePanel() }
        if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
      }.width('100%').padding(16)
    }.width('calc(100% - 32vp)').constraintSize({ maxWidth: 360, maxHeight: '85%' })
      .backgroundColor(UiColor.dialog).borderRadius(20)
  }
}
