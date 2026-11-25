import { localizedText } from '../ui/LocalizedText'
import { CoreSettings } from 'liborg_tasks_harmony.so'
import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { AppConfig, RepoConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreWebDavSyncEvent, NativeCoreService, SyncRequestSource, coreErrorMessage } from './NativeCoreService'
import { DeviceBadgeService } from './DeviceBadgeService'
import { DataSetManager } from './DataSetManager'
import { NotificationManager } from './NotificationManager'

export enum SyncStartPolicy {
  Reuse = 'Reuse',
  Reject = 'Reject',
  Wait = 'Wait'
}

export interface SyncStartOptions {
  source: SyncRequestSource
  policy: SyncStartPolicy
  repositoryId?: string
  beforeSync?: (config: AppConfig) => Promise<void>
}

export interface SyncCompletion {
  status: 'succeeded' | 'failed'
  message?: string
}

export interface SyncHandle {
  readonly id: number
  readonly source: SyncRequestSource
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
  options: SyncStartOptions
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
  private static changingConfiguration: boolean = false
  private static pending: SyncRequest[] = []
  private static nextId: number = 0
  private static observers: Set<(state: RepositorySyncState) => void> = new Set()

  static runningSync(): SyncHandle | undefined { return RepositorySyncService.active?.handle }

  static async changeConfiguration(change: () => Promise<void>): Promise<void> {
    if (RepositorySyncService.changingConfiguration) throw new Error(localizedText($r('app.string.text_modifying_configuration_please_try_again_later')))
    RepositorySyncService.changingConfiguration = true
    try {
      await RepositorySyncService.active?.handle.completion
      await change()
    } finally {
      RepositorySyncService.changingConfiguration = false
      RepositorySyncService.startPending()
    }
  }

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
    const handle: SyncHandle = { id: ++RepositorySyncService.nextId, source: options.source, completion }
    const request: SyncRequest = { context, handle, options, complete }
    if (active || RepositorySyncService.changingConfiguration) {
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
      completion = await RepositorySyncService.run(request.context, request.options)
    } catch (error) {
      const state = RepositorySyncService.state
      state.running = false
      state.error = true
      state.message = localizedText($r('app.string.text_synchronising_failed_2'), String(coreErrorMessage(error as CoreBridgeError)))
      if (!request.options.repositoryId) RepositorySyncService.failures.push(RepositorySyncService.snapshot())
      RepositorySyncService.publish()
      completion = { status: 'failed', message: state.message }
    }
    RepositorySyncService.active = undefined
    request.complete(completion)
    RepositorySyncService.startPending()
  }

  private static startPending(): void {
    if (RepositorySyncService.active || RepositorySyncService.changingConfiguration) return
    const next = RepositorySyncService.pending.shift()
    if (next) RepositorySyncService.activate(next)
  }

  private static async run(context: Context, options: SyncStartOptions): Promise<SyncCompletion> {
    console.info('文件同步开始')
    const generation = ++RepositorySyncService.generation
    const state = RepositorySyncService.state
    state.running = true
    state.determinate = false
    state.progress = 0
    state.message = localizedText($r('app.string.text_preparing_synchronization'))
    state.error = false
    state.needsRepository = false
    RepositorySyncService.publish()
    let repos: RepoConfig[] = []
    let todoDefaults: string = ''
    let coreSettings: CoreSettings = { additionStates: [] }
    try {
      const config = await AppConfigService.load(context)
      if (options.beforeSync) await options.beforeSync(config)
      const selected = options.repositoryId
        ? config.repos.filter((repo: RepoConfig) => repo.id === options.repositoryId) : config.repos
      if (options.repositoryId && selected.length === 0) throw new Error(localizedText($r('app.string.text_target_repository_does_not_exist')))
      const pending = selected.filter((repo: RepoConfig) => repo.webdavCleanupPending)
      if (pending.length > 0) {
        const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
        const activeRepos = await workspace.repos()
        for (const repository of pending) {
          const repo = activeRepos.find(item => item.rootDirectory === repository.rootDirectory)
          if (!repo) throw new Error(localizedText($r('app.string.text_unable_to_locate_repository_pending_cleanup_try')))
          await workspace.removeSyncPolicy(repo.id)
        }
        const current = await AppConfigService.load(context)
        for (const repository of pending) {
          const saved = current.repos.find(item => item.id === repository.id && item.rootDirectory === repository.rootDirectory)
          if (saved?.webdavCleanupPending && !saved.webdavEnabled) saved.webdavCleanupPending = undefined
        }
        await AppConfigService.save(context, current)
      }
      repos = config.repos
      todoDefaults = config.todoDefaults
      coreSettings = config.coreSettings
      if (repos.length === 0) {
        state.error = true
        state.needsRepository = true
        state.message = localizedText($r('app.string.text_add_repository_first_please'))
        return { status: 'failed', message: state.message }
      }
      RepositorySyncService.repositoryCount = selected.filter((repo: RepoConfig) => repo.webdavEnabled).length
      RepositorySyncService.completedRepositories = 0
      RepositorySyncService.fileTotal = 0
      RepositorySyncService.processedFiles = 0
      state.message = RepositorySyncService.repositoryCount > 0 ? localizedText($r('app.string.text_syncing_webdav')) : localizedText($r('app.string.text_reading_local_files'))
      RepositorySyncService.publish()
      await (RepositorySyncService.repositoryCount > 0
        ? NativeCoreService.syncWorkspaceWebDav(repos,
          (event: CoreWebDavSyncEvent) => {
            if (generation === RepositorySyncService.generation) RepositorySyncService.updateProgress(event)
          }, todoDefaults, coreSettings, options.source, options.repositoryId)
        : NativeCoreService.workspaceFor(repos, todoDefaults, coreSettings))
      if (options.source === 'manual' &&
        (RepositorySyncService.repositoryCount === 0 || NotificationManager.hasMissingRepository())) {
        await DataSetManager.reloadRepositories()
      }
      state.progress = 100
      state.determinate = true
      state.message = ''
    } catch (e) {
      state.error = true
      state.message = localizedText($r('app.string.text_synchronising_failed_2'), String(coreErrorMessage(e as CoreBridgeError)))

    } finally {
      state.running = false
      console.info(state.error ? '文件同步失败' : '文件同步完成')
      if (state.error && !options.repositoryId) RepositorySyncService.failures.push(RepositorySyncService.snapshot())
      RepositorySyncService.publish()
      try { await DeviceBadgeService.refresh(context, true) }
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
        state.message = localizedText($r('app.string.text_syncing_webdav'))
        break
      case 'listingStarted':
        state.message = localizedText($r('app.string.text_reading_webdav_file_list'))
        break
      case 'listed':
        state.message = localizedText($r('app.string.text_remote_files_found'), String(event.files))
        break
      case 'fileStarted':
        RepositorySyncService.fileTotal = event.total
        RepositorySyncService.processedFiles = event.index
        state.determinate = event.total > 0
        state.message = localizedText($r('app.string.text_syncing_2'), String(event.index + 1), String(event.total), String(event.path))
        break
      case 'fileProcessed':
        ++RepositorySyncService.processedFiles
        state.message = localizedText($r('app.string.text_processed'), String(event.path))
        break
      case 'finished':
        if (event.result === 'succeeded') ++RepositorySyncService.completedRepositories
        state.message = localizedText($r('app.string.text_finishing_sync'))
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
