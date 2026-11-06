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
        Button('记一条', { type: ButtonType.Capsule }).layoutWeight(1).height('100%')
          .padding({ left: 4, right: 4 }).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor('#123D37').backgroundColor('#5AC4B9')
          .onClick((): void => { this.capture(false) })
        Button('说一句', { type: ButtonType.Capsule }).layoutWeight(1).height('100%')
          .padding({ left: 4, right: 4 }).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor('#D8D8D8').backgroundColor('#3A3E3F')
          .onClick((): void => { this.capture(true) })
      }.width('100%').height('100%').padding({ left: 9, right: 9, top: 6, bottom: 6 })
        .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
        .border({ width: 0.75, color: '#626966' })
    }.width('100%').height('100%')
      // 铺满背景后交由桌面裁切，避免内层圆角与宿主不一致时露出白底。
      .backgroundColor('#18221E')
  }
}
