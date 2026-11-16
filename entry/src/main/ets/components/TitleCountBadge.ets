import { CoreTitleCount } from '../services/NativeCoreService'
import { titleCountColor, titleCountDescription, titleCountLabel, titleCountValue } from '../ui/TitleCountPresentation'

@Component
export struct TitleCountBadge {
  @Prop count: CoreTitleCount = { completed: null, total: null }

  color(): string {
    return titleCountColor(this.count)
  }

  build() {
    Row({ space: 5 }) {
      Progress({ value: titleCountValue(this.count), total: 100, type: ProgressType.Ring })
        .width(14).height(14).color(this.color()).backgroundColor('#686763')
        .style({ strokeWidth: 1.5, enableSmoothEffect: false }).accessibilityLevel('no')
      Text(titleCountLabel(this.count)).fontSize(12).fontColor(this.color()).maxLines(1).flexShrink(0)
    }.padding({ left: 7, right: 7, top: 3, bottom: 3 }).borderRadius(7).backgroundColor('#393E3C')
      .alignItems(VerticalAlign.Center).flexShrink(0).accessibilityGroup(true)
      .accessibilityText(titleCountDescription(this.count))
  }
}
