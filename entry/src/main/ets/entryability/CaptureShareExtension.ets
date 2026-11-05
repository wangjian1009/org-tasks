import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit'
import { systemShare } from '@kit.ShareKit'
import { captureTitle } from '../services/CaptureInput'

interface ShareCaptureState { sharedTitle: string; shareReady: boolean; shareError: string }

export default class CaptureShareExtension extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    const storage = new LocalStorage({ sharedTitle: '', shareReady: false, shareError: '' } as ShareCaptureState)
    session.loadContent('pages/ShareCapture', storage)
    this.readTitle(want, storage)
  }

  private async readTitle(want: Want, storage: LocalStorage): Promise<void> {
    try {
      const data = await systemShare.getSharedData(want)
      const parts: string[] = []
      for (const record of data.getRecords()) {
        if (record.utd === 'general.plain-text' || record.utd === 'general.text' || record.utd === 'general.hyperlink') {
          const text = record.utd === 'general.hyperlink' ? record.title || record.content || record.uri || '' : record.content || record.title || ''
          if (text) parts.push(text)
          const link = record.content || record.uri || ''
          if (record.utd === 'general.hyperlink' && link && link !== text) parts.push(link)
        }
      }
      const title = captureTitle(parts.join(' '))
      if (!title) throw new Error('请选择文字或链接进行分享')
      storage.set('sharedTitle', title)
      storage.set('shareReady', true)
    } catch (e) { storage.set('shareError', '无法读取分享内容，请选择文字或链接后重试') }
  }
}
