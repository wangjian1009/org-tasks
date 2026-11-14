import { UiColor } from '../../ui/Theme'

@Component
export struct EmptyState {
  @Prop title: string = ''
  @Prop detail: string = ''
  @Prop actionLabel: string = ''
  @Prop busy: boolean = false
  action: () => void = () => {}

  build() {
    Column({ space: 12 }) {
      if (this.busy) {
        LoadingProgress().width(32).height(32).color(UiColor.primary)
      }
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
      Text(this.detail).fontSize(14).fontColor(UiColor.secondary).textAlign(TextAlign.Center).lineHeight(22)
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).backgroundColor(UiColor.selected).fontColor(UiColor.onSelected)
          .margin({ top: 8 }).onClick((): void => { this.action() })
      }
    }
    .width('100%').height('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(32)
  }
}
