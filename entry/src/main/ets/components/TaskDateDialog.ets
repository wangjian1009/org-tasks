import { UiColor } from '../ui/Theme'
import { inlineDate, TaskCalendarDay, taskCalendarDays } from '../ui/TaskInlinePresentation'

@CustomDialog
export struct TaskDateDialog {
  controller: CustomDialogController
  selected: string = ''
  deadline: boolean = false
  allowClear: boolean = true
  closed: () => void = () => {}
  choose: (value: string) => Promise<boolean> = async () => false
  @State year: number = new Date().getFullYear()
  @State month: number = new Date().getMonth()
  @State busy: boolean = false
  @State message: string = ''

  aboutToAppear() {
    const date = this.selected ? new Date(`${this.selected}T12:00:00`) : new Date()
    this.year = date.getFullYear()
    this.month = date.getMonth()
  }
  color(): string { return this.deadline ? UiColor.error : UiColor.primary }
  move(delta: number) {
    const next = new Date(this.year, this.month + delta, 1, 12)
    if (next.getFullYear() < 1 || next.getFullYear() > 9999) return
    this.year = next.getFullYear(); this.month = next.getMonth()
  }
  async pick(value: string) {
    if (this.busy) return
    this.busy = true
    this.message = ''
    try {
      if (await this.choose(value)) { this.controller.close(); this.closed() }
      else this.message = '未能修改，请检查任务卡片上的错误提示'
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
    }.id(`inline_day_${day.date}`).width('100%').height(34).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      .accessibilityText(`${day.date}${day.today ? '，今天' : ''}${day.selected ? '，已选中' : ''}`)
      .enabled(!this.busy).onClick(() => { this.pick(day.date) })
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.deadline ? '截止日期' : '计划日期').fontSize(17).fontColor(UiColor.text).layoutWeight(1)
        Button('×').width(44).height(44).fontColor(UiColor.secondary).fontSize(24).backgroundColor(Color.Transparent)
          .accessibilityText('关闭日期选择').enabled(!this.busy).onClick(() => { this.controller.close(); this.closed() })
      }.width('100%')
      this.quick('今天', 0)
      this.quick('明天', 1)
      Row() {
        Button('‹').width(44).height(44).fontSize(24).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .accessibilityText('上个月').onClick(() => { this.move(-1) })
        Text(`${this.year}年${this.month + 1}月`).fontSize(14).fontColor(UiColor.text).textAlign(TextAlign.Center).layoutWeight(1)
        Button('›').width(44).height(44).fontSize(24).fontColor(UiColor.secondary).backgroundColor(Color.Transparent)
          .accessibilityText('下个月').onClick(() => { this.move(1) })
      }.width('100%')
      Row() {
        ForEach(['一', '二', '三', '四', '五', '六', '日'], (label: string) => {
          Text(label).fontSize(11).fontColor(UiColor.secondary).textAlign(TextAlign.Center).layoutWeight(1)
        })
      }.width('100%').height(24)
      Grid() {
        ForEach(taskCalendarDays(this.year, this.month, this.selected), (day: TaskCalendarDay) => {
          GridItem() { this.day(day) }
        }, (day: TaskCalendarDay) => day.key)
      }.width('100%').height(216).columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr').rowsGap(2).columnsGap(2)
      if (this.selected) {
        Text(`已选：${this.selected}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
        if (this.allowClear) {
        Button('清除日期').id('inline_date_clear').width('100%').height(40).backgroundColor('#443337').fontColor(UiColor.error)
          .enabled(!this.busy).onClick(() => { this.pick('') })
        }
      }
      if (this.message) { Text(this.message).fontSize(12).fontColor(UiColor.error).width('100%') }
    }.width('90%').constraintSize({ maxWidth: 360 }).padding(16).backgroundColor('#262B2D').borderRadius(20)
  }
}
