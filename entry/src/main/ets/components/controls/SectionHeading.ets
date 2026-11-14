import { UiColor } from '../../ui/Theme'

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
