import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { speechRecognizer } from '@kit.CoreSpeechKit'
import { audio } from '@kit.AudioKit'
import { util } from '@kit.ArkTS'
import { CaptureSpeechControl, CaptureSpeechEvents } from './CaptureSpeechTypes'

export class CaptureSpeechError extends Error {}

// 音频只在内存中按平台要求分帧传入识别引擎，不保存录音。
export class CaptureSpeechService implements CaptureSpeechControl {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined
  private microphone: audio.AudioCapturer | undefined = undefined
  private sessionId: string = ''
  private generation: number = 0
  private buffer: Uint8Array = new Uint8Array(0)
  private timeout: number = -1
  private finishing: boolean = false
  private sessionResult: Promise<boolean> = Promise.resolve(false)
  private resolveSession: (succeeded: boolean) => void = (succeeded: boolean): void => {}
  private sessionStarted: Promise<void> = Promise.resolve()
  private resolveStart: () => void = (): void => {}

  async start(context: common.UIAbilityContext, events: CaptureSpeechEvents): Promise<void> {
    await this.cancel()
    const generation = this.generation
    let authResults: number[]
    try {
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE'])
      authResults = permission.authResults
    } catch (error) { throw new CaptureSpeechError('无法请求麦克风权限，可以继续输入标题') }
    if (generation !== this.generation) return
    if (authResults[0] !== 0) throw new CaptureSpeechError('未获得麦克风权限，可以继续输入标题')
    let engine: speechRecognizer.SpeechRecognitionEngine
    try { engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 }) }
    catch (e) {
      if (generation !== this.generation) return
      try { engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 0 }) }
      catch (e) { throw new CaptureSpeechError('语音服务暂时不可用，可以继续输入标题') }
    }
    if (generation !== this.generation) { engine.shutdown(); return }
    this.engine = engine
    try {
      const microphone = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
      })
      if (generation !== this.generation) { await microphone.release(); return }
      this.microphone = microphone
      this.sessionId = util.generateRandomUUID()
      this.sessionResult = new Promise<boolean>((resolve: (succeeded: boolean) => void): void => { this.resolveSession = resolve })
      this.sessionStarted = new Promise<void>((resolve: () => void): void => { this.resolveStart = resolve })
      const session = this.sessionId
      let finalText = ''
      engine.setListener({
        onStart: (id: string, message: string): void => {
          if (id !== this.sessionId) return
          microphone.start().then((): void => {
            if (id !== this.sessionId) return
            events.started()
            this.resolveStart()
          }).catch((): void => { this.fail(events, '麦克风暂时不可用，可以继续输入标题') })
        },
        onEvent: (id: string, code: number, message: string): void => {},
        onResult: (id: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (id !== this.sessionId) return
          events.result(finalText + result.result)
          if (result.isFinal) finalText += result.result
          if (result.isLast) this.complete(events)
        },
        onComplete: (id: string, message: string): void => { if (id === this.sessionId) this.complete(events) },
        onError: (id: string, code: number, message: string): void => {
          if (id === this.sessionId) this.fail(events, '语音识别暂时不可用，可以继续输入标题')
        }
      })
      microphone.on('readData', (data: ArrayBuffer): void => {
        if (session !== this.sessionId || this.finishing) return
        const incoming = new Uint8Array(data)
        const combined = new Uint8Array(this.buffer.length + incoming.length)
        combined.set(this.buffer)
        combined.set(incoming, this.buffer.length)
        let offset = 0
        try {
          while (offset + 640 <= combined.length) {
            engine.writeAudio(session, combined.slice(offset, offset + 640))
            offset += 640
          }
          this.buffer = combined.slice(offset)
        } catch (e) { this.fail(events, '语音识别中断，可以继续编辑已识别的标题') }
      })
      engine.startListening({ sessionId: session,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 } })
      if (this.sessionId === session) this.timeout = setTimeout((): void => { this.finish(events) }, 60000)
      await this.sessionStarted
    } catch (e) { await this.cancel(); throw new CaptureSpeechError('语音识别暂时不可用，可以继续输入标题') }
  }

  async finish(events: CaptureSpeechEvents): Promise<boolean> {
    const result = this.sessionResult
    if (this.finishing) return await result
    if (!this.engine || !this.sessionId) return await result
    this.finishing = true
    clearTimeout(this.timeout)
    try {
      await this.microphone?.stop()
      if (!this.engine || !this.sessionId) return await result
      if (this.buffer.length > 0) {
        const frame = new Uint8Array(640)
        frame.set(this.buffer)
        this.engine.writeAudio(this.sessionId, frame)
      }
      const session = this.sessionId
      this.engine.finish(session)
      if (this.sessionId === session) this.timeout = setTimeout((): void => { this.complete(events) }, 5000)
    } catch (e) { this.fail(events, '语音识别已结束，请检查标题后保存') }
    return await result
  }

  private complete(events: CaptureSpeechEvents): void {
    const generation = this.generation + 1
    this.cancel(true).then((): void => { if (generation === this.generation) events.completed() })
  }

  private fail(events: CaptureSpeechEvents, message: string): void {
    const generation = this.generation + 1
    this.cancel().then((): void => { if (generation === this.generation) events.failed(message) })
  }

  async cancel(succeeded: boolean = false): Promise<void> {
    this.generation++
    clearTimeout(this.timeout)
    const engine = this.engine
    const microphone = this.microphone
    const session = this.sessionId
    const resolveSession = this.resolveSession
    const resolveStart = this.resolveStart
    this.resolveSession = (succeeded: boolean): void => {}
    this.resolveStart = (): void => {}
    this.engine = undefined
    this.microphone = undefined
    this.sessionId = ''
    this.finishing = false
    this.buffer = new Uint8Array(0)
    if (engine) {
      try { if (session) engine.cancel(session) } catch (e) {}
      try { engine.shutdown() } catch (e) {}
    }
    if (microphone) {
      try { microphone.off('readData'); await microphone.release() } catch (e) {}
    }
    resolveSession(succeeded)
    resolveStart()
  }
}
