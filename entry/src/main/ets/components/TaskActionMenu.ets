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
  @State private availableWidth: number = 0

  baseActionWidth(): number {
    return this.selecting ? Math.max(56, this.availableWidth / Math.max(1, this.items.length)) : 48
  }

  caption(item: TaskActionItem): string {
    return this.busy && this.busyAction === item.id ? item.busyTitle || item.title : item.title
  }

  actionWidth(item: TaskActionItem): number {
    const context = this.getUIContext()
    const width = context.getMeasureUtils().measureText({
      textContent: this.caption(item), fontSize: `${context.fp2px(11)}px`
    })
    return Math.max(this.baseActionWidth(), Math.ceil(context.px2vp(width)) + 4)
  }

  actionEnabled(item: TaskActionItem): boolean {
    return this.selecting ? taskBatchActionEnabled(item, this.count, this.busy, this.invalid) : !this.busy && !this.invalid
  }

  activate(item: TaskActionItem) {
    if (this.actionEnabled(item)) item.action()
  }

  @Builder
  actionIcon(item: TaskActionItem) {
    if (item.style === 'danger' || item.style === 'selection') {
      Image(item.icon).width(20).height(20).accessibilityLevel('no')
        .fillColor(item.style === 'danger' ? UiColor.error : Color.White)
    } else {
      Image(item.icon).width(20).height(20).accessibilityLevel('no')
    }
  }

  build() {
    Scroll() {
      Row() {
        ForEach(this.items, (item: TaskActionItem) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              this.actionIcon(item)
              Text(this.caption(item)).fontSize(11).maxLines(1)
                .fontColor(item.style === 'danger' ? UiColor.error : item.style === 'selection' ? Color.White : UiColor.text)
            }.opacity(this.actionEnabled(item) || this.busy && this.busyAction === item.id ? 1 : 0.4)
          }.id(`${this.idPrefix}_${item.id}`).width(this.actionWidth(item)).height(44).padding(0).flexShrink(0)
            .backgroundColor(item.style === 'selection' ? UiColor.selection : Color.Transparent)
            .enabled(this.actionEnabled(item)).accessibilityText(item.label)
            .onClick((): void => { this.activate(item) })
            .gesture(LongPressGesture().onAction((): void => {
              this.getUIContext().getPromptAction().showToast({ message: item.label })
            }))
        }, (item: TaskActionItem) => item.id)
      }.width(this.items.reduce((width: number, item: TaskActionItem): number => width + this.actionWidth(item), 0))
    }.id(`${this.idPrefix}_horizontal_menu`).width('100%').align(Alignment.Start)
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).height(44)
      .backgroundColor(this.selecting ? Color.Transparent : '#35383E').borderRadius(this.selecting ? 0 : 12).clip(true)
      .onAreaChange((_old: Area, area: Area): void => {
        const width = parseFloat(area.width.toString())
        if (this.selecting && width !== this.availableWidth) this.availableWidth = width
      })
  }
}
