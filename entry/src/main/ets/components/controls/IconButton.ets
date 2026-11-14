@Component
export struct IconButton {
  @Prop icon: Resource = $r('app.media.ui_more')
  @Prop label: string = ''
  @Prop disabled: boolean = false
  @Prop iconSize: number = 24
  @Prop buttonWidth: number = 48
  action: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.icon).width(this.iconSize).height(this.iconSize)
    }
    .width(this.buttonWidth).height(48).borderRadius(24).backgroundColor(Color.Transparent)
    .accessibilityText(this.label).enabled(!this.disabled).onClick((): void => { this.action() })
  }
}
