import { UiColor } from '../../ui/Theme'

@Component
export struct SettingsGroup {
  @Prop title: string = ''
  @Prop detail: string = ''
  @BuilderParam content: () => void = this.emptyContent
  @Builder emptyContent() {}

  build() {
    Column({ space: 10 }) {
      Text(this.title).fontSize(13).fontColor(UiColor.secondary).width('100%').padding({ left: 12, right: 12 })
      Column() { this.content() }.width('100%').backgroundColor(UiColor.container).borderRadius(12).clip(true)
      if (this.detail) {
        Text(this.detail).fontSize(13).lineHeight(21).fontColor(UiColor.secondary).width('100%').padding({ left: 12, right: 12 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 24 })
  }
}
