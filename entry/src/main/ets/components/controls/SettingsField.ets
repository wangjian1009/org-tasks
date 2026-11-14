import { UiColor } from '../../ui/Theme'

@Component
export struct SettingsField {
  @Prop title: string = ''
  @Prop text: string = ''
  @Prop placeholder: string = ''
  @Prop password: boolean = false
  @Prop divider: boolean = true
  changed: (value: string) => void = () => {}

  build() {
    Column({ space: 4 }) {
      Text(this.title).width('100%').fontSize(13).fontColor(UiColor.secondary).padding({ left: 4 })
      TextInput({ text: this.text, placeholder: this.placeholder }).height(44).padding({ left: 4, right: 4 })
        .backgroundColor(Color.Transparent).fontColor(UiColor.text).placeholderColor(UiColor.disabled)
        .fontSize(16).type(this.password ? InputType.Password : InputType.Normal)
        .accessibilityText(this.title).onChange((value: string): void => { this.changed(value) })
    }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })
      .border({ width: { bottom: this.divider ? 0.5 : 0 }, color: UiColor.divider })
  }
}
