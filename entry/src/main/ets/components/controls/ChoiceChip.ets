import { UiColor } from '../../ui/Theme'

@Component
export struct ChoiceChip {
  @Prop label: string = ''
  @Prop accessibilityLabel: string = ''
  @Prop controlId: string = ''
  @Prop chipWidth: number = 44
  @Prop textColor: ResourceColor = UiColor.text
  @Prop fill: ResourceColor = UiColor.field
  @Prop selected: boolean = false
  @Prop disabled: boolean = false
  choose: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(this.label).fontSize(14).fontColor(this.textColor).textAlign(TextAlign.Center)
          .constraintSize({ minWidth: this.chipWidth, minHeight: 32 })
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.fill).borderRadius(16)
          .border({ width: this.selected ? 1.3 : 0, color: UiColor.primary })
        if (this.selected) {
          Image($r('app.media.ui_done')).width(9).height(9).margin({ top: 3, right: 3 }).accessibilityLevel('no')
        }
      }
    }.id(this.controlId).constraintSize({ minWidth: this.chipWidth, minHeight: 44 }).padding(0)
      .backgroundColor(Color.Transparent).enabled(!this.disabled).defaultFocus(this.selected)
      .accessibilityText(this.accessibilityLabel || this.label).onClick(this.choose)
  }
}
