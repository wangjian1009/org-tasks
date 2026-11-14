import { UiColor } from '../../ui/Theme'

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
