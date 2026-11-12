import { TaskActionItem, taskBatchActionEnabled } from '../ui/TaskActionPresentation'
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

  activate(item: TaskActionItem) {
    if (taskBatchActionEnabled(item, this.count, this.busy, this.invalid)) item.action()
  }

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
        } else {
          ForEach(this.items, (item: TaskActionItem) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                Image(item.icon).width(20).height(20)
                Text(this.busy && this.busyAction === item.id ? item.busyTitle || item.title : item.title).fontSize(15)
                  .fontColor(item.style === 'danger' ? UiColor.error : Color.White)
              }.opacity(this.count >= (item.minimumSelection ?? 1) ? 1 : 0.4)
            }.id(`${this.idPrefix}_${item.id}`).height(44).padding({ left: 12, right: 8 })
              .backgroundColor(Color.Transparent).enabled(taskBatchActionEnabled(item, this.count, this.busy, this.invalid))
              .accessibilityText(item.label).onClick((): void => { this.activate(item) })
          }, (item: TaskActionItem) => item.id)
        }
      }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 18, right: 8 })
        .backgroundColor('#25282E').borderRadius(26).shadow({ radius: 8, color: '#40000000', offsetY: 3 })
    }.width('92%').constraintSize({ maxWidth: 420 }).margin({ bottom: 24 })
  }
}
