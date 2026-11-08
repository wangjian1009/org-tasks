import { common } from '@kit.AbilityKit'
import { KeyboardAvoidMode } from '@kit.ArkUI'
import { util } from '@kit.ArkTS'
import { CaptureDraftStore } from '../services/CaptureDraftStore'
import { CaptureRequest, captureTitle, emptyCaptureRequest } from '../services/CaptureInput'
import { CaptureSaveSession } from '../services/CaptureSaveSession'
import { CaptureSpeechControl, CaptureSpeechEvents } from '../services/CaptureSpeechTypes'
import { UiColor } from '../ui/Theme'

@Entry
@Component
struct Capture {
  @StorageLink('captureRequest') @Watch('requestChanged') request: CaptureRequest = emptyCaptureRequest()
  @StorageLink('captureVisible') @Watch('visibilityChanged') foreground: boolean = true
  @State title: string = ''
  @State saving: boolean = false
  @State saved: boolean = false
  @State closing: boolean = false
  @State listening: boolean = false
  @State message: string = ''
  @State speechMessage: string = ''
  @State panelOffset: number = 100
  private draftId: string = ''
  private revision: number = 0
  private handledRequest: string = ''
  private visible: boolean = false
  private departed: boolean = false
  private draftLoaded: boolean = false
  private pendingVoice: boolean = false
  private speechBase: string = ''
  private speechRequest: number = 0
  private speech: CaptureSpeechControl | undefined = undefined
  private speechStart: Promise<void> = Promise.resolve()
  private draftReady: Promise<void> = Promise.resolve()
  private backend: CaptureSaveSession | undefined = undefined
  private warmUpTimer: number = -1
  private panelTimer: number = -1

  aboutToAppear() {
    this.visible = true
    this.draftId = util.generateRandomUUID()
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    this.receiveRequest()
    this.draftReady = this.restoreDraft()
    // 首屏只依赖轻量存储；native 模块在页面显示后异步加载。
    this.warmUpTimer = setTimeout((): void => {
      if (!this.departed) this.saveSession().warmUp()
    }, 16)
  }

