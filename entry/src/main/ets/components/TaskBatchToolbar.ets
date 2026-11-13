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
  @Prop caption: string = ''
  @Prop idPrefix: string = 'task_batch'
  @Prop cancelLabel: string = ''
  retry: () => void = () => {}
  cancel: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      if (this.message) { Text(this.message).fontSize(13).fontColor(UiColor.error).width('100%') }
      if (this.caption) {
        Text(this.caption).fontSize(12).fontColor(UiColor.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 12, right: 12 })
      }
      Row({ space: 12 }) {
        if (this.cancelLabel) {
          Button(this.cancelLabel).height(44).fontColor(UiColor.primary).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick(() => { this.cancel() })
        }
        Text(`已选 ${this.count} 条`).fontSize(14).fontColor(UiColor.text).layoutWeight(1)
        if (this.invalid) {
          Button('刷新重选').height(44).fontColor(UiColor.selection).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick(this.retry)
        }
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 8 })
      if (!this.invalid && this.items.length > 0) {
        TaskActionMenu({ items: this.items, count: this.count, selecting: true, busy: this.busy,
          busyAction: this.busyAction, invalid: this.invalid, idPrefix: this.idPrefix })
          .width('100%')
      }
    }.width('92%').constraintSize({ maxWidth: 420 }).padding(8).backgroundColor('#25282E').borderRadius(20)
      .shadow({ radius: 8, color: '#40000000', offsetY: 3 }).margin({ bottom: 24 })
  }
}
