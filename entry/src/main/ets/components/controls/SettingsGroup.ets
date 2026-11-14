import { UiColor } from '../../ui/Theme'

@Component
export struct SettingsGroup {
  @Prop title: string = ''
  @Prop detail: string = ''
  @BuilderParam content: () => void = this.emptyContent
  @Builder emptyContent() {}

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(this.title).fontSize(13).fontColor(UiColor.secondary).layoutWeight(1)
        if (this.detail) {
          Button('?').width(32).height(32).padding(0).fontSize(16).borderRadius(16)
            .backgroundColor(Color.Transparent).fontColor(UiColor.secondary)
            .accessibilityText(`${this.title}：查看说明`)
            .onClick((): void => {
              this.getUIContext().showAlertDialog({ title: this.title, message: this.detail,
                confirm: { value: '知道了', action: () => {} } })
            })
        }
      }.width('100%').constraintSize({ minHeight: 32 }).padding({ left: 12, right: 4 })
      Column() { this.content() }.width('100%').backgroundColor(UiColor.container).borderRadius(12).clip(true)
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 24 })
  }
}
