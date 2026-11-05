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
        Button('记一条').layoutWeight(1).height(44).padding({ left: 4, right: 4 }).fontSize(14).fontColor('#123D37').backgroundColor('#5AC4B9')
          .onClick((): void => { this.capture(false) })
        Button('说一句').layoutWeight(1).height(44).padding({ left: 4, right: 4 }).fontSize(14).fontColor('#D8D8D8').backgroundColor('#3A3E3F')
          .onClick((): void => { this.capture(true) })
      }.width('100%')
    }.width('100%').height('100%').padding(8).justifyContent(FlexAlign.Center)
      .backgroundColor('#2D2C2B').borderRadius(20)
  }
}
