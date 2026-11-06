@Entry
@Component
struct CaptureCard {
  private capture(voice: boolean): void {
    postCardAction(this, { action: 'router', abilityName: 'CaptureAbility',
      params: { captureMode: voice ? 'voice' : 'text' } })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('记一条', { type: ButtonType.Normal }).layoutWeight(1).height(44).borderRadius(12)
          .padding({ left: 4, right: 4 }).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor('#123D37').backgroundColor('#5AC4B9')
          .onClick((): void => { this.capture(false) })
        Button('说一句', { type: ButtonType.Normal }).layoutWeight(1).height(44).borderRadius(12)
          .padding({ left: 4, right: 4 }).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor('#D8D8D8').backgroundColor('#3A3E3F')
          .onClick((): void => { this.capture(true) })
      }.width('100%')
    }.width('100%').height('100%').padding(12).justifyContent(FlexAlign.Center)
      .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card')).clip(true)
  }
}
