import { InternalLinkProcessor } from '../ui/InternalLinkProcessor'
import { CoreTitlePart, CoreTextLink, CoreLinkValue } from '../services/NativeCoreService'
import { LinkView, LinkEditController } from './LinkView'
import { UiSize } from '../ui/Theme'

@Component
export struct TitleText {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = UiSize.taskFont
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop lineLimit: number = 0
  @Prop lineHeight: number | undefined = undefined
  @Prop cancelled: boolean = false
  @Prop copyable: boolean = false
  @Prop showCounts: boolean = true
  @Prop openLinks: boolean = true
  @Prop editable: boolean = false
  @Prop revision: string = ''
  changeLink: ((link: CoreTextLink, value: CoreLinkValue | null) => Promise<void>) | undefined = undefined
  linkEditingChanged: (editing: boolean) => void = () => {}
  linkEditor: LinkEditController = new LinkEditController()
  internalLinkProcessor: InternalLinkProcessor | undefined = undefined
  activate: (() => void) | undefined = undefined
  @Builder
  titleContent() {
    LinkView({ text: this.text, parts: this.parts, textSize: this.textSize, weight: this.weight,
      lineLimit: this.lineLimit, lineHeight: this.lineHeight, showCounts: this.showCounts, cancelled: this.cancelled, copyable: this.copyable,
      internalLinkProcessor: this.internalLinkProcessor, openLinks: this.openLinks, activate: this.activate, editable: this.editable, revision: this.revision,
      change: this.changeLink, editingChanged: this.linkEditingChanged, editor: this.linkEditor })
  }

  build() {
    this.titleContent()
  }
}
