import { CoreTaskPriority } from '../services/NativeCoreService'
import { priorityColor, priorityBackground, priorityLabel } from '../ui/TaskPriorityPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct TaskPriorityChoices {
  @Prop options: CoreTaskPriority[] = []
  @Prop current: CoreTaskPriority | null = null
  @Prop disabled: boolean = false
  @Prop maximumWidth: number = 310
  choose: (name: string | null) => void = () => {}

  columns(): number { return Math.max(1, Math.min(6, this.options.length + 1, Math.floor((this.maximumWidth - 10) / 50))) }
  popupWidth(): number { return this.columns() * 44 + (this.columns() - 1) * 6 + 16 }
  selected(value: CoreTaskPriority | null): boolean { return (value?.name ?? null) === (this.current?.name ?? null) }

  @Builder
  chip(value: CoreTaskPriority | null, index: number) {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(value?.name ?? '无').fontSize(14).fontColor(value ? priorityColor(value.category) : UiColor.secondary)
          .constraintSize({ minWidth: 44, minHeight: 32 }).textAlign(TextAlign.Center)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(value ? priorityBackground(value.category) : UiColor.field).borderRadius(16)
          .border({ width: this.selected(value) ? 1.3 : 0, color: UiColor.primary })
        if (this.selected(value)) {
          Image($r('app.media.ui_done')).width(9).height(9).margin({ top: 3, right: 3 }).accessibilityLevel('no')
        }
      }
    }.constraintSize({ minWidth: 44, minHeight: 44 }).padding(0).backgroundColor(Color.Transparent)
      .margin({ right: (index + 1) % this.columns() === 0 ? 0 : 6 })
      .enabled(!this.disabled).defaultFocus(this.selected(value))
      .accessibilityText(`${priorityLabel(value)}，${this.selected(value) ? '已选中' : '未选中'}`)
      .onClick(() => { this.choose(value?.name ?? null) })
  }

  build() {
    Column() {
    Scroll() {
      Flex({ wrap: FlexWrap.Wrap }) {
        this.chip(null, 0)
        ForEach(this.options, (value: CoreTaskPriority, index: number) => { this.chip(value, index + 1) }, (value: CoreTaskPriority) => value.name)
      }.width(this.popupWidth() - 16)
    }.constraintSize({ maxHeight: 144 }).scrollBar(BarState.Auto).width(this.popupWidth() - 16)
    }.width(this.popupWidth()).padding(8).backgroundColor(UiColor.menu).borderRadius(10)
  }
}
