import { UiColor } from '../../ui/Theme'

@Component
export struct MessageBar {
  @Prop message: string = ''
  @Prop error: boolean = false

  build() {
    if (this.message.length > 0) {
      Text(this.message).width('100%').padding(16).fontSize(13).lineHeight(20)
        .fontColor(this.error ? UiColor.error : UiColor.secondary).backgroundColor(UiColor.container)
        .accessibilityLevel('yes')
    }
  }
}
