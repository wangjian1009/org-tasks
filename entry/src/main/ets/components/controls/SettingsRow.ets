import { UiColor } from '../../ui/Theme'

@Component
export struct SettingsRow {
  @Prop title: string = ''
  @Prop value: string = ''
  @Prop detail: string = ''
  @Prop icon: Resource | undefined = undefined
  @Prop divider: boolean = true
  @Prop disclosure: boolean = true
  @Prop danger: boolean = false
  @Prop disabled: boolean = false
  action: () => void = () => {}

  build() {
    Row({ space: 12 }) {
      if (this.icon) { Image(this.icon).width(20).height(20).fillColor(UiColor.secondary).accessibilityLevel('no') }
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Text(this.title).fontSize(16).fontColor(this.danger ? UiColor.error : UiColor.text).layoutWeight(1)
          if (this.value) {
            Text(this.value).fontSize(13).fontColor(UiColor.secondary).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '45%' })
          }
        }.width('100%')
        if (this.detail) { Text(this.detail).fontSize(13).fontColor(UiColor.secondary).lineHeight(20).width('100%') }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.disclosure) {
        Image($r('app.media.ui_next')).width(16).height(16).fillColor(UiColor.secondary).accessibilityLevel('no')
      }
    }.width('100%').constraintSize({ minHeight: 58 }).padding({ left: 14, right: 14, top: 14, bottom: 14 })
      .border({ width: { bottom: this.divider ? 0.5 : 0 }, color: UiColor.divider })
      .enabled(!this.disabled).opacity(this.disabled ? 0.6 : 1)
      .accessibilityText(`${this.title}${this.value ? `，${this.value}` : ''}${this.detail ? `，${this.detail}` : ''}`)
      .onClick((): void => { this.action() })
  }
}
