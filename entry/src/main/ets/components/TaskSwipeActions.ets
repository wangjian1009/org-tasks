import { TaskActionItem, taskSwipeMenuWidth } from '../ui/TaskActionPresentation'
import { UiColor } from '../ui/Theme'

// 动作内容、顺序和回调由页面提供，宽度随实际按钮数变化。
@Component
export struct TaskSwipeActions {
  @Prop items: TaskActionItem[] = []
  @Prop busy: boolean = false
  @Prop idPrefix: string = 'task_swipe'

  build() {
    Row() {
      Row() {
        ForEach(this.items, (item: TaskActionItem) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              Image(item.icon).width(20).height(20).accessibilityLevel('no')
                .fillColor(item.style === 'danger' ? UiColor.error : item.style === 'selection' ? Color.White : UiColor.text)
              Text(item.title).fontSize(11)
                .fontColor(item.style === 'danger' ? UiColor.error : item.style === 'selection' ? Color.White : UiColor.text)
            }
          }.id(`${this.idPrefix}_${item.id}`).width(48).height(44).padding(0)
            .backgroundColor(item.style === 'selection' ? UiColor.selection : Color.Transparent)
            .enabled(!this.busy).accessibilityText(item.label).onClick((): void => { if (!this.busy) item.action() })
            .gesture(LongPressGesture().onAction((): void => {
              this.getUIContext().getPromptAction().showToast({ message: item.label })
            }))
        }, (item: TaskActionItem) => item.id)
      }.backgroundColor('#35383E').borderRadius(12).clip(true)
    }.width(taskSwipeMenuWidth(this.items)).height('100%').padding({ left: 4, right: 12 }).alignItems(VerticalAlign.Center)
  }
}
