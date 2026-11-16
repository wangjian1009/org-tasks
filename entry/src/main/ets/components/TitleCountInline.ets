import { util } from '@kit.ArkTS'
import { image } from '@kit.ImageKit'
import { CoreTitleCount } from '../services/NativeCoreService'
import { titleCountColor, titleCountLabel, titleCountValue } from '../ui/TitleCountPresentation'

// 文本内的圆环与数字共用换行流；连接符使圆环和数值保持相邻。
function ringSource(count: CoreTitleCount): image.PixelMap {
  const value = Math.max(0, Math.min(100, titleCountValue(count)))
  const length = 2 * Math.PI * 6
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">` +
    `<circle cx="7" cy="7" r="6" fill="none" stroke="#686763" stroke-width="1.5"/>` +
    `<circle cx="7" cy="7" r="6" fill="none" stroke="${titleCountColor(count)}" stroke-width="1.5" ` +
    `stroke-dasharray="${length * value / 100} ${length}" transform="rotate(-90 7 7)"/></svg>`
  const source = image.createImageSource(new util.TextEncoder().encodeInto(svg).buffer as ArrayBuffer)
  const pixels = source.createPixelMapSync({ desiredSize: { width: 42, height: 42 } })
  source.release()
  return pixels
}

@Builder
export function titleCountInline(count: CoreTitleCount) {
  Span(' ')
  ContainerSpan() {
    Span('\u00A0').fontSize(12)
    ImageSpan(ringSource(count)).width(14).height(14).verticalAlign(ImageSpanAlignment.CENTER)
    Span('\u2060\u00A0' + titleCountLabel(count).split('').join('\u2060') + '\u00A0')
      .fontSize(12).fontWeight(FontWeight.Normal).fontColor(titleCountColor(count))
  }.textBackgroundStyle({ color: '#393E3C', radius: 7 })
}