  onPageShow() {
    this.visible = true
    this.resumeVoice()
    this.panelTimer = setTimeout((): void => {
      if (!this.departed && this.visible) {
        this.animatePanel(true).then((): void => { if (!this.request.voice && !this.listening) this.focusTitle() })
      }
    }, 16)
  }
  onPageHide() { this.visible = false; clearTimeout(this.panelTimer); this.stopSpeech(); this.persistTitle() }
  aboutToDisappear() { this.departed = true; this.visible = false; clearTimeout(this.warmUpTimer); clearTimeout(this.panelTimer); this.stopSpeech() }
  onBackPress(): boolean { this.close(); return true }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext()! as common.UIAbilityContext }

  private saveSession(): CaptureSaveSession {
    if (!this.backend) this.backend = new CaptureSaveSession(this.context())
    return this.backend
  }

  visibilityChanged() {
    this.visible = this.foreground
    if (this.foreground) this.resumeVoice()
    else { this.stopSpeech(); this.persistTitle() }
  }

  async restoreDraft() {
    const revision = this.revision
    try {
      const drafts = await CaptureDraftStore.drafts(this.context())
      if (!this.departed && this.revision === revision && !this.title && drafts.length > 0) {
        this.draftId = drafts[0].id
        this.title = drafts[0].title
      }
    } catch (e) { if (!this.departed) this.message = '读取草稿失败，仍可输入并重试保存' }
    finally {
      this.draftLoaded = true
      if (!this.departed) {
        this.resumeVoice()
        if (!this.pendingVoice && !this.listening) this.focusTitle()
      }
    }
  }

  requestChanged() { this.receiveRequest() }

  private receiveRequest() {
    const request = this.request
    if (request.id === this.handledRequest) return
    this.handledRequest = request.id
    if (request.title && request.title !== this.title) {
      // 新内容直接显示；旧标题仍作为独立草稿保留，成功保存后下次可自动恢复。
      this.persistTitle()
      this.revision++
      this.draftId = request.id || util.generateRandomUUID()
      this.title = request.title
      this.persistTitle()
    }
    this.pendingVoice = this.pendingVoice || request.voice
    this.resumeVoice()
    if (!request.voice) this.focusTitle()
  }

  private focusTitle() {
    setTimeout((): void => {
      if (this.visible && !this.departed && !this.listening && !this.saving && !this.closing && this.panelOffset === 0) {
        this.getUIContext().getFocusController().requestFocus('capture_title')
      }
    }, 150)
  }

  private animatePanel(show: boolean): Promise<void> {
    if (this.panelOffset === (show ? 0 : 100)) return Promise.resolve()
    return new Promise<void>((resolve): void => {
      this.getUIContext().animateTo({ duration: show ? 260 : 200, curve: Curve.EaseOut, onFinish: (): void => { resolve() } },
        (): void => { this.panelOffset = show ? 0 : 100 })
    })
  }

  private async persistTitle(): Promise<boolean> {
    if (this.saved || !this.draftId) return true
    try {
      await CaptureDraftStore.putDraft(this.context(), { id: this.draftId, title: this.title })
      return true
    } catch (e) {
      if (!this.departed) this.message = '草稿暂时无法保存，请保持当前窗口并重试'
      return false
    }
  }

  async save() {
    if (this.saving || this.saved || this.closing) return
    this.saving = true
    this.message = ''
    try {
      await this.draftReady
      await this.speechStart
      if (this.listening && this.speech) {
        const completed = await this.speech.finish(this.speechEvents())
        this.listening = false
        if (!completed) return
      }
      if (!this.title.trim()) { this.message = '请输入标题'; return }
      if (!await this.persistTitle()) return
      await this.saveSession().save(this.title)
      this.saved = true
    } catch (e) { this.message = `保存失败：${(e as Error).message || '请重试'}` }
    finally { this.saving = false }
    if (this.saved) await this.close()
  }

  async close() {
    if (this.saving || this.closing) return
    this.closing = true
    clearTimeout(this.warmUpTimer)
    clearTimeout(this.panelTimer)
    try {
      await this.stopSpeech()
      if (this.saved) await CaptureDraftStore.removeDraft(this.context(), this.draftId)
      else if (!await this.persistTitle()) { await this.animatePanel(true); return }
      await this.animatePanel(false)
      await this.context().terminateSelf()
    } catch (e) {
      this.message = this.saved ? '任务已保存，请再次点击面板外关闭' : '保留草稿失败，请重试关闭'
      await this.animatePanel(true)
    }
    finally { this.closing = false }
  }

  private resumeVoice() {
    if (!this.pendingVoice || !this.draftLoaded || !this.visible || this.saving || this.saved || this.closing) return
    this.pendingVoice = false
    this.listening = true
    this.speechBase = this.title.trim()
    this.speechMessage = '正在准备语音…'
    const request = ++this.speechRequest
    this.speechStart = this.startSpeech(request).catch((error: Error): void => {
      if (request !== this.speechRequest || this.departed) return
      this.listening = false
      this.speechMessage = /^(语音|未获得)/.test(error.message) ? error.message : '语音暂时不可用，可以继续输入标题'
      this.focusTitle()
    })
  }

  private async startSpeech(request: number): Promise<void> {
    const module = await import('../services/CaptureSpeechService')
    if (request !== this.speechRequest || this.departed) return
    this.speech = new module.CaptureSpeechService()
    await this.speech.start(this.context(), this.speechEvents())
  }

  private speechEvents(): CaptureSpeechEvents {
    return {
      started: (): void => { this.speechMessage = '正在聆听…' },
      result: (text: string): void => {
        this.revision++
        this.title = captureTitle(`${this.speechBase} ${text}`)
        this.persistTitle()
      },
      completed: (): void => { this.listening = false; this.speechMessage = ''; if (!this.saving) this.focusTitle() },
      failed: (message: string): void => { this.listening = false; this.speechMessage = message; this.focusTitle() }
    }
  }

  private async stopSpeech(): Promise<void> {
    this.speechRequest++
    this.listening = false
    this.speechMessage = ''
    await this.speech?.cancel()
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 捕捉窗口本身保持透明，只让底部录入面板覆盖来源界面。
      Column().id('capture_backdrop').width('100%').height('100%').backgroundColor(Color.Transparent)
        .accessibilityText('关闭并保留草稿').onClick((): void => { this.close() })
      Column({ space: 12 }) {
        TextInput({ text: this.title, placeholder: '记下一件事…' }).id('capture_title').height(60)
          .fontSize(20).fontColor(UiColor.text).placeholderColor(UiColor.secondary).backgroundColor(UiColor.field)
          .borderRadius(12).enterKeyType(EnterKeyType.Done)
          .enabled(!this.saving && !this.saved && !this.closing && !this.listening)
          .onChange((value: string): void => { this.revision++; this.title = value; this.persistTitle() })
          .onSubmit((): void => { this.save() })
        if (this.message || this.speechMessage) {
          Text(this.message || this.speechMessage).width('100%').fontSize(13)
            .fontColor(this.message ? UiColor.error : UiColor.secondary)
        }
        Button(this.saving ? '保存中…' : this.saved ? '已保存' : '保存').id('capture_save')
          .width('100%').height(48).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary)
          .enabled(!this.saving && !this.saved && !this.closing && (this.title.trim().length > 0 || this.listening))
          .onClick((): void => { this.save() })
      }.id('capture_panel').width('100%').constraintSize({ maxWidth: 560 }).padding(16)
        .backgroundColor(UiColor.surface).borderRadius({ topLeft: 20, topRight: 20 })
        .translate({ y: `${this.panelOffset}%` })
        .onClick((): void => {})
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
