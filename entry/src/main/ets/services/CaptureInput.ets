import { Want } from '@kit.AbilityKit'
import { url, util } from '@kit.ArkTS'

export interface CaptureRequest { id: string; title: string; voice: boolean }

export function emptyCaptureRequest(): CaptureRequest {
  return { id: '', title: '', voice: false }
}

// 外部文本只整理为单行输入；任务语义和 Org 校验仍由 Core 负责。
export function captureTitle(text: string): string {
  return text.replace(/[\s\x00-\x1f\x7f]+/g, ' ').trim()
}

export function captureRequest(want: Want): CaptureRequest {
  let title = typeof want.parameters?.title === 'string' ? want.parameters.title : ''
  let voice = want.parameters?.captureMode === 'voice'
  if (want.uri) {
    try {
      const link = new url.URL(want.uri)
      if (link.protocol === 'orgtasks:' && link.hostname === 'capture') {
        title = link.params.get('title') || title
        voice = voice || link.params.get('mode') === 'voice'
      }
    } catch (e) { /* 无法解析的链接仍可进入空白捕捉，不丢弃显式标题。 */ }
  }
  return { id: util.generateRandomUUID(), title: captureTitle(title), voice }
}
