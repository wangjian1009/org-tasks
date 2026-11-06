import { common } from '@kit.AbilityKit'
import { CoreTitlePart } from '../services/NativeCoreService'
import { ExternalLinkService } from '../services/ExternalLinkService'
import { UiColor } from '../ui/Theme'

@Component
export struct TitleText {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = 16
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop lineLimit: number = 0
  @Prop copyable: boolean = false
  activate: (() => void) | undefined = undefined

  async openLink(href: string) {
    try {
      await ExternalLinkService.open(getContext(this) as common.UIAbilityContext, href)
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接，请确认已安装对应应用。' })
    }
  }

  build() {
    Text() {
      if (this.parts.length === 0) {
        Span(this.text)
      } else {
        ForEach(this.parts, (part: CoreTitlePart) => {
          if (part.href) {
            Span(part.text).fontColor(UiColor.primary).decoration({ type: TextDecorationType.Underline })
              .onClick((): void => {
                this.openLink(part.href!)
              })
          } else if (part.isLink) {
            Span(part.text).fontColor(UiColor.secondary)
              .decoration({ type: TextDecorationType.Underline, color: UiColor.secondary, style: TextDecorationStyle.DASHED })
          } else {
            Span(part.text)
          }
        })
      }
    }.fontSize(this.textSize).fontWeight(this.weight).fontColor(UiColor.text)
      .maxLines(this.lineLimit > 0 ? this.lineLimit : 2147483647)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .wordBreak(WordBreak.BREAK_ALL)
      .copyOption(this.copyable ? CopyOptions.LocalDevice : CopyOptions.None)
      .onClick(this.activate)
  }
}
