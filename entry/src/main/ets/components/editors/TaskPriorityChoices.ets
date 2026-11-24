import { CoreTaskPriority } from '../../services/NativeCoreService'
import { priorityColor, priorityBackground, priorityLabel } from '../../ui/TaskPriorityPresentation'
import { UiColor } from '../../ui/Theme'
import { ChoiceChip } from '../controls/ChoiceChip'

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
    Column() {
      ChoiceChip({ label: value?.name ?? '无', controlId: `task_priority_${index}`,
        textColor: value ? priorityColor(value.category) : UiColor.secondary,
        fill: value ? priorityBackground(value.category) : UiColor.field,
        selected: this.selected(value), disabled: this.disabled,
        accessibilityLabel: `${priorityLabel(value)}，${this.selected(value) ? '已选中' : '未选中'}`,
        choose: (): void => { this.choose(value?.name ?? null) } })
    }.margin({ right: (index + 1) % this.columns() === 0 ? 0 : 6 })
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
