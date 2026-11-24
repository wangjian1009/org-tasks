@Builder
function emptyPanel() {}

@CustomDialog
export struct CenteredPanel {
  @BuilderParam content: () => void = emptyPanel
  controller?: CustomDialogController

  build() {
    Column() {
      this.content()
    }.width('92%').height('68%').constraintSize({ maxWidth: 460, maxHeight: 620 })
      .borderRadius(24).clip(true).backgroundColor('#363A38')
  }
}
