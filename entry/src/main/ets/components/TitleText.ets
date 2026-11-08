import { common } from '@kit.AbilityKit'
import { CoreTitleCount, CoreTitlePart } from '../services/NativeCoreService'
import { ExternalLinkService, MapAppChoice } from '../services/ExternalLinkService'
import { MapAppSheet } from './MapAppSheet'
import { TitleCountBadge } from './TitleCountBadge'
import { titleCounts } from '../ui/TitleCountPresentation'
import { UiColor } from '../ui/Theme'

@Component
export struct TitleText {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = 16
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop lineLimit: number = 0
  @Prop copyable: boolean = false
  @Prop showCounts: boolean = true
  activate: (() => void) | undefined = undefined
  @State chooserVisible: boolean = false
  @State mapChoices: MapAppChoice[] = []

  async openLink(href: string) {
    try {
      await ExternalLinkService.open(this.getUIContext().getHostContext()! as common.UIAbilityContext, href,
        (choices: MapAppChoice[]): void => { this.chooseMapApp(choices) })
    } catch (error) {
      const message = (error as Error).message
      this.showLinkError(message || '无法打开链接，请确认已安装对应应用。')
    }
  }

  showLinkError(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message }) }
    catch (error) { console.error('显示链接错误提示失败') }
  }

  chooseMapApp(choices: MapAppChoice[]): void {
    this.mapChoices = choices
    this.chooserVisible = true
  }

  @Builder
  titleContent() {
    Text() {
      if (this.parts.length === 0) {
        Span(this.text)
      } else {
        ForEach(this.parts, (part: CoreTitlePart) => {
          if (part.count) {
          } else if (part.href) {
            Span(part.text).fontColor(UiColor.primary).decoration({ type: TextDecorationType.Underline })
              .onClick((): void => { this.openLink(part.href!) })
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
      .onClick(this.activate).flexShrink(1)
      .bindSheet($$this.chooserVisible, MapAppSheet(this.mapChoices, (): void => { this.chooserVisible = false },
        (message: string): void => { this.showLinkError(message) }), {
        height: 300,
        detents: [300],
        preferType: SheetType.BOTTOM,
        backgroundColor: UiColor.surface,
        maskColor: Color.Transparent,
        showClose: false
      })
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
