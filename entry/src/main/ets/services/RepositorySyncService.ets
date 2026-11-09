import { Context } from '@kit.AbilityKit'
import { AppConfigService } from './AppConfigService'
import { RepoConfig } from '../models/OrgTask'
import { CoreBridgeError, CoreWebDavSyncEvent, NativeCoreService, coreErrorMessage } from './NativeCoreService'

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

// 前台同步会话独立于页面；这里只编排宿主调用并投影 Core 进度，不实现同步规则。
export class RepositorySyncService {
  private static state: RepositorySyncState = emptyRepositorySyncState()
  private static failurePending: boolean = false
  private static generation: number = 0
  private static repositoryCount: number = 0
  private static completedRepositories: number = 0
  private static fileTotal: number = 0
  private static processedFiles: number = 0

  private static snapshot(): RepositorySyncState {
    const state = RepositorySyncService.state
    return { running: state.running, determinate: state.determinate, progress: state.progress,
      message: state.message, error: state.error, needsRepository: state.needsRepository }
  }

  private static publish() {
    AppStorage.setOrCreate<RepositorySyncState>('repositorySync', RepositorySyncService.snapshot())
  }

  // 由当前可见页面领取一次错误，避免共享会话在多页重复弹窗。
  static takeFailure(): RepositorySyncState | undefined {
    if (!RepositorySyncService.failurePending || RepositorySyncService.state.running || !RepositorySyncService.state.error) return undefined
    RepositorySyncService.failurePending = false
    return RepositorySyncService.snapshot()
  }

  static async start(context: Context): Promise<void> {
    if (RepositorySyncService.state.running) return
    console.info('前台文件同步开始')
    RepositorySyncService.failurePending = false
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
    try {
      const config = await AppConfigService.load(context)
      repos = config.repos
      todoDefaults = config.todoDefaults
      if (repos.length === 0) {
        state.error = true
        state.needsRepository = true
        state.message = '请先添加存储库'
        return
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
          }, todoDefaults)
        : NativeCoreService.loadWorkspace(repos, todoDefaults))
      state.progress = 100
      state.determinate = true
      state.message = ''
    } catch (e) {
      state.error = true
      state.message = `同步失败：${coreErrorMessage(e as CoreBridgeError)}`

    } finally {
      state.running = false
      console.info(state.error ? '前台文件同步失败' : '前台文件同步完成')
      RepositorySyncService.failurePending = state.error
      RepositorySyncService.publish()
    }
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
