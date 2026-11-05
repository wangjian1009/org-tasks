import { Context } from '@kit.AbilityKit'

export interface CaptureBackend {
  prepare: (context: Context) => Promise<void>
  save: (context: Context, title: string) => Promise<void>
}

export type CaptureBackendLoader = () => Promise<CaptureBackend>

async function loadCaptureBackend(): Promise<CaptureBackend> {
  const module = await import('./CaptureService')
  return {
    prepare: async (context: Context): Promise<void> => { await module.CaptureService.prepare(context) },
    save: async (context: Context, title: string): Promise<void> => { await module.CaptureService.save(context, title) }
  }
}

// 页面先绘制，初始化失败只在用户保存时显示，并允许下一次保存重试。
export class CaptureSaveSession {
  private readonly context: Context
  private readonly loader: CaptureBackendLoader
  private initialization: Promise<CaptureBackend> | undefined = undefined

  constructor(context: Context, loader: CaptureBackendLoader = loadCaptureBackend) {
    this.context = context
    this.loader = loader
  }

  warmUp(): void { this.initialize() }

  private initialize(): Promise<CaptureBackend> {
    if (!this.initialization) {
      this.initialization = this.loader().then(async (backend: CaptureBackend): Promise<CaptureBackend> => {
        await backend.prepare(this.context)
        return backend
      })
      this.initialization.catch((): void => {})
    }
    return this.initialization
  }

  async save(title: string): Promise<void> {
    if (!title.trim()) throw new Error('请输入标题')
    let backend: CaptureBackend
    try { backend = await this.initialize() }
    catch (e) { this.initialization = undefined; throw new Error((e as Error).message || '初始化失败，请重试保存') }
    await backend.save(this.context, title)
  }
}
