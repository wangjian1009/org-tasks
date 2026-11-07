import { http } from '@kit.NetworkKit'

export interface ShareLocationRequest {
  title: string
  url: string
}

export interface SharedLocation {
  kind: 'coordinates' | 'address' | 'unknown'
  source: 'amap' | 'petal' | 'unknown'
  label: string
  address: string
  latitude: string
  longitude: string
  uri: string
  rawUrl: string
}

export function parseSharedLocation(request: ShareLocationRequest): SharedLocation {
  const url = request.url.trim()
  const title = request.title.trim() || '分享地点'
  const petal = /(?:https?:\/\/)?(?:www\.)?petalmaps\.com\/place\//i.test(url)
  const amap = /(?:https?:\/\/)?(?:surl\.)?amap\.com\//i.test(url)
  const marker = url.match(/[?&]marker=([-+]?\d+(?:\.\d+)?),([-+]?\d+(?:\.\d+)?)/i)
  if (marker) {
    const label = queryValue(url, 'name') || title
    return locationCoordinates(petal ? 'petal' : amap ? 'amap' : 'unknown', label, marker[1], marker[2], url)
  }
  if (url.startsWith('geo:')) return parseGeo(title, url)
  if (url.startsWith('addr:')) {
    const address = decodeURIComponent(url.substring(5))
    return { kind: 'address', source: 'unknown', label: title, address, latitude: '', longitude: '', uri: `addr:${encodeURIComponent(address)}`, rawUrl: url }
  }
  return { kind: 'unknown', source: amap ? 'amap' : petal ? 'petal' : 'unknown', label: title, address: '', latitude: '', longitude: '', uri: url, rawUrl: url }
}

export async function resolveAmapShortUrl(location: SharedLocation): Promise<SharedLocation> {
  if (location.source !== 'amap' || location.kind !== 'unknown' || !location.rawUrl) return location
  const request = http.createHttp()
  try {
    let redirect = ''
    request.on('headersReceive', (headers: Object): void => {
      const values = headers as Record<string, string>
      redirect = values['location'] || values['Location'] || redirect
    })
    const response = await request.request(location.rawUrl, {
      method: http.RequestMethod.GET,
      connectTimeout: 2500,
      readTimeout: 2500,
      expectDataType: http.HttpDataType.STRING
    })
    const header = response.header as Record<string, string>
    redirect = redirect || header['location'] || header['Location'] || ''
    const match = redirect.match(/[?&]p=[^,]+,([-+]?\d+(?:\.\d+)?),([-+]?\d+(?:\.\d+)?),([^&]+)/i)
    if (match) {
      return locationCoordinates('amap', decodeURIComponent(match[3]), match[1], match[2], location.rawUrl)
    }
  } catch (e) {
    // 解析失败保留原始链接，让用户决定是否保存。
  } finally {
    request.destroy()
  }
  return location
}

function locationCoordinates(source: 'amap' | 'petal' | 'unknown', label: string, latitude: string,
  longitude: string, rawUrl: string): SharedLocation {
  return { kind: 'coordinates', source, label, address: '', latitude, longitude,
    uri: `geo:${latitude},${longitude}`, rawUrl }
}

function parseGeo(title: string, value: string): SharedLocation {
  const match = value.match(/^geo:([^?]+)(?:\?(.+))?$/i)
  if (!match) return { kind: 'unknown', source: 'unknown', label: title, address: '', latitude: '', longitude: '', uri: value, rawUrl: value }
  const coordinates = match[1].split(',')
  const query = match[2] || ''
  const address = queryValue(`?${query}`, 'q')
  if (coordinates.length === 2 && coordinates[0] !== '0' && coordinates[1] !== '0') {
    return locationCoordinates('unknown', title, coordinates[0], coordinates[1], value)
  }
  if (address) return { kind: 'address', source: 'unknown', label: title, address, latitude: '', longitude: '', uri: `addr:${encodeURIComponent(address)}`, rawUrl: value }
  return { kind: 'unknown', source: 'unknown', label: title, address: '', latitude: '', longitude: '', uri: value, rawUrl: value }
}

function queryValue(value: string, key: string): string {
  const match = value.match(new RegExp(`[?&]${key}=([^&#]*)`, 'i'))
  if (!match) return ''
  try { return decodeURIComponent(match[1].replace(/\+/g, ' ')) } catch (e) { return match[1] }
}
