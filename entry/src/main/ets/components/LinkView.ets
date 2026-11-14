import { common, Want } from '@kit.AbilityKit'
import { petalMaps } from '@kit.MapKit'
import { CoreTitlePart } from '../services/NativeCoreService'
import { UiColor, UiSize } from '../ui/Theme'

interface MapAppChoice {
  title: string
  icon: Resource
  contextLabel: string
  description: string
  supported: boolean
  select: () => Promise<void>
}

// Web 适配器只转交导航事件；协议、地图选择与失败反馈均由控件拥有。
export class LinkController {
  private activate: (href: string) => Promise<void>
  constructor(activate: (href: string) => Promise<void>) { this.activate = activate }

  open(href: string): Promise<void> { return this.activate(href) }

  navigate(href: string, mainFrame: boolean): boolean {
    if (href === 'about:blank' || href.startsWith('data:') || href.startsWith('#')) return false
    if (mainFrame) this.open(href)
    return true
  }
}

@Component
export struct LinkView {
  @Prop text: string = ''
  @Prop parts: CoreTitlePart[] = []
  @Prop textSize: number = UiSize.taskFont
  @Prop weight: FontWeight = FontWeight.Normal
  @Prop lineLimit: number = 0
  @Prop cancelled: boolean = false
  @Prop copyable: boolean = false
  @Prop openLinks: boolean = true
  @Prop document: boolean = false
  @Prop contentHeight: number | string = '100%'
  activate: (() => void) | undefined = undefined
  @BuilderParam content: (links: LinkController) => void = this.emptyContent
  @State chooserVisible: boolean = false
  @State mapChoices: MapAppChoice[] = []
  @State launching: boolean = false
  private active: boolean = false
  private generation: number = 0
  private links: LinkController = new LinkController((href: string): Promise<void> => this.open(href))

  aboutToAppear() { this.active = true; this.generation++; this.launching = false }
  aboutToDisappear() { this.active = false; this.generation++; this.chooserVisible = false; this.mapChoices = [] }

  async open(href: string): Promise<void> {
    if (!this.active || !this.openLinks || this.launching) return
    const generation = this.generation
    this.launching = true
    try {
      await openExternalLink(this.getUIContext().getHostContext()! as common.UIAbilityContext, href,
        (choices: MapAppChoice[]): void => {
          if (this.active && generation === this.generation) { this.mapChoices = choices; this.chooserVisible = true }
        })
    } catch (_) {
      if (generation === this.generation) this.notify('无法打开链接，请确认地址有效且已安装对应应用。')
    } finally {
      if (this.active && generation === this.generation) this.launching = false
    }
  }

  notify(message: string): void {
    if (!this.active) return
    try { this.getUIContext().getPromptAction().showToast({ message }) }
    catch (_) { console.error('显示链接错误提示失败') }
  }

  async selectMapApp(choice: MapAppChoice): Promise<void> {
    if (!this.active || this.launching) return
    const generation = this.generation
    if (!choice.supported) {
      this.notify('高德地图暂不支持地址搜索，请选择花瓣地图。')
      return
    }
    this.launching = true
    try {
      await choice.select()
      if (this.active && generation === this.generation) this.chooserVisible = false
    } catch (_) {
      if (generation === this.generation) this.notify('无法打开地图，请确认已安装对应应用后重试。')
    } finally {
      if (this.active && generation === this.generation) this.launching = false
    }
  }

  @Builder
  emptyContent(_links: LinkController) {}

