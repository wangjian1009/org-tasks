import { TaskActionItem, taskBatchActionEnabled } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'

// 左滑与底部栏共用按钮、图标、颜色、无障碍名称及禁用判断。
@Component
export struct TaskActionMenu {
  @Prop items: TaskActionItem[] = []
  @Prop busy: boolean = false
  @Prop busyAction: string = ''
  @Prop count: number = 0
  @Prop selecting: boolean = false
  @Prop invalid: boolean = false
  @Prop idPrefix: string = 'task_action'

  actionEnabled(item: TaskActionItem): boolean {
    return this.selecting ? taskBatchActionEnabled(item, this.count, this.busy, this.invalid) : !this.busy && !this.invalid
  }

  activate(item: TaskActionItem) {
    if (this.actionEnabled(item)) item.action()
  }

  build() {
    Scroll() {
      Row() {
        ForEach(this.items, (item: TaskActionItem) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              Image(item.icon).width(20).height(20).accessibilityLevel('no')
                .fillColor(item.style === 'danger' ? UiColor.error : item.style === 'selection' ? Color.White : UiColor.text)
              Text(this.busy && this.busyAction === item.id ? item.busyTitle || item.title : item.title).fontSize(11).maxLines(1)
                .fontColor(item.style === 'danger' ? UiColor.error : item.style === 'selection' ? Color.White : UiColor.text)
            }.opacity(this.actionEnabled(item) || this.busy && this.busyAction === item.id ? 1 : 0.4)
          }.id(`${this.idPrefix}_${item.id}`).width(48).height(44).padding(0)
            .backgroundColor(item.style === 'selection' ? UiColor.selection : Color.Transparent)
            .enabled(this.actionEnabled(item)).accessibilityText(item.label)
            .onClick((): void => { this.activate(item) })
            .gesture(LongPressGesture().onAction((): void => {
              this.getUIContext().getPromptAction().showToast({ message: item.label })
            }))
        }, (item: TaskActionItem) => item.id)
      }
    }.align(this.selecting ? Alignment.End : Alignment.Start)
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).height(44)
      .backgroundColor(this.selecting ? Color.Transparent : '#35383E').borderRadius(this.selecting ? 0 : 12).clip(true)
  }
}
