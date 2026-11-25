// 协议展示与切换只处理 URI，不解析或生成 Org 源码。
export interface LinkProtocolChoice {
  kind: string
  title: Resource
  prefix: string
  icon: Resource
  path: string
}

export const LINK_PROTOCOLS: LinkProtocolChoice[] = [
  { kind: 'https', title: $r('app.string.text_https_web_page'), prefix: 'https://', icon: $r('app.media.ui_link_web'), path: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM3 12h18M12 3c-4 5-4 13 0 18 4-5 4-13 0-18Z' },
  { kind: 'http', title: $r('app.string.text_http_web_page'), prefix: 'http://', icon: $r('app.media.ui_link_web'), path: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM3 12h18M12 3c-4 5-4 13 0 18 4-5 4-13 0-18Z' },
  { kind: 'mailto', title: $r('app.string.text_mail'), prefix: 'mailto:', icon: $r('app.media.ui_link_mail'), path: 'M3 5h18v14H3ZM3 6l9 7 9-7' },
  { kind: 'tel', title: $r('app.string.text_telephone'), prefix: 'tel:', icon: $r('app.media.ui_link_phone'), path: 'M7 3H4c-2 8 9 19 17 17v-4l-5-2-2 2c-3-1-5-3-6-6l2-2Z' },
  { kind: 'geo', title: $r('app.string.text_coordinates'), prefix: 'geo:', icon: $r('app.media.ui_link_geo'), path: 'M12 22s8-8 8-13a8 8 0 1 0-16 0c0 5 8 13 8 13ZM12 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z' },
  { kind: 'addr', title: $r('app.string.text_address'), prefix: 'addr:', icon: $r('app.media.ui_link_addr'), path: 'M3 5l6-2 6 2 6-2v16l-6 2-6-2-6 2ZM9 3v16M15 5v16' },
  { kind: 'app', title: $r('app.string.text_apply'), prefix: 'app:', icon: $r('app.media.ui_link_other'), path: 'M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM9 6h6M9 18h6' },
  { kind: 'internal', title: $r('app.string.text_internal_document'), prefix: '', icon: $r('app.media.ui_link_internal'), path: 'M4 3h10l6 6v12H4ZM14 3v6h6M8 15h8M13 12l3 3-3 3' }
]

export function internalLinkTarget(href: string): string | undefined {
  if (!href.startsWith('org-internal:')) return undefined
  try { return decodeURIComponent(href.substring('org-internal:'.length)) } catch (_) { return undefined }
}

export function linkProtocol(url: string): LinkProtocolChoice {
  const value = url.trim()
  const kind = value.startsWith('org-internal:') || !value.includes(':') || value.startsWith('#') || value.startsWith('*')
    ? 'internal' : value.substring(0, value.indexOf(':')).toLowerCase()
  return LINK_PROTOCOLS.find((choice: LinkProtocolChoice) => choice.kind === kind) ?? {
    kind: 'other', title: $r('app.string.text_other_agreements'), prefix: '', icon: $r('app.media.ui_link_other'),
    path: 'M9 15l6-6M8 11l-2 2a4 4 0 0 0 6 6l2-2M10 7l2-2a4 4 0 0 1 6 6l-2 2'
  }
}

export function switchLinkProtocol(url: string, kind: string): string {
  const choice = LINK_PROTOCOLS.find((item: LinkProtocolChoice) => item.kind === kind)
  if (!choice || linkProtocol(url).kind === kind) return url
  const target = internalLinkTarget(url) ?? url
  const previous = linkProtocol(target)
  let value = previous.kind === 'internal' ? target : target.substring(target.indexOf(':') + 1)
  if (value.startsWith('//')) value = value.substring(2)
  return choice.prefix + value
}