  @Builder
  mapAppSheet() {
    Column() {
      Text('选择地图').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        .width('100%').padding({ left: 24, top: 8, bottom: 4 }).textAlign(TextAlign.Start)
      if (this.mapChoices.length > 0) {
        Text(this.mapChoices[0].contextLabel).fontSize(14).fontColor(UiColor.secondary)
          .width('100%').padding({ left: 24, bottom: 10 }).textAlign(TextAlign.Start)
      }
      Divider().color(UiColor.divider).margin({ left: 24, right: 24 })
      ForEach(this.mapChoices, (choice: MapAppChoice) => {
        Row({ space: 12 }) {
          Image(choice.icon).width(36).height(36).objectFit(ImageFit.Contain).borderRadius(8)
            .grayscale(choice.supported ? 0 : 1).opacity(choice.supported ? 1 : 0.5).accessibilityLevel('no')
          Column({ space: 4 }) {
            Text(choice.title).fontSize(20).fontWeight(FontWeight.Medium)
              .fontColor(choice.supported ? UiColor.text : UiColor.disabled)
            Text(choice.description).fontSize(14).fontColor(UiColor.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (choice.supported) {
            Image($r('app.media.ui_next')).width(24).height(24).fillColor(UiColor.primary).accessibilityLevel('no')
          }
        }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .enabled(!this.launching).onClick((): void => { this.selectMapApp(choice) })
      })
    }.width('100%').backgroundColor(UiColor.surface).borderRadius({ topLeft: 28, topRight: 28 })
  }

  @Builder
  inlineText() {
    Text() {
      if (this.parts.length === 0) {
        Span(this.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
          .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.None })
      } else {
        ForEach(this.parts, (part: CoreTitlePart) => {
          if (part.count) {
          } else if (part.href && this.openLinks) {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.primary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline })
              .onClick((): void => { this.links.open(part.href!) })
          } else if (part.isLink && this.openLinks) {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.secondary)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.Underline,
                color: UiColor.secondary, style: TextDecorationStyle.DASHED })
          } else {
            Span(part.text).fontColor(this.cancelled ? UiColor.disabled : UiColor.text)
              .decoration({ type: this.cancelled ? TextDecorationType.LineThrough : TextDecorationType.None })
          }
        })
      }
    }.fontSize(this.textSize).fontWeight(this.weight).fontColor(UiColor.text)
      .maxLines(this.lineLimit > 0 ? this.lineLimit : 2147483647).textOverflow({ overflow: TextOverflow.Ellipsis })
      .wordBreak(WordBreak.BREAK_ALL).copyOption(this.copyable ? CopyOptions.LocalDevice : CopyOptions.None)
      .onClick(this.activate).flexShrink(1)
  }

  build() {
    if (this.document) {
      Stack() { this.content(this.links) }.width('100%').height(this.contentHeight)
        .bindSheet($$this.chooserVisible, this.mapAppSheet(), {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT, '85%'], preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface, maskColor: Color.Transparent, showClose: false
        })
    } else {
      Row() { this.inlineText() }.flexShrink(1)
        .bindSheet($$this.chooserVisible, this.mapAppSheet(), {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT, '85%'], preferType: SheetType.BOTTOM,
          backgroundColor: UiColor.surface, maskColor: Color.Transparent, showClose: false
        })
    }
  }
}

interface GeoCoordinates {
  latitude: string
  longitude: string
}

