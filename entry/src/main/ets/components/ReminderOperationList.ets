import { ReminderManager, ReminderOperationLog } from '../services/ReminderManager'
import { UiColor, localDate } from '../ui/Theme'

// 只订阅内存日志；查看记录不查询任务或维护系统提醒。
@Component
export struct ReminderOperationList {
  @State private records: ReminderOperationLog[] = []
  private stop: (() => void) | undefined = undefined

  aboutToAppear(): void {
    this.stop?.()
    this.stop = ReminderManager.subscribeOperations((): void => { this.records = ReminderManager.operationLogs() })
    this.records = ReminderManager.operationLogs()
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = undefined }

  private timestamp(value: number, seconds: boolean = false): string {
    const date = new Date(value)
    const hour = date.getHours().toString().padStart(2, '0')
    const minute = date.getMinutes().toString().padStart(2, '0')
    return `${localDate(date)} ${hour}:${minute}${seconds ? `:${date.getSeconds().toString().padStart(2, '0')}` : ''}`
  }
  private reminderTime(record: ReminderOperationLog): string {
    if (record.operation === '修改' && record.previousReminderAt !== null && record.previousReminderAt !== record.reminderAt) {
      return `${this.timestamp(record.previousReminderAt)} → ${this.timestamp(record.reminderAt)}`
    }
    return this.timestamp(record.reminderAt)
  }

  build() {
    Column() {
      if (!this.records.length) {
        Text('本次运行暂无提醒操作记录').id('reminder_operation_empty')
          .fontSize(14).fontColor(UiColor.secondary).padding(20)
      }
      ForEach(this.records, (record: ReminderOperationLog) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(record.operation).fontSize(14).fontColor(UiColor.text)
            Text(record.succeeded ? '成功' : '失败').fontSize(12).fontColor(record.succeeded ? UiColor.primary : UiColor.error)
            Blank()
          }.width('100%')
          Text(record.heading || '未命名提醒').fontSize(16).fontColor(UiColor.text).width('100%')
          Text(`${record.trigger} · ${this.timestamp(record.at, true)}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
          Text(`提醒时间：${this.reminderTime(record)}`).fontSize(12).fontColor(UiColor.secondary).width('100%')
          if (!record.succeeded) {
            Text(record.error).fontSize(12).fontColor(UiColor.error).width('100%')
          }
        }.id(`reminder_operation_${record.id}`).width('100%').alignItems(HorizontalAlign.Start).padding(16)
          .border({ width: { bottom: 0.5 }, color: UiColor.divider })
      }, (record: ReminderOperationLog): string => `${record.id}`)
    }.id('reminder_operation_list').width('100%')
  }
}
