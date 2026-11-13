import { UiColor } from '../ui/Theme'

// 今天与随时的第一层分类标题，保留原有标题和分隔线布局。
@Component
export struct CategoryRegion {
  @Prop category: string | null = null

  build() {
    if (this.category) {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Image($r('app.media.ui_category')).width(22).height(22)
          Text(this.category).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Divider().color(UiColor.outline).strokeWidth(0.5)
      }.width('100%').padding({ left: 8, right: 8, top: 24, bottom: 8 }).backgroundColor(UiColor.surface)
    }
  }
}