// 链接解析由 Core 完成；宿主只调用系统能力打开支持的外部地址。
async function openExternalLink(context: common.UIAbilityContext, href: string, chooser: (choices: MapAppChoice[]) => void): Promise<void> {
  const scheme = href.substring(0, href.indexOf(':')).toLowerCase()
  if (scheme === 'http' || scheme === 'https') {
    await context.openLink(href, { appLinkingOnly: false })
  } else if (scheme === 'mailto' || scheme === 'tel') {
    try { await context.startAbility({ action: 'ohos.want.action.viewData', uri: href }) }
    catch (error) { throw new Error('无法打开链接，请确认已安装对应应用。') }
  } else if (scheme === 'geo') {
    const search = geoSearchAddress(href)
    if (search) {
      await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(search)}`, chooser)
    } else if (geoIsZero(href)) {
      throw new Error('地址链接缺少 q 搜索参数')
    } else {
      await openMapChooser(context, href, chooser)
    }
  } else if (scheme === 'addr') {
    // Core 已将地址文字按 URI 规则编码；转换为标准 geo 查询后交给系统选择器。
    const address = decodeURIComponent(href.substring(href.indexOf(':') + 1))
    await openMapChooser(context, `geo:0,0?q=${encodeURIComponent(address)}`, chooser)
  } else {
    throw new Error('此链接暂不支持打开')
  }
}

async function openMapChooser(context: common.UIAbilityContext, uri: string, chooser: (choices: MapAppChoice[]) => void): Promise<void> {
  const choices: MapAppChoice[] = [
    mapChoice(context, '高德地图', $r('app.media.map_app_amap'), 'com.amap.hmapp', uri),
    mapChoice(context, '花瓣地图', $r('app.media.map_app_petal'), 'com.huawei.hmos.maps.app', uri)
  ]
  chooser(choices)
}

function geoIsZero(href: string): boolean {
  const colon = href.indexOf(':')
  const query = href.indexOf('?')
  const coordinates = href.substring(colon + 1, query < 0 ? href.length : query)
  return /^0(?:\.0+)?\s*,\s*0(?:\.0+)?$/.test(coordinates)
}

function mapChoice(context: common.UIAbilityContext, title: string, icon: Resource, bundleName: string,
  uri: string): MapAppChoice {
  const search = geoSearchAddress(uri)
  const coordinates = geoCoordinates(uri)
  const contextLabel = search ? `搜索：${search}` : coordinates ? `坐标：${coordinates.latitude}, ${coordinates.longitude}` : '地址'
  const supported = !(bundleName === 'com.amap.hmapp' && Boolean(search))
  return {
    title,
    icon,
    contextLabel,
    description: search ? (supported ? '在地图中搜索地址' : '暂不支持地址搜索') : '在地图中打开坐标',
    supported,
    select: async (): Promise<void> => {
      if (bundleName === 'com.huawei.hmos.maps.app' && search) {
        await petalMaps.openMapTextSearch(context, { destinationName: search })
        return
      }
      if (bundleName === 'com.amap.hmapp' && search) {
        await context.openLink(`https://uri.amap.com/search?keyword=${encodeURIComponent(search)}`, { appLinkingOnly: false })
        return
      }
      const targetUri = bundleName === 'com.amap.hmapp' ? amapUri(uri, search) : uri
      const want: Want = { bundleName, abilityName: 'EntryAbility', action: 'ohos.want.action.viewData', uri: targetUri,
        entities: ['entity.system.browsable'] } as Want
      await context.startAbility(want)
    }
  }
}

function amapUri(uri: string, search: string | undefined): string {
  const coordinates = geoCoordinates(uri)
  if (coordinates) {
    return `amapuri://route/plan?dlat=${coordinates.latitude}&dlon=${coordinates.longitude}&dev=0&t=0`
  }
  return `amapuri://route/plan?dname=${encodeURIComponent(search || '')}&dev=0&t=0`
}

function geoCoordinates(uri: string): GeoCoordinates | undefined {
  const colon = uri.indexOf(':')
  const query = uri.indexOf('?')
  const value = uri.substring(colon + 1, query < 0 ? uri.length : query)
  const parts = value.split(',')
  if (parts.length !== 2 || parts[0] === '0' || parts[1] === '0') return undefined
  const result: GeoCoordinates = { latitude: parts[0], longitude: parts[1] }
  return result
}

function geoSearchAddress(href: string): string | undefined {
  const colon = href.indexOf(':')
  const query = href.indexOf('?')
  if (colon < 0 || query < 0 || href.substring(colon + 1, query) !== '0,0') return undefined
  for (const part of href.substring(query + 1).split('&')) {
    const equals = part.indexOf('=')
    if (equals < 0 || part.substring(0, equals) !== 'q') continue
    const value = part.substring(equals + 1).replace(/\+/g, ' ')
    if (!value) return undefined
    return decodeURIComponent(value)
  }
  return undefined
}
