import { UiColor } from '../../ui/Theme'

@Component
export struct PreferenceRow {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop icon: Resource = $r('app.media.ui_settings')
  action: () => void = () => {}

  build() {
    Row({ space: 24 }) {
      Image(this.icon).width(24).height(24)
      Column({ space: 5 }) {
        Text(this.title).fontSize(16).fontColor(UiColor.text).width('100%')
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(13).fontColor(UiColor.secondary).width('100%').lineHeight(20)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ui_next')).width(18).height(18)
    }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 18 }).onClick((): void => { this.action() })
  }
}
