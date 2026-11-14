import { TaskActionItem } from '../ui/TaskActionPresentation'
import { TaskActionMenu } from './TaskActionMenu'
import { UiColor } from '../ui/Theme'

@Component
export struct TaskBatchToolbar {
  @Prop items: TaskActionItem[] = []
  @Prop count: number = 0
  @Prop busy: boolean = false
  @Prop busyAction: string = ''
  @Prop invalid: boolean = false
  @Prop message: string = ''
  @Prop idPrefix: string = 'task_batch'
  retry: () => void = () => {}
  cancel: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(`已选 ${this.count} 条`).id(`${this.idPrefix}_count`).fontSize(17).fontColor(UiColor.text).layoutWeight(1)
        Button({ type: ButtonType.Normal }) { Image($r('app.media.ui_close')).width(20).height(20) }
          .id(`${this.idPrefix}_close`).width(44).height(44).backgroundColor(Color.Transparent)
          .accessibilityText('退出多选').enabled(!this.busy).onClick(() => { this.cancel() })
      }.width('100%')
      if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
      if (this.invalid) {
        Row() {
          Button('刷新重选').height(44).fontColor(UiColor.selection).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick(this.retry)
        }.width('100%').justifyContent(FlexAlign.End)
      }
      if (!this.invalid && this.items.length > 0) {
        TaskActionMenu({ items: this.items, count: this.count, selecting: true, busy: this.busy,
          busyAction: this.busyAction, invalid: this.invalid, idPrefix: this.idPrefix })
          .width('100%')
      }
    }.width('92%').constraintSize({ maxWidth: 420 }).padding(16).backgroundColor(UiColor.dialog).borderRadius(20)
      .shadow({ radius: 8, color: '#40000000', offsetY: 3 }).margin({ bottom: 24 })
  }
}
