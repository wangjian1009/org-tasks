import { common, Want } from '@kit.AbilityKit'
import { petalMaps } from '@kit.MapKit'

export interface MapAppChoice {
  title: string
  icon: Resource
  contextLabel: string
  description: string
  installed: boolean
  supported: boolean
  unsupportedMessage?: string
  select: () => void
}

export type MapAppChooser = (choices: MapAppChoice[]) => void

interface GeoCoordinates {
  latitude: string
  longitude: string
}

// 链接解析由 Core 完成；宿主只调用系统能力打开支持的外部地址。
export class ExternalLinkService {
  static async open(context: common.UIAbilityContext, href: string, chooser?: MapAppChooser): Promise<void> {
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
}

async function openMapChooser(context: common.UIAbilityContext, uri: string, chooser?: MapAppChooser): Promise<void> {
  const choices: MapAppChoice[] = [
    mapChoice(context, '高德地图', $r('app.media.map_app_amap'), 'com.amap.hmapp', uri),
    mapChoice(context, '花瓣地图', $r('app.media.map_app_petal'), 'com.huawei.hmos.maps.app', uri)
  ]
  if (chooser) chooser(choices)
  else if (choices.some((choice) => choice.installed && choice.supported)) {
    const choice = choices.find((item) => item.installed && item.supported)
    if (choice) choice.select()
  } else throw new Error('没有可用的地图应用')
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
    installed: true,
    supported,
    unsupportedMessage: supported ? undefined : '高德地图暂不支持地址搜索，请选择花瓣地图。',
    select: (): void => {
      if (bundleName === 'com.huawei.hmos.maps.app' && search) {
        petalMaps.openMapTextSearch(context, { destinationName: search }).catch(() => {})
        return
      }
      if (bundleName === 'com.amap.hmapp' && search) {
        context.openLink(`https://uri.amap.com/search?keyword=${encodeURIComponent(search)}`, { appLinkingOnly: false }).catch(() => {})
        return
      }
      const targetUri = bundleName === 'com.amap.hmapp' ? amapUri(uri, search) : uri
      const want: Want = { bundleName, abilityName: 'EntryAbility', action: 'ohos.want.action.viewData', uri: targetUri,
        entities: ['entity.system.browsable'] } as Want
      context.startAbility(want).catch(() => {})
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
