import { CoreTitleCount, CoreTitlePart } from '../services/NativeCoreService'
import { LinkView } from './LinkView'
import { TitleCountBadge } from './TitleCountBadge'
import { titleCounts } from '../ui/TitleCountPresentation'
import { UiSize } from '../ui/Theme'

@Component
export struct TitleText {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = UiSize.taskFont
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop lineLimit: number = 0
  @Prop cancelled: boolean = false
  @Prop copyable: boolean = false
  @Prop showCounts: boolean = true
  @Prop openLinks: boolean = true
  activate: (() => void) | undefined = undefined
  @Builder
  titleContent() {
    LinkView({ text: this.text, parts: this.parts, textSize: this.textSize, weight: this.weight,
      lineLimit: this.lineLimit, cancelled: this.cancelled, copyable: this.copyable,
      openLinks: this.openLinks, activate: this.activate })
  }

  build() {
    if (this.showCounts && titleCounts(this.parts).length > 0) {
      Flex({ direction: FlexDirection.Row, wrap: this.lineLimit === 1 ? FlexWrap.NoWrap : FlexWrap.Wrap,
        alignItems: ItemAlign.Center }) {
        this.titleContent()
        ForEach(titleCounts(this.parts), (count: CoreTitleCount) => {
          TitleCountBadge({ count }).margin({ left: 6, top: 2, bottom: 2 }).onClick(this.activate)
        })
      }
    } else {
      this.titleContent()
    }
  }
}
