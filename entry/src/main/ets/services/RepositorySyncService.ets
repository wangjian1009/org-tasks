import { CoreSettings, SyncTriggerReason } from 'liborg_tasks_harmony.so'
import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { RepoConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreWebDavSyncEvent, NativeCoreService, coreErrorMessage } from './NativeCoreService'
import { DeviceBadgeService } from './DeviceBadgeService'

export enum SyncStartPolicy {
  Reuse = 'Reuse',
  Reject = 'Reject',
  Wait = 'Wait'
}

export interface SyncStartOptions {
  triggerReason: SyncTriggerReason
  policy: SyncStartPolicy
}

export interface SyncCompletion {
  status: 'succeeded' | 'failed'
  message?: string
}

export interface SyncHandle {
  readonly id: number
  readonly triggerReason: SyncTriggerReason
  readonly completion: Promise<SyncCompletion>
}

export interface SyncAccepted {
  kind: 'started' | 'reused' | 'queued'
  handle: SyncHandle
}

export interface SyncRejected {
  kind: 'rejected'
  active: SyncHandle
}

export type SyncStartResult = SyncAccepted | SyncRejected

interface SyncRequest {
  context: Context
  handle: SyncHandle
  complete: (completion: SyncCompletion) => void
}

export interface RepositorySyncState {
  running: boolean
  determinate: boolean
  progress: number
  message: string
  error: boolean
  needsRepository: boolean
}

export function emptyRepositorySyncState(): RepositorySyncState {
  return { running: false, determinate: false, progress: 0, message: '', error: false,
    needsRepository: false }
}

// 同步会话独立于页面和前后台；这里只编排宿主调用并投影 Core 进度。
export class RepositorySyncService {
  private static state: RepositorySyncState = emptyRepositorySyncState()
  private static failures: RepositorySyncState[] = []
  private static generation: number = 0
  private static repositoryCount: number = 0
  private static completedRepositories: number = 0
  private static fileTotal: number = 0
  private static processedFiles: number = 0
  private static active: SyncRequest | undefined = undefined
  private static pending: SyncRequest[] = []
  private static nextId: number = 0
  private static observers: Set<(state: RepositorySyncState) => void> = new Set()

  static runningSync(): SyncHandle | undefined { return RepositorySyncService.active?.handle }

  static watch(observer: (state: RepositorySyncState) => void): void {
    RepositorySyncService.observers.add(observer)
    observer(RepositorySyncService.snapshot())
  }

  static stopWatching(observer: (state: RepositorySyncState) => void): void {
    RepositorySyncService.observers.delete(observer)
  }

  private static snapshot(): RepositorySyncState {
    const state = RepositorySyncService.state
    return { running: state.running, determinate: state.determinate, progress: state.progress,
      message: state.message, error: state.error, needsRepository: state.needsRepository }
  }

  private static publish() {
    AppStorage.setOrCreate<RepositorySyncState>('repositorySync', RepositorySyncService.snapshot())
    RepositorySyncService.observers.forEach((observer: (state: RepositorySyncState) => void): void => {
      observer(RepositorySyncService.snapshot())
    })
  }

  // 由当前可见页面领取一次错误，避免共享会话在多页重复弹窗。
  static takeFailure(): RepositorySyncState | undefined {
    return RepositorySyncService.failures.shift()
  }

  static start(context: Context, options: SyncStartOptions): SyncStartResult {
    const active = RepositorySyncService.active
    if (active && options.policy === SyncStartPolicy.Reuse) return { kind: 'reused', handle: active.handle }
    if (active && options.policy === SyncStartPolicy.Reject) return { kind: 'rejected', active: active.handle }
    let complete: (completion: SyncCompletion) => void = (_completion: SyncCompletion): void => {}
    const completion = new Promise<SyncCompletion>((resolve): void => { complete = resolve })
    const handle: SyncHandle = { id: ++RepositorySyncService.nextId, triggerReason: options.triggerReason, completion }
    const request: SyncRequest = { context, handle, complete }
    if (active) {
      RepositorySyncService.pending.push(request)
      return { kind: 'queued', handle }
    }
    RepositorySyncService.activate(request)
    return { kind: 'started', handle }
  }

  private static activate(request: SyncRequest): void {
    // 先保留当前会话，再异步执行，订阅回调中的请求也遵守相同策略。
    RepositorySyncService.active = request
    Promise.resolve().then((): Promise<void> => RepositorySyncService.execute(request))
  }

