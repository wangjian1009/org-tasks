import { CoreTitleCount, CoreTitlePart } from '../services/NativeCoreService'
import { titleCountDescription, titleCounts, titleCountsWidth } from '../ui/TitleCountPresentation'
import { UiColor } from '../ui/Theme'
import { TitleCountBadge } from './TitleCountBadge'

@Component
export struct TitleCounts {
  @Prop parts: CoreTitlePart[] = []
  @Prop budget: number = 0

  build() {
    if (this.budget > 0 && titleCountsWidth(this.parts) > this.budget) {
      Progress({ value: 0, total: 100, type: ProgressType.Ring }).width(14).height(14)
        .color(UiColor.secondary).backgroundColor('#686763').style({ strokeWidth: 1.5 })
        .accessibilityText(titleCounts(this.parts).map((count: CoreTitleCount): string => titleCountDescription(count)).join('；'))
    } else {
      Flex({ direction: FlexDirection.Row, wrap: this.budget > 0 ? FlexWrap.NoWrap : FlexWrap.Wrap,
        alignItems: ItemAlign.Center }) {
        ForEach(titleCounts(this.parts), (count: CoreTitleCount) => {
          TitleCountBadge({ count }).margin({ right: 6, bottom: this.budget > 0 ? 0 : 4 })
        })
      }.constraintSize({ maxWidth: this.budget > 0 ? this.budget : '100%' }).flexShrink(0)
    }
  }
}
