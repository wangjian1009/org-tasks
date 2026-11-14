import { UiColor } from '../ui/Theme'

@Component
export struct IconButton {
  @Prop icon: Resource = $r('app.media.ui_more')
  @Prop label: string = ''
  @Prop disabled: boolean = false
  @Prop iconSize: number = 24
  @Prop buttonWidth: number = 48
  action: () => void = () => {}

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.icon).width(this.iconSize).height(this.iconSize)
    }
    .width(this.buttonWidth).height(48).borderRadius(24).backgroundColor(Color.Transparent)
    .accessibilityText(this.label).enabled(!this.disabled).onClick((): void => { this.action() })
  }
}

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

@Component
export struct SectionHeading {
  @Prop title: string = ''
  @Prop subtitle: string = ''

  build() {
    Column({ space: 4 }) {
      Text(this.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.primary).width('100%')
      if (this.subtitle.length > 0) {
        Text(this.subtitle).fontSize(12).fontColor(UiColor.secondary).width('100%')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 24, bottom: 12 })
  }
}

@Component
export struct ListSectionHeader {
  @Prop title: string = ''

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ui_category')).width(22).height(22)
        Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Divider().color(UiColor.outline).strokeWidth(0.5)
    }.width('100%').padding({ top: 24, bottom: 8 })
  }
}

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