  private static async execute(request: SyncRequest): Promise<void> {
    let completion: SyncCompletion
    try {
      completion = await RepositorySyncService.run(request.context, request.handle.triggerReason)
    } catch (error) {
      const state = RepositorySyncService.state
      state.running = false
      state.error = true
      state.message = `同步失败：${coreErrorMessage(error as CoreBridgeError)}`
      RepositorySyncService.failures.push(RepositorySyncService.snapshot())
      RepositorySyncService.publish()
      completion = { status: 'failed', message: state.message }
    }
    RepositorySyncService.active = undefined
    request.complete(completion)
    const next = RepositorySyncService.pending.shift()
    if (next) RepositorySyncService.activate(next)
  }

  private static async run(context: Context, triggerReason: SyncTriggerReason): Promise<SyncCompletion> {
    console.info('文件同步开始')
    const generation = ++RepositorySyncService.generation
    const state = RepositorySyncService.state
    state.running = true
    state.determinate = false
    state.progress = 0
    state.message = '正在准备同步…'
    state.error = false
    state.needsRepository = false
    RepositorySyncService.publish()
    let repos: RepoConfig[] = []
    let todoDefaults: string = ''
    let coreSettings: CoreSettings = { additionStates: [] }
    try {
      const config = await AppConfigService.load(context)
      repos = config.repos
      todoDefaults = config.todoDefaults
      coreSettings = config.coreSettings
      if (repos.length === 0) {
        state.error = true
        state.needsRepository = true
        state.message = '请先添加存储库'
        return { status: 'failed', message: state.message }
      }
      RepositorySyncService.repositoryCount = repos.filter((repo: RepoConfig) => repo.webdavEnabled).length
      RepositorySyncService.completedRepositories = 0
      RepositorySyncService.fileTotal = 0
      RepositorySyncService.processedFiles = 0
      state.message = RepositorySyncService.repositoryCount > 0 ? '正在同步 WebDAV…' : '正在读取本地文件…'
      RepositorySyncService.publish()
      await (RepositorySyncService.repositoryCount > 0
        ? NativeCoreService.syncWorkspaceWebDav(repos,
          (event: CoreWebDavSyncEvent) => {
            if (generation === RepositorySyncService.generation) RepositorySyncService.updateProgress(event)
          }, todoDefaults, coreSettings, triggerReason)
        : NativeCoreService.loadWorkspace(repos, todoDefaults, coreSettings))
      state.progress = 100
      state.determinate = true
      state.message = ''
    } catch (e) {
      state.error = true
      state.message = `同步失败：${coreErrorMessage(e as CoreBridgeError)}`

    } finally {
      state.running = false
      console.info(state.error ? '文件同步失败' : '文件同步完成')
      if (state.error) RepositorySyncService.failures.push(RepositorySyncService.snapshot())
      RepositorySyncService.publish()
      try { await DeviceBadgeService.refresh(context) }
      catch (_) { console.error('同步后刷新角标失败') }
    }
    return state.error ? { status: 'failed', message: state.message } : { status: 'succeeded' }
  }

  private static updateProgress(event: CoreWebDavSyncEvent) {
    const state = RepositorySyncService.state
    if (!state.running) return
    switch (event.type) {
      case 'started':
        RepositorySyncService.fileTotal = 0
        RepositorySyncService.processedFiles = 0
        state.determinate = false
        state.message = '正在同步 WebDAV…'
        break
      case 'listingStarted':
        state.message = '正在读取 WebDAV 文件列表…'
        break
      case 'listed':
        state.message = `已发现 ${event.files} 个远端文件`
        break
      case 'fileStarted':
        RepositorySyncService.fileTotal = event.total
        RepositorySyncService.processedFiles = event.index
        state.determinate = event.total > 0
        state.message = `正在同步 ${event.index + 1}/${event.total}：${event.path}`
        break
      case 'fileProcessed':
        ++RepositorySyncService.processedFiles
        state.message = `已处理 ${event.path}`
        break
      case 'finished':
        if (event.result === 'succeeded') ++RepositorySyncService.completedRepositories
        state.message = '正在整理同步结果…'
        break
      default: return
    }
    const fraction = RepositorySyncService.fileTotal > 0
      ? Math.min(1, RepositorySyncService.processedFiles / RepositorySyncService.fileTotal) : 0
    const completed = RepositorySyncService.completedRepositories + (event.type === 'finished' ? 0 : fraction)
    state.progress = Math.max(state.progress, Math.min(99,
      Math.floor(completed / Math.max(1, RepositorySyncService.repositoryCount) * 100)))
    RepositorySyncService.publish()
  }
}
